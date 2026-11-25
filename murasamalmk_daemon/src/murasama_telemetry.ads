with Interfaces.C;
with Murasama_Types;

package Murasama_Telemetry is
   pragma SPARK_Mode (Off);

   use Interfaces.C;

   -- Export telemetry to /Volumes/EARU_dataIO/EARU_data.dat.
   -- Memstatus carries the six live kern.memorystatus values into the JSON.
   procedure Export_Telemetry (
      Free_MB                 : Long_Float;
      Wired_MB                : Long_Float;
      Pressure_Level          : Integer;
      Wired_Velocity          : Long_Float;
      Pageins_Per_Sec         : unsigned_long_long;
      Decomp_Per_Sec          : unsigned_long_long;
      Front_PID               : Integer;
      Front_Name              : String;
      Mitigation_Active       : Boolean;
      Memstatus               : Murasama_Types.Memorystatus_Config
   );

end Murasama_Telemetry;
