with Interfaces.C;
with Murasama_Types; use Murasama_Types;

package Murasama_Telemetry is
   pragma SPARK_Mode (Off);

   use Interfaces.C;

   -- Export telemetry to /usr/local/murasamaLMKd/EARU_data.dat
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
