-- Formalizes the EARU memory_stat entry invariant.
-- The new entry (EARU_data.dat "system.memory_stat") exposes
--   rss_bytes   : resident set size of the EARU daemon (bytes)
--   vsize_bytes : virtual size of the EARU daemon (bytes)
-- Claim (core inference): rss_bytes <= vsize_bytes (resident subset of
-- virtual) AND both >= 0. The leak-killer consumes rss_bytes as the
-- footprint proxy; if rss > vsize the data is corrupt and must be ignored.

structure MemStat where
  rss   : Int
  vsize : Int
  deriving DecidableEq

def Valid (m : MemStat) : Prop :=
  0 <= m.rss ∧ 0 <= m.vsize ∧ m.rss <= m.vsize

-- Observed 2026-11-10 11:47 run: rss=44843008, vsize=500627079168.
def obs : MemStat := { rss := 44843008, vsize := 500627079168 }

theorem obs_valid : Valid obs := by
  unfold Valid obs
  decide

-- Counterexample (the step that could fail): rss > vsize is invalid.
def bad : MemStat := { rss := 100, vsize := 50 }
theorem bad_invalid : ¬ Valid bad := by
  unfold Valid bad
  decide

-- The leak-killer's footprint proxy (rss) is non-negative whenever valid.
theorem rss_nonneg (m : MemStat) (h : Valid m) : 0 <= m.rss := h.1

#eval obs.rss  -- 44843008
