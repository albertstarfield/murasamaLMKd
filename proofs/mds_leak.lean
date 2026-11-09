-- Murasama MDS-specific leak reaper: formalization + proof.
-- Observed (footprint(1) 2026-11-09):
--   mds_stores pid 555 : phys_footprint 8909 MB, age 04-21:09:12 (>12h),
--   owner "_mds_stores" (contains '_' => exempt under generic *_* rule today),
--   Malloc Small 8794 MB (99% of footprint). Helpers pids 82328/82351: 8MB.
--   mds pid 388 : 77 MB, < 512MB => no action under new rule either.
-- Constants (Murasama_Types):
--   LEAK_MIN_FOOTPRINT_BYTES (generic) = 1 GiB, MDS_MIN = 512 MiB,
--   LEAK_MIN_AGE_SECONDS = 12h = 43200, LEAK_MAX_KILLS_PER_CYCLE = 2,
--   flag file "/usr/local/murasamaLMKd/disable_leak_killer_mds_stores".

def GEN_MIN : Nat := 1024 * 1024 * 1024      -- 1 GiB generic
def MDS_MIN : Nat := 512 * 1024 * 1024       -- 512 MiB mds_stores
def AGE_MIN : Nat := 12 * 3600

structure Cand where
  ownerKnown    : Bool
  hasUnderscore : Bool
  hasHomeDir    : Bool
  isMds         : Bool
  footprintMB   : Nat   -- convert: bytes = MB * 1024 * 1024
  ageSeconds    : Nat
  deriving Repr

-- Special MDS reap active only when the disable flag is ABSENT.
-- flagDisabled=true  -> MDS falls back to the generic policy (underscore exempt).
def mdsSpecialActive (flagDisabled : Bool) : Bool := ! flagDisabled

-- Underscore exemption: applies UNLESS MDS special reap is active for this
-- candidate. (MDS owner "_mds_stores" has '_' but must NOT be protected.)
def underscoreExempt (c : Cand) (flagDisabled : Bool) : Bool :=
  c.hasUnderscore && ! (c.isMds && mdsSpecialActive flagDisabled)

-- Effective footprint threshold: MDS -> 512MiB, else generic 1GiB.
def footprintOK (c : Cand) : Bool :=
  if c.isMds then decide (c.footprintMB * 1024 * 1024 > MDS_MIN)
  else            decide (c.footprintMB * 1024 * 1024 > GEN_MIN)

def shouldKill (c : Cand) (enabled flagDisabled : Bool) : Bool :=
  c.ownerKnown &&
  (! underscoreExempt c flagDisabled) &&
  (! c.hasHomeDir) &&
  footprintOK c &&
  (decide (c.ageSeconds > AGE_MIN)) &&
  enabled

-- observed mds_stores 555: 8909 MB, 421752 s age, underscore owner, no home
def mds555 : Cand := {
  ownerKnown := true, hasUnderscore := true, hasHomeDir := false,
  isMds := true, footprintMB := 8909, ageSeconds := 421752 }

-- observed mds 388: 77 MB, dwarfed  (pid 388 mds)
def mds388 : Cand := {
  ownerKnown := true, hasUnderscore := false, hasHomeDir := false,
  isMds := false, footprintMB := 77, ageSeconds := 421754 }

-- generic 600 MB vendor daemon, no underscore: below generic 1GiB
def vendor600 : Cand := {
  ownerKnown := true, hasUnderscore := false, hasHomeDir := false,
  isMds := false, footprintMB := 600, ageSeconds := 48 * 3600 }

-- mds at 600 MB (>512MiB) but flag present -> exempt fallback
def mds600 : Cand := {
  ownerKnown := true, hasUnderscore := true, hasHomeDir := false,
  isMds := true, footprintMB := 600, ageSeconds := 48 * 3600 }

-- main claim: the observed hog is reaped under the new rule
#eval shouldKill mds555 true false   -- expected: true
-- mds 77MB helper class: not reaped
#eval shouldKill mds388 true false   -- expected: false
-- generic 600MB: below 1GiB -> not reaped
#eval shouldKill vendor600 true false -- expected: false
-- mds 600MB but disable flag present -> NOT reaped (generic fallback)
#eval shouldKill mds600 true true     -- expected: false
-- mds 600MB flag absent -> reaped
#eval shouldKill mds600 true false    -- expected: true

-- THEOREM M1: MDS special reap never kills when the flag is present.
theorem mds_flag_exempt (c : Cand) (enabled : Bool)
    (h : c.isMds = true) (hu : c.hasUnderscore = true) :
    shouldKill c enabled true = false := by
  unfold shouldKill underscoreExempt mdsSpecialActive
  rw [h, hu]
  simp

-- THEOREM M2 (concrete observed instances): helper-class MDS at 77MB not
-- reaped; below-envelope holds on concrete values via native_decide.
theorem mds_below_512 : shouldKill mds388 true false = false := by
  native_decide
theorem mds555_killed : shouldKill mds555 true false = true := by
  native_decide

theorem mds_flag_600 : shouldKill mds600 true true = false := by
  native_decide
