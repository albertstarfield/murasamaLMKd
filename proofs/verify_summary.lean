-- Summary of verification claims from this turn, formalized.
-- Claim (core inference): the three cited measurements are mutually
-- consistent: murasama binary has MDS-768 code (count>=1), 247 binary has
-- the Brute-FORCE sleep code (count>=1), and EARU live file carries a
-- non-negative rss_bytes entry. Each conjunct must hold independently;
-- the step that could fail is "the live file was read after restart"
-- (empirical; replaced by direct read_file this turn, not formalizable).

structure V where
  murasamaMdsCount : Nat
  serve247BruteCount : Nat
  earuRssBytes : Int
  deriving DecidableEq

def Verified (v : V) : Prop :=
  v.murasamaMdsCount >= 1 ∧ v.serve247BruteCount >= 1 ∧ v.earuRssBytes >= 0

def obs : V := { murasamaMdsCount := 2, serve247BruteCount := 1, earuRssBytes := 16711680 }

theorem obs_verified : Verified obs := by
  unfold Verified obs
  decide

-- Counterexample: if any count were 0 the claim would fail.
def bad : V := { murasamaMdsCount := 0, serve247BruteCount := 1, earuRssBytes := 16711680 }
theorem bad_not_verified : ¬ Verified bad := by
  unfold Verified bad
  decide

#eval obs.murasamaMdsCount  -- 2
#eval obs.serve247BruteCount -- 1
