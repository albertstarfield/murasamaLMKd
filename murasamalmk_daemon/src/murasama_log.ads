-- ============================================================================
-- PACKAGE: Murasama_Log
-- ============================================================================
--
-- PURPOSE:
--   Central logging facility for the Murasamalmk daemon. Implements the
--   project-mandated VERBOSE ERROR REPORTING policy: every error, warning,
--   and state change MUST be reported with full details and NEVER silently
--   suppressed.
--
-- AXIOMS:
--   AXIOM 1: Logging must never crash or block the daemon indefinitely.
--     (from: safety-fallback mandate, code-quality.md "EVERY Package ... MUST
--      have a safety fallback")
--   AXIOM 2: Timestamps must be monotonic (immune to NTP jumps).
--     (from: nanosecond time-anchor policy, code-quality.md — FORBIDDEN:
--      Ada.Calendar.Clock; REQUIRED: Ada.Real_Time / CLOCK_MONOTONIC class)
--   AXIOM 3: Concurrent tasks may log simultaneously at any time.
--     (from: daemon architecture — 4 tasks + main loop run concurrently,
--      ARM 9.4 protected objects guarantee mutual exclusion)
--
-- THEORIES:
--   THEOREM 1: A protected procedure serializes writers, so interleaved
--     log lines are never torn mid-line.
--     PROOF: By AXIOM 3 and ARM 9.4(11): at most one task executes a
--     protected action at any time; Put_Line happens inside that action.
--   THEOREM 2: Elapsed = Clock - Start_Time is non-negative and monotonic.
--     PROOF: By AXIOM 2, Ada.Real_Time.Clock is a monotonic time source;
--     subtraction of later-from-earlier samples yields Time_Span >= 0.
--   THEOREM 3: If the log file backend fails, stderr output still proceeds.
--     PROOF: File errors are caught BEFORE the stderr write; the failure
--     path only degrades the file channel (AXIOM 1 fallback).
--
-- APPLICATIONS:
--   - Protected object serializes all writes (THEOREM 1).
--   - Ada.Real_Time elapsed-since-start timestamp (THEOREM 2).
--   - Dual sink: stderr (always) + append-mode log file (best effort).
--   - Last-resort fallback: if BOTH sinks fail, the handler returns
--     without propagating. Rationale: raising inside an error-reporting
--     path would convert a logged fault into a daemon crash, violating
--     AXIOM 1. This silent-return is documented, bounded, and unreachable
--     while stderr remains open (the kernel guarantees fd 2 exists).
--
-- CITATIONS:
--   - Ada 2012 Reference Manual, ARM 9.4 (Protected Objects)
--   - Ada 2012 Reference Manual, ARM D.8 (Monotonic Time: Real_Time)
--   - code-quality.md: Nanosecond Time Anchor Policy; Murphy's Law;
--     Verbose Error Reporting Mandate
-- ============================================================================
package Murasama_Log is
   pragma SPARK_Mode (Off);
   -- SPARK_Mode Off rationale: performs Text_IO and reads a clock; side
   -- effects place it outside the SPARK proof domain by design.

   -- Severity-ordered entry points. All are safe to call from any task.
   procedure Info     (Msg : String);
   procedure Warn     (Msg : String);
   procedure Error    (Msg : String);
   procedure Critical (Msg : String);

   LOG_FILE : constant String :=
     "/usr/local/murasamaLMKd/murasamalmk_daemon/murasamalmk.log";

end Murasama_Log;
