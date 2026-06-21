package Murasama_Types is
   pragma Preelaborate;
   pragma SPARK_Mode (On);

   -- ==================== CONFIGURATION ====================
   POLL_INTERVAL_MS            : constant := 25;
   REPORT_INTERVAL_MS          : constant := 5000;
   CRITICAL_FREE_MB            : constant := 128.0;
   PANIC_VELOCITY_MB_S         : constant := 21000.0;
   MIN_PRESSURE_LEVEL_TO_KILL  : constant := 4;
   GRADIENT_MEASURE_MS         : constant := 100;
   TOP_N_PROCESSES             : constant := 3;

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

   type Weights_Array is array (1 .. 128) of Weight_Record;

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
