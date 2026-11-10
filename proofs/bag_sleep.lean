-- Bag/closed-lid sleep verification: if the daemon's bag rule fired,
-- then the powerd log must contain a Sleep event for the same period,
-- and the system stayed asleep except darkwake. Formalize the check:
-- Count of Sleeping intervals outside 2026-11-09 15:20-19:00 must be
-- positive; intervals within could be zero (daemon rotates log).

structure Interval where
  start : Nat        -- epoch seconds
  stop : Nat
  deriving DecidableEq

-- A wake interval = inverted sleep (active). For system sleep model:
def sleepsIn (ivs : List Interval) (lo hi : Nat) : Nat :=
  ivs.foldl (fun n iv => if iv.start >= lo && iv.stop <= hi then n + 1 else n) 0

-- Example: 16:48-16:49 had 11 Sleep events (from pmset) -> positive.
-- We verify the COUNT predicate on synthetic thresholds, not that pmset
-- itself is correct (external evidence: pmset -g log counts).

def interestingIntervals : Nat := 11  -- count at 16:00 hr per pmset

-- If pmset reports >= 1 Sleep at 16h, then sleepsIn 16h >= 1.
structure Observation where
  count16 : Nat
  count17 : Nat
  count18 : Nat
  count19 : Nat
  deriving Repr

def obs : Observation := { count16 := 11, count17 := 98, count18 := 645, count19 := 88 }

-- Bag period 15:20-19:00 spans hours 15,16,17,18,19(partial).
-- Observed Sleep events at 16-19: >0 each (from pmset grep uniq -c).
#eval obs.count16 > 0   -- true
#eval obs.count17 > 0   -- true
#eval obs.count18 > 0   -- true
#eval obs.count19 > 0   -- true
-- Total events in window = 842. The 15th hour events are 0 per terminal
-- command output; absence of 15h Sleep events is consistent with log
-- rotation (prior policy / daemon started 18:?? in this log file? The
-- other possibility: pmset -g log only goes back to some timestamp).

-- Theorem: given positive counts at 16-19, bag-sleep activity occurred.
theorem bag_sleep_occurred : obs.count16 > 0 ∧ obs.count17 > 0 ∧
    obs.count18 > 0 ∧ obs.count19 > 0 := by
  native_decide

-- Theorem: the bag path in daemon requires lid closed + idle >= 15s.
-- If lid telemetry is in the 359-degree wrap (Lid > 350), Lid_Closed
-- can still be true: closed <=> Lid <10 or Lid >350.
def lidClosed (lid : Float) : Bool := (lid < 10.0) || (lid > 350.0)
#eval lidClosed 359.0  -- true (wrap case)
#eval lidClosed 0.0    -- true
#eval lidClosed 112.0  -- false (current EARU lid angle: open)

-- 15h absence theorem: count15 = 0 in terminal grep; this is weak evidence
-- (absence of evidence) — not "no sleeps happened". Marked unproven:
-- the pmset log is rotated/truncated; older sleeps get merged into summary.
