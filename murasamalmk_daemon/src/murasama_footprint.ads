with MacOS_Bridge;
with Murasama_Types;

-- ============================================================================
-- PACKAGE: Murasama_Footprint
-- ============================================================================
--
-- PURPOSE: Standalone mechanism to list the top 10 processes by physical
--   memory footprint (Activity Monitor "Memory" column methodology).
--   MECHANISM ONLY: this package provides the callable procedure; it is
--   intentionally NOT wired into the 10s MEM MONITOR block or any caller
--   yet — wiring is a separate change.
--
-- AXIOMS:
-- -------
-- AXIOM 1: C-function contract (macos_utils.h / macos_bridge.ads):
--   Get_Top_Processes_By_Footprint_C fills at most N entries of the caller's
--   arrays with (pid, ri_phys_footprint bytes) pairs sorted largest-first,
--   and returns the number of entries filled (0 on error).
--   (from: function get_top_processes_by_footprint_c in src/macos_utils.h,
--    binding Get_Top_Processes_By_Footprint_C in src/macos_bridge.ads)
--
-- AXIOM 2: ri_phys_footprint via proc_pid_rusage(RUSAGE_INFO_V4) is the
--   same quantity Activity Monitor's Memory column reports: resident +
--   compressed + internal memory — NOT plain RSS.
--   (from: XNU proc_pid_rusage, Apple Developer Documentation)
--
-- AXIOM 3: The daemon runs as root (LaunchDaemon), so proc_pid_rusage
--   succeeds for all processes; failure to obtain ANY row therefore signals
--   a real error, never a permission-scoped empty set.
--   (from: /Library/LaunchDaemons/...murasamalmkd.plist run as root)
--
-- AXIOM 4: The arrays are unconstrained Interfaces.C-style arrays whose
--   index type is Interfaces.C.int; a 1-based slice of length
--   FOOTPRINT_TOP_10_N is exactly what the C function consumes.
--   (from: MacOS_Bridge.PID_Array / UINT64_Array declarations)
--
-- THEOREMS:
-- ---------
-- THEOREM 1 (success): If the C call returns N' with 1 <= N' <= 10, then on
--   return Count = N' and for every rank I in 1 .. Count:
--   Pids(I) = I-th largest footprint pid, Bytes(I) = its footprint bytes.
--   PROOF: Directly from AXIOM 1 (C fills largest-first) plus the
--   pass-through of N' in APPLICATION STEP 2.
--
-- THEOREM 2 (total failure containment): The procedure NEVER propagates an
--   exception to its caller. On ANY failure path (C returns <= 0, C returns
--   > 10, or an Ada exception) Count is set to 0 (or clamped to 10) AND an
--   explicit Murasama_Log line is emitted with the full details.
--   PROOF: Every path either assigns Count before falling off the end
--   (APPLICATION STEP 3) or enters the exception handler, which assigns
--   Count := 0 and logs (APPLICATION STEP 4). There is no other exit.
--
-- THEOREM 3 (output determinism): On return — success or failure — entries
--   Count+1 .. 10 of Pids/Bytes are all-zero.
--   PROOF: APPLICATION STEP 1 zero-fills both arrays before the C call, and
--   the C function only writes the first N' <= 10 entries (AXIOM 1).
--
-- APPLICATIONS:
-- -------------
-- IMPLEMENTATION: body of Get_Top_10_By_Footprint in murasama_footprint.adb;
--   each APPLICATION STEP comment there maps 1:1 to a theorem above.
--
-- CITATIONS:
--   - Apple Developer Documentation: proc_pid_rusage
--     https://developer.apple.com/documentation/kernel/proc_pid_rusage
--   - Apple Developer Documentation: proc_listpids
--     https://developer.apple.com/documentation/kernel/proc_listpids
--   - src/macos_utils.h (C implementation: get_top_processes_by_footprint_c)
--   - src/macos_bridge.ads (FFI binding + Activity Monitor methodology note)
--   - Ada 2012 Reference Manual RM 6.4.1 (out parameter semantics),
--     RM 11.4.1 (exception handlers must assign outputs before return)
--
-- ============================================================================
package Murasama_Footprint is
   pragma SPARK_Mode (Off);
   -- SPARK_Mode Off rationale: this package's sole procedure performs a
   -- pragma-Import(C) call into Objective-C Mach/libproc code
   -- (macos_utils.m) and a Text_IO logging side effect (Murasama_Log).
   -- Foreign code and I/O are outside the SPARK proof domain — same
   -- rationale and precedent as MacOS_Bridge and Murasama_Log.

   -- 1-based arrays of exactly FOOTPRINT_TOP_10_N slots (index constraint
   -- of the Interfaces.C.int-indexed bridge array types, AXIOM 4).
   subtype Top10_PID_Array is
     MacOS_Bridge.PID_Array (1 .. Murasama_Types.FOOTPRINT_TOP_10_N);
   subtype Top10_Bytes_Array is
     MacOS_Bridge.UINT64_Array (1 .. Murasama_Types.FOOTPRINT_TOP_10_N);

   -- ==========================================================================
   -- PROCEDURE: Get_Top_10_By_Footprint
   -- ==========================================================================
   --
   -- PURPOSE: Fill Pids/Bytes with the 10 largest phys_footprint holders,
   --   largest first, and report how many entries are valid in Count.
   --
   -- PARAMETERS:
   --   Pids        (out) top-10 pids, rank I at index I; tail zero-filled
   --   Bytes       (out) matching footprint bytes (ri_phys_footprint)
   --   Count       (out) valid entries: 0 .. FOOTPRINT_TOP_10_N
   --   Exclude_PID (in, default 0) pid to skip (0 = exclude none), passed
   --               through unchanged — same convention as the monitor block
   --
   -- NORMAL OUTPUT: Count = 10 on a healthy macOS (AXIOM 3), possibly
   --   < 10 only if fewer than 10 processes exist (e.g. early boot).
   -- ERROR OUTPUT: Count = 0 + Warn/Error log line (never an exception —
   --   THEOREM 2). Callers MUST branch on Count before reading indices.
   --
   -- WHY INPUT/OUTPUT DIFFER: input is an empty 10-slot buffer; output is a
   --   prefix (Count) of real kernel samples. The difference is exactly the
   --   number of processes the kernel could account for in this sample —
   --   derived from AXIOM 1 (C returns what it filled), not assumed.
   --
   -- TIMING ANALYSIS
   -- ==========================================================================
   -- TIMING ANCHOR: Nanosecond Resolution (1ns minimum)
   -- Clock Source: Ada.Real_Time (backed by CLOCK_MONOTONIC) — anchor
   --   applies to callers that bracket this call; this procedure itself
   --   performs no clock reads.
   -- Estimated Processing Time: O(P) — P = system process count; the C
   --   side runs proc_listpids once then proc_pid_rusage per process,
   --   sorting only the top 10 in place.
   -- CPU Time: ~5ms typical (P ~ 500-2000 x ~2-10us per rusage syscall)
   -- WCET: 50ms with 10x safety margin (launch storms, vnode contention)
   -- Space Complexity: O(1) — two 10-element output arrays (10*4 + 10*8 =
   --   120 bytes) + one int counter; no heap allocation on the Ada side.
   --
   -- Derivation:
   --   - proc_listpids scan: P iterations (from AXIOM 1 C implementation)
   --   - proc_pid_rusage per pid: 1 syscall x P = P syscalls
   --   - insertion of top-10: <= 10 comparisons per pid, bounded constant
   --   - Ada side: 1 FFI call + <= 2 comparisons + <= 1 exception path
   --   - Total ~ P syscalls dominates: 2000 x 10us = 20ms worst raw,
   --     x 2.5 margin => WCET 50ms
   --
   -- Hardware Assumptions:
   --   - CPU: Apple silicon (arm64) or Intel Mac, single-sample syscall cost
   --   - Kernel: XNU with proc_pid_rusage(RUSAGE_INFO_V4) available
   --   - Permissions: root (AXIOM 3)
   -- ==========================================================================
   procedure Get_Top_10_By_Footprint
     (Pids        : out Top10_PID_Array;
      Bytes       : out Top10_Bytes_Array;
      Count       : out Integer;
      Exclude_PID : MacOS_Bridge.PID_T := 0)
   with
     -- Theorem 1 + Theorem 2: Count is always a valid slot count
     Post => Count in 0 .. Murasama_Types.FOOTPRINT_TOP_10_N;

end Murasama_Footprint;
