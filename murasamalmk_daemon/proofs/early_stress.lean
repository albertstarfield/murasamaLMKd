-- Models Is_Early_Stress after the critical-free gap fix:
-- pressure>=3 OR free<128 OR (free*4<=total AND (pressure>=2 OR ml>=4)).
def earlyStress (free total p ml : Int) : Bool :=
  p >= 3 || free < 128 || (free * 4 <= total && (p >= 2 || ml >= 4))

theorem pressureThreeSuffices (f t m : Int) (p : Int) (h : p >= 3) :
    earlyStress f t p m = true := by
  simp [earlyStress, h]

theorem criticalFreeAtPressureOne : earlyStress 100 16384 1 1 = true := by
  native_decide

theorem lowFreeAtPressureTwo : earlyStress 3000 16384 2 1 = true := by
  native_decide

-- Boundary: exactly 128 MB is NOT below CRITICAL_FREE_MB (strict).
theorem boundaryCriticalFree : earlyStress 128 16384 1 1 = false := by
  native_decide

theorem counterexampleHealthy : earlyStress 12000 16384 1 1 = false := by
  native_decide
