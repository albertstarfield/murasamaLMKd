-- Grace STOP/CONT policy axiom test. Mirrors Murasama_Types.Should_Grace
-- and the warden hold-file contract (skip TERM/KILL while hold is present).
-- Integer-scaled gradient (MB/s) and free MB; 2*grad*60 > free replaces the
-- floating-point 0.5 comparison in the Ada code.

def shouldGrace (grad free : Int) (ml : Int) : Bool :=
  decide (grad > 5 && (grad * 120 > free || ml >= 4))

def wardenKills (holdActive : Bool) : Bool := !holdActive

#eval shouldGrace 100 2048 1    -- true: linear prediction
#eval shouldGrace 6 2048 4      -- true: ML early warning
#eval shouldGrace 5 2048 1      -- false: boundary counterexample

theorem linear_prediction_graces : shouldGrace 100 2048 1 = true := by
  native_decide

theorem ml_early_graces : shouldGrace 6 2048 4 = true := by
  native_decide

-- COUNTEREXAMPLE: exactly at the minimum gradient and no ML warning, the
-- grace predicate is False, so this process is NOT paused by this policy.
theorem boundary_not_graced : shouldGrace 5 2048 1 = false := by
  native_decide

-- Hold file present => warden never kills the STOPped process.
theorem hold_means_no_warden_kill : wardenKills true = false := by
  native_decide

theorem no_hold_allows_warden_kill : wardenKills false = true := by
  native_decide
