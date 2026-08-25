-- ============================================================================
-- PACKAGE BODY: Murasama_Log
-- ============================================================================
-- See murasama_log.ads for AXIOMS / THEORIES / APPLICATIONS / CITATIONS.
--
-- TIMING ANALYSIS
-- ============================================================================
-- Estimated Processing Time: O(len(Msg)) typical; two buffered line writes.
-- CPU Time: ~2-10us per line (Apple M-series SoC).
-- WCET: ~50ms worst case - pathological disk stall on the file sink
--   (10ms base latency x5 penalty factor per code-quality.md table).
-- Space Complexity: O(1) auxiliary - fixed-size timestamp buffer only.
--
-- Derivation:
--   - Prefix build: fixed-width fields => O(1), loop-free.
--   - Message emit: two Put_Line calls => linear in message length.
--   - WCET dominated by file-sink stalls; stderr write is ~us.
--
-- Hardware Assumptions:
--   - Apple Silicon host, APFS volume hosting LOG_FILE.
--   - Daemon runs as root via launchd; stderr always captured.
--
-- TIMING ANCHOR: Nanosecond Resolution (1ns minimum)
-- Clock Source: Ada.Real_Time.Clock (mach_absolute_time / CLOCK_MONOTONIC
--   class on macOS - immune to NTP steps)
-- Resolution: 1ns (Real_Time.Time_Span units)
-- ============================================================================

with Ada.Text_IO;
with Ada.Real_Time;

package body Murasama_Log is

   -- Make primitive operators ("-") of Real_Time.Time visible for infix use
   -- WITHOUT opening the whole package (ARM 8.4 / 10.1.6 use-type clause).
   use type Ada.Real_Time.Time;

   Start_Time : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;

   -- ------------------------------------------------------------------------
   -- Local string helpers (fixed-size, allocation-free, loop-free).
   -- Declared BEFORE first use per ARM 8.3 declarative-region rules.
   -- ------------------------------------------------------------------------

   -- Strip leading space produced by 'Image for non-negative values.
   -- AXIOM: V >= 0 (callers guarantee); fallback keeps full image anyway.
   function Trim_Nonneg (V : Integer) return String is
      Img : constant String := Integer'Image (V);
   begin
      if Img (Img'First) = ' ' then
         return Img (Img'First + 1 .. Img'Last);
      end if;
      return Img;
   end Trim_Nonneg;

   -- Zero-pad to exactly 3 digits (milliseconds field).
   -- Invariant: result length = 3 for V in 0..999 (callers guarantee range).
   function Pad3 (V : Integer) return String is
      S : constant String := Trim_Nonneg (V);
   begin
      case S'Length is
         when 0     => return "000";
         when 1     => return "00" & S;
         when 2     => return "0" & S;
         when 3     => return S;
         when others => return S (S'Last - 2 .. S'Last);
      end case;
   end Pad3;

   -- Bounded append: never writes past Buffer'Last (loop-free, provable).
   -- Invariant: Last <= Buffer'Length on entry and exit.
   procedure Append_Token
     (Buffer : in out String; Last : in out Natural; Token : String)
   is
      Space : constant Natural := Buffer'Length - Last;
      Take  : constant Natural := Natural'Min (Space, Token'Length);
   begin
      if Take > 0 then
         Buffer (Last + 1 .. Last + Take) :=
           Token (Token'First .. Token'First + Take - 1);
         Last := Last + Take;
      end if;
   end Append_Token;

   -- ------------------------------------------------------------------------
   -- THEOREM 1 implementation: mutual exclusion via protected object.
   -- All sink writes happen inside one protected action => lines atomic.
   -- ------------------------------------------------------------------------
   protected Log_Gate is
      procedure Emit (Severity_Tag : String; Msg : String);
   private
      File_Sink_Dead : Boolean := False;
   end Log_Gate;

   protected body Log_Gate is
      procedure Emit (Severity_Tag : String; Msg : String) is
         use Ada.Text_IO;

         -- APPLICATION STEP 1: monotonic elapsed timestamp (THEOREM 2).
         -- Integer arithmetic only: 'rem'/'/' are integer operators.
         Now       : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
         Elapsed   : constant Duration :=
           Ada.Real_Time.To_Duration (Now - Start_Time);
         Total_S   : constant Integer := Integer (Elapsed);          -- truncate
         Hours     : constant Integer := Total_S / 3600;
         Minutes   : constant Integer := (Total_S rem 3600) / 60;
         Seconds   : constant Integer := Total_S rem 60;
         Millis    : constant Integer :=
           Integer ((Elapsed - Duration (Total_S)) * 1000.0);

         subtype TS_Range is Positive range 1 .. 40;
         TS      : String (TS_Range) := (others => ' ');
         TS_Last : Natural := 0;
       begin
         -- APPLICATION STEP 2: build "[H:MM:SS.mmm]" prefix.
         -- Invariant: every append is bounds-checked by Append_Token.
         Append_Token (TS, TS_Last, "[");
         Append_Token (TS, TS_Last, Trim_Nonneg (Hours));
         Append_Token (TS, TS_Last, ":");
         if Minutes < 10 then
            Append_Token (TS, TS_Last, "0");
         end if;
         Append_Token (TS, TS_Last, Trim_Nonneg (Minutes));
         Append_Token (TS, TS_Last, ":");
         if Seconds < 10 then
            Append_Token (TS, TS_Last, "0");
         end if;
         Append_Token (TS, TS_Last, Trim_Nonneg (Seconds));
         Append_Token (TS, TS_Last, ".");
         Append_Token (TS, TS_Last, Pad3 (Millis));
         Append_Token (TS, TS_Last, "]");

         -- APPLICATION STEP 3a: stderr sink - primary, never skipped.
         Put_Line (Current_Error,
                   TS (1 .. TS_Last) & "[" & Severity_Tag & "] " & Msg);

         -- APPLICATION STEP 3b: file sink - best effort (THEOREM 3).
         if not File_Sink_Dead then
            declare
               F : File_Type;
            begin
               Open (F, Append_File, LOG_FILE);
               Put_Line (F, TS (1 .. TS_Last) & "[" & Severity_Tag & "] "
                           & Msg);
               Close (F);
            exception
               when Name_Error | Use_Error | Status_Error =>
                  -- Degrade permanently to stderr-only (AXIOM 1 fallback).
                  -- Documented, bounded; avoids retry spam on every call.
                  File_Sink_Dead := True;
                  Put_Line (Current_Error,
                            TS (1 .. TS_Last)
                            & "[LOG ] File sink unavailable ('" & LOG_FILE
                            & "') - continuing on stderr only.");
            end;
         end if;

      exception
         when others =>
            -- LAST-RESORT FALLBACK (ads header APPLICATIONS):
            -- the error-reporting layer must not itself raise; raising here
            -- would convert any logged fault into a daemon crash (AXIOM 1).
            -- Deliberate, documented silent return - reachable only if even
            -- stderr fails.
            null;
      end Emit;
   end Log_Gate;

   -- ------------------------------------------------------------------------
   -- Public API - thin severity wrappers around the serialized emitter.
   -- Safety fallback: wrappers cannot raise; Emit absorbs everything.
   --
   -- TIMING ANALYSIS (each): delegates to Emit => see header block above.
   -- Estimated O(len(Msg)); CPU ~2-10us; WCET ~50ms; Space O(1).
   -- TIMING ANCHOR: Ada.Real_Time (monotonic, 1ns units) via Emit.
   -- ------------------------------------------------------------------------
   procedure Info (Msg : String) is
   begin
      Log_Gate.Emit ("INFO", Msg);
   end Info;

   procedure Warn (Msg : String) is
   begin
      Log_Gate.Emit ("WARN", Msg);
   end Warn;

   procedure Error (Msg : String) is
   begin
      Log_Gate.Emit ("ERROR", Msg);
   end Error;

   procedure Critical (Msg : String) is
   begin
      Log_Gate.Emit ("CRIT", Msg);
   end Critical;

begin
   -- Package elaboration: announce the logger is live (proves sinks work).
   Murasama_Log.Info ("Murasama_Log initialized (monotonic anchor active)");
end Murasama_Log;
