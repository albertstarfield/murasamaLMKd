with Ada.Text_IO;
-- FIX: Removed unused 'with Ada.IO_Exceptions'.
-- REASON: No exceptions from Ada.IO_Exceptions are referenced in this body.
--         (Warning: -gnatwu)
with Ada.Directories;
-- FIX: The with/use clause for Murasama_Types is needed here (in the body) since
--         types like Process_Name_String, MAX_NAME_LEN, Weights_Array are used.
with Murasama_Types; use Murasama_Types;

package body Murasama_Weights is
   pragma SPARK_Mode (Off);

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

   protected Weights_Store is
      procedure Init;
      procedure Load_From_File (Path : String);
      procedure Save_To_File (Path : String);
      procedure Increment (Name_Str : String);
      procedure Decrement (Changed : out Boolean);
      function Get (Name_Str : String) return Natural;
   private
      List : Weights_Array;
      Size : Natural range 0 .. 128 := 0;
   end Weights_Store;

   protected body Weights_Store is

      procedure Init is
      begin
         Size := 0;
         List := (others => (Name => (others => ' '), Length => 0, Value => 0));
      end Init;

      procedure Load_From_File (Path : String) is
         File : Ada.Text_IO.File_Type;
      begin
         if not Ada.Directories.Exists (Path) then
            return;
         end if;

         begin
            Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
         exception
            when others =>
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
                        begin
                           Weight_Val := Natural'Value (Weight_Part);
                        exception
                           when others =>
                              Weight_Val := 0;
                        end;

                        if Weight_Val > 0 and then Size < 128 then
                           Size := Size + 1;
                           List (Size).Name   := To_Process_Name (Name_Part);
                           List (Size).Length := Natural'Min (Name_Part'Length, MAX_NAME_LEN);
                           List (Size).Value  := Weight_Val;
                        end if;
                     end if;
                  end;
               end if;
            end;
         end loop;

         Ada.Text_IO.Close (File);
      exception
         when others =>
            if Ada.Text_IO.Is_Open (File) then
               Ada.Text_IO.Close (File);
            end if;
      end Load_From_File;

      procedure Save_To_File (Path : String) is
         File : Ada.Text_IO.File_Type;
      begin
         -- Ensure parent directory exists
         begin
            Ada.Directories.Create_Directory ("/usr/local/murasamaLMKd");
         exception
            when others =>
               null;
         end;

         begin
            Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
         exception
            when others =>
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
         when others =>
            if Ada.Text_IO.Is_Open (File) then
               Ada.Text_IO.Close (File);
            end if;
      end Save_To_File;

      procedure Increment (Name_Str : String) is
         Found : Boolean := False;
      begin
         if Name_Str = "unknown" or else Name_Str'Length = 0 then
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

   end Weights_Store;

   procedure Init_Weights is
   begin
      Weights_Store.Init;
   end Init_Weights;

   procedure Load_Weights is
   begin
      Weights_Store.Load_From_File (WEIGHTS_FILE);
   end Load_Weights;

   procedure Save_Weights is
   begin
      Weights_Store.Save_To_File (WEIGHTS_FILE);
   end Save_Weights;

   procedure Increment_Weight (Name : String) is
   begin
      Weights_Store.Increment (Name);
      Weights_Store.Save_To_File (WEIGHTS_FILE);
   end Increment_Weight;

   procedure Decrement_Weights (Changed : out Boolean) is
   begin
      Weights_Store.Decrement (Changed);
      if Changed then
         Weights_Store.Save_To_File (WEIGHTS_FILE);
      end if;
   end Decrement_Weights;

   function Get_Weight (Name : String) return Natural is
   begin
      return Weights_Store.Get (Name);
   end Get_Weight;

end Murasama_Weights;
