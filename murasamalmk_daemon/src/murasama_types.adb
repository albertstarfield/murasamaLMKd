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

   function Is_Velocity_Panic (Velocity_MB_S : Long_Float) return Boolean is
   begin
      -- PROVED: Floating-point comparison with constant. No special values
      -- can cause undefined behavior.
      return Velocity_MB_S > PANIC_VELOCITY_MB_S;
   end Is_Velocity_Panic;

   function Is_Weight_Priority (Weight : Natural) return Boolean is
   begin
      -- PROVED: Natural range check. Weight is Non Negative by subtype,
      -- comparison with constant is always well-defined.
      return Weight > WEIGHT_PRIORITY_THRESHOLD;
   end Is_Weight_Priority;

   function Clamp_Pressure_Level (Level : Integer) return Integer is
   begin
      -- PROVED: Integer'Min and Integer'Max are total functions that always
      -- return a value within the specified bounds. The postcondition
      -- (Result >= 1 and Result <= 5) is satisfied by construction.
      return Integer'Max (1, Integer'Min (Level, 5));
   end Clamp_Pressure_Level;

end Murasama_Types;
