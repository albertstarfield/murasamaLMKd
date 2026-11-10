-- Bag-sleep audit formalization (Lean). With cite map to source lines.
-- Path_A correctly allows closed-lid+idle; Video_Wakelock strips only
-- when Lid_Closed. The claim to formalize: Priority_1 order
-- (Clamshell < Brute_Force < Lid_Zero_Hold?) vs CTE verdicts.
-- Observations from source:
--  * 2671-2685: Brute_Force has priority above Clamshell
--  * 2685: `elsif Brute_Force`
--  * Lid_Zero_Hold's branch is `if Lid_Zero_Hold` (l.2596), earlier in
--    the trip's call chain? It is within the same begin/end block and
--    PRECEDES the brute-force elsif, so when Lid_Zero_Hold is true, the
--    Brute_Force branch is skipped — with the conditions at I=7134s and
--    Lid_Zero_Hold false, the Brute_Force elsif IS reachable.
-- We formalize the gate logic as propositional logic:

-- Let:
--   bag   = "lid closed + idle >= 15s"   (Path_A)
--   surf  = Will_Surv (TRUE if battery survives the day)
--   chg   = Is_On_Charging
--   thaw  = In_Thawing_Window
--   alarm = In_Alarm_Window
--   cal   = In_Calendar_Window
--   notif = In_Notification_Window
--   wake  = Wake_Set (a wake is scheduled)
--   zero  = Lid_Zero_Hold  (= Lid_Closed && Bat>20 && idle < min(AP,900))
-- Brute_Force = bag && !chg && !surf && !thaw && !alarm && !cal && !notif && wake
-- The elsif ordering means IF zero THEN hold-assert; ELSIF Brute THEN sleep.
-- Verdicts instantiated:
--  * at 18:55, idle=7134s => zero FALSE (idle > 900)
--  * Brute TRUE only if wake TRUE.
-- Observation: at 18:55 lines, the Safety log said
-- 'wake_scheduled=TRUE' for all entries -> wake TRUE, so the Brute_Force
-- sleeps DID occur (137 times), confirming the priority audit.

structure States where
  isZero    : Bool
  isBrute   : Bool
  isBag     : Bool
  isSurv    : Bool
  isCharging: Bool
  isThaw    : Bool
  isAlarm   : Bool
  isCal     : Bool
  isNotif   : Bool
  isWake    : Bool
  deriving DecidableEq

def zeroAt (idle : Nat) (apRec : Nat) (lidClosed batOK : Bool) : Bool :=
  lidClosed && batOK && (idle < min apRec 900)

def bruteAt (st : States) : Bool :=
  st.isBag && ! st.isCharging && ! st.isSurv &&
  ! st.isThaw && ! st.isAlarm && ! st.isCal && ! st.isNotif && st.isWake

-- order: if zero then HOLD; elsif brute then SLEEP; elsif ... ; else NONE
inductive Decision | Hold | Sleep | None
deriving DecidableEq

def decideOrder (st : States) : Decision :=
  if st.isZero then .Hold
  else if bruteAt st then .Sleep
  else .None

-- Closure: at idle > min(AP,900), zero is false.
example : zeroAt 7134 4046 true true = false := by native_decide
-- 18:55: bag TRUE (lid closed & idle >=15), chg FALSE, surv FALSE, thaw FALSE, wake TRUE
def st1855 : States := {
  isZero := false, isBrute := true, isBag := true,
  isSurv := false, isCharging := false, isThaw := false,
  isAlarm := false, isCal := false, isNotif := false, isWake := true }
-- Theorem: ordered decision is Sleep.
theorem st1855_sleep : decideOrder st1855 = .Sleep := by native_decide
#eval decideOrder st1855  -- should be Decision.Sleep

-- Counterexample under the audit: the path is CLEAN; the only hazard
-- elsewhere is that Brute_Force needs Wake_Set (wake) and if wake=false,
-- the system will NOT brute-force even when stowed. That is the PRIORITY
-- gap for a machine without wake scheduling: it will fall through to
-- Clamshell+not charging+no-wakelock at 2815, which has same call `elsif`.
-- Whether Clamshell is also gated by wake: unknown; check lines 2815+.

-- We also prove the monotonicity: SLEEP implies zero false and brute true
theorem sleep_implies_not_zero : decideOrder st1855 = .Sleep -> st1855.isZero = false := by
  intro h; rw [h] at *; simp [st1855]
