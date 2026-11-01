--  Murasama_Guard — SPARK-proved path exclusion for the leak killer.
--
--  Owner mandate (2026-11-02): never kill a process whose executable path
--  contains "hermes", "syncthing" or "omlx" in any letter case.
--
--  This unit is the Ada/SPARK twin of the C guard in macos_utils.m.  The C
--  guard remains the last line of defence for paths that never reach Ada;
--  this unit makes the same decision provable and callable from the kill
--  loop before any signal is sent.
--
--  CITATIONS: Ada 2012 RM 4.5.2 (string indexing), RM 11.4.2 (pre/post),
--  SPARK User's Guide 7 (SPARK_Mode).  No library I/O is used, so the unit
--  stays Pure and Ravenscar-compatible by construction.

package Murasama_Guard with
   SPARK_Mode,
   Pure
is

   --  Path is a NUL-trimmed executable path.  The 4096 bound matches
   --  PROC_PIDPATHINFO_MAXSIZE on macOS.
   function Is_Protected_Path (Path : String) return Boolean
   with
     Pre => Path'Length <= 4096;

end Murasama_Guard;
