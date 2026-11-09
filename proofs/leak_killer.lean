-- Murasama leak-killer decision logic, formalized and proved.
-- Constants (from murasama_types.ads): LEAK_MIN_FOOTPRINT_BYTES = 1024^3,
-- LEAK_MIN_AGE_SECONDS = 12*3600 = 43200, LEAK_MAX_KILLS_PER_CYCLE = 2,
-- LEAK_KILL_ENABLED = True.

def LEAK_MIN_FOOTPRINT_BYTES : Nat := 1024 * 1024 * 1024
def LEAK_MIN_AGE_SECONDS     : Nat := 12 * 3600
def LEAK_MAX_KILLS_PER_CYCLE : Nat := 2

structure Candidate where
  ownerKnown      : Bool
  hasUnderscore   : Bool
  hasHomeDir      : Bool
  footprintBytes  : Nat
  ageSeconds      : Nat
  deriving Repr

-- Decision: should this candidate be killed this cycle?
-- Mirrors the Ada elsif chain in Check_And_Kill (APPLICATION STEPS 2-5).
def shouldKill (c : Candidate) (enabled : Bool) : Bool :=
  c.ownerKnown &&
  (! c.hasUnderscore) &&
  (! c.hasHomeDir) &&
  (decide (c.footprintBytes > LEAK_MIN_FOOTPRINT_BYTES)) &&
  (decide (c.ageSeconds > LEAK_MIN_AGE_SECONDS)) &&
  enabled

-- THEOREM 1: unknown owner => never killed
theorem no_kill_unknown_owner (c : Candidate) (enabled : Bool)
    (h : c.ownerKnown = false) : shouldKill c enabled = false := by
  simp [shouldKill, h]

-- THEOREM 3a: underscore username => never killed
theorem no_kill_underscore (c : Candidate) (enabled : Bool)
    (h : c.hasUnderscore = true) : shouldKill c enabled = false := by
  simp [shouldKill, h]

-- THEOREM 3b: home dir exists => never killed
theorem no_kill_home (c : Candidate) (enabled : Bool)
    (h : c.hasHomeDir = true) : shouldKill c enabled = false := by
  simp [shouldKill, h]

-- footprint below threshold => never killed
theorem no_kill_small_footprint (c : Candidate) (enabled : Bool)
    (h : c.footprintBytes <= LEAK_MIN_FOOTPRINT_BYTES) :
    shouldKill c enabled = false := by
  unfold shouldKill
  have hf : decide (c.footprintBytes > LEAK_MIN_FOOTPRINT_BYTES) = false := by
    apply decide_eq_false
    intro hgt
    omega
  simp [hf]

-- age below threshold => never killed
theorem no_kill_young (c : Candidate) (enabled : Bool)
    (h : c.ageSeconds <= LEAK_MIN_AGE_SECONDS) :
    shouldKill c enabled = false := by
  unfold shouldKill
  have ha : decide (c.ageSeconds > LEAK_MIN_AGE_SECONDS) = false := by
    apply decide_eq_false
    intro hgt
    omega
  simp [ha]

-- THEOREM 5: dry-run purity
theorem dryrun_no_kill (c : Candidate) :
    shouldKill c false = false := by
  simp [shouldKill]

-- Cap: at most LEAK_MAX_KILLS_PER_CYCLE kills. Modeled as: if killedCount
-- already equals cap, no further candidate is killed this cycle.
def cycleKill (c : Candidate) (enabled : Bool) (killedSoFar : Nat) : Bool :=
  if killedSoFar >= LEAK_MAX_KILLS_PER_CYCLE then false
  else shouldKill c enabled

theorem cap_respected (c : Candidate) (enabled : Bool) :
    cycleKill c enabled LEAK_MAX_KILLS_PER_CYCLE = false := by
  simp [cycleKill, LEAK_MAX_KILLS_PER_CYCLE]

-- Counterexample check: a vendor daemon with NO underscore, NO home, huge
-- footprint, old age, enabled -> killed (sanity).
def exampleVendor : Candidate := {
  ownerKnown := true, hasUnderscore := false, hasHomeDir := false,
  footprintBytes := 2 * 1024 * 1024 * 1024, ageSeconds := 24 * 3600 }
#eval shouldKill exampleVendor true  -- expected true

-- Counterexample: user process with home dir but huge footprint -> NOT killed
def exampleUser : Candidate := {
  ownerKnown := true, hasUnderscore := false, hasHomeDir := true,
  footprintBytes := 2 * 1024 * 1024 * 1024, ageSeconds := 24 * 3600 }
#eval shouldKill exampleUser true  -- expected false
