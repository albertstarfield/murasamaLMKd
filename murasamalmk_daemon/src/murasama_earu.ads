--  EARU sensor bridge: reads the live telemetry volume from inside the Ada
--  program. Replaces the old synthetic weather formulas in Murasama_Telemetry.

package Murasama_EARU is
   pragma SPARK_Mode (Off);
   --  File I/O and JSON scanning are outside the SPARK subset; the
   --  plausibility gate (EARU_Usable) lives in Murasama_Types and is proved.

   type EARU_Sensors is record
      Temperature_C : Long_Float := 0.0;
      Apparent_C    : Long_Float := 0.0;
      Humidity_Pct  : Long_Float := 0.0;
      Pressure_HPa  : Long_Float := 0.0;
      Surface_HPa   : Long_Float := 0.0;
      Wind_Kmh      : Long_Float := 0.0;
      Wind_Deg      : Long_Float := 0.0;
      Cloud_Pct     : Long_Float := 0.0;
      Weather_Code  : Integer := -1;
      CPU_Temp_C    : Long_Float := 0.0;
      Fan0_RPM      : Long_Float := 0.0;
      Turbo_Mode    : Long_Float := 0.0;
      Power_Day_Wh  : Long_Float := 0.0;
      Read_OK       : Boolean := False;
   end record;

   procedure Read (S : out EARU_Sensors);
   --  Reads /Volumes/EARU_dataIO/EARU_meteo.dat ("current" block) plus the
   --  scalar sensor_*.dat files. Missing/corrupt sources yield defaults and
   --  Read_OK = False; they are never published as plausible weather.

end Murasama_EARU;
