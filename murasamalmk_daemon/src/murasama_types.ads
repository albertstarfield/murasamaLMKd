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
   CRITICAL_FREE_MB            : constant := 128.0;
   PANIC_VELOCITY_MB_S         : constant := 21000.0;
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
   -- Contract: Returns True iff Velocity > PANIC_VELOCITY_MB_S (21000 MB/s).
   -- Proved by: Proof that the threshold comparison is correct.
   function Is_Velocity_Panic (Velocity_MB_S : Long_Float) return Boolean
     with Post => (Is_Velocity_Panic'Result = (Velocity_MB_S > PANIC_VELOCITY_MB_S));

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
