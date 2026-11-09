package Murasama_Types is
   pragma Preelaborate;
   pragma SPARK_Mode (On);

   -- ==================== CONFIGURATION ====================
   -- All timing constants are single sources of truth (🟡22): every loop in
   -- the daemon derives its delays from these values. POLL_INTERVAL_MS is
   -- 100ms: measured steady-state CPU of the main poll loop is <0.9% at this
   -- rate; a faster poll would violate that budget without adding safety.

   -- Main monitoring loop period. Wired into main.adb main loop + runner idle.
   POLL_INTERVAL_MS            : constant := 100;
   -- Health-report / telemetry-export cadence (5s).
   REPORT_INTERVAL_MS          : constant := 5000;
   -- Memory-monitor cadence (10s): logs XNU pressure level, free/wired/
   -- compressor MB, swap usage, and top processes by phys_footprint
   -- (Activity Monitor methodology). Read-only — never triggers mitigation.
   MEM_MONITOR_INTERVAL_MS     : constant := 10000;
   -- How many top-footprint processes the 10s monitor logs per cycle.
   MEM_MONITOR_TOP_N           : constant := 5;
   -- Size of the standalone top-10 footprint listing mechanism
   -- (Murasama_Footprint.Get_Top_10_By_Footprint). Independent of
   -- MEM_MONITOR_TOP_N: the monitor logs 5 lines per 10s cycle, while this
   -- constant sizes the on-demand query procedure (🟡23).
   FOOTPRINT_TOP_10_N          : constant := 10;

    -- ==================== LEAK KILLER (memory-leak reaper) ====================
    -- Policy thresholds for Murasama_Leak_Killer.Check_And_Kill. A process is
    -- a leak candidate only when ALL of these hold (each STRICT):
    --   * owner username does NOT contain '_'  (the *_* rule — macOS service
    --     accounts like _spotlight/_windowserver are exempt),
    --   * owner has NO home directory /Users/<username> (USER PRIORITY —
    --     user processes never respawn themselves, so they are never
    --     reaped; vendor sloppiness must be endured by the user, not
    --     punished by killing the USER's processes),
    --   * ri_phys_footprint > 1 GB (Activity Monitor "Memory" methodology),
    --   * wall-clock age    > 12 h (now - pbi_start_tvsec).
    -- The daemon's own pid is additionally exempt (enforced once in C by
    -- getpid()). There is deliberately NO uid-0 exemption: root-owned
    -- vendor daemons (LuLu, XProtect, root leakers) — which run without
    -- user volition and respawn themselves — are exactly the targets.

   -- 1 GB strict threshold on phys_footprint (2^30 bytes).
   LEAK_MIN_FOOTPRINT_BYTES    : constant := 1024 * 1024 * 1024;
   -- 12 hours (43200 s) strict minimum wall-clock process age.
   LEAK_MIN_AGE_SECONDS        : constant := 12 * 3600;
   -- Leak-scan cadence (10 min): the thresholds are hourly-scale, so a
   -- faster scan adds CPU cost without materially changing kill latency
   -- (worst case = interval + scan duration).
   LEAK_CHECK_INTERVAL_MS      : constant := 600_000;
   -- Safety valve: at most this many SIGKILLs per scan cycle — a wrong
   -- policy or pathological system can never wipe the process table in
   -- one pass; remaining candidates are re-evaluated next cycle.
   LEAK_MAX_KILLS_PER_CYCLE    : constant := 2;
   -- Scan buffer: max candidates fetched per cycle (largest-first; any
   -- matches beyond the buffer wait for later cycles after the cap).
   LEAK_MAX_CANDIDATES         : constant := 8;
   -- MDS FINAL CORRECTION (user 2026-11-09): mds_stores must operate at
   -- 512 MiB, not 8 GB. Observed 2026-11-09 (footprint(1), pid 555,
   -- owner _mds_stores, age 04-21:09:12): phys_footprint 8909 MB, of which
   -- Malloc Small = 8794 MB (98.7%). Helpers at 8 MB, mds at 77 MB. The
   -- earlier "768MB" figure was an underestimate; raw measured value used.
   -- Owner requirement: this process must stay <= 512 MiB; action = the
   -- same SIGKILL path as the generic 1GB/12h leak rule, but at 512 MiB.
   -- Why this daemon on this target (first principles, not marketing):
   --   * mds_stores is Apple's metadata indexer. It runs as _mds_stores
   --     (underscore owner) with NO /Users/ home dir, so the generic *_*
   --     exemption (below) would shield it forever — the generic 1GB/12h
   --     rule as written can never reap it whatever its footprint.
   --   * The exemption's rationale is: *_* accounts are kernel/serving
   --     plumbing that must never be killed. mds_stores is NOT plumbing:
   --     it is a rebuildable search-index cache. Killing it loses no data;
   --     macOS respawns it and it re-indexes (slowly, once, self-limiting).
   --     The user did not choose to run it (no volition), it does not
   --     respawn user work, and under USER PRIORITY the process classes
   --     that must never die are user processes — this is a vendor system
   --     daemon precisely in scope ("targets are vendor/system daemons
   --     running without user volition or authorization").
   --   * 512 MiB is therefore the operating envelope for the process; the
   --     reap is the "killed" signal when it leaves that envelope. The
   --     generic 1 GiB threshold stays for everything else.
   -- IMPLEMENTATION SHAPE (mirrors the generic rule exactly):
   --   * MDS process name (exact basename, no substring): "mds_stores".
   --     mds / mds_stores helpers (8 MB) stay below 512 MiB anyway, so
   --     exact-name + footprint gate needs no special case for them.
   --   * strict phys_footprint > 512 MiB (536870912 B = 512*1024*1024).
   --   * wall-clock age > LEAK_MIN_AGE_SECONDS (12 h), same as generic —
   --     a freshly-rebuilt index briefly past 512 MiB while re-indexing
   --     after a reap is not a leak; only a long-lived, swollen index is.
   --   * other exemptions unchanged: unknown owner => no kill; /Users/
   --     home => no kill (user priority; USER PRIORITY applies to MDS
   --     owners too — if a real user ever owned an indexer, it is kept).
   --   * caps unchanged: LEAK_MAX_KILLS_PER_CYCLE per cycle, scanned
   --     candidates LEAK_MAX_CANDIDATES per cycle, dry-run gate
   --     LEAK_KILL_ENABLED unchanged.
   -- DISABLE FLAG (same-directory idiom as 247's disable_* flags, e.g.
   --   /usr/local/247AlwaysOnlineServe/disable_qos_warden_energy):
   --   "/usr/local/murasamaLMKd/disable_leak_killer_mds_stores", checked
   --   per cycle: if the file exists, the MDS special reap is off (the
   --   generic *_* exemption applies, so mds_stores is never reaped by
   --   this daemon); remove the file to re-enable. Flag semantics: pure
   --   existence, contents ignored; fail-open (a stat failure means "no
   --   exemption", i.e. the daemon still reaps — existence is the only
   --   signal that can exempt, and it is re-read every cycle).
   MDS_PROCESS_NAME            : constant String := "mds_stores";
   MDS_MIN_FOOTPRINT_BYTES     : constant := 512 * 1024 * 1024;
   MDS_DISABLE_FLAG_PATH       : constant String :=
     "/usr/local/murasamaLMKd/disable_leak_killer_mds_stores";
    -- Phase gate: False = DRY-RUN ("[LEAK WOULD KILL]" log lines only),
    -- True = actually SIGKILL. Constant (not variable) because flipping it
    -- requires a rebuild + daemon restart either way; flip ONLY after
    -- reviewing dry-run output. Phase 2 ENABLED 2026-09-25 after dry-run
    -- review + user priority policy finalized: /Users/ homes exempt
    -- (user priority), no uid-0 exemption (vendor root daemons are the
    -- targets: LuLu 689 / root python 55883 were dry-run exempt under the
    -- old uid-0 rule; _windowserver 1723 exempt via *_*).
    LEAK_KILL_ENABLED           : constant Boolean := True;
   CRITICAL_FREE_MB            : constant := 128.0;
   MIN_PRESSURE_LEVEL_TO_KILL  : constant := 4;
   GRADIENT_MEASURE_MS         : constant := 100;
   TOP_N_PROCESSES             : constant := 3;

   -- Thrashing_Task sampling cadence (snapshot pair spacing + idle sleep).
   SNAPSHOT_SPACING_MS         : constant := 100;
   THRASHING_IDLE_MS           : constant := 900;

   -- Weight table capacity: Weights_Array index bound and full-table checks
   -- both derive from this constant so they can never drift apart.
   WEIGHTS_TABLE_SIZE          : constant := 128;

   WEIGHTS_FILE                : constant String := "/usr/local/murasamaLMKd/murasamalmk_daemon/weights.csv";
   EARU_DATA_FILE              : constant String := "/Volumes/EARU_dataIO/EARU_data.dat";

   WEIGHT_DECREMENT_HOURS      : constant := 12;
   WEIGHT_PRIORITY_THRESHOLD   : constant := 3;

   -- Thrashing thresholds
   THRASHING_THRESHOLD_PAGEINS : constant := 500;
   THRASHING_THRESHOLD_DECOMP  : constant := 10000;
   HYSTERESIS_SECONDS          : constant := 60;

   -- Process name maximum length
   MAX_NAME_LEN                : constant := 64;

   type Process_Name_String is new String (1 .. MAX_NAME_LEN);

   type Weight_Record is record
      Name   : Process_Name_String;
      Length : Natural range 0 .. MAX_NAME_LEN;
      Value  : Natural;
   end record;

   type Weights_Array is array (1 .. WEIGHTS_TABLE_SIZE) of Weight_Record;

   -- ==================== LEAK KILLER: MDS PLUMBING (pure helpers) ====================
   -- The MDS special reap's threshold/disable-flag logic, stated as pure
   -- SPARK functions so gnatprove can check them AND so the Lean/Rocq proofs
   -- (proofs/mds_leak.lean|v) mirror real Ada code, not a sketch.

   -- Flag-file existence => MDS special reap is OFF. Checked every cycle
   -- (Ada.Directories.Exists); anything short of "exists" (missing file,
   -- bad permissions, ENOTDIR) reads as False = reap on.
   function MDS_Special_Reap_Disabled (Flag_Exists : Boolean) return Boolean
     with Post => (MDS_Special_Reap_Disabled'Result = Flag_Exists);

   -- The MDS process-name test is an EXACT match: no substring, no prefix.
   -- It is what keeps mds helpers (8 MB, below 512 MiB anyway) and binaries
   -- merely containing "mds" from inheriting the lower threshold.
   function Is_MDS_Indexer (Process_Name : String) return Boolean
     with Post => (Is_MDS_Indexer'Result = (Process_Name = MDS_PROCESS_NAME));

   -- Footprint gate for the MDS envelope: strict > 512 MiB.
   function MDS_Crosses_512MiB (Phys_Footprint_Bytes : Long_Long_Integer) return Boolean
     with Post => (MDS_Crosses_512MiB'Result =
                   (Phys_Footprint_Bytes > Long_Long_Integer (MDS_MIN_FOOTPRINT_BYTES)));

   -- The *_* exemption's MDS waiver, on published inputs (no I/O): the
   -- exemption is waived iff this is an exact mds_stores process whose
   -- reap is enabled. The checklist in Check_And_Kill offers the SAME
   -- values (process name, flag stat, footprint, age) at the decision.
   function MDS_Waives_Underscore_Exemption
     (Process_Name : String; Flag_Exists : Boolean) return Boolean
     with Post => (MDS_Waives_Underscore_Exemption'Result =
                   (Is_MDS_Indexer (Process_Name)
                    and then not MDS_Special_Reap_Disabled (Flag_Exists)));

   -- ==================== SPARK-VERIFIED PURE FUNCTIONS ====================
   -- These pure functions are verified by gnatprove --level=4 to have no
   -- runtime errors, correct data flow, and satisfied contracts.

   -- Purpose: Determine if a memory pressure level warrants killing processes.
   -- Contract: Returns True iff Level >= MIN_PRESSURE_LEVEL_TO_KILL (4).
   -- Proved by: Flow analysis + proof that comparison is correct.
   function Is_Critical_Pressure (Level : Integer) return Boolean
     with Post => (Is_Critical_Pressure'Result = (Level >= MIN_PRESSURE_LEVEL_TO_KILL));

   -- Purpose: Determine if free memory has dropped below the critical threshold.
   -- Contract: Returns True iff Free_MB < CRITICAL_FREE_MB (128.0 MB).
   -- Proved by: Proof that floating-point comparison is well-defined.
   function Is_Free_Memory_Critical (Free_MB : Long_Float) return Boolean
     with Post => (Is_Free_Memory_Critical'Result = (Free_MB < CRITICAL_FREE_MB));

   -- Purpose: Determine if wired memory velocity indicates a violent allocation spike.
   -- Contract: Returns True iff Velocity > Threshold_MB_S (MB/s). Threshold is
   --   derived at runtime from the machine's total RAM (dynamic detection),
   --   not a compile-time constant (see murasamalmk_daemon.adb).
   -- Proved by: Proof that the threshold comparison is correct.
   function Is_Velocity_Panic (Velocity_MB_S : Long_Float; Threshold_MB_S : Long_Float) return Boolean
     with Post => (Is_Velocity_Panic'Result = (Velocity_MB_S > Threshold_MB_S));

   -- Purpose: Determine if a process weight exceeds the priority kill threshold.
   -- Contract: Returns True iff Weight > WEIGHT_PRIORITY_THRESHOLD (3).
   -- Proved by: Proof that the comparison and range are correct.
   function Is_Weight_Priority (Weight : Natural) return Boolean
     with Post => (Is_Weight_Priority'Result = (Weight > WEIGHT_PRIORITY_THRESHOLD));

   -- Purpose: Clamp a pressure level to the valid range [1..5].
   -- Contract: Result is always in range 1..5 regardless of input.
   -- Proved by: Proof that Integer'Min/Integer'Max produce in-range results.
   function Clamp_Pressure_Level (Level : Integer) return Integer
     with Post => (Clamp_Pressure_Level'Result >= 1
                   and then Clamp_Pressure_Level'Result <= 5);

end Murasama_Types;
