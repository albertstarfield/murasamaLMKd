with Ada.Text_IO;
with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Directories;
with Murasama_Types; use Murasama_Types;

package body Murasama_Telemetry is
   pragma SPARK_Mode (Off);

   procedure Export_Telemetry (
      Free_MB                 : Long_Float;
      Wired_MB                : Long_Float;
      Pressure_Level          : Integer;
      Wired_Velocity          : Long_Float;
      Pageins_Per_Sec         : unsigned_long_long;
      Decomp_Per_Sec          : unsigned_long_long;
      Front_PID               : Integer;
      Front_Name              : String;
      Mitigation_Active       : Boolean
   ) is
      Now  : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      Time_Str : constant String := Ada.Calendar.Formatting.Image (Now);

      -- Mock climate/weather formulas derived from system activity (parities with environmental expectations)
      -- Let's derive mock ambient metrics from memory pressure
      Mock_Pressure : constant Long_Float := 1013.25 - (Long_Float (Pressure_Level) * 2.5);
      Mock_Temp     : constant Long_Float := 20.0 + (Long_Float (Pageins_Per_Sec) / 100.0) + (Long_Float (Pressure_Level) * 1.5);
      Mock_Humid    : constant Long_Float := 50.0 + (Long_Float (Decomp_Per_Sec) / 500.0);

      -- Format helpers for floats
      function F_Str (V : Long_Float) return String is
         Img : constant String := Long_Float'Image (V);
         Start : Positive := Img'First;
      begin
         if Img (Img'First) = ' ' then
            Start := Img'First + 1;
         end if;
         return Img (Start .. Img'Last);
      end F_Str;

      -- Format helpers for integers
      function I_Str (V : Integer) return String is
         Img : constant String := Integer'Image (V);
         Start : Positive := Img'First;
      begin
         if Img (Img'First) = ' ' then
            Start := Img'First + 1;
         end if;
         return Img (Start .. Img'Last);
      end I_Str;

      -- Format helpers for uint64
      function U_Str (V : unsigned_long_long) return String is
         Img : constant String := unsigned_long_long'Image (V);
         Start : Positive := Img'First;
      begin
         if Img (Img'First) = ' ' then
            Start := Img'First + 1;
         end if;
         return Img (Start .. Img'Last);
      end U_Str;

      procedure Write_To_Path (Path : String) is
         Out_File : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Path);
         Ada.Text_IO.Put_Line (Out_File, "{");
         Ada.Text_IO.Put_Line (Out_File, "  ""timestamp"": """ & Time_Str & """,");
         Ada.Text_IO.Put_Line (Out_File, "  ""memory"": {");
         Ada.Text_IO.Put_Line (Out_File, "    ""free_mb"": " & F_Str (Free_MB) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""wired_mb"": " & F_Str (Wired_MB) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""pressure_level"": " & I_Str (Pressure_Level) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""velocity_mb_s"": " & F_Str (Wired_Velocity));
         Ada.Text_IO.Put_Line (Out_File, "  },");
         Ada.Text_IO.Put_Line (Out_File, "  ""thrashing"": {");
         Ada.Text_IO.Put_Line (Out_File, "    ""pageins_per_sec"": " & U_Str (Pageins_Per_Sec) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""decomp_per_sec"": " & U_Str (Decomp_Per_Sec) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""is_mitigating"": " & (if Mitigation_Active then "true" else "false"));
         Ada.Text_IO.Put_Line (Out_File, "  },");
         Ada.Text_IO.Put_Line (Out_File, "  ""active_app"": {");
         Ada.Text_IO.Put_Line (Out_File, "    ""pid"": " & I_Str (Front_PID) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""name"": """ & Front_Name & """");
         Ada.Text_IO.Put_Line (Out_File, "  },");
         Ada.Text_IO.Put_Line (Out_File, "  ""weather"": {");
         Ada.Text_IO.Put_Line (Out_File, "    ""atmospheric_pressure_hPa"": " & F_Str (Mock_Pressure) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""temperature_c"": " & F_Str (Mock_Temp) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""humidity_pct"": " & F_Str (Mock_Humid));
         Ada.Text_IO.Put_Line (Out_File, "  }");
         Ada.Text_IO.Put_Line (Out_File, "}");
         Ada.Text_IO.Close (Out_File);
      exception
         when others =>
            if Ada.Text_IO.Is_Open (Out_File) then
               Ada.Text_IO.Close (Out_File);
            end if;
      end Write_To_Path;

   begin
      -- Write telemetry for the ML predictor (EARU_DATA_FILE = /Volumes/EARU_dataIO/EARU_data.dat)
      Write_To_Path (EARU_DATA_FILE);
   end Export_Telemetry;

begin
   -- Ensure parent directory exists once at package initialization
   begin
      if not Ada.Directories.Exists ("/usr/local/murasamaLMKd/murasamalmk_daemon") then
         Ada.Directories.Create_Directory ("/usr/local/murasamaLMKd/murasamalmk_daemon");
      end if;
   exception
      when others =>
         null;
   end;
end Murasama_Telemetry;
