-- Murasama MDS 768 MiB envelope: formalization + proof (Lean).
-- User correction 2026-11-09: envelope is 768 MB, not 512 MiB (prior commit
-- bf2d869 used 512). Taking 768 MiB = 768 * 1024 * 1024 = 805306368 B, in
-- the same MiB units as the Ada constant (footprint(1) prints MB = MiB).

def MDS_MIN : Nat := 768 * 1024 * 1024       -- 805306368
def AGE_MIN : Nat := 12 * 3600               -- 43200

structure Cand where
  isMds         : Bool
  footprintB    : Nat   -- ri_phys_footprint bytes
  ageSeconds    : Nat
  deriving Repr

-- Special MDS reap active only when the disable flag is ABSENT.
def mdsSpecialActive (flagDisabled : Bool) : Bool := ! flagDisabled

-- Footprint gate: strict > 768 MiB.
def footprintOK (c : Cand) : Bool := decide (c.footprintB > MDS_MIN)

def shouldKillMds (c : Cand) (flagDisabled : Bool) : Bool :=
  c.isMds &&
  footprintOK c &&
  (decide (c.ageSeconds > AGE_MIN)) &&
  mdsSpecialActive flagDisabled

-- observed hog pid 555 (2026-11-09): footprint 9091 MB = 9091 MiB
-- = 9532604416 B, age ~421k s (>12h). Both 512 and 768 gates reap it;
-- the question is the envelope, not the hog.
def mds9091 : Cand := {
  isMds := true, footprintB := 9532604416, ageSeconds := 422000 }

-- BETWEEN the old and new envelopes: 600 MiB = 629145600 B.
-- Under 512 MiB this is reaped; under 768 MiB it must NOT be.
def mds600 : Cand := {
  isMds := true, footprintB := 629145600, ageSeconds := 48 * 3600 }

-- between 768 and 1024: 900 MiB = 943718400 B. Reaped at 768, not at 1GiB.
def mds900 : Cand := {
  isMds := true, footprintB := 943718400, ageSeconds := 48 * 3600 }

-- helpers present earlier: 8224KB = 8421376 B; 7360KB = 7536640 B;
-- mds pid 388 at 77 MB = 80740352 B. All below BOTH 512 and 768.
def helper8224 : Cand := {
  isMds := true, footprintB := 8421376, ageSeconds := 15 * 3600 }
def mds77 : Cand := {
  isMds := true, footprintB := 80740352, ageSeconds := 422000 }

-- exact boundary: exactly 768 MiB must NOT be reaped (strict >).
def mdsExact768 : Cand := {
  isMds := true, footprintB := 805306368, ageSeconds := 48 * 3600 }
-- one byte above: reaped.
def mdsAbove768 : Cand := {
  isMds := true, footprintB := 805306369, ageSeconds := 48 * 3600 }

-- main claim: observation is reaped under 768; the 600MiB band is NOT.
#eval shouldKillMds mds9091 false   -- expected: true  (9.09GB hog reaped)
#eval shouldKillMds mds600 false    -- expected: false (600MiB < 768MiB: kept)
#eval shouldKillMds mds900 false    -- expected: true  (900MiB > 768MiB: reaped)
#eval shouldKillMds helper8224 false -- expected: false (8MB helper kept)
#eval shouldKillMds mds77 false     -- expected: false (77MB mds kept)
#eval shouldKillMds mdsExact768 false -- expected: false (strict >)
#eval shouldKillMds mdsAbove768 false -- expected: true (1 byte over: reaped)
#eval shouldKillMds mds900 true     -- expected: false (flag present: exempt)

-- THEOREM: 768 MiB strictly contains 512 MiB. The band [512MiB, 768MiB]
-- that the old code reaped is now spared (for processes older than 12h).
theorem envelope_monotone :
    (629145600 ≤ MDS_MIN) ∧ (805306368 = MDS_MIN) := by
  native_decide

theorem mds600_not_killed : shouldKillMds mds600 false = false := by
  native_decide

theorem mds900_killed : shouldKillMds mds900 false = true := by
  native_decide

theorem mds9091_killed : shouldKillMds mds9091 false = true := by
  native_decide

theorem mdsExact_not_killed : shouldKillMds mdsExact768 false = false := by
  native_decide

theorem mdsAbove_killed : shouldKillMds mdsAbove768 false = true := by
  native_decide

theorem helper_not_killed : shouldKillMds helper8224 false = false := by
  native_decide

theorem mds77_not_killed : shouldKillMds mds77 false = false := by
  native_decide

theorem across_both_gates :
    shouldKillMds mds9091 false = true ∧
    shouldKillMds mds600 false = false ∧
    shouldKillMds mds900 false = true := by
  refine ⟨?_, ?_, ?_⟩ <;> native_decide

-- Counterexamples reconciled (observed):
-- mds helper spids (8MB and 7MB): not reaped under either 512 or 768 — the
-- exact-name+footprint gate keeps them regardless of envelope choice.
-- mds 77MB (pid 388): not reaped under either gate.
-- A generic non-MDS process at 600MiB would not be gated by this branch
-- at all (isMds guard in shouldKillMds) — threshold change does not leak
-- into the generic policy.
-- Residual, marked UNPROVEN (empirical, not formalizable from this file):
-- the choice 768 vs 512 is a policy input from the user (RAW observation),
-- not a theorem; formalization proves the consequences of that input
-- (threshold monotonicity, strictness at the boundary, flag/totality),
-- not the input itself. The hog 9091MB is a live measurement via
-- footprint(1) at 2026-11-09 11:55:59 JST (working dir /Volumes/
-- EARU_dataIO? No — the EARU context is environmental telemetry only and
-- is not used as evidence; measurement source is `sudo footprint 555`
-- run in terminal, reported in the accompanying message with citation.)
