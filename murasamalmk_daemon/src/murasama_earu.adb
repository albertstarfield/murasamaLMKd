--  EARU sensor bridge body. Bounded reads only: a 200 KB buffer covers the
--  ~57 KB meteo JSON, and every scan stays inside that buffer.
with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Murasama_Log;
with Murasama_Types;

package body Murasama_EARU is

   Volume      : constant String := "/Volumes/EARU_dataIO";
   Meteo_Path  : constant String := Volume & "/EARU_meteo.dat";
   Buffer_Size : constant := 200_000;

   --  Extract "key": <number> from a bounded JSON slice. No full JSON parser
   --  is needed: the meteo producer writes a flat "current" object.
   procedure Parse_Number
     (Source : String;
      Key    : String;
      Value  : out Long_Float;
      Found  : out Boolean)
   is
      Pattern : constant String := """" & Key & """:";
      K       : constant Natural := Ada.Strings.Fixed.Index (Source, Pattern);
      P       : Natural;
      N       : Natural := 0;
      Buf     : String (1 .. 64) := (others => ' ');
   begin
      Value := 0.0;
      Found := False;
      if K = 0 then
         return;
      end if;

      P := K + Pattern'Length;
      while P <= Source'Last and then Source (P) = ' ' loop
         P := P + 1;
      end loop;

      while P <= Source'Last and then N < Buf'Last loop
         declare
            Ch : constant Character := Source (P);
         begin
            if Ch in '0' .. '9'
              or else Ch = '+' or else Ch = '-' or else Ch = '.'
              or else Ch = 'e' or else Ch = 'E'
            then
               N := N + 1;
               Buf (N) := Ch;
            else
               exit;
            end if;
         end;
         P := P + 1;
      end loop;

      if N = 0 then
         return;
      end if;
      begin
         Value := Long_Float'Value (Buf (1 .. N));
         Found := True;
      exception
         when others =>
            Found := False;
      end;
   end Parse_Number;

   function Read_Scalar (Name : String; Default : Long_Float) return Long_Float is
      Path : constant String := Volume & "/" & Name;
      F    : Ada.Text_IO.File_Type;
      Line : String (1 .. 128);
      Last : Natural;
   begin
      if not Ada.Directories.Exists (Path) then
         Murasama_Log.Warn ("[EARU] sensor file absent: " & Name);
         return Default;
      end if;
      Ada.Text_IO.Open (F, Ada.Text_IO.In_File, Path);
      Ada.Text_IO.Get_Line (F, Line, Last);
      Ada.Text_IO.Close (F);
      if Last = 0 then
         return Default;
      end if;
      return Long_Float'Value (Line (1 .. Last));
   exception
      when E : others =>
         if Ada.Text_IO.Is_Open (F) then
            Ada.Text_IO.Close (F);
         end if;
         Murasama_Log.Warn ("[EARU] cannot parse " & Name & ": " &
                            Ada.Exceptions.Exception_Message (E));
         return Default;
   end Read_Scalar;

   procedure Read (S : out EARU_Sensors) is
      Buf  : String (1 .. Buffer_Size) := (others => ' ');
      Last : Natural := 0;
      F    : Ada.Text_IO.File_Type;
      Ch   : Character;
   begin
      S := (others => <>);

      if Ada.Directories.Exists (Meteo_Path) then
         begin
            Ada.Text_IO.Open (F, Ada.Text_IO.In_File, Meteo_Path);
            while not Ada.Text_IO.End_Of_File (F) and then Last < Buf'Last loop
               Ada.Text_IO.Get (F, Ch);
               Last := Last + 1;
               Buf (Last) := Ch;
            end loop;
            Ada.Text_IO.Close (F);
         exception
            when E : others =>
               if Ada.Text_IO.Is_Open (F) then
                  Ada.Text_IO.Close (F);
               end if;
               Murasama_Log.Error ("[EARU] meteo read failed: " &
                                   Ada.Exceptions.Exception_Message (E));
               Last := 0;
         end;
      else
         Murasama_Log.Warn ("[EARU] meteo volume not mounted: " & Meteo_Path);
      end if;

      if Last > 0 then
         declare
            Text : constant String := Buf (1 .. Last);
            Pos  : constant Natural :=
              Ada.Strings.Fixed.Index (Text, """current"":");
         begin
            if Pos > 0 then
               declare
                  Hi  : constant Natural := Natural'Min (Text'Last, Pos + 4096);
                  Win : constant String := Text (Pos .. Hi);
                  Found : Boolean;
                  V     : Long_Float;
                  All_OK : Boolean := True;
               begin
                  Parse_Number (Win, "temperature_2m", S.Temperature_C, Found);
                  if not Found then
                     All_OK := False;
                  end if;
                  Parse_Number (Win, "apparent_temperature", S.Apparent_C, Found);
                  if not Found then
                     All_OK := False;
                  end if;
                  Parse_Number (Win, "relative_humidity_2m", S.Humidity_Pct, Found);
                  if not Found then
                     All_OK := False;
                  end if;
                  Parse_Number (Win, "pressure_msl", S.Pressure_HPa, Found);
                  if not Found then
                     All_OK := False;
                  end if;
                  Parse_Number (Win, "surface_pressure", S.Surface_HPa, Found);
                  if not Found then
                     All_OK := False;
                  end if;
                  Parse_Number (Win, "wind_speed_10m", S.Wind_Kmh, Found);
                  if not Found then
                     All_OK := False;
                  end if;
                  Parse_Number (Win, "wind_direction_10m", S.Wind_Deg, Found);
                  if not Found then
                     All_OK := False;
                  end if;
                  Parse_Number (Win, "cloud_cover", S.Cloud_Pct, Found);
                  if not Found then
                     All_OK := False;
                  end if;
                  Parse_Number (Win, "weather_code", V, Found);
                  if not Found then
                     All_OK := False;
                  end if;
                  if Found then
                     S.Weather_Code := Integer (Long_Float'Rounding (V));
                  end if;
                  S.Read_OK := All_OK;
               end;
            else
               Murasama_Log.Warn ("[EARU] meteo JSON has no ""current"" block");
            end if;
         end;
      end if;

      if not Murasama_Types.EARU_Usable
        (S.Read_OK, S.Temperature_C, S.Humidity_Pct, S.Pressure_HPa)
      then
         Murasama_Log.Warn
           ("[EARU] implausible/missing weather - telemetry will mark source=fallback");
      end if;

      S.CPU_Temp_C   := Read_Scalar ("sensor_temp_TCMz.dat", 0.0);
      S.Fan0_RPM     := Read_Scalar ("sensor_fan_F0Ac.dat", 0.0);
      S.Turbo_Mode   := Read_Scalar ("sensor_TURBO_MODE.dat", 0.0);
      S.Power_Day_Wh := Read_Scalar ("sensor_power_day_wh.dat", 0.0);
   end Read;

end Murasama_EARU;
