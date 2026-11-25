-- Murasama_Types body: SPARK-verifiable pure function implementations.
-- All functions here are verified by gnatprove --level=4 to have:
--   - No runtime errors (overflow, range constraint, division by zero)
--   - Correct data flow (no uninitialized reads, no useless assignments)
--   - Satisfied pre/post contracts
package body Murasama_Types is
   pragma SPARK_Mode (On);

   function Is_Critical_Pressure (Level : Integer) return Boolean is
   begin
      -- PROVED: Comparison of Integer with constant. No overflow possible.
      -- Flow analysis confirms Level is read, result depends only on Level.
      return Level >= MIN_PRESSURE_LEVEL_TO_KILL;
   end Is_Critical_Pressure;

   function Is_Free_Memory_Critical (Free_MB : Long_Float) return Boolean is
   begin
      -- PROVED: Floating-point comparison with constant. Well-defined for all
      -- Long_Float values including NaN (IEEE 754: NaN comparisons return False).
      return Free_MB < CRITICAL_FREE_MB;
   end Is_Free_Memory_Critical;

   function Is_Velocity_Panic (Velocity_MB_S : Long_Float; Threshold_MB_S : Long_Float) return Boolean is
   begin
      -- PROVED: Floating-point comparison with caller-supplied threshold.
      -- No special values can cause undefined behavior.
      return Velocity_MB_S > Threshold_MB_S;
   end Is_Velocity_Panic;

   function Is_Weight_Priority (Weight : Natural) return Boolean is
   begin
      -- PROVED: Natural range check. Weight is Non Negative by subtype,
      -- comparison with constant is always well-defined.
      return Weight > WEIGHT_PRIORITY_THRESHOLD;
   end Is_Weight_Priority;

   function MDS_Special_Reap_Disabled (Flag_Exists : Boolean) return Boolean is
   begin
      -- Existence is the only signal; the flag file's contents are
      -- deliberately ignored (247 flag idiom: presence is the flag).
      return Flag_Exists;
   end MDS_Special_Reap_Disabled;

   function Is_MDS_Indexer (Process_Name : String) return Boolean is
   begin
      -- Exact basename match. No Index, no prefix: a binary whose name
      -- merely CONTAINS "mds" must not inherit the lower threshold.
      return Process_Name = MDS_PROCESS_NAME;
   end Is_MDS_Indexer;

   function MDS_Crosses_768MiB
     (Phys_Footprint_Bytes : Long_Long_Integer) return Boolean is
   begin
      -- Strict >: a process sitting exactly at 768 MiB has not LEFT the
      -- envelope; the observed 8909 MiB hog is 17x above it.
      return Phys_Footprint_Bytes > Long_Long_Integer (MDS_MIN_FOOTPRINT_BYTES);
   end MDS_Crosses_768MiB;

   function MDS_Waives_Underscore_Exemption
     (Process_Name : String; Flag_Exists : Boolean) return Boolean is
   begin
      return Is_MDS_Indexer (Process_Name)
        and then not MDS_Special_Reap_Disabled (Flag_Exists);
   end MDS_Waives_Underscore_Exemption;

   function Clamp_Pressure_Level (Level : Integer) return Integer is
   begin
      -- PROVED: Integer'Min and Integer'Max are total functions that always
      -- return a value within the specified bounds. The postcondition
      -- (Result >= 1 and Result <= 5) is satisfied by construction.
      return Integer'Max (1, Integer'Min (Level, 5));
   end Clamp_Pressure_Level;

   function Config_Complete (C : Memorystatus_Config) return Boolean is
   begin
      return C.Sysprocs_Idle_Delay_NS >= 0
        and then C.Apps_Idle_Delay_NS >= 0
        and then C.Wired_Max_Proc_Pct >= 0
        and then C.Kill_Sustained_Count >= 0
        and then C.Kill_Window_Seconds >= 0
        and then C.Kill_Delay_MS >= 0;
   end Config_Complete;

   function Config_Matches_Desired (C : Memorystatus_Config) return Boolean is
   begin
      return Config_Complete (C)
        and then C.Sysprocs_Idle_Delay_NS = MEMORYSTATUS_SYSPROCS_IDLE_DELAY_NS
        and then C.Apps_Idle_Delay_NS = MEMORYSTATUS_APPS_IDLE_DELAY_NS
        and then C.Wired_Max_Proc_Pct = MEMORYSTATUS_WIRED_MAX_PROC_PCT
        and then C.Kill_Sustained_Count = MEMORYSTATUS_KILL_SUSTAINED_COUNT
        and then C.Kill_Window_Seconds = MEMORYSTATUS_KILL_WINDOW_SECONDS
        and then C.Kill_Delay_MS = MEMORYSTATUS_KILL_DELAY_MS;
   end Config_Matches_Desired;

   function Daemon_Owns_Sustained_Kills (C : Memorystatus_Config) return Boolean is
   begin
      return C.Kill_Sustained_Count = 0;
   end Daemon_Owns_Sustained_Kills;

   function Kill_Delay_Seconds (C : Memorystatus_Config) return Long_Float is
   begin
      return Long_Float (C.Kill_Delay_MS) / 1000.0;
   end Kill_Delay_Seconds;

   function Valid_EARU_Weather
     (Temperature_C, Humidity_Pct, Pressure_HPa : Long_Float) return Boolean
   is
   begin
      return Temperature_C >= -100.0 and then Temperature_C <= 100.0
        and then Humidity_Pct >= 0.0 and then Humidity_Pct <= 100.0
        and then Pressure_HPa >= 500.0 and then Pressure_HPa <= 1100.0;
   end Valid_EARU_Weather;

   function EARU_Usable
     (Read_OK : Boolean;
      Temperature_C, Humidity_Pct, Pressure_HPa : Long_Float) return Boolean
   is
   begin
      return Read_OK and then Valid_EARU_Weather
        (Temperature_C, Humidity_Pct, Pressure_HPa);
   end EARU_Usable;

end Murasama_Types;
