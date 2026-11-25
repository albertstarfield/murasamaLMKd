-- Formalizes ensureAppServiceRunning.c cooldown: per-app, 600s window.
-- Each app may be launched at most once per 600s (Theorem T1 in the C file).
-- Empirical inputs: CHECK_INTERVAL = 7s, COOLDOWN = 600s.

def CheckInterval : Nat := 7
def Cooldown : Nat := 600

-- A launch schedule for one app: list of launch times (seconds, monotonic).
-- Valid iff consecutive launches are at least Cooldown apart.
def ValidSchedule (ts : List Nat) : Bool :=
  match ts with
  | [] => true
  | [_] => true
  | t1 :: t2 :: rest => (t2 - t1 >= Cooldown) && ValidSchedule (t2 :: rest)

-- Theorem: two launches 7s apart are INVALID (storm case, pre-fix).
theorem storm_invalid : ValidSchedule [0, 7] = false := by
  unfold ValidSchedule Cooldown
  rfl

-- Theorem: two launches 600s apart are VALID.
theorem spaced_valid : ValidSchedule [0, 600] = true := by
  unfold ValidSchedule Cooldown
  rfl

-- Counterexample: launches at 0 and 599 are invalid (strict >=).
def c_edge : List Nat := [0, 599]
theorem edge_invalid : ValidSchedule c_edge = false := by
  unfold ValidSchedule Cooldown c_edge
  rfl

-- Theorem: launches at 0 and 600 and 1200 are valid.
theorem three_valid : ValidSchedule [0, 600, 1200] = true := by
  unfold ValidSchedule Cooldown
  rfl

#eval ValidSchedule [0, 600, 1200]
