-- Dynamic grace: each freeze window is capped at 60s; the process is
-- continued only when memory is stable or the total hold cap is reached.
def stable (pressure free_mb : Int) : Bool :=
  pressure <= 2 && free_mb >= 512

def window (cap : Int) : Int := min cap 60

theorem window_whitelist_capped : window 21600 = 60 := by native_decide
theorem window_normal_capped : window 60 = 60 := by native_decide
theorem stable_at_pressure_two : stable 2 600 = true := by native_decide
theorem unstable_at_pressure_three : stable 3 600 = false := by native_decide
theorem release_when_stable : (stable 2 600 || 600 >= 21600) = true := by native_decide
