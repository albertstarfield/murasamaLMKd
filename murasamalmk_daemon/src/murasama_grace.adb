--  Graceful pause manager: highest-gradient processes are STOPped instead of
--  killed, with a per-PID hold file that tells CriticalUIUXRespWarden not to
--  mistake the intentional STOP for an unresponsive app.
with Ada.Directories;
with Ada.Exceptions;
with Ada.Real_Time; use Ada.Real_Time;
with Ada.Text_IO;
with Interfaces.C; use Interfaces.C;
with MacOS_Bridge;
with Murasama_Log;
with Murasama_Types;

package body Murasama_Grace is

   --  Darwin signal numbers from sys/signal.h: SIGSTOP=17, SIGCONT=19.
   SIGSTOP : constant int := 17;
   SIGCONT : constant int := 19;
   RECHECK_SECONDS : constant := 1;

   function Kill_Process (PID : int; Sig : int) return int;
   pragma Import (C, Kill_Process, "kill");

   type Phase_Kind is (Held, Rechecking);

   type Hold_Record is record
      Active         : Boolean := False;
      Phase          : Phase_Kind := Held;
      PID            : MacOS_Bridge.PID_T := 0;
      Gradient_MB_S  : Long_Float := 0.0;
      Risk_Pct       : Long_Float := 0.0;
      Started        : Time := Clock;
      Sample_Bytes   : MacOS_Bridge.UINT64_T := 0;
      Stops          : Natural := 0;
   end record;

   type Hold_Array is array (1 .. Murasama_Types.GRACE_MAX_SLOTS) of Hold_Record;
   Holds : Hold_Array :=
     (others => (Active => False, Phase => Held, PID => 0,
                 Gradient_MB_S => 0.0, Risk_Pct => 0.0, Started => Clock,
                 Sample_Bytes => 0, Stops => 0));

   function Trim_Int (V : int) return String is
      S : constant String := int'Image (V);
   begin
      return S (S'First + 1 .. S'Last);
   end Trim_Int;

   function Trim_Float (V : Long_Float) return String is
      S : constant String := Long_Float'Image (V);
      P : Positive := S'First;
   begin
      if S (P) = ' ' then
         P := P + 1;
      end if;
      return S (P .. S'Last);
   end Trim_Float;

   function Hold_Path (PID : MacOS_Bridge.PID_T) return String is
   begin
      return Murasama_Types.WARDEN_HOLD_DIR & "/" & Trim_Int (PID);
   end Hold_Path;

   procedure Notify_Warden (PID : MacOS_Bridge.PID_T; Risk_Pct : Long_Float) is
      F : Ada.Text_IO.File_Type;
   begin
      if not Ada.Directories.Exists (Murasama_Types.WARDEN_HOLD_DIR) then
         begin
            Ada.Directories.Create_Path (Murasama_Types.WARDEN_HOLD_DIR);
         exception
            when E : others =>
               Murasama_Log.Error ("[GRACE] cannot create warden hold dir: " &
                                   Ada.Exceptions.Exception_Message (E));
               return;
         end;
      end if;
      begin
         Ada.Text_IO.Create (F, Ada.Text_IO.Out_File, Hold_Path (PID));
         Ada.Text_IO.Put_Line (F, "owner:murasama_lmkd");
         Ada.Text_IO.Put_Line (F, "pid:" & Trim_Int (PID));
         Ada.Text_IO.Put_Line (F, "risk_pct:" & Trim_Float (Risk_Pct));
         Ada.Text_IO.Put_Line (F, "state:SIGSTOP-grace-period");
         Ada.Text_IO.Close (F);
         Murasama_Log.Info ("[GRACE] notified warden: " & Hold_Path (PID) &
                            " risk=" & Trim_Float (Risk_Pct) & "%");
      exception
         when E : others =>
            if Ada.Text_IO.Is_Open (F) then
               Ada.Text_IO.Close (F);
            end if;
            Murasama_Log.Error ("[GRACE] warden notify failed: " &
                                Ada.Exceptions.Exception_Message (E));
      end;
   end Notify_Warden;

   procedure Clear_Warden (PID : MacOS_Bridge.PID_T) is
   begin
      if Ada.Directories.Exists (Hold_Path (PID)) then
         begin
            Ada.Directories.Delete_File (Hold_Path (PID));
            Murasama_Log.Info ("[GRACE] warden hold cleared for pid" &
                               Trim_Int (PID));
         exception
            when E : others =>
               Murasama_Log.Error ("[GRACE] warden hold clear failed: " &
                                   Ada.Exceptions.Exception_Message (E));
         end;
      end if;
   end Clear_Warden;

   function Risk_For
     (Gradient_MB_S, Total_RAM_MB : Long_Float) return Long_Float
   is
   begin
      if Total_RAM_MB < 1.0
        or else Gradient_MB_S < 0.0
        or else Gradient_MB_S > 1.0E6
      then
         return 0.0;
      end if;
      return Murasama_Types.Grace_Risk_Percent (Gradient_MB_S, Total_RAM_MB);
   end Risk_For;

   procedure Begin_Hold
     (PID           : Interfaces.C.int;
      Gradient_MB_S : Long_Float;
      Total_RAM_MB  : Long_Float;
      ML_Predicted  : Integer)
   is
      Slot : Natural := 0;
      RC   : int;
      pragma Unreferenced (ML_Predicted);
   begin
      for I in Holds'Range loop
         if not Holds (I).Active then
            Slot := I;
            exit;
         end if;
      end loop;
      if Slot = 0 then
         Murasama_Log.Warn ("[GRACE] all " &
           Integer'Image (Murasama_Types.GRACE_MAX_SLOTS) &
           " grace slots occupied; pid" & Trim_Int (PID) & " NOT stopped");
         return;
      end if;

      Holds (Slot) :=
        (Active => True, Phase => Held, PID => PID,
         Gradient_MB_S => Gradient_MB_S,
         Risk_Pct => Risk_For (Gradient_MB_S, Total_RAM_MB),
         Started => Clock, Sample_Bytes => 0, Stops => 1);

      Notify_Warden (PID, Holds (Slot).Risk_Pct);
      RC := Kill_Process (PID, SIGSTOP);
      if RC /= 0 then
         Holds (Slot).Active := False;
         Clear_Warden (PID);
         Murasama_Log.Error ("[GRACE] SIGSTOP on pid" & Trim_Int (PID) &
                             " failed rc=" & Trim_Int (RC) &
                             " - warden hold rolled back, no pause in effect");
      else
         Murasama_Log.Info ("[GRACE] SIGSTOP pid" & Trim_Int (PID) &
                            " gradient=" & Trim_Float (Gradient_MB_S) &
                            " MB/s risk=" & Trim_Float (Holds (Slot).Risk_Pct) &
                            "% held for " &
                            Integer'Image (Murasama_Types.GRACE_HOLD_SECONDS) &
                            "s (NO KILL)");
      end if;
   end Begin_Hold;

   procedure Service is
      Now : constant Time := Clock;
      RC  : int;
      M1  : MacOS_Bridge.UINT64_T;
      Grad : Long_Float;
   begin
      for I in Holds'Range loop
         if Holds (I).Active
           and then Holds (I).Phase = Held
           and then Murasama_Types.Grace_Expired (To_Duration (Now - Holds (I).Started))
         then
            RC := Kill_Process (Holds (I).PID, SIGCONT);
            if RC /= 0 then
               Murasama_Log.Error ("[GRACE] SIGCONT failed on pid" &
                                   Trim_Int (Holds (I).PID) & " rc=" &
                                   Trim_Int (RC));
            else
               Murasama_Log.Info ("[GRACE] SIGCONT pid" &
                                  Trim_Int (Holds (I).PID) &
                                  " after 60s; rechecking gradient");
            end if;
            Clear_Warden (Holds (I).PID);
            Holds (I).Sample_Bytes :=
              MacOS_Bridge.Get_Process_Memory_C (Holds (I).PID);
            Holds (I).Phase := Rechecking;
            Holds (I).Started := Clock;

         elsif Holds (I).Active
           and then Holds (I).Phase = Rechecking
           and then Holds (I).Started + Seconds (RECHECK_SECONDS) <= Now
         then
            M1 := MacOS_Bridge.Get_Process_Memory_C (Holds (I).PID);
            Grad := (Long_Float (M1) - Long_Float (Holds (I).Sample_Bytes))
                    / 1024.0 / 1024.0 / Long_Float (RECHECK_SECONDS);
            if Grad < 0.0 then
               Grad := 0.0;
            end if;
            Holds (I).Gradient_MB_S := Grad;

            if Grad > Murasama_Types.GRACE_MIN_GRADIENT_MB_S then
               Holds (I).Stops := Holds (I).Stops + 1;
               Holds (I).Started := Clock;
               Holds (I).Phase := Held;
               Notify_Warden (Holds (I).PID, Holds (I).Risk_Pct);
               RC := Kill_Process (Holds (I).PID, SIGSTOP);
               if RC = 0 then
                  Murasama_Log.Info ("[GRACE] still climbing at " &
                    Trim_Float (Grad) & " MB/s after CONT - STOP #" &
                    Trim_Int (int (Holds (I).Stops)) & " on pid" &
                    Trim_Int (Holds (I).PID) & " (NO KILL)");
               else
                  Murasama_Log.Error ("[GRACE] repeat SIGSTOP failed on pid" &
                    Trim_Int (Holds (I).PID) & " rc=" & Trim_Int (RC));
                  Holds (I).Active := False;
                  Clear_Warden (Holds (I).PID);
               end if;
            else
               Holds (I).Active := False;
               Murasama_Log.Info ("[GRACE] pid" & Trim_Int (Holds (I).PID) &
                 " recovered after CONT; gradient=" & Trim_Float (Grad) &
                 " MB/s, no further STOP");
            end if;
         end if;
      end loop;
   end Service;

end Murasama_Grace;
