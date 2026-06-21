with Interfaces.C;
-- FIX: Removed 'with Murasama_Types; use Murasama_Types' from spec.
-- REASON: No entities from Murasama_Types are referenced in the spec. The procedure
--         uses standard Ada types and Interfaces.C.unsigned_long_long. The with/use
--         clause belongs in the body where EARU_DATA_FILE is used. (Warning: -gnatwu)

package Murasama_Telemetry is
   pragma SPARK_Mode (Off);

   use Interfaces.C;

   -- Export telemetry to /Volumes/EARU_dataIO/EARU_data.dat
   procedure Export_Telemetry (
      Free_MB                 : Long_Float;
      Wired_MB                : Long_Float;
      Pressure_Level          : Integer;
      Wired_Velocity          : Long_Float;
      Pageins_Per_Sec         : unsigned_long_long;
      Decomp_Per_Sec          : unsigned_long_long;
      Front_PID               : Integer;
      Front_Name              : String;
      Mitigation_Active       : Boolean
   );

end Murasama_Telemetry;
