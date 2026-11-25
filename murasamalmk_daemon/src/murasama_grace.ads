with Interfaces.C;

package Murasama_Grace is
   pragma SPARK_Mode (Off);
   --  Taskless state machine called only from the daemon's main task. FFI and
   --  file I/O are outside SPARK; the risk/prediction decisions come from the
   --  proved predicates in Murasama_Types.

   procedure Begin_Hold
     (PID           : Interfaces.C.int;
      Gradient_MB_S : Long_Float;
      Total_RAM_MB  : Long_Float;
      ML_Predicted  : Integer);
   --  Notify the UI warden with a per-PID hold file, then SIGSTOP the process.

   procedure Begin_Long_Hold
     (PID           : Interfaces.C.int;
      Gradient_MB_S : Long_Float;
      Total_RAM_MB  : Long_Float;
      ML_Predicted  : Integer);
   --  User-requested 6-hour freeze: same non-killing STOP, longer hold window.

   procedure Service;
   --  Every cycle: after 60 s SIGCONT, re-measure the gradient on the next
   --  one-second cycle, and STOP again if it is still climbing.

   function Risk_For
     (Gradient_MB_S, Total_RAM_MB : Long_Float) return Long_Float;
   --  Guarded wrapper around the SPARK-proved Grace_Risk_Percent.

end Murasama_Grace;
