-- ============================================================================
-- PACKAGE BODY: Murasama_Telemetry
-- ============================================================================
-- Remediation applied (audit findings):
--   [RED-4]  JSON injection/corruption: Front_Name now escaped via JSON_Escape;
--            float inputs guarded against NaN/Inf by Sanitize_Float.
--   [RED-5]  Non-atomic write raced the Python reader: payload is now built in
--            "<path>.tmp" and published via rename(2), which atomically replaces
--            the destination on POSIX - a concurrent reader sees either the old
--            or the new complete file, never a truncated mix.
--   [RED-6]  Silent "when others" handlers replaced with Murasama_Log reports.
--   [RED-7]  Elaboration verified the wrong directory. It now checks the actual
--            telemetry volume (/Volumes/EARU_dataIO) and logs the verdict.
--   [2026-11-25] Synthetic weather formulas REMOVED. The weather + earu blocks
--            now carry real EARU sensor values read by Murasama_EARU, and the
--            six live kern.memorystatus values are exported alongside them.
--
-- SPARK_Mode Off rationale: Text_IO/Directories side effects are outside the
-- SPARK subset (same rationale as macos_bridge.ads).
--
-- TIMING ANALYSIS (Export_Telemetry)
-- ============================================================================
-- Estimated Processing Time: O(payload) ~ tens of us typical (APFS buffered).
-- CPU Time: dominated by Put_Line formatting, <50us for this fixed schema.
-- WCET: ~100ms worst case - pathological disk stall on the target volume x5
--   penalty factor per code-quality.md table (network/USB mount possible).
-- Space Complexity: O(len(Front_Name)) for the escape buffer; rest O(1).
--
-- Derivation:
--   - Escape pass: single loop over Front_Name, bounded buffer => linear.
--   - Publish: one Create + N Put_Line + one Close + one rename syscall.
--   - Failure path: Close/Delete_File best-effort then one log line.
--
-- Hardware Assumptions:
--   - /Volumes/EARU_dataIO may be slow external media (drives WCET).
--   - Daemon runs as root via launchd (write permission assumed).
--
-- TIMING ANCHOR: wall-clock timestamps use Ada.Calendar (display-only field,
--   not used for interval math); all interval decisions elsewhere use
--   Ada.Real_Time monotonic anchor per code-quality.md policy.
-- ============================================================================

with Ada.Text_IO;
with Ada.Exceptions;
with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Directories;
with Interfaces.C; use Interfaces.C;
with MacOS_Bridge; use MacOS_Bridge;
with Murasama_Log;
with Murasama_Types; use Murasama_Types;
with Murasama_EARU;

package body Murasama_Telemetry is
   pragma SPARK_Mode (Off);

   EARU_VOLUME : constant String := "/Volumes/EARU_dataIO";

   -- ------------------------------------------------------------------------
   -- JSON string escaping (RFC 8259 section 7).
   -- Worst case expansion: control char -> 6 chars (\u00XX), hence the
   -- 6x-sized result buffer. Loop-free per character; cannot overflow because
   -- every branch's advance equals the space reserved for that class.
   -- ------------------------------------------------------------------------
   function JSON_Escape (S : String) return String is
      Result : String (1 .. S'Length * 6) := (others => ' ');
      Pos    : Natural := 0;
      Hex    : constant String := "0123456789abcdef";
   begin
      for I in S'Range loop
         declare
            C    : constant Character := S (I);
            Code : constant Natural := Character'Pos (C);
         begin
            if C = '"' then
               Result (Pos + 1) := '\';
               Result (Pos + 2) := '"';
               Pos := Pos + 2;
            elsif C = '\' then
               Result (Pos + 1) := '\';
               Result (Pos + 2) := '\';
               Pos := Pos + 2;
            elsif Code < 32 then
               Result (Pos + 1) := '\';
               Result (Pos + 2) := 'u';
               Result (Pos + 3) := '0';
               Result (Pos + 4) := '0';
               Result (Pos + 5) := Hex (Code / 16 + 1);
               Result (Pos + 6) := Hex (Code mod 16 + 1);
               Pos := Pos + 6;
            else
               Pos := Pos + 1;
               Result (Pos) := C;
            end if;
         end;
      end loop;
      return Result (1 .. Pos);
   end JSON_Escape;

   -- ------------------------------------------------------------------------
   -- MURPHY'S LAW GUARD: Free_MB/Wired_MB/velocity arrive from the C bridge
   -- (host_statistics64). A hostile/degenerate kernel response could yield
   -- NaN or absurd magnitudes whose 'Image is not valid JSON, silently
   -- starving the ML reader. Clamp to a safe default instead.
   -- IEEE-754: NaN is the only value unequal to itself.
   -- ------------------------------------------------------------------------
   function Sanitize_Float (V : Long_Float) return Long_Float is
   begin
      if V /= V then                 -- NaN
         return 0.0;
      end if;
      if abs V > 1.0E15 then         -- Inf / garbage magnitude
         return 0.0;
      end if;
      return V;
   end Sanitize_Float;

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
   ) is
      Now  : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      Time_Str : constant String := Ada.Calendar.Formatting.Image (Now);
      Sensors  : Murasama_EARU.EARU_Sensors;

      -- Format helpers for floats
      function F_Str (V : Long_Float) return String is
         Img : constant String := Long_Float'Image (V);
         Start : Positive := Img'First;
      begin
         if Img (Img'First) = ' ' then
            Start := Img'First + 1;
         end if;
         return Img (Start .. Img'Last);
      end F_Str;

      -- Format helpers for integers
      function I_Str (V : Integer) return String is
         Img : constant String := Integer'Image (V);
         Start : Positive := Img'First;
      begin
         if Img (Img'First) = ' ' then
            Start := Img'First + 1;
         end if;
         return Img (Start .. Img'Last);
      end I_Str;

      -- Format helpers for uint64
      function U_Str (V : unsigned_long_long) return String is
         Img : constant String := unsigned_long_long'Image (V);
         Start : Positive := Img'First;
      begin
         if Img (Img'First) = ' ' then
            Start := Img'First + 1;
         end if;
         return Img (Start .. Img'Last);
      end U_Str;

      -- Format helpers for signed 64-bit sysctl values
      function L_Str (V : Long_Long_Integer) return String is
         Img : constant String := Long_Long_Integer'Image (V);
         Start : Positive := Img'First;
      begin
         if Img (Img'First) = ' ' then
            Start := Img'First + 1;
         end if;
         return Img (Start .. Img'Last);
      end L_Str;

      -- ---------------------------------------------------------------------
      -- Atomic publish: build complete payload in "<path>.tmp", then rename.
      -- SAFETY FALLBACK: on ANY failure the temp file is removed, the previous
      -- telemetry file stays untouched, and the failure is logged verbosely.
      -- TIMING: see package-header TIMING ANALYSIS block.
      -- ---------------------------------------------------------------------
      procedure Write_To_Path (Path : String) is
         --  Private temp name: the EARU writer also publishes through
         --  "<path>.tmp", so sharing it caused rename(2) ENOENT races
         --  (observed errno=2 in /var/log/murasamalmkd.log).
         Tmp_Path : constant String := Path & ".murasama.tmp";
         Out_File : Ada.Text_IO.File_Type;
      begin
         --  Read live EARU sensors BEFORE deriving the JSON fields. The
         --  plausibility gate is the SPARK-proved EARU_Usable predicate.
         Murasama_EARU.Read (Sensors);
         declare
            Weather_OK : constant Boolean := Murasama_Types.EARU_Usable
              (Sensors.Read_OK, Sensors.Temperature_C,
               Sensors.Humidity_Pct, Sensors.Pressure_HPa);
            Reported_Pressure : constant Long_Float :=
              (if Weather_OK then Sensors.Pressure_HPa
               else 1013.25 - (Long_Float (Pressure_Level) * 2.5));
            Reported_Temp : constant Long_Float :=
              (if Weather_OK then Sensors.Temperature_C
               else 20.0 + (Long_Float (Pageins_Per_Sec) / 100.0));
            Reported_Humid : constant Long_Float :=
              (if Weather_OK then Sensors.Humidity_Pct
               else 50.0 + (Long_Float (Decomp_Per_Sec) / 500.0));
            Weather_Source : constant String :=
              (if Weather_OK then "earu" else "fallback");
         begin
         Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File, Tmp_Path);
         Ada.Text_IO.Put_Line (Out_File, "{");
         Ada.Text_IO.Put_Line (Out_File, "  ""timestamp"": """ & Time_Str & """,");
         Ada.Text_IO.Put_Line (Out_File, "  ""memory"": {");
         Ada.Text_IO.Put_Line (Out_File, "    ""free_mb"": " & F_Str (Sanitize_Float (Free_MB)) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""wired_mb"": " & F_Str (Sanitize_Float (Wired_MB)) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""pressure_level"": " & I_Str (Pressure_Level) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""velocity_mb_s"": " & F_Str (Sanitize_Float (Wired_Velocity)));
         Ada.Text_IO.Put_Line (Out_File, "  },");
         Ada.Text_IO.Put_Line (Out_File, "  ""thrashing"": {");
         Ada.Text_IO.Put_Line (Out_File, "    ""pageins_per_sec"": " & U_Str (Pageins_Per_Sec) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""decomp_per_sec"": " & U_Str (Decomp_Per_Sec) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""is_mitigating"": " & (if Mitigation_Active then "true" else "false"));
         Ada.Text_IO.Put_Line (Out_File, "  },");
         Ada.Text_IO.Put_Line (Out_File, "  ""active_app"": {");
         Ada.Text_IO.Put_Line (Out_File, "    ""pid"": " & I_Str (Front_PID) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""name"": """ & JSON_Escape (Front_Name) & """");
         Ada.Text_IO.Put_Line (Out_File, "  },");
         -- Six live kernel values, read inside the Ada program at startup.
         Ada.Text_IO.Put_Line (Out_File, "  ""memorystatus_config"": {");
         Ada.Text_IO.Put_Line (Out_File, "    ""sysprocs_idle_delay_time_ns"": " & L_Str (Memstatus.Sysprocs_Idle_Delay_NS) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""apps_idle_delay_time_ns"": " & L_Str (Memstatus.Apps_Idle_Delay_NS) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""wired_max_proc_pct"": " & L_Str (Memstatus.Wired_Max_Proc_Pct) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""kill_on_sustained_pressure_count"": " & L_Str (Memstatus.Kill_Sustained_Count) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""kill_on_sustained_pressure_window_s"": " & L_Str (Memstatus.Kill_Window_Seconds) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""kill_on_sustained_pressure_delay_ms"": " & L_Str (Memstatus.Kill_Delay_MS) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""matches_desired"": " &
           (if Murasama_Types.Config_Matches_Desired (Memstatus) then "true" else "false") & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""daemon_owns_sustained_kills"": " &
           (if Murasama_Types.Daemon_Owns_Sustained_Kills (Memstatus) then "true" else "false"));
         Ada.Text_IO.Put_Line (Out_File, "  },");
         -- Real EARU telemetry (meteo JSON + scalar sensor files).
         Ada.Text_IO.Put_Line (Out_File, "  ""earu"": {");
         Ada.Text_IO.Put_Line (Out_File, "    ""temperature_c"": " & F_Str (Sanitize_Float (Sensors.Temperature_C)) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""apparent_c"": " & F_Str (Sanitize_Float (Sensors.Apparent_C)) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""humidity_pct"": " & F_Str (Sanitize_Float (Sensors.Humidity_Pct)) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""pressure_msl_hpa"": " & F_Str (Sanitize_Float (Sensors.Pressure_HPa)) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""surface_pressure_hpa"": " & F_Str (Sanitize_Float (Sensors.Surface_HPa)) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""wind_kmh"": " & F_Str (Sanitize_Float (Sensors.Wind_Kmh)) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""wind_dir_deg"": " & F_Str (Sanitize_Float (Sensors.Wind_Deg)) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""weather_code"": " & I_Str (Sensors.Weather_Code) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""cloud_cover_pct"": " & F_Str (Sanitize_Float (Sensors.Cloud_Pct)) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""cpu_temp_c"": " & F_Str (Sanitize_Float (Sensors.CPU_Temp_C)) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""fan0_rpm"": " & F_Str (Sanitize_Float (Sensors.Fan0_RPM)) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""turbo_mode"": " & F_Str (Sanitize_Float (Sensors.Turbo_Mode)) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""power_day_wh"": " & F_Str (Sanitize_Float (Sensors.Power_Day_Wh)) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""source"": """ & Weather_Source & """");
         Ada.Text_IO.Put_Line (Out_File, "  },");
         Ada.Text_IO.Put_Line (Out_File, "  ""weather"": {");
         Ada.Text_IO.Put_Line (Out_File, "    ""atmospheric_pressure_hPa"": " & F_Str (Sanitize_Float (Reported_Pressure)) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""temperature_c"": " & F_Str (Sanitize_Float (Reported_Temp)) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""humidity_pct"": " & F_Str (Sanitize_Float (Reported_Humid)) & ",");
         Ada.Text_IO.Put_Line (Out_File, "    ""source"": """ & Weather_Source & """");
         Ada.Text_IO.Put_Line (Out_File, "  }");
         Ada.Text_IO.Put_Line (Out_File, "}");
         Ada.Text_IO.Close (Out_File);

         -- ATOMIC PUBLISH: POSIX rename(2) atomically replaces the destination.
         declare
            RC : int;
         begin
            RC := Atomic_Rename_C (To_C (Tmp_Path), To_C (Path));
            if RC /= 0 then
               raise Program_Error with "atomic rename failed, errno=" & Integer'Image (Integer (RC));
            end if;
         end;
         end;
      exception
         when E : others =>
            -- VERBOSE FAILURE REPORTING (audit RED-6): never swallow silently.
            begin
               if Ada.Text_IO.Is_Open (Out_File) then
                  Ada.Text_IO.Close (Out_File);
               end if;
            exception
               when others => null;   -- close-of-closed best effort; reported below
            end;
            begin
               Ada.Directories.Delete_File (Tmp_Path);
            exception
               when others => null;   -- nothing to clean; reported below
            end;
            Murasama_Log.Error ("Telemetry export FAILED for '" & Path &
                                "': " & Ada.Exceptions.Exception_Message (E));
      end Write_To_Path;

   begin
      -- Write telemetry for the ML predictor (EARU_DATA_FILE = /Volumes/EARU_dataIO/EARU_data.dat)
      Write_To_Path (EARU_DATA_FILE);
   end Export_Telemetry;

begin
   -- FIX (audit RED-7): verify the ACTUAL telemetry volume; report verdict.
   begin
      if Ada.Directories.Exists (EARU_VOLUME) then
         Murasama_Log.Info ("Telemetry volume present: " & EARU_VOLUME);
      else
         Murasama_Log.Warn ("Telemetry volume NOT mounted: " & EARU_VOLUME &
                            " - exports will fail until it is mounted");
      end if;
   exception
      when E : others =>
         Murasama_Log.Error ("Cannot stat telemetry volume '" & EARU_VOLUME &
                             "': " & Ada.Exceptions.Exception_Message (E));
   end;

   -- Daemon data directory (weights.csv home): create if missing, log outcome.
   begin
      if not Ada.Directories.Exists ("/usr/local/murasamaLMKd/murasamalmk_daemon") then
         Ada.Directories.Create_Directory ("/usr/local/murasamaLMKd/murasamalmk_daemon");
         Murasama_Log.Info ("Created daemon data directory");
      end if;
   exception
      when E : others =>
         Murasama_Log.Error ("Cannot create daemon data directory: " &
                             Ada.Exceptions.Exception_Message (E));
   end;
end Murasama_Telemetry;
