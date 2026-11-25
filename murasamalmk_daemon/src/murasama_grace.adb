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

   procedure Run_System_Command_C (Cmd : char_array);
   pragma Import (C, Run_System_Command_C, "run_system_command_c");

   function Trim_Int (V : int) return String;
   function Trim_Float (V : Long_Float) return String;

   function System_Stable return Boolean is
      Page    : constant MacOS_Bridge.UINT64_T := MacOS_Bridge.Get_Page_Size_C;
      Free_MB : constant Long_Float :=
        Long_Float (MacOS_Bridge.Get_Free_MB_C (Page));
      Pressure : constant Integer :=
        Integer (MacOS_Bridge.Get_Memory_Pressure_Level_C);
   begin
      return Pressure <= 2
        and then Free_MB >= Murasama_Types.CRITICAL_FREE_MB * 4.0;
   end System_Stable;

   --  Every freeze (initial or extended) also produces a macOS notification;
   --  zenity may be unavailable in the user's GUI session, osascript is not.
   procedure Notify_Freeze
     (PID : MacOS_Bridge.PID_T; Risk_Pct : Long_Float; Extended : Boolean)
   is
      UID : constant MacOS_Bridge.UID_T := MacOS_Bridge.Get_Console_UID_C;
      Msg : constant String :=
        "pid" & Trim_Int (PID) &
        (if Extended then " still frozen; " else " frozen; ") &
        "risk " & Trim_Float (Risk_Pct) & "% - not killed";
      Cmd : constant String :=        "launchctl asuser " & Trim_Int (int (UID)) &
        " /usr/bin/osascript -e 'display notification """ & Msg &
        """ with title ""An program attempted to Freeze the whole computer""'";
   begin
      if UID = 0 then
         return;
      end if;
      Run_System_Command_C (To_C (Cmd));
   exception
      when others => null;
   end Notify_Freeze;

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
      Hold_Seconds   : Long_Float := 60.0;
      Total_Held     : Long_Float := 0.0;
   end record;

   type Hold_Array is array (1 .. Murasama_Types.GRACE_MAX_SLOTS) of Hold_Record;
   Holds : Hold_Array :=
     (others => (Active => False, Phase => Held, PID => 0,
                 Gradient_MB_S => 0.0, Risk_Pct => 0.0, Started => Clock,
                 Sample_Bytes => 0, Stops => 0, Hold_Seconds => 60.0,
                 Total_Held => 0.0));

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

   procedure Start_Hold
     (PID           : Interfaces.C.int;
      Gradient_MB_S : Long_Float;
      Total_RAM_MB  : Long_Float;
      ML_Predicted  : Integer;
      Hold_Seconds  : Long_Float)
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
         Started => Clock, Sample_Bytes => 0, Stops => 1,
         Hold_Seconds => Hold_Seconds, Total_Held => 0.0);

      Notify_Warden (PID, Holds (Slot).Risk_Pct);
      Notify_Freeze (PID, Holds (Slot).Risk_Pct, False);
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
                            "% held for " & Trim_Float (Hold_Seconds) &
                            "s (NO KILL)");
      end if;
   end Start_Hold;

   procedure Begin_Hold
     (PID           : Interfaces.C.int;
      Gradient_MB_S : Long_Float;
      Total_RAM_MB  : Long_Float;
      ML_Predicted  : Integer)
   is
   begin
      Start_Hold (PID, Gradient_MB_S, Total_RAM_MB, ML_Predicted,
                  Long_Float (Murasama_Types.GRACE_HOLD_SECONDS));
   end Begin_Hold;

   procedure Begin_Long_Hold
     (PID           : Interfaces.C.int;
      Gradient_MB_S : Long_Float;
      Total_RAM_MB  : Long_Float;
      ML_Predicted  : Integer)
   is
   begin
      Start_Hold (PID, Gradient_MB_S, Total_RAM_MB, ML_Predicted,
                  Long_Float (Murasama_Types.WHITELIST_HOLD_SECONDS));
   end Begin_Long_Hold;

   procedure Service is
      Now : constant Time := Clock;
      RC  : int;
      M1  : MacOS_Bridge.UINT64_T;
      Grad : Long_Float;
   begin
      for I in Holds'Range loop
         if Holds (I).Active
           and then Holds (I).Phase = Held
           and then To_Duration (Now - Holds (I).Started)
                    >= Duration (Long_Float'Min (Holds (I).Hold_Seconds, 60.0))
         then
            declare
               Window : constant Long_Float :=
                 Long_Float'Min (Holds (I).Hold_Seconds, 60.0);
            begin
               Holds (I).Total_Held := Holds (I).Total_Held + Window;
               if System_Stable
                 or else Holds (I).Total_Held >= Holds (I).Hold_Seconds
               then
                  RC := Kill_Process (Holds (I).PID, SIGCONT);
                  if RC /= 0 then
                     Murasama_Log.Error ("[GRACE] SIGCONT failed on pid" &
                                         Trim_Int (Holds (I).PID) & " rc=" &
                                         Trim_Int (RC));
                  else
                     Murasama_Log.Info ("[GRACE] SIGCONT pid" &
                       Trim_Int (Holds (I).PID) &
                       (if System_Stable then " after memory stabilized"
                        else " after hold cap reached") &
                       "; rechecking gradient");
                  end if;
                  Clear_Warden (Holds (I).PID);
                  Holds (I).Sample_Bytes :=
                    MacOS_Bridge.Get_Process_Memory_C (Holds (I).PID);
                  Holds (I).Phase := Rechecking;
                  Holds (I).Started := Clock;
               else
                  --  Still thrashing: stay STOPped, re-arm the warden hold
                  --  for another bounded 60 s window and notify the user.
                  Notify_Warden (Holds (I).PID, Holds (I).Risk_Pct);
                  Notify_Freeze (Holds (I).PID, Holds (I).Risk_Pct, True);
                  Holds (I).Started := Clock;
                  Murasama_Log.Warn ("[GRACE] pid" &
                    Trim_Int (Holds (I).PID) &
                    " memory still unstable after " &
                    Trim_Float (Holds (I).Total_Held) &
                    "s frozen - extending freeze (NO KILL)");
               end if;
            end;

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

            if System_Stable then
               Holds (I).Active := False;
               Murasama_Log.Info ("[GRACE] pid" & Trim_Int (Holds (I).PID) &
                 " released: memory stable, gradient=" & Trim_Float (Grad) &
                 " MB/s");
            elsif Grad > Murasama_Types.GRACE_MIN_GRADIENT_MB_S then
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
