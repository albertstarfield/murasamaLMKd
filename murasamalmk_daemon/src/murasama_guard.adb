package body Murasama_Guard with SPARK_Mode is

   function Lower (C : Character) return Character is
   begin
      if C in 'A' .. 'Z' then
         return Character'Val (Character'Pos (C) + 32);
      else
         return C;
      end if;
   end Lower;

   function Contains_CI (Hay, Needle : String) return Boolean
   with
     Pre => Hay'Length <= 4096 and then Needle'Length <= 16
   is
      --  Re-base both strings to 1 .. N so no index arithmetic can overflow
      --  and every index is provably inside the array bounds.
      H : String (1 .. Hay'Length) := Hay;
      N : String (1 .. Needle'Length) := Needle;
   begin
      if N'Length = 0 or else H'Length < N'Length then
         return False;
      end if;

      for I in 1 .. H'Length - N'Length + 1 loop
         declare
            Match : Boolean := True;
         begin
            for J in 1 .. N'Length loop
               if Lower (H (I + J - 1)) /= Lower (N (J)) then
                  Match := False;
               end if;
               exit when not Match;
            end loop;
            if Match then
               return True;
            end if;
         end;
      end loop;
      return False;
   end Contains_CI;

   function Is_Protected_Path (Path : String) return Boolean is
   begin
      return Contains_CI (Path, "hermes")
        or else Contains_CI (Path, "syncthing")
        or else Contains_CI (Path, "omlx");
   end Is_Protected_Path;

end Murasama_Guard;
