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

   WEIGHTS_FILE                : constant String := "/usr/local/murasamaLMKd/weights.csv";
   EARU_DATA_FILE              : constant String := "/usr/local/murasamaLMKd/EARU_data.dat";

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

end Murasama_Types;
