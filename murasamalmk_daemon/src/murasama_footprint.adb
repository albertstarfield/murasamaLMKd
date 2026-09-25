with Ada.Exceptions;
with Interfaces.C;
with Murasama_Log;

package body Murasama_Footprint is
   pragma SPARK_Mode (Off);
   -- SPARK_Mode Off rationale: see spec — FFI call + logging side effects.

   -- ==========================================================================
   -- PROCEDURE: Get_Top_10_By_Footprint (body)
   -- ==========================================================================
   --
   -- AXIOMS:      1-4 as stated in the package spec header.
   -- THEOREMS:    1-3 as stated in the package spec header.
   -- APPLICATIONS: each step below is labelled with the theorem it proves.
   -- CITATIONS:   Apple proc_pid_rusage docs (see spec header), Ada 2012
   --              RM 11.4.1 (handler must define outputs), src/macos_utils.h.
   --
   -- TIMING ANALYSIS (body): no loops in Ada — all iteration happens inside
   --   the imported C function (see spec header: O(P), WCET 50ms).
   --   Ada-side cost: 1 FFI call + <= 3 comparisons + <= 1 exception path
   --   => WCET contribution <= 1us; Space Complexity O(1) (one int local).
   -- ==========================================================================
   procedure Get_Top_10_By_Footprint
     (Pids        : out Top10_PID_Array;
      Bytes       : out Top10_Bytes_Array;
      Count       : out Integer;
      Exclude_PID : MacOS_Bridge.PID_T := 0)
   is
      use type Interfaces.C.int;
      Count_C : Interfaces.C.int;
   begin
      -- APPLICATION STEP 1 (proves THEOREM 3, first half):
      -- Zero-fill before the FFI call so that whatever the C side does,
      -- entries beyond the returned count are deterministic all-zero —
      -- the caller can never observe stale caller-side garbage (Murphy).
      Pids  := (others => 0);
      Bytes := (others => 0);
      Count := 0;

      -- APPLICATION STEP 2 (proves THEOREM 1 precondition):
      -- Single FFI call; N = FOOTPRINT_TOP_10_N (axiom 4: arrays are
      -- exactly that long). Return value is the count the C side filled
      -- (AXIOM 1): 0 on error, otherwise <= N.
      Count_C := MacOS_Bridge.Get_Top_Processes_By_Footprint_C
        (Pids, Bytes,
         Interfaces.C.int (Murasama_Types.FOOTPRINT_TOP_10_N),
         Exclude_PID);

      -- APPLICATION STEP 3 (proves THEOREMS 1 and 2, non-exception paths):
      -- Three exhaustive cases over the C return value (AXIOM 1 says only
      -- 0..N should occur, but the kernel/FFI boundary is not trusted —
      -- Murphy's law: verify the range instead of assuming it).
      if Count_C <= 0 then
         -- Error path (AXIOM 3: root should always see processes, so an
         -- empty result IS an error): keep Count = 0, report FULL details.
         Count := 0;
         Murasama_Log.Warn
           ("[FOOTPRINT] top-10 query returned count=" &
            Interfaces.C.int'Image (Count_C) &
            " (expected 1.." &
            Integer'Image (Murasama_Types.FOOTPRINT_TOP_10_N) &
            ") -- proc_pid_rusage failed or no processes visible; " &
            "outputs zero-filled, Count=0");
      elsif Count_C > Interfaces.C.int (Murasama_Types.FOOTPRINT_TOP_10_N) then
         -- Defensive clamp: a return > N would make the arrays unreadable
         -- past their bounds if trusted verbatim (CWE-119 class). Clamp to
         -- N, log loudly so the contract drift is visible in the log.
         Count := Murasama_Types.FOOTPRINT_TOP_10_N;
         Murasama_Log.Warn
           ("[FOOTPRINT] top-10 query returned count=" &
            Interfaces.C.int'Image (Count_C) &
            " > N=" &
            Integer'Image (Murasama_Types.FOOTPRINT_TOP_10_N) &
            " -- clamped to N, entries beyond N ignored");
      else
         -- Success path (THEOREM 1): Count_C in 1..N, arrays valid for
         -- 1 .. Count_C; tail already zero (THEOREM 3).
         Count := Integer (Count_C);
      end if;

   exception
      when E : others =>
         -- APPLICATION STEP 4 (proves THEOREM 2, exception path):
         -- Safety fallback: never propagate into the caller (the monitor
         -- block and future callers run inside the daemon main loop).
         -- Re-zero everything so the outputs satisfy the postcondition and
         -- THEOREM 3 even after an unexpected exception (Ada RM: out params
         -- are only guaranteed defined if the body assigns them).
         Pids  := (others => 0);
         Bytes := (others => 0);
         Count := 0;
         Murasama_Log.Error
           ("[FOOTPRINT] Get_Top_10_By_Footprint raised: " &
            Ada.Exceptions.Exception_Information (E) &
            " -- outputs zero-filled, Count=0");
   end Get_Top_10_By_Footprint;

end Murasama_Footprint;
