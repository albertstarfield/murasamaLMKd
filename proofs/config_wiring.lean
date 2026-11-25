-- Axiom test for the Ada/SPARK wiring predicates added 2026-11-25.
-- Mirrors Murasama_Types.Config_Complete / Config_Matches_Desired /
-- Daemon_Owns_Sustained_Kills / EARU_Usable exactly.

structure MemConfig where
  sys_idle   : Int
  app_idle   : Int
  wired_pct  : Int
  kill_count : Int
  window_s   : Int
  delay_ms   : Int
  deriving Repr, DecidableEq

def desired : MemConfig :=
  { sys_idle := 10, app_idle := 10, wired_pct := 25,
    kill_count := 0, window_s := 600, delay_ms := 500 }

abbrev complete (c : MemConfig) : Prop :=
  c.sys_idle >= 0 ∧ c.app_idle >= 0 ∧ c.wired_pct >= 0 ∧
  c.kill_count >= 0 ∧ c.window_s >= 0 ∧ c.delay_ms >= 0

-- "matches" is a reserved Lean keyword: use matchesDesired.
abbrev matchesDesired (c : MemConfig) : Prop := complete c ∧ c = desired

abbrev daemonOwns (c : MemConfig) : Prop := c.kill_count = 0

abbrev validEARU (t h p : Int) : Prop :=
  -100 <= t ∧ t <= 100 ∧ 0 <= h ∧ h <= 100 ∧ 500 <= p ∧ p <= 1100

abbrev earuUsable (ok : Bool) (t h p : Int) : Prop := ok = true ∧ validEARU t h p

theorem complete_desired : complete desired := by native_decide
theorem owns_desired : daemonOwns desired := by native_decide

theorem matches_implies_complete_and_owns (c : MemConfig) (hm : matchesDesired c) :
    complete c ∧ daemonOwns c := by
  rcases hm with ⟨hc, heq⟩
  rw [heq]
  exact ⟨complete_desired, owns_desired⟩

-- COUNTEREXAMPLE: the kernel sysctl count is the ONLY gate on kill ownership.
-- Five of six values matching is not enough; count=1 closes the daemon gate.
theorem five_of_six_is_not_match :
    ¬ matchesDesired { desired with kill_count := 1 } := by
  native_decide

theorem count_one_closes_daemon_gate :
    ¬ daemonOwns { desired with kill_count := 1 } := by
  native_decide

-- EARU plausibility: real reading accepted, zero pressure rejected.
theorem real_reading_is_usable : earuUsable true 22 89 1013 := by
  native_decide

theorem zero_pressure_rejected : ¬ earuUsable true 22 89 0 := by
  native_decide
