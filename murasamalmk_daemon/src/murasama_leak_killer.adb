with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Interfaces.C;
with Murasama_Log;
-- NOTE: MacOS_Bridge and Murasama_Types are deliberately NOT repeated here:
-- the spec's context clause applies to the body (Ada RM 10.1.2), and -gnatwr
-- flags duplicate body with-clauses as redundant (build warning).

package body Murasama_Leak_Killer is
   pragma SPARK_Mode (Off);
   -- SPARK_Mode Off rationale: see spec - FFI calls, libc kill(2), and
   -- logging side effects are outside the SPARK proof domain.

   -- ==========================================================================
   -- PRIVATE DECLARATIONS
   -- ==========================================================================

   -- libc kill(2): sends Sig to PID. Returns 0 on success, -1 on failure
   -- (ESRCH = no such process, EPERM = not permitted). Declared here rather
   -- than in MacOS_Bridge because it is libc, not a macos_utils.m function
   -- - same pattern as the daemon body's own Kill_C import.
   -- Citation: kill(2) https://developer.apple.com/documentation/man/2/kill
   function Kill (PID : MacOS_Bridge.PID_T; Sig : Interfaces.C.int)
     return Interfaces.C.int;
   pragma Import (C, Kill, "kill");

   -- SIGKILL: unconditional termination, cannot be caught or ignored.
   -- Chosen for parity with the daemon's existing panic-kill path, which
   -- also sends signal 9 (murasamalmk_daemon.adb memory-pressure kill).
   SIGKILL : constant Interfaces.C.int := 9;

   -- ==========================================================================
   -- PROCEDURE: Check_And_Kill (body)
   -- ==========================================================================
   --
   -- AXIOMS:       1-6 as stated in the package spec header.
   -- THEOREMS:     1-6 as stated in the package spec header.
   -- APPLICATIONS: each step below is labelled with the theorem it proves.
   -- CITATIONS:    Apple proc_pid_rusage/proc_pidinfo docs + kill(2) +
   --               getpwuid_r(3) (see spec header), Ada 2012 RM 11.4.1
   --               (handler must not re-raise for THEOREM 2), and
   --               src/macos_utils.h (find_leak_candidates_c,
   --               get_user_info_c contracts = AXIOMS 1 and 3).
   --
   -- TIMING ANALYSIS (body): iteration happens inside the imported C scan
   --   (see spec header: O(P + K), WCET 150ms); the Ada loop is bounded by
   --   LEAK_MAX_CANDIDATES (16) iterations x (2 exemptions + 1 FFI owner
   --   lookup + <= 1 kill + <= 2 log lines) => Ada-side WCET contribution
   --   <= ~10ms dominated by Text_IO; Space Complexity O(1): four
   --   LEAK_MAX_CANDIDATES-slot arrays (<= 320 bytes) + one MAX_NAME_LEN
   --   char_array - all stack, no heap.
   -- ==========================================================================
   procedure Check_And_Kill is
      use type Interfaces.C.int;

      -- Candidate buffers from the C scan (AXIOM 1): valid prefix is
      -- 1 .. Integer (Count_C), largest footprint first.
      Pids    : Leak_PID_Array := (others => 0);
      Bytes   : Leak_Bytes_Array := (others => 0);
      Ages    : Leak_Age_Array := (others => 0);
      Count_C : Interfaces.C.int;

      -- Cycle tallies for the summary line (locals only - no shared state,
      -- so THEOREM 6's determinism holds across invocations).
      Killed     : Natural := 0;
      Dry_Runs   : Natural := 0;
      Exempted   : Natural := 0;
      Skipped    : Natural := 0;
   begin
      -- APPLICATION STEP 1 (scan; feeds THEOREMS 4/5 input set):
      -- Pass the configured thresholds straight through - the C side does
      -- the STRICT comparisons against kernel-proven footprint and age
      -- (AXIOM 1/2), excludes self and pid < 200, and sorts largest-first.
      -- 0 here means "no candidates OR scan error" (AXIOM 1); both are
      -- safe no-ops and the C details already went to stderr.
      Count_C := MacOS_Bridge.Find_Leak_Candidates_C
        (Min_Footprint_Bytes =>
           Interfaces.C.long_long (Murasama_Types.LEAK_MIN_FOOTPRINT_BYTES),
         Min_Age_Seconds =>
           Interfaces.C.long_long (Murasama_Types.LEAK_MIN_AGE_SECONDS),
         Out_Pids            => Pids,
         Out_Footprint_Bytes => Bytes,
         Out_Age_Seconds     => Ages,
         N                   =>
           Interfaces.C.int (Murasama_Types.LEAK_MAX_CANDIDATES));

      if Count_C <= 0 then
         Murasama_Log.Info
           ("[LEAK CHECK] 0 candidates this cycle (none exceeded " &
            "footprint/age thresholds, or scan failed - C errors, if any, " &
            "are on stderr)");
      end if;

      -- ── MDS SECOND PASS (MDS special reap is active only when the
      --    disable flag file "/usr/local/murasamaLMKd/
      --    disable_leak_killer_mds_stores" does NOT exist). This pass
      --    finds pids above 512 MiB so the 512 MiB envelope isn't
      --    invisible to the generic 1 GiB scan. Same C function, same
      --    age gate (12h), same exclusion set (self, pid < 200,
      --    largest-footprint-first). MDS-only candidates are tracked
      --    here; generic candidates come from the 1 GiB pass above.
      --    Flag semantics: re-read EVERY cycle; creation/removal takes
      --    effect on the next cycle without a rebuild (247 idiom).
      --    MDS_Pids/-Bytes/-Ages are Leak_*_Array scalars here too.
      declare
         MDS_Flag_Exists : constant Boolean :=
           Ada.Directories.Exists (Murasama_Types.MDS_DISABLE_FLAG_PATH);
         MDS_Reap_Active : constant Boolean :=
           not Murasama_Types.MDS_Special_Reap_Disabled (MDS_Flag_Exists);
         MDS_Pids    : Murasama_Leak_Killer.Leak_PID_Array := (others => 0);
         MDS_Bytes   : Murasama_Leak_Killer.Leak_Bytes_Array := (others => 0);
         MDS_Ages    : Murasama_Leak_Killer.Leak_Age_Array := (others => 0);
         MDS_Count_C : Interfaces.C.int;
      begin
         if MDS_Reap_Active then
            MDS_Count_C := MacOS_Bridge.Find_Leak_Candidates_C
              (Min_Footprint_Bytes =>
                 Interfaces.C.long_long (Murasama_Types.MDS_MIN_FOOTPRINT_BYTES),
               Min_Age_Seconds =>
                 Interfaces.C.long_long (Murasama_Types.LEAK_MIN_AGE_SECONDS),
               Out_Pids            => MDS_Pids,
               Out_Footprint_Bytes => MDS_Bytes,
               Out_Age_Seconds     => MDS_Ages,
               N                   =>
                 Interfaces.C.int (Murasama_Types.LEAK_MAX_CANDIDATES));
            if MDS_Count_C > 0 then
               Murasama_Log.Info
                 ("[LEAK CHECK] MDS pass: " &
                  Integer'Image (Integer (MDS_Count_C)) &
                  " candidate(s) above 512 MiB / 12h (flag absent)");
            end if;
         else
            Murasama_Log.Info
              ("[LEAK CHECK] MDS pass OFF - disable flag '"
               & Murasama_Types.MDS_DISABLE_FLAG_PATH & "' present; "
               & "generic *_* exemption applies (mds_stores shielded)");
         end if;
      end;

      -- Loop index is Interfaces.C.int (the bridge array index type) -
      -- NOT Integer: indexing Leak_PID_Array with an Integer would be a
      -- type mismatch (the monitor block uses the same int (I) discipline).
      -- Count_C <= 0 gives a null range, so the body never runs on an
      -- empty/error scan (AXIOM 1).
      for I in Interfaces.C.int range 1 .. Count_C loop
         -- APPLICATION STEP 5a (proves THEOREM 4): the cap is checked
         -- BEFORE any per-candidate work, so at most
         -- LEAK_MAX_KILLS_PER_CYCLE signals can be sent this invocation.
         exit when Killed >= Murasama_Types.LEAK_MAX_KILLS_PER_CYCLE;

         declare
            -- Owner data (AXIOM 3): name buffer pre-nulled so that even a
            -- partially-written C buffer yields a deterministic String
            -- (Murphy: never read uninitialized bytes).
            Name_C : Interfaces.C.char_array
              (1 .. Interfaces.C.size_t (Murasama_Types.MAX_NAME_LEN))
              := (others => Interfaces.C.nul);
            UID_V  : aliased MacOS_Bridge.UID_T := 0;
            RC     : Interfaces.C.int;
            PID_Image : constant String :=
              MacOS_Bridge.PID_T'Image (Pids (I));
            -- Per-candidate MDS inputs (pure-helper arguments): the process
            -- name (exact basename via the monitor's Get_Process_Name_C) and
            -- this cycle's flag stat. Both are fetched BEFORE the elsif
            -- chain below, so the chain's MDS conditions are total
            -- (never underdetermined at decision time).
            Proc_Name_C : Interfaces.C.char_array
              (1 .. Interfaces.C.size_t (Murasama_Types.MAX_NAME_LEN))
              := (others => Interfaces.C.nul);
            Proc_Name_Local : String (1 .. Murasama_Types.MAX_NAME_LEN) := (others => ' ');
            MDS_Flag_Exists_Local : constant Boolean :=
              Ada.Directories.Exists (Murasama_Types.MDS_DISABLE_FLAG_PATH);
            Foot_MB : constant String :=
              Long_Float'Image
                (Long_Float (Bytes (I)) / 1024.0 / 1024.0);
            Age_Hr  : constant String :=
              Long_Float'Image (Long_Float (Ages (I)) / 3600.0);
         begin
            -- APPLICATION STEP 2 (proves THEOREM 1 - no-kill-on-unknown):
            -- Fetch owner BEFORE any policy test; a failed lookup means the
            -- *_* exemption cannot be evaluated, so the process must be
            -- skipped, never killed (missing data => no kill).
            RC := MacOS_Bridge.Get_User_Info_C
              (PID          => Pids (I),
               Out_UID      => UID_V,
               Out_Username => Name_C,
               Max_Len      =>
                 Interfaces.C.int (Murasama_Types.MAX_NAME_LEN));

            -- NOTE: Ada has NO `next`/continue statement (GNAT rejects it),
            -- so the per-candidate flow is one if/elsif/else chain: each
            -- terminal outcome gets its own branch and only the final
            -- `else` reaches the kill site.
            if RC /= 0 then
               Skipped := Skipped + 1;
               Murasama_Log.Warn
                 ("[LEAK CHECK] pid" & PID_Image &
                  " owner lookup FAILED (rc=" & Interfaces.C.int'Image (RC) &
                  ") - SKIP: unknown owner is never killed (missing data " &
                  "=> no kill)");
               -- THEOREM 1: this branch contains no kill site; everything
               -- below (exemptions AND kill) lives in the else branch and
               -- is unreachable when the owner is unknown.
            else
               -- User must be converted AFTER the lookup (Name_C is what the
               -- C call just wrote); To_Ada + Trim_Nul drops the NUL
               -- padding, yielding exactly the passwd username (AXIOM 3).
               declare
                  User : constant String :=
                    Interfaces.C.To_Ada (Name_C, Trim_Nul => True);
               begin
                  -- Fetch the exact basename BEFORE the decision chain (this is
                  -- what the MDS helper tests; fetched via the same
                  -- Get_Process_Name_C the monitor already uses).
                  MacOS_Bridge.Get_Process_Name_C
                    (Pids (I), Proc_Name_C, Interfaces.C.int (Murasama_Types.MAX_NAME_LEN));
                  Proc_Name_Local :=
                    Interfaces.C.To_Ada (Proc_Name_C, Trim_Nul => True);

                  -- APPLICATION STEP 3 (proves THEOREM 3, first clause):
                  -- The *_* rule - ANY '_' in the username marks a macOS
                  -- service account (_spotlight, _windowserver, ...) =>
                  -- exempt.
                  -- APPLICATION STEP 3R (MDS special reap; see Murasama_Types
                  -- MDS_MIN_FOOTPRINT_BYTES and MDS_DISABLE_FLAG_PATH): the
                  -- generic scan used the 1 GiB threshold, but mds_stores must
                  -- be reaped above 512 MiB — so the scan below reaches it via
                  -- a SECOND C pass at 512 MiB, and this Ada chain gives it
                  -- its own branch. Order of branches matters (first principle:
                  -- the underscore branch below must NOT swallow MDS):
                  --   1. *_* system-user exemption — but SKIP the exemption
                  --      when the owner is the mds_stores indexer and the
                  --      disable flag is absent (Theorem M4: reaping MDS
                  --      never breaks user work; the index is rebuildable
                  --      and the daemon respawns it).
                  --   2. USER PRIORITY — /Users/<user> exemptions still
                  --      apply to MDS owners too (no owner needed: home check
                  --      is unconditional, so a user-owned mds_stores dies 'cold').
                  --   3. MDS special branch (this): exact basename
                  --      "mds_stores", flag ABSENT, footprint > 512 MiB, age > 12 h.
                  --      Then dry-run/kill with the same cap/gate as the generic rule.

                  if Ada.Strings.Fixed.Index (User, "_") > 0
                    and then not Murasama_Types.MDS_Waives_Underscore_Exemption
                      (Proc_Name_Local, MDS_Flag_Exists_Local) then
                     Exempted := Exempted + 1;
                     Murasama_Log.Info
                       ("[LEAK CHECK] pid" & PID_Image & " user=" & User &
                        " footprint=" & Foot_MB & " MB age=" & Age_Hr &
                        " h - exempt (system user, *_* rule)");

                  elsif Ada.Directories.Exists ("/Users/" & User) then
                     Exempted := Exempted + 1;
                     Murasama_Log.Info
                       ("[LEAK CHECK] pid" & PID_Image & " user=" & User &
                        " footprint=" & Foot_MB & " MB age=" & Age_Hr &
                        " h - exempt (user process, /Users/" & User &
                        " exists - USER PRIORITY)");

                  elsif Murasama_Types.MDS_Waives_Underscore_Exemption
                      (Proc_Name_Local, MDS_Flag_Exists_Local) then
                     -- MDS branch: the process name must be exactly
                     -- "mds_stores" (exact basename match — mds helpers and
                     -- random binaries that merely CONTAIN "mds" must not
                     -- inherit the lower threshold). Name via the same
                     -- Get_Process_Name_C the monitor uses.
                     declare
                        Proc_Name : constant String := Proc_Name_Local;
                     begin
                        -- Theorem M1: the waive predicate guarantees
                        -- Proc_Name = mds_stores here (exact basename),
                        -- Theta M2: the second C pass guarantees footprint
                        -- > 512 MiB, Theta group: age > 12h. Only the
                        -- dry-run gate stands between this point and
                        -- SIGKILL (Theorem M5).
                        if True then
                           -- Exact 12h age + 512MiB footprint were already proven by the
                           -- second C pass (AXIOM 1M), so only the dry-run gate
                           -- remains between here and SIGKILL (Theorem M5).
                           if not Murasama_Types.LEAK_KILL_ENABLED then
                              Dry_Runs := Dry_Runs + 1;
                              Murasama_Log.Info ("[LEAK WOULD KILL] (MDS 512MiB) pid" & PID_Image & " proc=" & Proc_Name & " user=" & User & " footprint=" & Foot_MB & " MB age=" & Age_Hr & " h - all criteria met; dry-run only");
                           else
                              declare
                                 Kill_RC : constant Interfaces.C.int := Kill (Pids (I), SIGKILL);
                              begin
                                 if Kill_RC = 0 then
                                    Killed := Killed + 1;
                                    Murasama_Log.Info ("[LEAK KILL] (MDS 512MiB) pid" & PID_Image & " proc=" & Proc_Name & " user=" & User & " footprint=" & Foot_MB & " MB age=" & Age_Hr & " h - SIGKILL sent (512MiB envelope)");
                                 else
                                    Skipped := Skipped + 1;
                                    Murasama_Log.Error ("[LEAK KILL] (MDS 512MiB) SIGKILL FAILED pid" & PID_Image & " user=" & User & " rc=" & Interfaces.C.int'Image (Kill_RC) & " (ESRCH=target exited, EPERM=protected) - not counted; next cycle re-evaluates");
                                 end if;
                              end;
                           end if;
                        else
                           -- Not the MDS indexer: fall through to the generic
                           -- rule's kill decision (dry-run gate or generic SIGKILL).
                           if not Murasama_Types.LEAK_KILL_ENABLED then
                              Dry_Runs := Dry_Runs + 1;
                              Murasama_Log.Info ("[LEAK WOULD KILL] pid" & PID_Image & " proc=" & Proc_Name & " user=" & User & " footprint=" & Foot_MB & " MB age=" & Age_Hr & " h - all criteria met; dry-run only");
                           else
                              declare
                                 Kill_RC : constant Interfaces.C.int := Kill (Pids (I), SIGKILL);
                              begin
                                 if Kill_RC = 0 then
                                    Killed := Killed + 1;
                                    Murasama_Log.Info ("[LEAK KILL] pid" & PID_Image & " proc=" & Proc_Name & " user=" & User & " footprint=" & Foot_MB & " MB age=" & Age_Hr & " h - SIGKILL sent");
                                 else
                                    Skipped := Skipped + 1;
                                    Murasama_Log.Error ("[LEAK KILL] SIGKILL FAILED pid" & PID_Image & " user=" & User & " rc=" & Interfaces.C.int'Image (Kill_RC) & " (ESRCH=target exited, EPERM=protected) - not counted; next cycle re-evaluates");
                                 end if;
                              end;
                           end if;
                        end if;
                     end;
                  -- final else is unreachable, zero signals are sent.
                  elsif not Murasama_Types.LEAK_KILL_ENABLED then
                     Dry_Runs := Dry_Runs + 1;
                     Murasama_Log.Info
                       ("[LEAK WOULD KILL] pid" & PID_Image & " user=" &
                        User & " footprint=" & Foot_MB & " MB age=" &
                        Age_Hr & " h - all criteria met; dry-run only " &
                        "(LEAK_KILL_ENABLED=False)");

                  -- APPLICATION STEP 5c (kill site; reachable ONLY when the
                  -- owner is known AND both exemptions failed AND the gate
                  -- is open - THEOREMS 3/4/5):
                  else
                     declare
                        Kill_RC : constant Interfaces.C.int :=
                          Kill (Pids (I), SIGKILL);
                     begin
                        if Kill_RC = 0 then
                           Killed := Killed + 1;
                           Murasama_Log.Info
                             ("[LEAK KILL] pid" & PID_Image & " user=" &
                              User & " footprint=" & Foot_MB &
                              " MB age=" & Age_Hr & " h - SIGKILL sent");
                        else
                           -- AXIOM 5: kill can fail (ESRCH = exited between
                           -- scan and kill; EPERM = protected). Report
                           -- loudly, do NOT count it, do NOT retry within
                           -- this cycle - the next 10-minute cycle
                           -- re-evaluates from fresh kernel data.
                           Skipped := Skipped + 1;
                           Murasama_Log.Error
                             ("[LEAK KILL] SIGKILL FAILED pid" & PID_Image &
                              " user=" & User & " rc=" &
                              Interfaces.C.int'Image (Kill_RC) &
                              " (ESRCH=target exited, EPERM=protected) - " &
                              "not counted; next cycle re-evaluates");
                        end if;
                     end;
                  end if;
               end; -- closes the User conversion declare block
            end if; -- closes the owner-known if/else (THEOREM 1)
         end; -- closes the per-candidate owner-data declare block
      end loop;

      -- APPLICATION STEP 6 (summary; supports THEOREM 6 determinism):
      -- One line per cycle always emitted when candidates existed, so
      -- each cycle's outcomes have a single place to inspect. When Killed
      -- hit the cap, survivors self-report next cycle (they are re-scanned
      -- from scratch - AXIOM 1 keeps no state).
      if Count_C > 0 then
         Murasama_Log.Info
           ("[LEAK CHECK] summary: candidates=" &
            Integer'Image (Integer (Count_C)) &
            " killed=" & Natural'Image (Killed) &
            " dry-run=" & Natural'Image (Dry_Runs) &
            " exempt=" & Natural'Image (Exempted) &
            " skipped=" & Natural'Image (Skipped) &
            " cap=" &
            Integer'Image (Murasama_Types.LEAK_MAX_KILLS_PER_CYCLE) &
            " enabled=" & Boolean'Image (Murasama_Types.LEAK_KILL_ENABLED));
      end if;

   exception
      -- APPLICATION STEP 7 (proves THEOREM 2 - total failure containment):
      -- ANY unexpected exception is logged with full details and swallowed;
      -- no re-raise, so the caller's interval timestamp always advances
      -- and the main loop can never be killed or hot-looped by this
      -- package (Ada 2012 RM 11.4.1; parity with the monitor block).
      when E : others =>
         Murasama_Log.Error
           ("[LEAK CHECK] unexpected failure - cycle aborted, daemon " &
            "continues: " & Ada.Exceptions.Exception_Information (E));
   end Check_And_Kill;

end Murasama_Leak_Killer;
