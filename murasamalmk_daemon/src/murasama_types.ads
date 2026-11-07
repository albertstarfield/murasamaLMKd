package Murasama_Types is
   pragma Preelaborate;
   pragma SPARK_Mode (On);

   -- ==================== CONFIGURATION ====================
   -- All timing constants are single sources of truth (🟡22): every loop in
   -- the daemon derives its delays from these values. POLL_INTERVAL_MS is
   -- 100ms: measured steady-state CPU of the main poll loop is <0.9% at this
   -- rate; a faster poll would violate that budget without adding safety.

   -- Main monitoring loop period. Wired into main.adb main loop + runner idle.
   POLL_INTERVAL_MS            : constant := 100;
   -- Health-report / telemetry-export cadence (5s).
   REPORT_INTERVAL_MS          : constant := 5000;
   -- Memory-monitor cadence (10s): logs XNU pressure level, free/wired/
   -- compressor MB, swap usage, and top processes by phys_footprint
   -- (Activity Monitor methodology). Read-only — never triggers mitigation.
   MEM_MONITOR_INTERVAL_MS     : constant := 10000;
   -- How many top-footprint processes the 10s monitor logs per cycle.
   MEM_MONITOR_TOP_N           : constant := 5;
   -- Size of the standalone top-10 footprint listing mechanism
   -- (Murasama_Footprint.Get_Top_10_By_Footprint). Independent of
   -- MEM_MONITOR_TOP_N: the monitor logs 5 lines per 10s cycle, while this
   -- constant sizes the on-demand query procedure (🟡23).
   FOOTPRINT_TOP_10_N          : constant := 10;

    -- ==================== LEAK KILLER (memory-leak reaper) ====================
    -- Policy thresholds for Murasama_Leak_Killer.Check_And_Kill. A process is
    -- a leak candidate only when ALL of these hold (each STRICT):
    --   * owner username does NOT contain '_'  (the *_* rule — macOS service
    --     accounts like _spotlight/_windowserver are exempt),
    --   * owner has NO home directory /Users/<username> (USER PRIORITY —
    --     user processes never respawn themselves, so they are never
    --     reaped; vendor sloppiness must be endured by the user, not
    --     punished by killing the USER's processes),
    --   * ri_phys_footprint > 1 GB (Activity Monitor "Memory" methodology),
    --   * wall-clock age    > 12 h (now - pbi_start_tvsec).
    -- The daemon's own pid is additionally exempt (enforced once in C by
    -- getpid()). There is deliberately NO uid-0 exemption: root-owned
    -- vendor daemons (LuLu, XProtect, root leakers) — which run without
    -- user volition and respawn themselves — are exactly the targets.

   -- 1 GB strict threshold on phys_footprint (2^30 bytes).
   LEAK_MIN_FOOTPRINT_BYTES    : constant := 1024 * 1024 * 1024;
   -- 12 hours (43200 s) strict minimum wall-clock process age.
   LEAK_MIN_AGE_SECONDS        : constant := 12 * 3600;
   -- Leak-scan cadence (10 min): the thresholds are hourly-scale, so a
   -- faster scan adds CPU cost without materially changing kill latency
   -- (worst case = interval + scan duration).
   LEAK_CHECK_INTERVAL_MS      : constant := 600_000;
   -- Safety valve: at most this many SIGKILLs per scan cycle — a wrong
   -- policy or pathological system can never wipe the process table in
   -- one pass; remaining candidates are re-evaluated next cycle.
   LEAK_MAX_KILLS_PER_CYCLE    : constant := 2;
   -- Scan buffer: max candidates fetched per cycle (largest-first; any
   -- matches beyond the buffer wait for later cycles after the cap).
   LEAK_MAX_CANDIDATES         : constant := 8;
    -- Phase gate: False = DRY-RUN ("[LEAK WOULD KILL]" log lines only),
    -- True = actually SIGKILL. Constant (not variable) because flipping it
    -- requires a rebuild + daemon restart either way; flip ONLY after
    -- reviewing dry-run output. Phase 2 ENABLED 2026-09-25 after dry-run
    -- review + user priority policy finalized: /Users/ homes exempt
    -- (user priority), no uid-0 exemption (vendor root daemons are the
    -- targets: LuLu 689 / root python 55883 were dry-run exempt under the
    -- old uid-0 rule; _windowserver 1723 exempt via *_*).
    LEAK_KILL_ENABLED           : constant Boolean := True;
   CRITICAL_FREE_MB            : constant := 128.0;
   MIN_PRESSURE_LEVEL_TO_KILL  : constant := 4;
   GRADIENT_MEASURE_MS         : constant := 100;
   TOP_N_PROCESSES             : constant := 3;

   -- Thrashing_Task sampling cadence (snapshot pair spacing + idle sleep).
   SNAPSHOT_SPACING_MS         : constant := 100;
   THRASHING_IDLE_MS           : constant := 900;

   -- Weight table capacity: Weights_Array index bound and full-table checks
   -- both derive from this constant so they can never drift apart.
   WEIGHTS_TABLE_SIZE          : constant := 128;

   WEIGHTS_FILE                : constant String := "/usr/local/murasamaLMKd/murasamalmk_daemon/weights.csv";
   EARU_DATA_FILE              : constant String := "/Volumes/EARU_dataIO/EARU_data.dat";

   WEIGHT_DECREMENT_HOURS      : constant := 12;
   WEIGHT_PRIORITY_THRESHOLD   : constant := 3;

   -- Thrashing thresholds
   THRASHING_THRESHOLD_PAGEINS : constant := 500;
   THRASHING_THRESHOLD_DECOMP  : constant := 10000;
   HYSTERESIS_SECONDS          : constant := 60;

   -- Process name maximum length
   MAX_NAME_LEN                : constant := 64;

   type Process_Name_String is new String (1 .. MAX_NAME_LEN);

   type Weight_Record is record
      Name   : Process_Name_String;
      Length : Natural range 0 .. MAX_NAME_LEN;
      Value  : Natural;
   end record;

   type Weights_Array is array (1 .. WEIGHTS_TABLE_SIZE) of Weight_Record;

   -- ==================== SPARK-VERIFIED PURE FUNCTIONS ====================
   -- These pure functions are verified by gnatprove --level=4 to have no
   -- runtime errors, correct data flow, and satisfied contracts.

   -- Purpose: Determine if a memory pressure level warrants killing processes.
   -- Contract: Returns True iff Level >= MIN_PRESSURE_LEVEL_TO_KILL (4).
   -- Proved by: Flow analysis + proof that comparison is correct.
   function Is_Critical_Pressure (Level : Integer) return Boolean
     with Post => (Is_Critical_Pressure'Result = (Level >= MIN_PRESSURE_LEVEL_TO_KILL));

   -- Purpose: Determine if free memory has dropped below the critical threshold.
   -- Contract: Returns True iff Free_MB < CRITICAL_FREE_MB (128.0 MB).
   -- Proved by: Proof that floating-point comparison is well-defined.
   function Is_Free_Memory_Critical (Free_MB : Long_Float) return Boolean
     with Post => (Is_Free_Memory_Critical'Result = (Free_MB < CRITICAL_FREE_MB));

   -- Purpose: Determine if wired memory velocity indicates a violent allocation spike.
   -- Contract: Returns True iff Velocity > Threshold_MB_S (MB/s). Threshold is
   --   derived at runtime from the machine's total RAM (dynamic detection),
   --   not a compile-time constant (see murasamalmk_daemon.adb).
   -- Proved by: Proof that the threshold comparison is correct.
   function Is_Velocity_Panic (Velocity_MB_S : Long_Float; Threshold_MB_S : Long_Float) return Boolean
     with Post => (Is_Velocity_Panic'Result = (Velocity_MB_S > Threshold_MB_S));

   -- Purpose: Determine if a process weight exceeds the priority kill threshold.
   -- Contract: Returns True iff Weight > WEIGHT_PRIORITY_THRESHOLD (3).
   -- Proved by: Proof that the comparison and range are correct.
   function Is_Weight_Priority (Weight : Natural) return Boolean
     with Post => (Is_Weight_Priority'Result = (Weight > WEIGHT_PRIORITY_THRESHOLD));

   -- Purpose: Clamp a pressure level to the valid range [1..5].
   -- Contract: Result is always in range 1..5 regardless of input.
   -- Proved by: Proof that Integer'Min/Integer'Max produce in-range results.
   function Clamp_Pressure_Level (Level : Integer) return Integer
     with Post => (Clamp_Pressure_Level'Result >= 1
                   and then Clamp_Pressure_Level'Result <= 5);

end Murasama_Types;
