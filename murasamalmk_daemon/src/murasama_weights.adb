with Ada.Text_IO;
-- FIX: Removed unused 'with Ada.IO_Exceptions'.
-- REASON: No exceptions from Ada.IO_Exceptions are referenced in this body.
--         (Warning: -gnatwu)
with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Fixed;
-- FIX: The with/use clause for Murasama_Types is needed here (in the body) since
--         types like Process_Name_String, MAX_NAME_LEN, Weights_Array are used.
with Murasama_Types; use Murasama_Types;
with Murasama_Log;

package body Murasama_Weights is
   pragma SPARK_Mode (Off);

   -- -------------------------------------------------------------------------
   -- DIAGNOSTIC CHANNEL (audit RED-6 de-silencing):
   -- ARM 9.5 forbids potentially-blocking operations inside protected actions,
   -- and Murasama_Log performs Text_IO (blocking). Therefore protected
   -- operations NEVER log directly; they record a diagnostic code + message,
   -- and the unprotected public wrappers report it via Murasama_Log AFTER the
   -- protected action completes. Same-object serialization makes this race-free.
   -- -------------------------------------------------------------------------
   Diag_None          : constant Natural := 0;
   Diag_Load_Open     : constant Natural := 1;
   Diag_Save_Create   : constant Natural := 2;
   Diag_Table_Full    : constant Natural := 3;
   Diag_Bad_Value     : constant Natural := 4;
   Diag_Load_Read     : constant Natural := 5;
   Diag_Comma_Name    : constant Natural := 6;

   -- Helper to convert String to Process_Name_String
   function To_Process_Name (Str : String) return Process_Name_String is
      Res : Process_Name_String := (others => ' ');
      Len : constant Natural := Natural'Min (Str'Length, MAX_NAME_LEN);
   begin
      if Len > 0 then
         Res (1 .. Len) := Process_Name_String (Str (Str'First .. Str'First + Len - 1));
      end if;
      return Res;
   end To_Process_Name;

   -- Helper to compare String with Process_Name_String of a given length
   function Name_Equals (P_Name : Process_Name_String; P_Len : Natural; Str : String) return Boolean is
      Len : constant Natural := Natural'Min (Str'Length, MAX_NAME_LEN);
   begin
      if P_Len /= Len then
         return False;
      end if;
      return P_Name (1 .. P_Len) = Process_Name_String (Str (Str'First .. Str'First + Len - 1));
   end Name_Equals;

   -- FIX (audit YELLOW-29, ingest side): a comma inside a process name would
   -- corrupt the CSV round-trip (name,value). Names containing commas are
   -- rejected at every ingestion point instead of silently breaking Save.
   function Contains_Comma (S : String) return Boolean is
   begin
      return Ada.Strings.Fixed.Index (S, ",") > 0;
   end Contains_Comma;

   protected Weights_Store is
      procedure Init;
      procedure Load_From_File (Path : String);
      procedure Save_To_File (Path : String);
      procedure Increment (Name_Str : String);
      procedure Decrement (Changed : out Boolean);
      function Get (Name_Str : String) return Natural;
      -- Diagnostic channel: atomically returns AND clears pending issue.
      procedure Take_Diag (Code : out Natural; Msg : out String; Msg_Last : out Natural);
   private
      List : Weights_Array;
      Size : Natural range 0 .. 128 := 0;

      Diag_Code : Natural := Diag_None;   -- highest-severity pending issue
      Diag_Msg  : String (1 .. 192) := (others => ' ');
      Diag_Len  : Natural := 0;

      procedure Set_Diag (Code : Natural; Msg : String);
   end Weights_Store;

   protected body Weights_Store is

      -- Bounded copy; never raises; keeps FIRST recorded issue per cycle
      -- (later lower-priority issues during the same op do not overwrite).
      procedure Set_Diag (Code : Natural; Msg : String) is
         Take : constant Natural := Natural'Min (Msg'Length, Diag_Msg'Length);
      begin
         if Diag_Code = Diag_None then
            Diag_Code := Code;
            Diag_Msg (1 .. Take) := Msg (Msg'First .. Msg'First + Take - 1);
            Diag_Len := Take;
         end if;
      end Set_Diag;

      procedure Init is
      begin
         Size := 0;
         List := (others => (Name => (others => ' '), Length => 0, Value => 0));
      end Init;

      procedure Load_From_File (Path : String) is
         File : Ada.Text_IO.File_Type;
      begin
         if not Ada.Directories.Exists (Path) then
            return;   -- first run: caller reports "starting fresh"
         end if;

         begin
            Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
         exception
            when E : others =>
               Set_Diag (Diag_Load_Open, "open failed: " &
                       Ada.Exceptions.Exception_Message (E));
               return;
         end;

         Size := 0;

         while not Ada.Text_IO.End_Of_File (File) loop
            declare
               Line : constant String := Ada.Text_IO.Get_Line (File);
               Idx  : Natural := 0;
            begin
               -- Find comma
               for I in Line'Range loop
                  if Line (I) = ',' then
                     Idx := I;
                     exit;
                  end if;
               end loop;

               if Idx > 0 and then Idx > Line'First and then Idx < Line'Last then
                  declare
                     Name_Part   : constant String := Line (Line'First .. Idx - 1);
                     Weight_Part : constant String := Line (Idx + 1 .. Line'Last);
                     Weight_Val  : Natural;
                  begin
                     if Name_Part /= "unknown" and then Name_Part'Length > 0 then
                        if Contains_Comma (Name_Part) then
                           Set_Diag (Diag_Comma_Name,
                                   "skipped CSV line with comma-in-name: '" &
                                   Name_Part & "'");
                        else
                           begin
                              Weight_Val := Natural'Value (Weight_Part);
                           exception
                              when E : others =>
                                 Weight_Val := 0;
                                 Set_Diag (Diag_Bad_Value,
                                         "malformed weight '" & Weight_Part &
                                         "': " & Ada.Exceptions.Exception_Message (E));
                           end;

                           if Weight_Val > 0 and then Size < WEIGHTS_TABLE_SIZE then
                              Size := Size + 1;
                              List (Size).Name   := To_Process_Name (Name_Part);
                              List (Size).Length := Natural'Min (Name_Part'Length, MAX_NAME_LEN);
                              List (Size).Value  := Weight_Val;
                           elsif Weight_Val > 0 and then Size = WEIGHTS_TABLE_SIZE then
                              Set_Diag (Diag_Table_Full,
                                      "weight table full (" &
                                      Integer'Image (WEIGHTS_TABLE_SIZE) &
                                      "); dropped '" & Name_Part & "'");
                           end if;
                        end if;
                     end if;
                  end;
               end if;
            end;
         end loop;

         Ada.Text_IO.Close (File);
      exception
         when E : others =>
            if Ada.Text_IO.Is_Open (File) then
               Ada.Text_IO.Close (File);
            end if;
            Set_Diag (Diag_Load_Read, "read aborted: " &
                    Ada.Exceptions.Exception_Message (E));
      end Load_From_File;

      procedure Save_To_File (Path : String) is
         File : Ada.Text_IO.File_Type;
      begin
         -- Ensure parent directory exists (benign no-op when present).
         begin
            Ada.Directories.Create_Directory ("/usr/local/murasamaLMKd");
         exception
            when others => null;   -- exists already; not an error condition
         end;

         begin
            Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
         exception
            when E : others =>
               Set_Diag (Diag_Save_Create, "create failed: " &
                       Ada.Exceptions.Exception_Message (E));
               return;
         end;

         for I in 1 .. Size loop
            if List (I).Length > 0 and then List (I).Value > 0 then
               Ada.Text_IO.Put_Line (File,
                 String (List (I).Name (1 .. List (I).Length)) & "," &
                 Integer'Image (List (I).Value) (2 .. Integer'Image (List (I).Value)'Last));
            end if;
         end loop;

         Ada.Text_IO.Close (File);
      exception
         when E : others =>
            if Ada.Text_IO.Is_Open (File) then
               Ada.Text_IO.Close (File);
            end if;
            Set_Diag (Diag_Save_Create, "write aborted: " &
                    Ada.Exceptions.Exception_Message (E));
      end Save_To_File;

      procedure Increment (Name_Str : String) is
         Found : Boolean := False;
      begin
         if Name_Str = "unknown" or else Name_Str'Length = 0 then
            return;
         end if;

         if Contains_Comma (Name_Str) then
            Set_Diag (Diag_Comma_Name,
                    "rejected kill-weight name containing comma: '" &
                    Name_Str & "'");
            return;
         end if;

         for I in 1 .. Size loop
            if Name_Equals (List (I).Name, List (I).Length, Name_Str) then
               List (I).Value := List (I).Value + 1;
               Found := True;
               exit;
            end if;
         end loop;

         if not Found and then Size < 128 then
            Size := Size + 1;
            List (Size).Name   := To_Process_Name (Name_Str);
            List (Size).Length := Natural'Min (Name_Str'Length, MAX_NAME_LEN);
            List (Size).Value  := 1;
         elsif not Found then
            Set_Diag (Diag_Table_Full,
                    "weight table full (128); not tracking '" & Name_Str & "'");
         end if;
      end Increment;

      procedure Decrement (Changed : out Boolean) is
         New_Size : Natural := 0;
         Temp_List : Weights_Array := (others => (Name => (others => ' '), Length => 0, Value => 0));
      begin
         Changed := False;
         for I in 1 .. Size loop
            if List (I).Value > 0 then
               declare
                  New_Val : constant Natural := List (I).Value - 1;
               begin
                  Changed := True;
                  if New_Val > 0 then
                     New_Size := New_Size + 1;
                     Temp_List (New_Size).Name   := List (I).Name;
                     Temp_List (New_Size).Length := List (I).Length;
                     Temp_List (New_Size).Value  := New_Val;
                  end if;
               end;
            end if;
         end loop;

         List := Temp_List;
         Size := New_Size;
      end Decrement;

      function Get (Name_Str : String) return Natural is
      begin
         for I in 1 .. Size loop
            if Name_Equals (List (I).Name, List (I).Length, Name_Str) then
               return List (I).Value;
            end if;
         end loop;
         return 0;
      end Get;

      procedure Take_Diag (Code : out Natural; Msg : out String; Msg_Last : out Natural) is
         Take : constant Natural := Natural'Min (Msg'Length, Diag_Len);
      begin
         Code := Diag_Code;
         Msg (Msg'First .. Msg'First + Take - 1) := Diag_Msg (1 .. Take);
         Msg_Last := Take;
         Diag_Code := Diag_None;   -- consume: each issue reported exactly once
         Diag_Len  := 0;
      end Take_Diag;

   end Weights_Store;

   -- -------------------------------------------------------------------------
   -- Unprotected wrapper-level reporting (runs OUTSIDE any protected action,
   -- so Murasama_Log's blocking sinks are legal here).
   -- -------------------------------------------------------------------------
   procedure Report_Diagnostics (Op : String) is
      Code     : Natural;
      Msg      : String (1 .. 192);
      Msg_Last : Natural;
   begin
      loop
         Weights_Store.Take_Diag (Code, Msg, Msg_Last);
         exit when Code = Diag_None;

         case Code is
            when Diag_Load_Open =>
               Murasama_Log.Error ("Weights " & Op & ": cannot open " &
                                   WEIGHTS_FILE & " (" & Msg (1 .. Msg_Last) & ")");
            when Diag_Save_Create =>
               Murasama_Log.Error ("Weights " & Op & ": cannot write " &
                                   WEIGHTS_FILE & " (" & Msg (1 .. Msg_Last) & ")");
            when Diag_Table_Full =>
               Murasama_Log.Warn ("Weights " & Op & ": " & Msg (1 .. Msg_Last));
            when Diag_Bad_Value =>
               Murasama_Log.Warn ("Weights " & Op & ": " & Msg (1 .. Msg_Last));
            when Diag_Load_Read =>
               Murasama_Log.Error ("Weights " & Op & ": " & Msg (1 .. Msg_Last));
            when Diag_Comma_Name =>
               Murasama_Log.Warn ("Weights " & Op & ": " & Msg (1 .. Msg_Last));
            when others =>
               exit;
         end case;
      end loop;
   end Report_Diagnostics;

   procedure Init_Weights is
   begin
      Weights_Store.Init;
   end Init_Weights;

   procedure Load_Weights is
   begin
      Weights_Store.Load_From_File (WEIGHTS_FILE);
      Report_Diagnostics ("load");
   end Load_Weights;

   procedure Save_Weights is
   begin
      Weights_Store.Save_To_File (WEIGHTS_FILE);
      Report_Diagnostics ("save");
   end Save_Weights;

   procedure Increment_Weight (Name : String) is
   begin
      Weights_Store.Increment (Name);
      Weights_Store.Save_To_File (WEIGHTS_FILE);
      Report_Diagnostics ("increment");
   end Increment_Weight;

   procedure Decrement_Weights (Changed : out Boolean) is
   begin
      Weights_Store.Decrement (Changed);
      if Changed then
         Weights_Store.Save_To_File (WEIGHTS_FILE);
      end if;
      Report_Diagnostics ("decrement");
   end Decrement_Weights;

   function Get_Weight (Name : String) return Natural is
   begin
      return Weights_Store.Get (Name);
   end Get_Weight;

end Murasama_Weights;
