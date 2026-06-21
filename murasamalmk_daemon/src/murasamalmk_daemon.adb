with Ada.Text_IO;
with Ada.Real_Time; use Ada.Real_Time;
with Ada.Directories;
with Interfaces.C; use Interfaces.C;
with MacOS_Bridge; use MacOS_Bridge;
with Murasama_Types; use Murasama_Types;
with Murasama_Weights; use Murasama_Weights;
with Murasama_Telemetry; use Murasama_Telemetry;

-- SPARK_Mode => Off: The main daemon procedure cannot be verified by SPARK because:
--   1. Ada tasks (Async_Command_Runner, Decrement_Task, Thrashing_Task) with rendezvous
--   2. File I/O via Ada.Text_IO (reading ml_prediction.txt, weight files)
--   3. C library imports (kill, system) via pragma Import
--   4. Protected types with mutable state (Mitigation_State)
--   5. Unbounded delays and real-time scheduling
-- Only the pure computation subpackages (murasama_types) are SPARK-verified.
procedure Murasamalmk_Daemon is

   -- Import kill function from C library
   function Kill_C (PID : int; Sig : int) return int;
   pragma Import (C, Kill_C, "kill");

   -- Async AppleScript/Zenity Warning Task
   task type Async_Command_Runner is
      entry Enqueue (Cmd : String);
   end Async_Command_Runner;

   type Async_Command_Runner_Access is access Async_Command_Runner;
   Runner : Async_Command_Runner_Access;

   task body Async_Command_Runner is
      -- Tasking loop to run commands asynchronously with 30s throttling
      type String_Access is access String;
      type Queue_Array is array (1 .. 128) of String_Access;
      Queue : Queue_Array := (others => null);
      Head  : Positive := 1;
      Tail  : Positive := 1;
      Count : Natural := 0;
   begin
      loop
         select
            accept Enqueue (Cmd : String) do
               if Count < 128 then
                  Queue (Tail) := new String'(Cmd);
                  Tail := (if Tail = 128 then 1 else Tail + 1);
                  Count := Count + 1;
               end if;
            end Enqueue;
         or
            delay 0.1;
         end select;

         if Count > 0 then
            declare
               Cmd_To_Run : constant String := Queue (Head).all;
            begin
               Queue (Head) := null;
               Head := (if Head = 128 then 1 else Head + 1);
               Count := Count - 1;

               -- Execute command
               declare
                  C_Cmd : constant char_array := To_C (Cmd_To_Run);
               begin
                  Run_System_Command_C (C_Cmd);
               end;
            end;
            -- 30-second throttle
            delay 30.0;
         end if;
      end loop;
   end Async_Command_Runner;

   -- Global mitigation state (protected for task safety)
   protected Mitigation_State is
      procedure Set_Mitigating (Val : Boolean);
      function Is_Mitigating return Boolean;
      procedure Set_End_Time (T : Time);
      function Get_End_Time return Time;
      procedure Set_Boosted_PIDs (PIDs : PID_Array; Count : Integer);
      function Get_Boosted_PID (Idx : Integer) return PID_T;
      function Get_Boosted_Count return Integer;
      procedure Clear_Boosted_PIDs;
      procedure Increment_Triggers (Pagein_Trip, Decomp_Trip, Pressure_Trip : Boolean);
      procedure Reset_Hourly_Triggers (Total, Pageins, Decomp, Pressure : out Integer);
   private
      Active        : Boolean := False;
      End_Time      : Time := Clock;
      Boosted_List  : PID_Array (int(1) .. int(512)) := (others => 0);
      Boosted_Count : Integer := 0;

      Total_Triggers  : Integer := 0;
      Reason_Pageins  : Integer := 0;
      Reason_Decomp   : Integer := 0;
      Reason_Pressure : Integer := 0;
   end Mitigation_State;

   protected body Mitigation_State is
      procedure Set_Mitigating (Val : Boolean) is
      begin
         Active := Val;
      end Set_Mitigating;

      function Is_Mitigating return Boolean is
      begin
         return Active;
      end Is_Mitigating;

      procedure Set_End_Time (T : Time) is
      begin
         End_Time := T;
      end Set_End_Time;

      function Get_End_Time return Time is
      begin
         return End_Time;
      end Get_End_Time;

      procedure Set_Boosted_PIDs (PIDs : PID_Array; Count : Integer) is
      begin
         Boosted_Count := Count;
         for I in 1 .. Count loop
            if I <= 512 then
               Boosted_List (int(I)) := PIDs (PIDs'First + int(I) - 1);
            end if;
         end loop;
      end Set_Boosted_PIDs;

      function Get_Boosted_PID (Idx : Integer) return PID_T is
      begin
         if Idx >= 1 and then Idx <= Boosted_Count then
            return Boosted_List (int(Idx));
         end if;
         return 0;
      end Get_Boosted_PID;

      function Get_Boosted_Count return Integer is
      begin
         return Boosted_Count;
      end Get_Boosted_Count;

      procedure Clear_Boosted_PIDs is
      begin
         Boosted_Count := 0;
      end Clear_Boosted_PIDs;

      procedure Increment_Triggers (Pagein_Trip, Decomp_Trip, Pressure_Trip : Boolean) is
      begin
         Total_Triggers := Total_Triggers + 1;
         if Pagein_Trip then
            Reason_Pageins := Reason_Pageins + 1;
         end if;
         if Decomp_Trip then
            Reason_Decomp := Reason_Decomp + 1;
         end if;
         if Pressure_Trip then
            Reason_Pressure := Reason_Pressure + 1;
         end if;
      end Increment_Triggers;

      procedure Reset_Hourly_Triggers (Total, Pageins, Decomp, Pressure : out Integer) is
      begin
         Total := Total_Triggers;
         Pageins := Reason_Pageins;
         Decomp := Reason_Decomp;
         Pressure := Reason_Pressure;

         Total_Triggers := 0;
         Reason_Pageins := 0;
         Reason_Decomp := 0;
         Reason_Pressure := 0;
      end Reset_Hourly_Triggers;
   end Mitigation_State;

   -- Helper to execute asynchronous notifications
   procedure Queue_Zenity_Warning (Target_Name, Reason : String) is
      UID : constant UID_T := Get_Console_UID_C;
   begin
      if UID = 0 then
         return;
      end if;
      declare
         UID_Str : constant String := UID_T'Image (UID);
         UID_Trimmed : constant String := UID_Str (UID_Str'First + 1 .. UID_Str'Last);
         Cmd : constant String := "launchctl asuser " & UID_Trimmed &
           " /opt/homebrew/bin/zenity --warning --text=""Terminated " & Target_Name &
           ". Reason: " & Reason & """ --title=""Murasama LMKd: Bloodshed"" --width=300";
      begin
         Runner.Enqueue (Cmd);
      end;
   end Queue_Zenity_Warning;

   procedure Queue_Thrashing_Summary_Notification (Total, Pageins, Decomp, Pressure : Integer) is
      UID : constant UID_T := Get_Console_UID_C;
   begin
      if UID = 0 then
         return;
      end if;
      declare
         UID_Str : constant String := UID_T'Image (UID);
         UID_Trimmed : constant String := UID_Str (UID_Str'First + 1 .. UID_Str'Last);
         Msg : constant String := "Total triggers: " & Integer'Image (Total) &
           " (Pageins: " & Integer'Image (Pageins) & ", Decomp: " & Integer'Image (Decomp) &
           ", Pressure: " & Integer'Image (Pressure) & ")";
         Cmd : constant String := "launchctl asuser " & UID_Trimmed &
           " osascript -e 'display notification """ & Msg & """ with title ""Murasama: Thrashing Summary (Last 1h)""'";
      begin
         Runner.Enqueue (Cmd);
      end;
   end Queue_Thrashing_Summary_Notification;

   -- Mitigation In / Out helpers
   -- FIX: Removed unused Front_Name_C and Front_Name variables.
   -- REASON: These were populated from Get_Process_Name_C but never read afterward.
   --         The frontmost process name is not needed for the mitigation logic itself,
   --         only its PID is used for priority boosting. (Warning: -gnatwm)
   procedure Thrashing_Mitigation_In (Current_Front : PID_T) is
   begin
      if Mitigation_State.Is_Mitigating then
         return;
      end if;

      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put_Line ("[CRITICAL] Thrashing tripped! Engaging Mitigation...");

      -- Fetch and print top 50 processes
      declare
         Top_Pids : PID_Array (int(1) .. int(100)) := (others => 0);
         Top_RAM  : UINT64_Array (int(1) .. int(100)) := (others => 0);
         Top_Count : int;
      begin
         Top_Count := Get_Top_Processes_By_Memory_C (Top_Pids, Top_RAM, int(50), int(0));
         Ada.Text_IO.Put_Line ("[!] Top Thrashers (Sorted by RAM):");
         for I in int(1) .. Top_Count loop
            declare
               P_Name_C : char_array (size_t(1) .. size_t(MAX_NAME_LEN)) := (others => ' ');
               P_Name   : String (1 .. MAX_NAME_LEN) := (others => ' ');
               P_Len    : Integer := 0;
            begin
               Get_Process_Name_C (Top_Pids (I), P_Name_C, int(MAX_NAME_LEN));
               for J in P_Name_C'Range loop
                  if P_Name_C (J) = char'Val (0) then
                     P_Len := Integer (J) - Integer (P_Name_C'First);
                     exit;
                  end if;
                  P_Name (Integer (J) - Integer (P_Name_C'First) + 1) := To_Ada (P_Name_C (J));
               end loop;
               if P_Len = 0 then
                  P_Len := MAX_NAME_LEN;
               end if;
               Ada.Text_IO.Put_Line ("PID: " & PID_T'Image (Top_Pids (I)) & " | " &
                 P_Name (1 .. P_Len) & " | RAM: " &
                 Integer'Image (Integer (Top_RAM (I) / 1024 / 1024)) & " MB");
            end;
         end loop;
      end;

      -- Boost frontmost app process tree
      if Current_Front > 0 then
         declare
            Tree_Pids : PID_Array (int(1) .. int(256)) := (others => 0);
            Tree_Count : int;
         begin
            Tree_Count := Get_Process_Tree_C (Current_Front, Tree_Pids, int(256));
            if Tree_Count > 0 then
               Mitigation_State.Set_Boosted_PIDs (Tree_Pids, Integer (Tree_Count));
               for I in int(1) .. Tree_Count loop
                  Set_Process_Priority_C (Tree_Pids (I), int(-20));
               end loop;
               Ada.Text_IO.Put_Line ("[+] Boosted " & int'Image (Tree_Count) & " PIDs for frontmost app.");
            else
               Set_Process_Priority_C (Current_Front, int(-20));
               declare
                  -- FIX: Added 'constant' qualifier to Single_Array.
                  -- REASON: The array is never modified after initialization, so it should
                  --         be declared constant. (Warning: -gnatwk)
                  Single_Array : constant PID_Array (int(1) .. int(1)) := (others => Current_Front);
               begin
                  Mitigation_State.Set_Boosted_PIDs (Single_Array, 1);
               end;
               Ada.Text_IO.Put_Line ("[+] Boosted frontmost PID only.");
            end if;
         end;

         if Is_Gamepolicyctl_Available_C /= 0 then
            Set_Game_Mode_C (To_C ("on"));
            Ada.Text_IO.Put_Line ("[+] Enabled game mode.");
         end if;
      end if;

      Mitigation_State.Set_Mitigating (True);
      Mitigation_State.Set_End_Time (Clock + Seconds (HYSTERESIS_SECONDS));
   end Thrashing_Mitigation_In;

   procedure Thrashing_Mitigation_Out is
      Count : constant Integer := Mitigation_State.Get_Boosted_Count;
   begin
      if not Mitigation_State.Is_Mitigating then
         return;
      end if;

      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put_Line ("[RECOVERY] Hysteresis timer expired. Restoring system state...");

      for I in 1 .. Count loop
         declare
            P : constant PID_T := Mitigation_State.Get_Boosted_PID (I);
         begin
            if P > 0 then
               Set_Process_Priority_C (P, int(0));
            end if;
         end;
      end loop;

      Mitigation_State.Clear_Boosted_PIDs;

      if Is_Gamepolicyctl_Available_C /= 0 then
         Set_Game_Mode_C (To_C ("auto"));
         Ada.Text_IO.Put_Line ("[+] Reverted game mode to auto.");
      end if;

      -- Kill any remaining cpulimit tasks if any were spawned in background shell scripts
      Run_System_Command_C (To_C ("pkill -f 'cpulimit.*-p'"));

      Mitigation_State.Set_Mitigating (False);
   end Thrashing_Mitigation_Out;

   -- Periodic Decrement Task
   task Decrement_Task;
   task body Decrement_Task is
      Changed : Boolean;
   begin
      loop
         delay Duration (WEIGHT_DECREMENT_HOURS * 3600);
         Decrement_Weights (Changed);
         if Changed then
            Ada.Text_IO.Put_Line ("[WEIGHTS] Periodically decremented weights and saved.");
         end if;
      end loop;
   end Decrement_Task;

   -- Thrashing Detection Task
   task Thrashing_Task;
   task body Thrashing_Task is
      Snap_Start_Faults, Snap_Start_Pageins, Snap_Start_Decomp : UINT64_T;
      Snap_End_Faults, Snap_End_Pageins, Snap_End_Decomp : UINT64_T;
      Pageins_Per_Sec, Decomp_Per_Sec : UINT64_T;
      Pressure_Level : Integer;
      Front_PID : PID_T;
      Next_Summary_Time : Time := Clock + Seconds (3600);
   begin
      loop
         Get_Memory_Snapshot_C (Snap_Start_Faults, Snap_Start_Pageins, Snap_Start_Decomp);
         delay 0.1;
         Get_Memory_Snapshot_C (Snap_End_Faults, Snap_End_Pageins, Snap_End_Decomp);

         Pageins_Per_Sec := (Snap_End_Pageins - Snap_Start_Pageins) * 10;
         Decomp_Per_Sec := (Snap_End_Decomp - Snap_Start_Decomp) * 10;
         Pressure_Level := Integer (Get_Memory_Pressure_Level_C);
         Front_PID := Get_Frontmost_PID_C;

         declare
            Pagein_Trip : constant Boolean := Pageins_Per_Sec > THRASHING_THRESHOLD_PAGEINS;
            Decomp_Trip : constant Boolean := Decomp_Per_Sec > THRASHING_THRESHOLD_DECOMP;
            Pressure_Trip : constant Boolean := Pressure_Level >= 3;
         begin
            if Pagein_Trip or Decomp_Trip or Pressure_Trip then
               if not Mitigation_State.Is_Mitigating then
                  Mitigation_State.Increment_Triggers (Pagein_Trip, Decomp_Trip, Pressure_Trip);
                  Thrashing_Mitigation_In (Front_PID);
               end if;
            end if;
         end;

         -- Hourly notification summary check
         if Clock >= Next_Summary_Time then
            declare
               Total, Pageins, Decomp, Pressure : Integer;
            begin
               Mitigation_State.Reset_Hourly_Triggers (Total, Pageins, Decomp, Pressure);
               if Total > 0 then
                  Queue_Thrashing_Summary_Notification (Total, Pageins, Decomp, Pressure);
               end if;
               Next_Summary_Time := Clock + Seconds (3600);
            end;
         end if;

         -- Mitigation Hysteresis Check
         if Mitigation_State.Is_Mitigating and then Clock >= Mitigation_State.Get_End_Time then
            Thrashing_Mitigation_Out;
         end if;

         delay 0.9; -- Repeat cycle
      end loop;
   end Thrashing_Task;

   -- Bloodshed Handler
   procedure Handle_Bloodshed (Trigger_Reason : String; Page_Size : UINT64_T) is
      MAX_KILLS : constant := 3;
      Kill_Count : Integer := 0;

      Free_MB        : Long_Float;
      -- FIX: Removed unused Wired_MB variable.
      -- REASON: This variable was declared but never assigned or read. The bloodshed
      --         handler only needs Free_MB and Pressure_Level to decide if pressure
      --         has been resolved after a kill. (Warning: -gnatwu)
      Pressure_Level : Integer;
   begin
      Ada.Text_IO.Put_Line ("");
      Ada.Text_IO.Put_Line ("--- BLOODSHED INITIATED ---");
      Ada.Text_IO.Put_Line ("Reason: " & Trigger_Reason);

      while Kill_Count < MAX_KILLS loop
         declare
            Top_Pids : PID_Array (int(1) .. int(TOP_N_PROCESSES)) := (others => 0);
            Top_RAM  : UINT64_Array (int(1) .. int(TOP_N_PROCESSES)) := (others => 0);
            Top_Count : int;
         begin
            Top_Count := Get_Top_Processes_By_Memory_C (Top_Pids, Top_RAM, int(TOP_N_PROCESSES), int(0));
            if Top_Count = 0 then
               Ada.Text_IO.Put_Line ("No processes to evaluate. Aborting bloodshed.");
               exit;
            end if;

            -- Allocation Rate Measurement over GRADIENT_MEASURE_MS
            declare
               T0_RAM : UINT64_Array (int(1) .. int(TOP_N_PROCESSES)) := (others => 0);
               T1_RAM : UINT64_Array (int(1) .. int(TOP_N_PROCESSES)) := (others => 0);
               Rates  : array (1 .. TOP_N_PROCESSES) of Long_Float := (others => 0.0);
               Names  : array (1 .. TOP_N_PROCESSES) of String (1 .. MAX_NAME_LEN) := (others => (others => ' '));
               Name_Lens : array (1 .. TOP_N_PROCESSES) of Integer := (others => 0);
               Delta_Secs : constant Long_Float := Long_Float (GRADIENT_MEASURE_MS) / 1000.0;
            begin
               for I in int(1) .. Top_Count loop
                  T0_RAM (I) := Get_Process_Memory_C (Top_Pids (I));
               end loop;

               delay Duration (Long_Float (GRADIENT_MEASURE_MS) / 1000.0);

               for I in int(1) .. Top_Count loop
                  T1_RAM (I) := Get_Process_Memory_C (Top_Pids (I));
                  declare
                     Diff_Bytes : constant Long_Float := Long_Float (T1_RAM (I)) - Long_Float (T0_RAM (I));
                     Diff_MB    : constant Long_Float := Diff_Bytes / (1024.0 * 1024.0);
                     Name_C     : char_array (size_t(1) .. size_t(MAX_NAME_LEN)) := (others => ' ');
                     Idx        : constant Integer := Integer (I);
                  begin
                     Rates (Idx) := Diff_MB / Delta_Secs;
                     Get_Process_Name_C (Top_Pids (I), Name_C, int(MAX_NAME_LEN));
                     for J in Name_C'Range loop
                        if Name_C (J) = char'Val (0) then
                           Name_Lens (Idx) := Integer (J) - Integer (Name_C'First);
                           exit;
                        end if;
                        Names (Idx) (Integer (J) - Integer (Name_C'First) + 1) := To_Ada (Name_C (J));
                     end loop;
                     if Name_Lens (Idx) = 0 then
                        Name_Lens (Idx) := MAX_NAME_LEN;
                     end if;
                  end;
               end loop;

               -- Select target pid
               declare
                  Target_Idx : Integer := -1;
                  Max_Weight : Integer := -1;
                  Phase_Desc : String (1 .. 64) := (others => ' ');
                  Phase_Len  : Integer := 0;
               begin
                  -- 1. Check for weight priority
                  for I in 1 .. Integer (Top_Count) loop
                     declare
                        P_Name : constant String := Names (I) (1 .. Name_Lens (I));
                        W      : constant Natural := Get_Weight (P_Name);
                     begin
                        if W > WEIGHT_PRIORITY_THRESHOLD then
                           if W > Max_Weight then
                              Max_Weight := W;
                              Target_Idx := I;
                              Phase_Desc (1 .. 13) := "priority kill";
                              Phase_Len := 13;
                           end if;
                        end if;
                     end;
                  end loop;

                  -- 2. fallback to rate behavior
                  if Target_Idx = -1 then
                     if Kill_Count < 2 then
                        -- First and second kills: target lowest rate (often bloated dormant/leaky processes)
                        declare
                           Min_Rate : Long_Float := 999999.0;
                        begin
                           for I in 1 .. Integer (Top_Count) loop
                              if Rates (I) < Min_Rate then
                                 Min_Rate := Rates (I);
                                 Target_Idx := I;
                              end if;
                           end loop;
                           if Kill_Count = 0 then
                              Phase_Desc (1 .. 25) := "first kill (lowest rate) ";
                              Phase_Len := 25;
                           else
                              -- FIX: Changed slice from (1..26) to (1..25).
                              -- REASON: The string literal "second kill (lowest rate)" is 25
                              --         characters, not 26. Mismatched slice length causes
                              --         Constraint_Error at runtime. (Warning: default)
                              Phase_Desc (1 .. 25) := "second kill (lowest rate)";
                              Phase_Len := 25;
                           end if;
                        end;
                     else
                           -- Third kill: target highest rate (active memory hoarder)
                           declare
                              Max_Rate : Long_Float := -999999.0;
                           begin
                              for I in 1 .. Integer (Top_Count) loop
                                 if Rates (I) > Max_Rate then
                                    Max_Rate := Rates (I);
                                    Target_Idx := I;
                                 end if;
                              end loop;
                              -- FIX: Changed slice from (1..26) to (1..25).
                              -- REASON: The string literal "third kill (highest rate)" is 25
                              --         characters, not 26. Mismatched slice length causes
                              --         Constraint_Error at runtime. (Warning: default)
                              Phase_Desc (1 .. 25) := "third kill (highest rate)";
                              Phase_Len := 25;
                        end;
                     end if;
                  end if;

                  if Target_Idx /= -1 then
                     declare
                        T_PID  : constant PID_T := Top_Pids (int(Target_Idx));
                        T_Name : constant String := Names (Target_Idx) (1 .. Name_Lens (Target_Idx));
                        -- FIX: Removed unused 'Res' variable.
                        -- REASON: The return value of Kill_C was assigned to Res but never
                        --         read. The kill result is not checked, so the variable is
                        --         unnecessary. (Warning: -gnatwm)
                     begin
                        Ada.Text_IO.Put_Line ("Phase: " & Phase_Desc (1 .. Phase_Len));
                        Ada.Text_IO.Put_Line ("Target: PID " & PID_T'Image (T_PID) & " (" & T_Name & ")");

                        Queue_Zenity_Warning (T_Name, Trigger_Reason & " (" & Phase_Desc (1 .. Phase_Len) & ")");

                         -- Kill target
                         -- FIX: Removed Res assignment. The return value of Kill_C is not
                         --         checked, so we discard it directly. (Warning: -gnatwm)
                         declare
                            Kill_Result : int;
                            pragma Unreferenced (Kill_Result);
                         begin
                            Kill_Result := Kill_C (T_PID, int(9)); -- SIGKILL
                         end;
                        Kill_Count := Kill_Count + 1;

                        -- Increment weight
                        Increment_Weight (T_Name);

                        delay 0.2;
                      exception
                        when others => null;
                     end;
                  else
                     Ada.Text_IO.Put_Line ("No eligible target found.");
                     exit;
                  end if;
               end;
            end;
         end;

         -- Re-evaluate pressure
         Free_MB        := Long_Float (Get_Free_MB_C (Page_Size));
         Pressure_Level := Integer (Get_Memory_Pressure_Level_C);
         if Free_MB >= CRITICAL_FREE_MB and then Pressure_Level < MIN_PRESSURE_LEVEL_TO_KILL then
            Ada.Text_IO.Put_Line ("Memory pressure resolved after " & Integer'Image (Kill_Count) & " kill(s).");
            exit;
         end if;
      end loop;

      if Kill_Count = MAX_KILLS then
         Ada.Text_IO.Put_Line ("Maximum kills reached. Pressure may still persist.");
      end if;
   end Handle_Bloodshed;

   -- Read machine learning prediction from a flat file
   procedure Read_ML_Prediction (Predicted_Pressure : out Integer; Risk_Level : out String; Target_PID : out PID_T) is
      File : Ada.Text_IO.File_Type;
      Line : String (1 .. 256);
      Last : Natural;
      Path : constant String := "/usr/local/murasamaLMKd/murasamalmk_daemon/ml_prediction.txt";
   begin
      Predicted_Pressure := 1;
      Risk_Level := "low       ";
      Target_PID := 0;

      if not Ada.Directories.Exists (Path) then
         return;
      end if;

      begin
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      exception
         when others =>
            return;
      end;

      while not Ada.Text_IO.End_Of_File (File) loop
         Ada.Text_IO.Get_Line (File, Line, Last);
         if Last >= 20 and then Line (1 .. 19) = "predicted_pressure:" then
            begin
               Predicted_Pressure := Integer'Value (Line (20 .. Last));
            exception
               when others => null;
            end;
         elsif Last >= 12 and then Line (1 .. 11) = "risk_level:" then
            declare
               Val : constant String := Line (12 .. Last);
            begin
                Risk_Level := (others => ' ');
                -- FIX: Use Risk_Level'First instead of hardcoded 1.
                -- REASON: The compiler warns that the index may assume lower bound of 1.
                --         Using 'First makes the code correct regardless of the array's
                --         actual lower bound. (Warning: -gnatww)
                Risk_Level (Risk_Level'First .. Risk_Level'First + Natural'Min (Val'Length, 10) - 1)
                  := Val (Val'First .. Val'First + Natural'Min (Val'Length, 10) - 1);
            end;
         elsif Last >= 12 and then Line (1 .. 11) = "target_pid:" then
            begin
               Target_PID := PID_T'Value (Line (12 .. Last));
            exception
               when others => null;
            end;
         end if;
      end loop;

      Ada.Text_IO.Close (File);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
   end Read_ML_Prediction;

   -- ==================== SIDECAR MANAGER ====================
   -- Spawns, monitors, and restarts the Python ML predictor sidecar.
   -- Replaces the nohup-based launch from start.sh with proper process
   -- lifecycle management from within the Ada daemon.

   ML_PREDICTOR_PATH : constant String :=
     "/usr/local/murasamaLMKd/murasamalmk_daemon/python/venv/bin/python3";
   ML_PREDICTOR_SCRIPT : constant String :=
     "/usr/local/murasamaLMKd/murasamalmk_daemon/python/ml_predictor.py";
   ML_PREDICTOR_LOG : constant String :=
     "/tmp/murasamalmk_ml.log";

   -- Check if a process with given PID is alive
   function Is_Process_Alive (PID : PID_T) return Boolean is
      Result : int;
      pragma Unreferenced (Result);
   begin
      -- kill(pid, 0) checks existence without sending signal
      Result := Kill_C (PID, 0);
      return Result = 0;
   end Is_Process_Alive;

   -- Spawn the ML predictor sidecar, return its PID (0 on failure)
   function Spawn_ML_Predictor return PID_T is
   begin
      -- Write a temp script to get the PID
      declare
         Script_Path : constant String := "/tmp/murasama_spawn.sh";
         File : Ada.Text_IO.File_Type;
         Line : String (1 .. 32);
         Last : Natural;
         Result_PID : PID_T := 0;
      begin
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Script_Path);
         Ada.Text_IO.Put_Line (File, "#!/bin/bash");
         Ada.Text_IO.Put_Line (File, ML_PREDICTOR_PATH & " " & ML_PREDICTOR_SCRIPT &
           " > /dev/null 2>&1 &");
         Ada.Text_IO.Put_Line (File, "echo $!");
         Ada.Text_IO.Close (File);

         Run_System_Command_C (To_C ("chmod +x " & Script_Path));

         -- Read the PID from stdout
         Run_System_Command_C (To_C (Script_Path & " > /tmp/murasama_pid.txt"));
         delay 0.5;

         if Ada.Directories.Exists ("/tmp/murasama_pid.txt") then
            Ada.Text_IO.Open (File, Ada.Text_IO.In_File, "/tmp/murasama_pid.txt");
            if not Ada.Text_IO.End_Of_File (File) then
               Ada.Text_IO.Get_Line (File, Line, Last);
               if Last > 0 then
                  begin
                     Result_PID := PID_T'Value (Line (1 .. Last));
                  exception
                     when others => Result_PID := 0;
                  end;
               end if;
            end if;
            Ada.Text_IO.Close (File);
         end if;

         return Result_PID;
      end;
   end Spawn_ML_Predictor;

   -- Kill the ML predictor sidecar gracefully, then force if needed
   procedure Kill_ML_Predictor (PID : PID_T) is
      Result : int;
      pragma Unreferenced (Result);
   begin
      if PID <= 0 then
         return;
      end if;
      -- SIGTERM first (graceful)
      Result := Kill_C (PID, int(15));
      delay 1.0;
      -- Check if still alive, force kill
      if Is_Process_Alive (PID) then
         Result := Kill_C (PID, int(9)); -- SIGKILL
      end if;
   end Kill_ML_Predictor;

   -- Sidecar Manager Task: spawns and monitors the ML predictor
   task Sidecar_Manager_Task;
   task body Sidecar_Manager_Task is
      ML_PID        : PID_T := 0;
      Restart_Count : Integer := 0;
      Max_Restarts  : constant Integer := 5;
      Check_Interval : constant Duration := 5.0;
      Last_Health_Check : Time := Clock;
   begin
      delay 3.0; -- Wait for daemon initialization

      -- Initial spawn
      Ada.Text_IO.Put_Line ("[SIDECAR] Spawning ML predictor sidecar...");
      ML_PID := Spawn_ML_Predictor;
      if ML_PID > 0 then
         Ada.Text_IO.Put_Line ("[SIDECAR] ML predictor started. PID:" & PID_T'Image (ML_PID));
      else
         Ada.Text_IO.Put_Line ("[SIDECAR] WARNING: Failed to spawn ML predictor.");
      end if;

      loop
         delay Check_Interval;

         -- Check if ML predictor is still alive
         if ML_PID > 0 then
            if not Is_Process_Alive (ML_PID) then
               Ada.Text_IO.Put_Line ("[SIDECAR] ML predictor died (PID:" &
                 PID_T'Image (ML_PID) & "). Restarting...");
               Restart_Count := Restart_Count + 1;

               if Restart_Count > Max_Restarts then
                  Ada.Text_IO.Put_Line ("[SIDECAR] Max restarts (" &
                    Integer'Image (Max_Restarts) & ") reached. Giving up.");
                  exit;
               end if;

               delay 1.0;
               ML_PID := Spawn_ML_Predictor;
               if ML_PID > 0 then
                  Ada.Text_IO.Put_Line ("[SIDECAR] ML predictor restarted. PID:" &
                    PID_T'Image (ML_PID) & " (attempt" & Integer'Image (Restart_Count) & ")");
               else
                  Ada.Text_IO.Put_Line ("[SIDECAR] Failed to restart ML predictor.");
               end if;
            end if;
         else
            -- Try to spawn if we don't have a PID
            ML_PID := Spawn_ML_Predictor;
            if ML_PID > 0 then
               Ada.Text_IO.Put_Line ("[SIDECAR] ML predictor spawned. PID:" & PID_T'Image (ML_PID));
            end if;
         end if;

         -- Periodic health log
         if Clock >= Last_Health_Check + Seconds (30) then
            if ML_PID > 0 and then Is_Process_Alive (ML_PID) then
               Ada.Text_IO.Put_Line ("[SIDECAR] ML predictor healthy. PID:" &
                 PID_T'Image (ML_PID) & " | Restarts:" & Integer'Image (Restart_Count));
            else
               Ada.Text_IO.Put_Line ("[SIDECAR] ML predictor not running. Restarts:" &
                 Integer'Image (Restart_Count));
            end if;
            Last_Health_Check := Clock;
         end if;
      end loop;

      -- Cleanup on task exit
      Kill_ML_Predictor (ML_PID);
      Ada.Text_IO.Put_Line ("[SIDECAR] Sidecar manager shutting down.");
   end Sidecar_Manager_Task;

   -- Variables for main loop
   Page_Size : constant UINT64_T := Get_Page_Size_C;
   Last_Time : Time := Clock;
   Last_Report_Time : Time := Clock;
   Last_Telemetry_Time : Time := Clock;
   Last_Front_Check_Time : Time := Clock;

   Last_Wired_MB : Long_Float;

   Current_Free_MB : Long_Float;
   Current_Wired_MB : Long_Float;
   Current_Pressure : Integer;

   ML_Predicted_Pressure : Integer := 1;
   ML_Risk_Level : String (1 .. 10) := (others => ' ');
   ML_Target_PID : PID_T := 0;

   Front_PID : PID_T := 0;
   Front_Name : String (1 .. MAX_NAME_LEN) := (others => ' ');
   Front_Len : Integer := 0;

begin
   -- Initialize async runner
   Runner := new Async_Command_Runner;

   Ada.Text_IO.Put_Line ("[Murasama LMKd] Unsheathed. GUI Notifications Enabled. Polling interval = 100ms.");
   Ada.Text_IO.Put_Line ("Thrashing detection active. Mitigation threshold: pageins/s > " &
     Integer'Image (THRASHING_THRESHOLD_PAGEINS) & " or decomp/s > " & Integer'Image (THRASHING_THRESHOLD_DECOMP));

   Init_Weights;
   Load_Weights;

   Last_Wired_MB := Long_Float (Get_Wired_MB_C (Page_Size));

   -- Main Loop
   loop
      delay 0.1; -- 100ms poll (Optimized for <0.9% CPU)

      Current_Free_MB := Long_Float (Get_Free_MB_C (Page_Size));
      Current_Wired_MB := Long_Float (Get_Wired_MB_C (Page_Size));
      Current_Pressure := Integer (Get_Memory_Pressure_Level_C);

      declare
         Now : Time := Clock;
         Elapsed : constant Duration := To_Duration (Now - Last_Time);
         Elapsed_Secs : constant Long_Float := Long_Float (Elapsed);
         Wired_Velocity : Long_Float := 0.0;
      begin
         if Elapsed_Secs > 0.0 then
            Wired_Velocity := (Current_Wired_MB - Last_Wired_MB) / Elapsed_Secs;
            if Wired_Velocity < 0.0 then
               Wired_Velocity := 0.0;
            end if;
         end if;

         -- Query frontmost app info (Throttled to 1s to avoid SkyLight IPC overhead)
         if Now >= Last_Front_Check_Time + Seconds (1) then
            declare
               Front_Name_C : char_array (size_t(1) .. size_t(MAX_NAME_LEN)) := (others => ' ');
            begin
               Front_PID := Get_Frontmost_PID_C;
               Get_Process_Name_C (Front_PID, Front_Name_C, int(MAX_NAME_LEN));
               Front_Len := 0;
               for I in Front_Name_C'Range loop
                  if Front_Name_C (I) = char'Val (0) then
                     Front_Len := Integer (I) - Integer (Front_Name_C'First);
                     exit;
                  end if;
                  Front_Name (Integer (I) - Integer (Front_Name_C'First) + 1) := To_Ada (Front_Name_C (I));
               end loop;
               if Front_Len = 0 then
                  Front_Len := MAX_NAME_LEN;
               end if;
               Last_Front_Check_Time := Now;
            end;
         end if;

         -- Periodic 5-Second Health Report
         if Now >= Last_Report_Time + Seconds (5) then
            Ada.Text_IO.Put_Line ("[HEALTH CHECK] Free: " &
              Long_Float'Image (Current_Free_MB) & " MB | Wired: " &
              Long_Float'Image (Current_Wired_MB) & " MB | Lvl: " &
              Integer'Image (Current_Pressure) & " | Vel: " &
              Long_Float'Image (Wired_Velocity) & " MB/s");

            -- Read current Machine Learning forecasts
            Read_ML_Prediction (ML_Predicted_Pressure, ML_Risk_Level, ML_Target_PID);
            if ML_Predicted_Pressure >= 4 or else ML_Risk_Level (1 .. 4) = "high" then
               Ada.Text_IO.Put_Line ("[ML ALIGNMENT] Imminent spike forecasted! Level: " &
                 Integer'Image (ML_Predicted_Pressure) & " | Target Suggestion: PID " &
                 PID_T'Image (ML_Target_PID));
            end if;

            Last_Report_Time := Now;
         end if;

         -- Export JSON Telemetry (Throttled to 2s to avoid high I/O churn)
         if Now >= Last_Telemetry_Time + Seconds (2) then
            declare
               F_Start, P_Start, D_Start : UINT64_T;
               F_End, P_End, D_End : UINT64_T;
            begin
               Get_Memory_Snapshot_C (F_Start, P_Start, D_Start);
               delay 0.001;
               Get_Memory_Snapshot_C (F_End, P_End, D_End);
               Export_Telemetry (
                 Free_MB => Current_Free_MB,
                 Wired_MB => Current_Wired_MB,
                 Pressure_Level => Current_Pressure,
                 Wired_Velocity => Wired_Velocity,
                 Pageins_Per_Sec => (P_End - P_Start) * 1000,
                 Decomp_Per_Sec => (D_End - D_Start) * 1000,
                 Front_PID => Integer (Front_PID),
                 Front_Name => Front_Name (1 .. Front_Len),
                 Mitigation_Active => Mitigation_State.Is_Mitigating
               );
               Last_Telemetry_Time := Now;
            exception
               when others => null;
            end;
         end if;

         -- Decision Tree for Bloodshed
         declare
            Condition_Met : Boolean := False;
            Trigger_Reason : String (1 .. 128) := (others => ' ');
            Trigger_Len : Integer := 0;
         begin
            if Current_Pressure >= 4 then
               Condition_Met := True;
               -- FIX: Changed slice from (1..27) to (1..26).
               -- REASON: The string literal "Level 4 OS Memory Pressure" is 26
               --         characters, not 27. Mismatched slice length causes
               --         Constraint_Error at runtime. (Warning: default)
               Trigger_Reason (1 .. 26) := "Level 4 OS Memory Pressure";
               Trigger_Len := 26;
            elsif Current_Free_MB < CRITICAL_FREE_MB then
               Condition_Met := True;
               -- FIX: Changed slice from (1..28) to (1..27).
               -- REASON: The string literal "Free Memory Below Threshold" is 27
               --         characters, not 28. Mismatched slice length causes
               --         Constraint_Error at runtime. (Warning: default)
               Trigger_Reason (1 .. 27) := "Free Memory Below Threshold";
               Trigger_Len := 27;
            elsif Wired_Velocity > PANIC_VELOCITY_MB_S and then Current_Free_MB < (CRITICAL_FREE_MB * 4.0) then
               Condition_Met := True;
               -- FIX: Changed slice from (1..32) to (1..31).
               -- REASON: The string literal "Violent Memory Allocation Spike" is 31
               --         characters, not 32. Mismatched slice length causes
               --         Constraint_Error at runtime. (Warning: default)
               Trigger_Reason (1 .. 31) := "Violent Memory Allocation Spike";
               Trigger_Len := 31;
            -- FIX: Changed Current_Pressure >= 3 to Current_Pressure = 3.
            -- REASON: The compiler correctly identifies that since the first `if` branch
            --         already handles Current_Pressure >= 4, by the time we reach this
            --         elsif, Current_Pressure must be < 4. Therefore >= 3 is equivalent
            --         to = 3. (Warning: -gnatwc)
            elsif (ML_Predicted_Pressure = 4 or else ML_Predicted_Pressure = 5)
              and then Current_Pressure = 3
            then
               -- ML proactive tripwire: if ML predicts level 4 or 5, and current pressure
               -- is already level 3, proactively triggers bloodshed to prevent the OS
               -- from freezing up!
               Condition_Met := True;
               -- FIX: Changed slice from (1..45) to (1..44).
               -- REASON: The string literal "ML Preemptive Memory Pressure Spike Forecast"
               --         is 44 characters, not 45. Mismatched slice length causes
               --         Constraint_Error at runtime. (Warning: default)
               Trigger_Reason (1 .. 44) := "ML Preemptive Memory Pressure Spike Forecast";
               Trigger_Len := 44;
            end if;

            if Condition_Met and then Current_Pressure >= MIN_PRESSURE_LEVEL_TO_KILL
              and then not Mitigation_State.Is_Mitigating
            then
               Handle_Bloodshed (Trigger_Reason (1 .. Trigger_Len), Page_Size);
               Now := Clock;
               Current_Free_MB := Long_Float (Get_Free_MB_C (Page_Size));
               Current_Pressure := Integer (Get_Memory_Pressure_Level_C);
            end if;
         end;

         Last_Time := Now;
         Last_Wired_MB := Current_Wired_MB;
      end;
   end loop;

exception
   when others =>
      Thrashing_Mitigation_Out;
      Ada.Text_IO.Put_Line ("[Murasama LMKd] Daemon shut down cleanly.");
end Murasamalmk_Daemon;
