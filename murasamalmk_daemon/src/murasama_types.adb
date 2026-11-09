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

   function MDS_Crosses_512MiB
     (Phys_Footprint_Bytes : Long_Long_Integer) return Boolean is
   begin
      -- Strict >: a process sitting exactly at 512 MiB has not LEFT the
      -- envelope; the observed 8909 MiB hog is 17x above it.
      return Phys_Footprint_Bytes > Long_Long_Integer (MDS_MIN_FOOTPRINT_BYTES);
   end MDS_Crosses_512MiB;

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

end Murasama_Types;
