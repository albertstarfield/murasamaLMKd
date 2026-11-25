--  Configuration bridge: pulls the six kern.memorystatus.* values the user
--  set in the kernel straight into the Ada policy layer. No sidecar config,
--  no separate C shim: sysctlbyname comes from libSystem via pragma Import.
with Murasama_Types;

package Murasama_Config is
   pragma SPARK_Mode (Off);
   --  FFI + logging are outside the SPARK subset; the policy predicates the
   --  results feed into live in Murasama_Types and ARE gnatprove-verified.

   procedure Load (C : out Murasama_Types.Memorystatus_Config);
   --  Reads each key from the running kernel. A missing/failed read stays -1
   --  so Config_Complete reports False and policy never guesses a value.

   procedure Log (C : Murasama_Types.Memorystatus_Config);
   --  Verbose reporting mandate: every key, its observed value, and whether
   --  it matches the desired configuration go to Murasama_Log.

end Murasama_Config;
