-- Formalizes the log/health check: 4 daemons alive, autotask mem gate < 69.
-- Empirical inputs from this turn:
--   alive count = 4 (EARU pid 39414, murasama 624+1192, autotask 45899, 247 14648)
--   autotask last mem_usage = 52.4927711637720 -> scaled 52492 (< 69000)

structure Health where
  aliveCount : Nat
  memUsageScaled : Int
  deriving DecidableEq

def Healthy (h : Health) : Bool :=
  h.aliveCount >= 4 && h.memUsageScaled < 69000

def obs : Health := { aliveCount := 4, memUsageScaled := 52492 }

theorem obs_healthy : Healthy obs = true := by
  unfold Healthy obs
  rfl

-- Counterexample: if only 3 daemons alive, not healthy.
def bad : Health := { aliveCount := 3, memUsageScaled := 52492 }
theorem bad_not_healthy : Healthy bad = false := by
  unfold Healthy bad
  rfl

-- Counterexample: if mem_usage >= 69, not healthy.
def bad2 : Health := { aliveCount := 4, memUsageScaled := 70000 }
theorem bad2_not_healthy : Healthy bad2 = false := by
  unfold Healthy bad2
  rfl

#eval Healthy obs
