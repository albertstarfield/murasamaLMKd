--  Murasama_Config body: direct libSystem binding, no separate C file.
with Ada.Exceptions;
with Interfaces.C;
with Murasama_Log;
with System;

package body Murasama_Config is
   use type Interfaces.C.int;
   use type Interfaces.C.size_t;

   Key_Sysprocs : constant String :=
     "kern.memorystatus.sysprocs_idle_delay_time_ns";
   Key_Apps     : constant String :=
     "kern.memorystatus.apps_idle_delay_time_ns";
   Key_Wired    : constant String :=
     "kern.memorystatus.wired_max_proc_pct";
   Key_Count    : constant String :=
     "kern.memorystatus.kill_on_sustained_pressure_count";
   Key_Window   : constant String :=
     "kern.memorystatus.kill_on_sustained_pressure_window_s";
   Key_Delay    : constant String :=
     "kern.memorystatus.kill_on_sustained_pressure_delay_ms";

   --  Apple sysctl(3): int sysctlbyname(const char *, void *, size_t *,
   --  const void *, size_t). Newp = NULL / Newlen = 0 means read-only.
   --  Citation: https://developer.apple.com/library/archive/documentation/
   --  System/Conceptual/ManPages_iPhoneOS/man3/sysctl.3.html
   function Sysctl_By_Name
     (Name    : Interfaces.C.char_array;
      Oldp    : System.Address;
      Oldlenp : access Interfaces.C.size_t;
      Newp    : System.Address;
      Newlen  : Interfaces.C.size_t) return Interfaces.C.int;
   pragma Import (C, Sysctl_By_Name, "sysctlbyname");

   --  All six keys are integer sysctls. We read 8 bytes into an 8-byte
   --  zeroed slot: a 4-byte kernel result leaves the high bytes zero on
   --  little-endian arm64, so both widths decode correctly.
   function Read_I64 (Key : String) return Long_Long_Integer is
      Value : aliased Interfaces.C.long_long := 0;
      Len   : aliased Interfaces.C.size_t := Interfaces.C.size_t (8);
      RC    : constant Interfaces.C.int :=
        Sysctl_By_Name (Interfaces.C.To_C (Key),
                        Value'Address, Len'Access,
                        System.Null_Address, 0);
   begin
      if RC /= 0 then
         Murasama_Log.Warn ("[SYSCTL] " & Key & " read failed, rc=" &
                            Interfaces.C.int'Image (RC));
         return -1;
      end if;
      if Len < Interfaces.C.size_t (4) then
         Murasama_Log.Warn ("[SYSCTL] " & Key & " returned only " &
                            Interfaces.C.size_t'Image (Len) & " bytes");
         return -1;
      end if;
      return Long_Long_Integer (Value);
   exception
      when E : others =>
         Murasama_Log.Error ("[SYSCTL] " & Key & " unexpected failure: " &
                             Ada.Exceptions.Exception_Message (E));
         return -1;
   end Read_I64;

   procedure Load (C : out Murasama_Types.Memorystatus_Config) is
   begin
      C := (Sysprocs_Idle_Delay_NS => Read_I64 (Key_Sysprocs),
            Apps_Idle_Delay_NS     => Read_I64 (Key_Apps),
            Wired_Max_Proc_Pct     => Read_I64 (Key_Wired),
            Kill_Sustained_Count   => Read_I64 (Key_Count),
            Kill_Window_Seconds    => Read_I64 (Key_Window),
            Kill_Delay_MS          => Read_I64 (Key_Delay));
   end Load;

   procedure Log (C : Murasama_Types.Memorystatus_Config) is
      function Img (X : Long_Long_Integer) return String is
         S : constant String := Long_Long_Integer'Image (X);
      begin
         return S (S'First + 1 .. S'Last);
      end Img;
   begin
      Murasama_Log.Info ("[MEMORYSTATUS] " & Key_Sysprocs & "=" &
                         Img (C.Sysprocs_Idle_Delay_NS));
      Murasama_Log.Info ("[MEMORYSTATUS] " & Key_Apps & "=" &
                         Img (C.Apps_Idle_Delay_NS));
      Murasama_Log.Info ("[MEMORYSTATUS] " & Key_Wired & "=" &
                         Img (C.Wired_Max_Proc_Pct));
      Murasama_Log.Info ("[MEMORYSTATUS] " & Key_Count & "=" &
                         Img (C.Kill_Sustained_Count));
      Murasama_Log.Info ("[MEMORYSTATUS] " & Key_Window & "=" &
                         Img (C.Kill_Window_Seconds));
      Murasama_Log.Info ("[MEMORYSTATUS] " & Key_Delay & "=" &
                         Img (C.Kill_Delay_MS));

      if Murasama_Types.Config_Matches_Desired (C) then
         Murasama_Log.Info
           ("[MEMORYSTATUS] all six values match the desired configuration");
      elsif not Murasama_Types.Config_Complete (C) then
         Murasama_Log.Warn
           ("[MEMORYSTATUS] at least one sysctl was unreadable (-1); " &
            "policy keeps its built-in safe defaults");
      else
         Murasama_Log.Warn
           ("[MEMORYSTATUS] live kernel values differ from desired; " &
            "using the live values as the single source of truth");
      end if;
   end Log;

end Murasama_Config;
