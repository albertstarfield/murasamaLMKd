-- Stability of the hold-until-stable grace policy.
-- Source of truth (2026-11-25 working tree):
--   murasama_grace.adb:239-282  window = min(hold, 60); while the system is
--     unstable the process stays STOPped and the warden hold is re-armed;
--   murasama_grace.adb:284-324  after the probe, stable memory allows CONT;
--     a still-climbing gradient triggers another STOP;
--   murasama_types.ads:304-312  GRACE_HOLD_SECONDS = 60.
-- Failure modes refuted below: a window longer than 60 s, a release while the
-- system is unstable before the cap, and a release of an active long hold.

def freezeWindow (hold : Nat) : Nat := min hold 60

def stillFrozen (systemStable : Bool) (totalHeld : Nat) (cap : Nat) : Bool :=
  if systemStable then false else if totalHeld < cap then true else false

def releaseAllowed (gradAbove : Bool) (quietProbes : Nat) (longHold : Bool) : Bool :=
  (!gradAbove) && decide (quietProbes >= 3) && (!longHold)

theorem window_le_60 (hold : Nat) : freezeWindow hold <= 60 := by
  unfold freezeWindow
  exact Nat.min_le_right hold 60

theorem full_hold_is_capped : freezeWindow 21600 = 60 := by
  decide

theorem thrash_keeps_frozen (total cap : Nat) (h : total < cap) :
    stillFrozen false total cap = true := by
  simp [stillFrozen, h]

theorem stable_releases (total cap : Nat) :
    stillFrozen true total cap = false := by
  simp [stillFrozen]

theorem cap_forces_probe (cap : Nat) :
    stillFrozen false cap cap = false := by
  simp [stillFrozen]

-- The stability contract: release implies quiet gradient and sufficient
-- consecutive quiet probes and no active user-requested freeze.
theorem release_requires_quiet (g : Bool) (s : Nat) (l : Bool)
    (h : releaseAllowed g s l = true) : g = false := by
  simp [releaseAllowed] at h
  exact h.1.1

theorem release_requires_three_probes (g : Bool) (s : Nat) (l : Bool)
    (h : releaseAllowed g s l = true) : s >= 3 := by
  simp [releaseAllowed] at h
  exact h.1.2

theorem release_forbids_long_hold (g : Bool) (s : Nat)
    (h : releaseAllowed g s true = true) : False := by
  simp [releaseAllowed] at h
