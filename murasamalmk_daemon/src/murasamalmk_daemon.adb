with Ada.Text_IO;
with Ada.Real_Time; use Ada.Real_Time;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Unchecked_Deallocation;
with Interfaces.C; use Interfaces.C;
with MacOS_Bridge; use MacOS_Bridge;
with Murasama_Log;  -- parameterless procs only: use-clause has no effect (-gnatwu)
with Murasama_Types; use Murasama_Types;
with Murasama_Weights; use Murasama_Weights;
with Murasama_Telemetry; use Murasama_Telemetry;
with Murasama_Leak_Killer;  -- parameterless Check_And_Kill: full name call
with Murasama_Guard;

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

   -- Thread-safe errno access (GNAT idiom): errno is thread-local on Darwin,
   -- so we must read it through libc's __error accessor, never a global.
   function Errno_Location return access constant int;
   pragma Import (C, Errno_Location, "__error");

   -- errno values used by kill(pid, 0) disambiguation (sys/errno.h)
   EPERM : constant int := 1;  -- Operation not permitted: process EXISTS,
                               -- but our uid lacks signal permission
   ESRCH : constant int := 3;  -- No such process: genuinely dead

   -- Async AppleScript/Zenity Warning Task
   task type Async_Command_Runner is
      entry Enqueue (Cmd : String);
   end Async_Command_Runner;

   type Async_Command_Runner_Access is access Async_Command_Runner;
   Runner : Async_Command_Runner_Access;

   -- DERIVATION:
   --   AXIOMS: A1) notification commands may arrive at any instant from any
   --     task; A2) the monitoring loop must NEVER stall waiting on this task;
   --     A3) at most one shell command executes per 30s window (throttle).
   --   THEOREMS: T1) a select with delay alternative keeps the entry open
   --     while timing out (ARM 9.7.2); T2) accept statements are legal only
   --     directly inside a task body (ARM 9.5); T3) modular ring indices
   --     bounded by Command_Queue_Size never overflow.
   --   APPLICATIONS: the 30s cooldown is a delay-alternative, not a bare
   --     delay -- Enqueue stays open throughout (T1 => A2, liveness fix);
   --     both select arms written inline because helpers cannot contain
   --     accepts (T2); Head/Tail wrap arithmetic (T3); dequeued strings are
   --     freed via Unchecked_Deallocation (leak fix).
   -- TIMING ANALYSIS:
   --   Estimated: rendezvous <10us; command execution unbounded (external)
   --   CPU Time: idle ~0 (task blocked inside select)
   --   WCET: enqueue O(1) bounded; execution delegated to OS scheduler
   --   Space: fixed 128-slot access table (~1KB) + heap command strings
   --   Hardware Assumptions: none beyond POSIX fork/exec availability

    task body Async_Command_Runner is
      -- Tasking loop to run commands asynchronously with 30s throttling
      type String_Access is access String;
      -- Queue depth: local constant so bound and wrap-around arithmetic
      -- share one source of truth (🟡22).
      Command_Queue_Size : constant := 128;
      type Queue_Array is array (1 .. Command_Queue_Size) of String_Access;
      Queue : Queue_Array := (others => null);
      Head  : Positive := 1;
      Tail  : Positive := 1;
      Count : Natural := 0;

      -- FIX: dequeued strings were previously leaked (access discarded, never
      -- freed). Explicit reclamation via Unchecked_Deallocation.
      procedure Free_String is new Ada.Unchecked_Deallocation (
         Object => String,
         Name   => String_Access);

      Throttling : Boolean := False;
   begin
      loop
         -- FIX (LIVENESS): the 30s cooldown previously ran as a bare `delay
         -- 30.0` OUTSIDE any select, which blocked the Enqueue rendezvous and
         -- stalled the main monitoring task for up to 30s during critical
         -- events. Now the cooldown is a select delay-alternative: Enqueue
         -- stays open throughout, so callers never block. Rate-limiting
         -- semantics preserved (max one command executed per 30s window).
         -- NOTE: accept statements cannot live in nested procedures
         -- (ARM 9.5), so both select arms are written out in full here.
         if Throttling then
            select
               accept Enqueue (Cmd : String) do
                  if Count < Command_Queue_Size then
                     Queue (Tail) := new String'(Cmd);
                     Tail := (if Tail = Command_Queue_Size then 1 else Tail + 1);
                     Count := Count + 1;
                  end if;
               end Enqueue;
            or
               delay 30.0;
               Throttling := False;
            end select;
         else
            select
               accept Enqueue (Cmd : String) do
                  if Count < Command_Queue_Size then
                     Queue (Tail) := new String'(Cmd);
                     Tail := (if Tail = Command_Queue_Size then 1 else Tail + 1);
                     Count := Count + 1;
                  end if;
               end Enqueue;
            or
               delay Duration (POLL_INTERVAL_MS) / 1000.0;
            end select;
         end if;

         if Count > 0 then
            declare
               Cmd_To_Run : constant String := Queue (Head).all;
               Slot       : String_Access := Queue (Head);
            begin
               Queue (Head) := null;
               Head := (if Head = Command_Queue_Size then 1 else Head + 1);
               Count := Count - 1;

               Free_String (Slot);

               -- Execute command
               declare
                  C_Cmd : constant char_array := To_C (Cmd_To_Run);
               begin
                  Run_System_Command_C (C_Cmd);
               end;
            end;
            Throttling := True;
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
      procedure Set_Blacklisted_Deprioritized (Val : Boolean);
      function Blacklisted_Deprioritized return Boolean;
   private
      Active        : Boolean := False;
      End_Time      : Time := Clock;
      Boosted_List  : PID_Array (int(1) .. int(512)) := (others => 0);
      Boosted_Count : Integer := 0;

      -- FIX (RESTORE STORM): Restore_Blacklisted_Priorities_C was previously
      -- invoked on EVERY 100ms main-loop iteration under normal pressure,
      -- causing a full PID scan + fork/exec per match. It is now gated on
      -- this flag: restore only runs when a deprioritization actually
      -- happened since the last restore.
      Blacklisted_Flag : Boolean := False;

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
         -- FIX: Boosted_Count was stored unclamped while Boosted_List is
         -- bounded at 512 — a latent Constraint_Error if ever called with
         -- Count > 512. Clamped to both the list bound and the source length.
         Safe_Count : constant Integer :=
           Integer'Min (Integer'Min (Count, Boosted_List'Length), PIDs'Length);
      begin
         Boosted_Count := Safe_Count;
         for I in 1 .. Safe_Count loop
            Boosted_List (int(I)) := PIDs (PIDs'First + int(I) - 1);
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

      procedure Set_Blacklisted_Deprioritized (Val : Boolean) is
      begin
         Blacklisted_Flag := Val;
      end Set_Blacklisted_Deprioritized;

      function Blacklisted_Deprioritized return Boolean is
      begin
         return Blacklisted_Flag;
      end Blacklisted_Deprioritized;
   end Mitigation_State;

   -- POSIX shell single-quote escaping: wraps the value in '...' and embeds
   -- literal single quotes as the 4-char idiom '\'' (close-quote, escaped
   -- quote, reopen). Prevents CWE-78 shell command injection when process
   -- names (attacker-controllable via argv[0]) are interpolated into commands
   -- executed through system().
   -- TIMING ANALYSIS:
   --   Estimated: O(n) single pass, n = MAX_NAME_LEN(64) worst case
   --   CPU Time: <1us on Apple Silicon (M-series), no syscalls
   --   WCET: bounded by fixed buffer size (2 + 5*64 chars)
   --   Space: 322-byte stack buffer
   --   Derivation: each input char emits at most 4 output chars (quote case,
   --               '\'' idiom), plus 2 wrapper quotes; loop is linear.
   --               NOTE: Ada strings have NO escape sequences, so the idiom
   --               is written literally as "'\''".
   --   Hardware Assumptions: none (pure computation)
   function Shell_Quote (S : String) return String is
      Result : String (1 .. 2 + S'Length * 5) := (others => ' ');
      Pos    : Natural := 0;
   begin
      Pos := Pos + 1;
      Result (Pos) := ''';
      for I in S'Range loop
         if S (I) = ''' then
            Result (Pos + 1 .. Pos + 4) := "'\''";
            Pos := Pos + 4;
         else
            Pos := Pos + 1;
            Result (Pos) := S (I);
         end if;
      end loop;
      Pos := Pos + 1;
      Result (Pos) := ''';
      return Result (1 .. Pos);
   end Shell_Quote;

   -- DERIVATION:
   --   AXIOMS: process names are attacker-controllable (argv[0]) and reach
   --     this code verbatim from the kernel's process table.
   --   THEOREMS: a POSIX sh token in single quotes is literal data with no
   --     interpolation; the only required escape is the 4-char idiom '\''
   --     for embedded quotes (see Shell_Quote; CWE-78 countermeasure).
   --   APPLICATIONS: every free-text field passes through Shell_Quote; the
   --     UID field is numeric via 'Image, hence injection-safe.
   -- TIMING ANALYSIS:
   --   Estimated: string build O(name len); enqueue O(1); exec async
   --   CPU Time: <5us to build and queue
   --   WCET: bounded by MAX_NAME_LEN-derived Shell_Quote buffers
   --   Space: ~700B transient declare-block strings
   --   Hardware Assumptions: zenity installed at hardcoded path (silent no-op
   --     if missing; enqueue still occurs)
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
         -- FIX (CWE-78): Target_Name and Reason were previously interpolated
         -- UNESCAPED into a double-quoted shell string. A process named e.g.
         --    x"; rm -rf ~; echo "
         -- would break out and execute arbitrary commands as root. Both fields
         -- are now Shell_Quote'd, making the argument a single literal token.
         Cmd : constant String := "launchctl asuser " & UID_Trimmed &
           " /opt/homebrew/bin/zenity --warning --text=" &
           Shell_Quote ("Terminated " & Target_Name & ". Reason: " & Reason) &
           " --title=" & Shell_Quote ("Murasama LMKd: Bloodshed") & " --width=300";
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
   -- DERIVATION:
   --   AXIOMS: A1) mitigation must be idempotent against concurrent trip
   --     sources; A2) every boost applied here is reversible by Mitigation_Out;
   --     A3) blacklisted deprioritization pairs with exactly ONE restore
   --     (restore-storm invariant, enforced via Blacklisted_Flag).
   --   THEOREMS: T1) protected-object mutual exclusion serializes Mitigation_
   --     State updates across tasks (ARM 9.4); T2) Get_Process_Tree_C emits
   --     at most 256 entries == Boosted_List capacity (clamped on store).
   --   APPLICATIONS: early-return guard implements A1 (T1); boosted PID set
   --     is recorded BEFORE priorities change, guaranteeing A2; flag arm
   --     after Deprioritize_Blacklisted_C discharges A3.
   -- TIMING ANALYSIS:
   --   Estimated: top-50 report + BFS tree walk + <=256 setpriority calls
   --   CPU Time: dominated by C-bridge sysctl scans (~10ms typical)
   --   WCET: ~100ms under heavy contention; runs at most once per hysteresis
   --   Space: 100-entry + 256-entry PID/RAM arrays (~4KB stack)
   --   Hardware Assumptions: macOS proc_info sysctl interface present
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

         -- Deprioritize blacklisted processes during thrashing mitigation
         Deprioritize_Blacklisted_C;
         Mitigation_State.Set_Blacklisted_Deprioritized (True);
      end if;

      Mitigation_State.Set_Mitigating (True);
      Mitigation_State.Set_End_Time (Clock + Seconds (HYSTERESIS_SECONDS));
   end Thrashing_Mitigation_In;

   -- DERIVATION: exact mirror of Thrashing_Mitigation_In.
   --   AXIOM: restores touch ONLY PIDs recorded during In (no blind resets).
   --   THEOREM: a restored PID that exited meanwhile makes setpriority fail
   --     harmlessly (ESRCH swallowed by the C bridge); PID reuse inside the
   --     60s hysteresis window is accepted residual risk (documented).
   --   APPLICATION: iterate recorded list -> priority 0 -> clear -> game
   --     mode auto -> cpulimit sweep -> Active := False releases the guard.
   -- TIMING ANALYSIS: Estimated <=512 setpriority calls ~1ms total; WCET
   --   bounded by Boosted_List'Length; Space O(1) locals; Hardware:
   --   macOS setpriority(2)/taskpolicy semantics.
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
          delay Duration (SNAPSHOT_SPACING_MS) / 1000.0;
          Get_Memory_Snapshot_C (Snap_End_Faults, Snap_End_Pageins, Snap_End_Decomp);

          Pageins_Per_Sec := (Snap_End_Pageins - Snap_Start_Pageins) * 10;
          Decomp_Per_Sec := (Snap_End_Decomp - Snap_Start_Decomp) * 10;
          Pressure_Level := Clamp_Pressure_Level (Integer (Get_Memory_Pressure_Level_C));
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

         delay Duration (THRASHING_IDLE_MS) / 1000.0; -- Repeat cycle
      end loop;
   end Thrashing_Task;

   -- Bloodshed Handler
   -- DERIVATION:
   --   AXIOMS: A1) SIGKILL can fail (target exited, EPERM, zombie race);
   --     A2) kill weights reflect CONFIRMED kills only; A3) system processes
   --     are never targeted.
   --   THEOREMS: T1) kill() reports failure via nonzero return + errno
   --     (POSIX signal(3)); T2) RAM-gradient over GRADIENT_MEASURE_MS ranks
   --     leaky vs steady consumers; T3) protection gate precedes every kill.
   --   APPLICATIONS: Kill_Result checked at the kill site (A1/T1): failures
   --     log loudly, mark the target skipped, and never Increment_Weight
   --     (A2); Is_System_Process_C guard (A3/T3); selection policy =
   --     weight-priority first, then lowest growth (least collateral),
   --     finally highest-growth offender.
   -- TIMING ANALYSIS:
   --   Estimated: per cycle = 100ms gradient + 200ms settle + queries
   --   CPU Time: sysctl-bound; <15% of one core across <=3 cycles
   --   WCET: ~1s hard bound (3 cycles max via MAX_KILLS)
   --   Space: TOP_N_PROCESSES-sized arrays, O(1) aux state
   --   Hardware Assumptions: proc_pidinfo resident size stable enough over
   --     100ms for meaningful rate ranking
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

      -- Deprioritize blacklisted processes during bloodshed
      Deprioritize_Blacklisted_C;
      Mitigation_State.Set_Blacklisted_Deprioritized (True);

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

               -- Select and kill an eligible target, skipping system processes
               declare
                  Skipped_Pids : array (1 .. TOP_N_PROCESSES) of PID_T := (others => 0);
                  Skipped_Count : Natural := 0;
                  Killed_Something : Boolean := False;
               begin
                  for Attempt in 1 .. int(TOP_N_PROCESSES) loop
                     declare
                        Target_Idx : Integer := -1;
                        Max_Weight : Integer := -1;
                        Phase_Desc : String (1 .. 64) := (others => ' ');
                        Phase_Len  : Integer := 0;
                     begin
                        -- 1. Check for weight priority (skip already-skipped PIDs)
                        for I in 1 .. Integer (Top_Count) loop
                           declare
                              P_Name : constant String := Names (I) (1 .. Name_Lens (I));
                              W      : constant Natural := Get_Weight (P_Name);
                              Is_Skipped : Boolean := False;
                           begin
                              for S in 1 .. Skipped_Count loop
                                 if Top_Pids (int(I)) = Skipped_Pids (S) then
                                    Is_Skipped := True;
                                    exit;
                                 end if;
                              end loop;
                               if not Is_Skipped and then Is_Weight_Priority (W) then
                                 if W > Max_Weight then
                                    Max_Weight := W;
                                    Target_Idx := I;
                                    Phase_Desc (1 .. 13) := "priority kill";
                                    Phase_Len := 13;
                                 end if;
                              end if;
                           end;
                        end loop;

                        -- 2. Fallback to rate behavior (skip already-skipped PIDs)
                        if Target_Idx = -1 then
                           if Kill_Count < 2 then
                              declare
                                 Min_Rate : Long_Float := 999999.0;
                              begin
                                 for I in 1 .. Integer (Top_Count) loop
                                    declare
                                       Is_Skipped : Boolean := False;
                                    begin
                                       for S in 1 .. Skipped_Count loop
                                          if Top_Pids (int(I)) = Skipped_Pids (S) then
                                             Is_Skipped := True;
                                             exit;
                                          end if;
                                       end loop;
                                       if not Is_Skipped and then Rates (I) < Min_Rate then
                                          Min_Rate := Rates (I);
                                          Target_Idx := I;
                                       end if;
                                    end;
                                 end loop;
                                 if Target_Idx /= -1 then
                                    if Kill_Count = 0 then
                                       Phase_Desc (1 .. 25) := "first kill (lowest rate) ";
                                       Phase_Len := 25;
                                    else
                                       Phase_Desc (1 .. 25) := "second kill (lowest rate)";
                                       Phase_Len := 25;
                                    end if;
                                 end if;
                              end;
                           else
                              declare
                                 Max_Rate : Long_Float := -999999.0;
                              begin
                                 for I in 1 .. Integer (Top_Count) loop
                                    declare
                                       Is_Skipped : Boolean := False;
                                    begin
                                       for S in 1 .. Skipped_Count loop
                                          if Top_Pids (int(I)) = Skipped_Pids (S) then
                                             Is_Skipped := True;
                                             exit;
                                          end if;
                                       end loop;
                                       if not Is_Skipped and then Rates (I) > Max_Rate then
                                          Max_Rate := Rates (I);
                                          Target_Idx := I;
                                       end if;
                                    end;
                                 end loop;
                                 if Target_Idx /= -1 then
                                    Phase_Desc (1 .. 25) := "third kill (highest rate)";
                                    Phase_Len := 25;
                                 end if;
                              end;
                           end if;
                        end if;

                        if Target_Idx /= -1 then
                           declare
                              T_PID  : constant PID_T := Top_Pids (int(Target_Idx));
                              T_Name : constant String := Names (Target_Idx) (1 .. Name_Lens (Target_Idx));
                              T_Path : char_array (size_t(1) .. size_t(1024)) := (others => ' ');
                           begin
                              Get_Process_Path_C (T_PID, T_Path, int(1024));

                              if Is_System_Process_C (T_Path) /= 0
                                or else Murasama_Guard.Is_Protected_Path
                                  (To_Ada (T_Path, Trim_Nul => True))
                              then
                                 Ada.Text_IO.Put_Line ("[SKIP] PID " & PID_T'Image (T_PID) & " (" &
                                   T_Name & ") is a protected system process. Skipping.");
                                 Skipped_Count := Skipped_Count + 1;
                                 Skipped_Pids (Skipped_Count) := T_PID;
                              else
                                 Ada.Text_IO.Put_Line ("Phase: " & Phase_Desc (1 .. Phase_Len));
                                 Ada.Text_IO.Put_Line ("Target: PID " & PID_T'Image (T_PID) & " (" & T_Name & ")");

                                 Queue_Zenity_Warning (T_Name, Trigger_Reason & " (" & Phase_Desc (1 .. Phase_Len) & ")");

                                  -- FIX (MURPHY'S LAW): the SIGKILL result was previously
                                  -- discarded via pragma Unreferenced — a failed kill was
                                  -- counted as success AND falsely incremented the kill
                                  -- weight. Now: nonzero result → verbose report, target
                                  -- marked skipped, no weight increment, no kill count.
                                  declare
                                     Kill_Result : constant int := Kill_C (T_PID, int(9)); -- SIGKILL
                                  begin
                                     if Kill_Result /= 0 then
                                        Ada.Text_IO.Put_Line ("[KILL FAILED] SIGKILL on PID " &
                                          PID_T'Image (T_PID) & " (" & T_Name & ") returned " &
                                          int'Image (Kill_Result) & " (see errno). Not counting as killed.");
                                        Skipped_Count := Skipped_Count + 1;
                                        Skipped_Pids (Skipped_Count) := T_PID;
                                     else
                                        Kill_Count := Kill_Count + 1;
                                        Increment_Weight (T_Name);
                                        delay 0.2;
                                        Killed_Something := True;
                                     end if;
                                  end;
                              end if;
                           exception
                              when others =>
                                 Skipped_Count := Skipped_Count + 1;
                                 if Target_Idx >= 1 and then Target_Idx <= Integer (Top_Count) then
                                    Skipped_Pids (Skipped_Count) := Top_Pids (int(Target_Idx));
                                 end if;
                           end;
                        end if;

                        exit when Target_Idx = -1 or else Killed_Something;
                     end;
                  end loop;

                  if not Killed_Something then
                     Ada.Text_IO.Put_Line ("No eligible target found. All candidates are protected.");
                     exit;
                  end if;
               end;
            end;
         end;

         -- Re-evaluate pressure (via SPARK-verified predicates — single source of truth)
         Free_MB        := Long_Float (Get_Free_MB_C (Page_Size));
         Pressure_Level := Clamp_Pressure_Level (Integer (Get_Memory_Pressure_Level_C));
         if not Is_Free_Memory_Critical (Free_MB)
           and then not Is_Critical_Pressure (Pressure_Level)
         then
            Ada.Text_IO.Put_Line ("Memory pressure resolved after " & Integer'Image (Kill_Count) & " kill(s).");
            exit;
         end if;
      end loop;

      if Kill_Count = MAX_KILLS then
         Ada.Text_IO.Put_Line ("Maximum kills reached. Pressure may still persist.");
      end if;
   end Handle_Bloodshed;

   -- Read machine learning prediction from a flat file
   -- DERIVATION:
   --   AXIOMS: A1) the file may be missing, mid-rename, or malformed at any
   --     read (Python sidecar writes concurrently); A2) parse failure must
   --     degrade to safe defaults, never propagate.
   --   THEOREMS: the sidecar writes atomically (tmp+rename), so any fully
   --     opened snapshot is internally consistent.
   --   APPLICATIONS: defaults seeded into out-params FIRST (level=1,
   --     risk="low", pid=0) so every early-return is well-defined; open and
   --     per-field 'Value conversions individually guarded and LOGGED via
   --     Murasama_Log (verbose-reporting mandate, no silent swallow).
   -- TIMING ANALYSIS: Estimated <0.1ms; WCET bounded by 256-byte lines over
   --   a handful of records; Space: 256B line buffer; Hardware: none.
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
            -- FIX: previously a silent return. File exists but cannot be opened
            -- (permissions/race with atomic rename) — report verbosely.
            Murasama_Log.Warn ("ML prediction file exists but cannot be opened: " & Path);
            return;
      end;

      while not Ada.Text_IO.End_Of_File (File) loop
         Ada.Text_IO.Get_Line (File, Line, Last);
         if Last >= 20 and then Line (1 .. 19) = "predicted_pressure:" then
            begin
               Predicted_Pressure := Integer'Value (Line (20 .. Last));
            exception
               when others =>
                  Murasama_Log.Warn ("ML parse: malformed predicted_pressure value '" &
                    Line (20 .. Last) & "'");
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
               when others =>
                  Murasama_Log.Warn ("ML parse: malformed target_pid value '" &
                    Line (12 .. Last) & "'");
            end;
         end if;
      end loop;

      Ada.Text_IO.Close (File);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         Murasama_Log.Error ("Unexpected failure while reading ML prediction file: " & Path);
   end Read_ML_Prediction;

   -- ==================== SIDECAR MANAGER ====================
   -- Spawns, monitors, and restarts the Python ML predictor sidecar.
   -- Replaces the nohup-based launch from start.sh with proper process
   -- lifecycle management from within the Ada daemon.

   -- FIX (CWE-377): spawn artifacts moved from world-writable /tmp (where the
   -- predictable names murasama_spawn.sh / murasama_pid.txt were symlink-
   -- clobberable by any local user against a ROOT daemon) to a root-owned
   -- private runtime directory created at startup.
   RUN_DIR          : constant String := "/usr/local/murasamaLMKd/run";
   SPAWN_SCRIPT     : constant String := RUN_DIR & "/murasama_spawn.sh";
   SPAWN_PID_FILE   : constant String := RUN_DIR & "/murasama_pid.txt";
   ML_PREDICTOR_PATH : constant String :=
     "/usr/local/murasamaLMKd/murasamalmk_daemon/python/venv/bin/python3";
   ML_PREDICTOR_SCRIPT : constant String :=
     "/usr/local/murasamaLMKd/murasamalmk_daemon/python/ml_predictor.py";
   ML_PREDICTOR_LOG : constant String :=
     RUN_DIR & "/ml_predictor.log";

   -- Check if a process with given PID is alive
   -- DERIVATION (audit 🟡30):
   --   AXIOM: kill(pid, 0) sends no signal; its errno fully disambiguates.
   --   THEOREM: Result=0 => exists+permitted; Result=-1 with EPERM => the
   --     process EXISTS but our uid may not signal it (must count as ALIVE,
   --     else we would restart a live sidecar forever); -1 with ESRCH =>
   --     no such process. Any other errno: fail closed as dead + log.
   --   APPLICATIONS: read errno via thread-local __error accessor BEFORE
   --     any other libc call can clobber it.
   function Is_Process_Alive (PID : PID_T) return Boolean is
      Result : int;
   begin
      -- kill(pid, 0) checks existence without sending signal
      Result := Kill_C (PID, 0);
      if Result = 0 then
         return True;
      end if;

      declare
         Err : constant int := Errno_Location.all;
      begin
         if Err = EPERM then
            return True;  -- exists, owned by another uid
         elsif Err /= ESRCH then
            Murasama_Log.Warn
              ("Is_Process_Alive(" & PID_T'Image (PID) &
               "): unexpected errno" & int'Image (Err) & ", treating as dead");
         end if;
         return False;
      end;
   end Is_Process_Alive;

   -- Spawn the ML predictor sidecar, return its PID (0 on failure)
   -- DERIVATION:
   --   AXIOMS: A1) spawn artifacts exist only in root-owned RUN_DIR
   --     (CWE-377: predictable names in world-writable /tmp are symlink-
   --     clobberable against a ROOT daemon); A2) child startup can fail
   --     (missing venv, exec error) and MUST surface as PID 0.
   --   THEOREMS: bash "$!" expands to the background child's PID, providing
   --     a race-free handle later polled via kill(pid,0).
   --   APPLICATIONS: write script -> chmod -> run redirecting "$!" into
   --     SPAWN_PID_FILE -> guarded 'Value parse; every failure branch logs
   --     (Warn/Error) and yields 0 (A2).
   -- TIMING ANALYSIS:
   --   Estimated: ~550ms wall (system() fork/exec + 0.5s settle delay)
   --   CPU Time: negligible here; work belongs to the child
   --   WCET: unbounded if fork stalls -- acceptable, off the hot path
   --   Space: 32-byte PID line buffer
   --   Hardware Assumptions: /usr/local mount exec-permitted, venv intact
   function Spawn_ML_Predictor return PID_T is
   begin
      -- Write a spawn script in the private runtime dir to get the PID
      declare
         File : Ada.Text_IO.File_Type;
         Line : String (1 .. 32);
         Last : Natural;
         Result_PID : PID_T := 0;
      begin
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, SPAWN_SCRIPT);
         Ada.Text_IO.Put_Line (File, "#!/bin/bash");
         Ada.Text_IO.Put_Line (File, "nice -n 19 " & ML_PREDICTOR_PATH & " " & ML_PREDICTOR_SCRIPT &
           " > " & ML_PREDICTOR_LOG & " 2>&1 &");
         Ada.Text_IO.Put_Line (File, "echo $!");
         Ada.Text_IO.Close (File);

         Run_System_Command_C (To_C ("chmod +x " & SPAWN_SCRIPT));

         -- Read the PID from stdout
         Run_System_Command_C (To_C (SPAWN_SCRIPT & " > " & SPAWN_PID_FILE));
         delay 0.5;

         if Ada.Directories.Exists (SPAWN_PID_FILE) then
            begin
               Ada.Text_IO.Open (File, Ada.Text_IO.In_File, SPAWN_PID_FILE);
            exception
               when others =>
                  Murasama_Log.Warn ("Spawn: pid file exists but cannot be opened: " & SPAWN_PID_FILE);
                  return 0;
            end;
            if not Ada.Text_IO.End_Of_File (File) then
               Ada.Text_IO.Get_Line (File, Line, Last);
               if Last > 0 then
                  begin
                     Result_PID := PID_T'Value (Line (1 .. Last));
                  exception
                     when others =>
                        Murasama_Log.Warn ("Spawn: malformed pid value '" & Line (1 .. Last) & "'");
                        Result_PID := 0;
                  end;
               end if;
            end if;
            Ada.Text_IO.Close (File);
         else
            Murasama_Log.Error ("Spawn: pid file was not produced: " & SPAWN_PID_FILE);
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

   -- Shared sidecar PID so the main-procedure shutdown path can reap the
   -- child even though it is managed by a separate task.
   protected Sidecar_State is
      procedure Set_Current_PID (PID : PID_T);
      function Get_Current_PID return PID_T;
   private
      Current_PID : PID_T := 0;
   end Sidecar_State;

   protected body Sidecar_State is
      procedure Set_Current_PID (PID : PID_T) is
      begin
         Current_PID := PID;
      end Set_Current_PID;

      function Get_Current_PID return PID_T is
      begin
         return Current_PID;
      end Get_Current_PID;
   end Sidecar_State;

   -- Sidecar Manager Task: spawns and monitors the ML predictor
   task Sidecar_Manager_Task;
   task body Sidecar_Manager_Task is
      ML_PID        : PID_T := 0;
      Restart_Count : Integer := 0;
      Max_Restarts  : constant Integer := 5;
      Check_Interval : constant Duration := 5.0;
      Last_Health_Check : Time := Clock;

      -- Sustained-health forgiveness (audit 🟡20/🔵37): a crash storm hours
      -- ago must not permanently exhaust the restart budget. After
      -- Healthy_Streak_Target consecutive healthy checks (~5 min), the
      -- counter resets so only RECENT instability can trigger give-up.
      Healthy_Streak          : Integer := 0;
      Healthy_Streak_Target   : constant Integer := 10;  -- 10 x 30s = 5 min
   begin
      delay 3.0; -- Wait for daemon initialization

      -- Initial spawn
      Ada.Text_IO.Put_Line ("[SIDECAR] Spawning ML predictor sidecar...");
      ML_PID := Spawn_ML_Predictor;
      Sidecar_State.Set_Current_PID (ML_PID);
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
                 Sidecar_State.Set_Current_PID (0);
                 Restart_Count := Restart_Count + 1;
                 Healthy_Streak := 0;

                if Restart_Count > Max_Restarts then
                   Ada.Text_IO.Put_Line ("[SIDECAR] Max restarts (" &
                     Integer'Image (Max_Restarts) & ") reached. Giving up.");
                   exit;
                end if;

                delay 1.0;
                ML_PID := Spawn_ML_Predictor;
                Sidecar_State.Set_Current_PID (ML_PID);
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
             Sidecar_State.Set_Current_PID (ML_PID);
             if ML_PID > 0 then
               Ada.Text_IO.Put_Line ("[SIDECAR] ML predictor spawned. PID:" & PID_T'Image (ML_PID));
            end if;
         end if;

         -- Periodic health log
         if Clock >= Last_Health_Check + Seconds (30) then
            if ML_PID > 0 and then Is_Process_Alive (ML_PID) then
               Ada.Text_IO.Put_Line ("[SIDECAR] ML predictor healthy. PID:" &
                 PID_T'Image (ML_PID) & " | Restarts:" & Integer'Image (Restart_Count));
               Healthy_Streak := Healthy_Streak + 1;
               if Restart_Count > 0 and then Healthy_Streak >= Healthy_Streak_Target then
                  Ada.Text_IO.Put_Line ("[SIDECAR] Sustained health (" &
                    Integer'Image (Healthy_Streak) & " checks). Restart budget restored.");
                  Restart_Count := 0;
               end if;
            else
               Ada.Text_IO.Put_Line ("[SIDECAR] ML predictor not running. Restarts:" &
                 Integer'Image (Restart_Count));
               Healthy_Streak := 0;
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
   Last_Mem_Monitor_Time : Time := Clock;
   Last_Leak_Check_Time : Time := Clock;
   Last_CPU_Check_Time  : Time := Clock;

   CPU_Baseline_Set : Boolean := False;
   CPU_Inefficiency_Active : Boolean := False;
   Prev_User_Ticks   : UINT64_T := 0;
   Prev_System_Ticks : UINT64_T := 0;
   Prev_Idle_Ticks   : UINT64_T := 0;
   Prev_Nice_Ticks   : UINT64_T := 0;

   Iteration_Start : Time := Clock;

   Last_Wired_MB : Long_Float;

   Current_Free_MB : Long_Float;
   Current_Wired_MB : Long_Float;
   Current_Pressure : Integer;

   -- Panic velocity threshold (MB/s) derived dynamically from total RAM.
   Panic_Velocity_Threshold_MB_S : Long_Float := 15750.0;

   ML_Predicted_Pressure : Integer := 1;
   ML_Risk_Level : String (1 .. 10) := (others => ' ');
   ML_Target_PID : PID_T := 0;

   Front_PID : PID_T := 0;
   Front_Name : String (1 .. MAX_NAME_LEN) := (others => ' ');
   Front_Len : Integer := 0;

begin
   -- Install async-safe SIGTERM/SIGINT flag handlers FIRST so a kill arriving
   -- during initialization is still honored by the main-loop poll.
   Install_Shutdown_Handlers_C;

   -- Initialize async runner
   Runner := new Async_Command_Runner;

   -- Create the root-owned private runtime directory used for sidecar spawn
   -- artifacts (CWE-377 fix — never /tmp).
   if not Ada.Directories.Exists (RUN_DIR) then
      begin
         Ada.Directories.Create_Directory (RUN_DIR);
         Murasama_Log.Info ("Created private runtime directory: " & RUN_DIR);
      exception
         when others =>
            Murasama_Log.Critical ("Cannot create runtime directory " & RUN_DIR &
              " -- sidecar spawn will fail");
      end;
   end if;

   Ada.Text_IO.Put_Line ("[Murasama LMKd] Unsheathed. GUI Notifications Enabled. Polling interval = 100ms.");
   Ada.Text_IO.Put_Line ("Thrashing detection active. Mitigation threshold: pageins/s > " &
     Integer'Image (THRASHING_THRESHOLD_PAGEINS) & " or decomp/s > " & Integer'Image (THRASHING_THRESHOLD_DECOMP));

   Init_Weights;
   Load_Weights;

   -- ---- Memory pinning (mlockall) ----
   -- A memory-pressure daemon must never be paged out during the very crisis
   -- it mitigates. MCL_CURRENT pins all existing mappings; MCL_FUTURE pins all
   -- future heap allocations, keeping the hardened allocation paths reliable
   -- under pressure. Requires root — the daemon runs as root via launchd.
   if Lock_All_Memory_C /= 0 then
      Murasama_Log.Critical ("mlockall FAILED -- daemon pages may be evicted under pressure");
   else
      Murasama_Log.Info ("Daemon memory pinned in RAM (mlockall MCL_CURRENT|MCL_FUTURE)");
   end if;

   -- Pre-fault sweep: exercise the large working-set buffers once while the
   -- system is healthy so their pages are materialized and (post-mlockall)
   -- permanently resident before any crisis.
   declare
      Sweep_Pids : PID_Array (int(1) .. int(512)) := (others => 0);
      Sweep_RAM  : UINT64_Array (int(1) .. int(512)) := (others => 0);
      Sweep_Count : int;
      pragma Unreferenced (Sweep_Count);
   begin
      Sweep_Count := Get_Top_Processes_By_Memory_C (Sweep_Pids, Sweep_RAM, int(512), int(0));
      Murasama_Log.Info ("Pre-fault sweep complete: 512-entry process buffers resident");
   end;

   Last_Wired_MB := Long_Float (Get_Wired_MB_C (Page_Size));

   -- Dynamic panic-velocity threshold = machine total RAM (MB).
   declare
      Total_RAM_MB : constant Long_Float := Long_Float (Get_Total_RAM_MB_C);
   begin
      if Total_RAM_MB > 0.0 then
         Panic_Velocity_Threshold_MB_S := Total_RAM_MB * 0.75;
         Murasama_Log.Info ("Panic velocity threshold set to 75% of total RAM: " &
           Long_Float'Image (Panic_Velocity_Threshold_MB_S) & " MB/s");
      else
         Murasama_Log.Warn ("Total RAM detection failed; using fallback threshold 15750.0 MB/s");
      end if;
   end;

   -- Main Loop
   loop
      delay Duration (POLL_INTERVAL_MS) / 1000.0; -- 100ms poll (Optimized for <0.9% CPU)
      Iteration_Start := Clock;

      -- Clean-shutdown poll (SIGTERM/SIGINT): handlers only set a flag, all
      -- cleanup happens here in normal tasking context.
      if Shutdown_Requested_C /= 0 then
         Murasama_Log.Warn ("Shutdown signal received -- initiating graceful shutdown");
         exit;
      end if;

      Current_Free_MB := Long_Float (Get_Free_MB_C (Page_Size));
      Current_Wired_MB := Long_Float (Get_Wired_MB_C (Page_Size));
      Current_Pressure := Clamp_Pressure_Level (Integer (Get_Memory_Pressure_Level_C));

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

         -- Lightweight CPU sampling (every 30s; no top(1) fork).
         -- Heuristic: if idle < 50% AND sys/user tick ratio > 1.0, the
         -- kernel is doing more work than userspace -> inefficiency, often
         -- a symptom of paging/decompression/fault storms.
         if Now >= Last_CPU_Check_Time + Seconds (30) then
            declare
               U, S, I, N : UINT64_T;
               RC : int;
            begin
               RC := Get_CPU_Ticks_C (U, S, I, N);
               if RC = 0 then
                  if CPU_Baseline_Set then
                     declare
                        DU : constant Long_Float := Long_Float (U - Prev_User_Ticks);
                        DS : constant Long_Float := Long_Float (S - Prev_System_Ticks);
                        DI : constant Long_Float := Long_Float (I - Prev_Idle_Ticks);
                        DN : constant Long_Float := Long_Float (N - Prev_Nice_Ticks);
                        Total : constant Long_Float := DU + DS + DI + DN;
                        Idle_Pct : Long_Float := 0.0;
                        Ratio : Long_Float := 0.0;
                     begin
                        if Total > 0.0 then
                           Idle_Pct := DI / Total * 100.0;
                           if DU > 0.0 then
                              Ratio := DS / DU;
                           end if;
                           if Idle_Pct < 50.0 and then Ratio > 1.0 then
                              Murasama_Log.Warn ("CPU inefficiency: idle=" &
                                Long_Float'Image (Idle_Pct) & "% sys/user ratio=" &
                                Long_Float'Image (Ratio));
                              CPU_Inefficiency_Active := True;
                           else
                              CPU_Inefficiency_Active := False;
                           end if;
                        end if;
                     end;
                  end if;
                  Prev_User_Ticks   := U;
                  Prev_System_Ticks := S;
                  Prev_Idle_Ticks   := I;
                  Prev_Nice_Ticks   := N;
                  CPU_Baseline_Set  := True;
               end if;
               Last_CPU_Check_Time := Now;
            end;
         end if;

         -- Trigger mitigation on CPU inefficiency + memory pressure (AND gate).
         if CPU_Inefficiency_Active and Current_Pressure >= 2
            and not Mitigation_State.Is_Mitigating
         then
            Mitigation_State.Increment_Triggers (False, False, False);
            Thrashing_Mitigation_In (Front_PID);
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

         -- Periodic Health Report (REPORT_INTERVAL_MS = single source of truth)
         if Now >= Last_Report_Time + Milliseconds (REPORT_INTERVAL_MS) then
            Ada.Text_IO.Put_Line ("[HEALTH CHECK] Free: " &
              Long_Float'Image (Current_Free_MB) & " MB | Wired: " &
              Long_Float'Image (Current_Wired_MB) & " MB | Lvl: " &
              Integer'Image (Current_Pressure) & " | Vel: " &
              Long_Float'Image (Wired_Velocity) & " MB/s");

            -- Read current Machine Learning forecasts.
            -- NOTE: the Python sidecar ML is advisory only and is NOT our
            -- main priority during an emergency: bloodshed decisions are
            -- driven by OS pressure / free memory / velocity, never by ML.
            Read_ML_Prediction (ML_Predicted_Pressure, ML_Risk_Level, ML_Target_PID);
            if Is_Critical_Pressure (ML_Predicted_Pressure)
              or else ML_Risk_Level (1 .. 4) = "high"
            then
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

         -- ---- 10s Memory Monitor (Activity Monitor methodology) ----
         -- Logs every MEM_MONITOR_INTERVAL_MS: XNU pressure level, free/
         -- wired/compressor MB, swap used/total, and top
         -- MEM_MONITOR_TOP_N processes by phys_footprint.
         --
         -- AXIOMS:
         --   A1: Responsiveness derives from XNU pressure level
         --       (kern.memorystatus_vm_pressure_level), NOT raw free-%:
         --       page cache is reclaimable, so free-% legitimately reads
         --       ~57% while the machine is simultaneously swap-starved.
         --       (from: XNU jetsam/memorystatus design; observed on-host)
         --   A2: Swap fullness = sysctl vm.swapusage (xsw_usage), same
         --       source as Activity Monitor's "Swap Used" line.
         --   A3: Top consumers ranked by ri_phys_footprint (resident +
         --       compressed + internal), the exact quantity Activity
         --       Monitor's Memory column shows — NOT RSS. Verified:
         --       Lulu PID 689 = 1540 MB footprint vs 71 MB RSS.
         --   A4: Current_Pressure/Free/Wired were sampled this iteration
         --       (100ms ago max) — freshness bound, no extra sysctl.
         --
         -- THEOREMS:
         --   T1: Read-only cycle — never calls mitigation/kill paths.
         --   T2: Any FFI failure is caught, logged with full exception
         --       details, and Last_Mem_Monitor_Time still advances, so a
         --       broken metric degrades to log spam at 10s, never a
         --       hot-loop inside the 100ms main poll.
         --
         -- CITATIONS:
         --   [1] XNU osfmk/kern/memorystatus.c — pressure levels 1/2/4
         --   [2] Apple man sysctl(3) — vm.swapusage
         --   [3] Apple proc_pid_rusage(3) — ri_phys_footprint
         if Now >= Last_Mem_Monitor_Time + Milliseconds (MEM_MONITOR_INTERVAL_MS) then
            declare
               Swap_Total_MB : double := 0.0;
               Swap_Used_MB  : double := 0.0;
               Compressor_MB : double := 0.0;
               Swap_Pct      : Long_Float := 0.0;
               FP_Pids   : PID_Array (int (1) .. int (MEM_MONITOR_TOP_N)) := (others => 0);
               FP_Bytes  : UINT64_Array (int (1) .. int (MEM_MONITOR_TOP_N)) := (others => 0);
               FP_Count  : int;
               Name_C    : char_array (size_t (1) .. size_t (MAX_NAME_LEN));
               P_Name    : String (1 .. MAX_NAME_LEN);
               N_Len     : Integer;
               FP_MB     : Long_Float;
            begin
               -- APPLICATION STEP 1: swap + compressor (A2, A1)
               Get_Swap_Usage_C (Swap_Total_MB, Swap_Used_MB);
               Compressor_MB := Get_Compressor_MB_C (Page_Size);
               if Swap_Total_MB > 0.0 then
                  Swap_Pct := (Long_Float (Swap_Used_MB) / Long_Float (Swap_Total_MB)) * 100.0;
               else
                  -- A2 failure signal: total=0.0 means sysctl failed (a
                  -- machine with swap configured always reports >0), so
                  -- print an explicit warning instead of a fake 0%.
                  Murasama_Log.Warn ("[MEM MONITOR] vm.swapusage unavailable " &
                    "(sysctl failed or swap disabled) -- totals reported as 0");
               end if;

               -- APPLICATION STEP 2: headline line (A4: reuse loop samples)
               Murasama_Log.Info
                 ("[MEM MONITOR] Pressure:" & Integer'Image (Current_Pressure) &
                  " | Free:" & Long_Float'Image (Current_Free_MB) & " MB" &
                  " | Wired:" & Long_Float'Image (Current_Wired_MB) & " MB" &
                  " | Compressor:" & Long_Float'Image (Long_Float (Compressor_MB)) & " MB" &
                  " | Swap:" & Long_Float'Image (Long_Float (Swap_Used_MB)) & "/" &
                  Long_Float'Image (Long_Float (Swap_Total_MB)) & " MB (" &
                  Long_Float'Image (Swap_Pct) & "%)");

               -- APPLICATION STEP 3: top-N by phys_footprint (A3, T1)
               FP_Count := Get_Top_Processes_By_Footprint_C
                 (FP_Pids, FP_Bytes, int (MEM_MONITOR_TOP_N), int (0));
               if FP_Count > 0 then
                  for I in 1 .. Integer (FP_Count) loop
                     Name_C := (others => ' ');
                     Get_Process_Name_C (FP_Pids (int (I)), Name_C, int (MAX_NAME_LEN));
                     -- Bounds-safe name trim: stop at NUL, at buffer end,
                     -- or at P_Name capacity (Murphy: no NUL guarantee).
                     N_Len := 0;
                     for J in Name_C'Range loop
                        exit when Name_C (J) = char'Val (0);
                        exit when N_Len >= MAX_NAME_LEN;
                        N_Len := N_Len + 1;
                        P_Name (N_Len) := To_Ada (Name_C (J));
                     end loop;
                     if N_Len = 0 then
                        P_Name (1 .. 9) := "<unknown>";
                        N_Len := 9;
                     end if;
                     FP_MB := Long_Float (FP_Bytes (int (I))) / (1024.0 * 1024.0);
                     Murasama_Log.Info
                       ("[MEM MONITOR]   #" & Integer'Image (I) &
                        " pid" & PID_T'Image (FP_Pids (int (I))) &
                        " " & P_Name (1 .. N_Len) &
                        " footprint:" & Long_Float'Image (FP_MB) & " MB");
                  end loop;
               else
                  Murasama_Log.Warn ("[MEM MONITOR] footprint query returned " &
                    "0 processes -- check proc_pid_rusage permissions/root");
               end if;
            exception
               when E : others =>
                  -- T2: log full details, never propagate into main loop
                  Murasama_Log.Error ("[MEM MONITOR] cycle failed: " &
                    Ada.Exceptions.Exception_Information (E));
            end;
            -- T2: always advance, even after failure (no hot-loop)
            Last_Mem_Monitor_Time := Now;
         end if;

         -- Leak reaper (Murasama_Leak_Killer): every LEAK_CHECK_INTERVAL_MS
         -- (10 min) scan for processes matching ALL configured criteria —
         -- phys_footprint > 1 GB, age > 12 h, username without '_', owner
         -- home NOT under /Users/ (user priority), not self (C getpid) —
         -- then dry-run log (gate False) or SIGKILL (gate True, Phase 2).
         -- T2 structure mirrors the MEM MONITOR block above: the callee
         -- itself never raises (its THEOREM 2), the wiring handler is
         -- belt+braces, and the timestamp ALWAYS advances after the block.
         if Now >= Last_Leak_Check_Time +
             Milliseconds (LEAK_CHECK_INTERVAL_MS) then
            begin
               Murasama_Leak_Killer.Check_And_Kill;
            exception
               when E : others =>
                  -- T2: log full details, never propagate into main loop
                  Murasama_Log.Error ("[LEAK CHECK] cycle failed: " &
                    Ada.Exceptions.Exception_Information (E));
            end;
            -- T2: always advance, even after failure (no hot-loop)
            Last_Leak_Check_Time := Now;
         end if;

         -- Decision Tree for Bloodshed
         declare
            Condition_Met : Boolean := False;
            Trigger_Reason : String (1 .. 128) := (others => ' ');
            Trigger_Len : Integer := 0;
         begin
            -- Decision conditions use the SPARK-verified predicates from
            -- Murasama_Types as the single source of truth (previously dead
            -- code while equivalent comparisons were reimplemented inline).
            if Is_Critical_Pressure (Current_Pressure) then
               Condition_Met := True;
               -- FIX: Changed slice from (1..27) to (1..26).
               -- REASON: The string literal "Level 4 OS Memory Pressure" is 26
               --         characters, not 27. Mismatched slice length causes
               --         Constraint_Error at runtime. (Warning: default)
               Trigger_Reason (1 .. 26) := "Level 4 OS Memory Pressure";
               Trigger_Len := 26;
            elsif Is_Free_Memory_Critical (Current_Free_MB) then
               Condition_Met := True;
               -- FIX: Changed slice from (1..28) to (1..27).
               -- REASON: The string literal "Free Memory Below Threshold" is 27
               --         characters, not 28. Mismatched slice length causes
               --         Constraint_Error at runtime. (Warning: default)
               Trigger_Reason (1 .. 27) := "Free Memory Below Threshold";
               Trigger_Len := 27;
             elsif Is_Velocity_Panic (Wired_Velocity, Panic_Velocity_Threshold_MB_S) and then Current_Free_MB < (CRITICAL_FREE_MB * 4.0) then
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
             else
                -- FIX (RESTORE STORM): previously called
                -- Restore_Blacklisted_Priorities_C on EVERY 100ms iteration —
                -- a full PID scan + fork/exec per match under normal load.
                -- Now gated: restore only when something was deprioritized.
                if Mitigation_State.Blacklisted_Deprioritized then
                   Restore_Blacklisted_Priorities_C;
                   Mitigation_State.Set_Blacklisted_Deprioritized (False);
                end if;
             end if;
         end;

       -- Watchdog: treat any iteration longer than POLL_INTERVAL_MS as a fault.
       declare
          Iter_Elapsed : constant Duration := To_Duration (Clock - Iteration_Start);
       begin
          if Iter_Elapsed > Duration (POLL_INTERVAL_MS) / 1000.0 then
             Murasama_Log.Warn ("Watchdog: main-loop iteration exceeded " &
               Integer'Image (POLL_INTERVAL_MS) & " ms (" &
               Duration'Image (Iter_Elapsed) & " s)");
          end if;
       end;

       Last_Time := Now;
       Last_Wired_MB := Current_Wired_MB;
    end;
   end loop;

   -- Graceful shutdown path (SIGTERM/SIGINT received in main loop):
   -- restore boosted priorities + game mode, reap the ML sidecar child so it
   -- does not orphan, then exit. launchd KeepAlive restarts us fresh.
   Thrashing_Mitigation_Out;
   Kill_ML_Predictor (Sidecar_State.Get_Current_PID);
   Ada.Text_IO.Put_Line ("[Murasama LMKd] Daemon shut down cleanly.");
   Murasama_Log.Info ("Daemon shut down cleanly after shutdown signal");

exception
   when others =>
      -- Crash-path cleanup mirrors the graceful path (FIX: previously left
      -- boosted PIDs pinned at nice -20 and orphaned the sidecar child).
      Thrashing_Mitigation_Out;
      Kill_ML_Predictor (Sidecar_State.Get_Current_PID);
      Ada.Text_IO.Put_Line ("[Murasama LMKd] Daemon shut down cleanly.");
      Murasama_Log.Critical ("Daemon exited via unhandled exception; mitigation cleanup performed");
end Murasamalmk_Daemon;
