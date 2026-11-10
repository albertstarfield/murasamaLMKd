-- Formalizes the fix for the bag-sleep Wake_Set gate hole.
-- OLD gate (always_online_serve.adb:2438-2446):
--   Brute <- Path_A ∧ ¬Charging ∧ ¬WillSurv ∧ ¬Thaw ∧ ¬Alarm ∧ ¬Cal ∧ ¬Notif ∧ Wake_Set
-- Residual hole: when Wake_Set = false, Brute = false even when stowed, so the
-- machine sat awake in the bag; the priority-2a fallback then only forces
-- IOKit display sleep while the machine stays awake (2778-2793).
-- FIX: drop the Wake_Set conjunct from Brute_Force. Wake_Set remains a
-- separate scheduled-recovery consideration, not a sleep condition.

structure BagState where
  bag            : Bool  -- Path_A: lid closed + HID idle >= 15s
  notCharging    : Bool
  notWillSurv    : Bool
  notThaw        : Bool
  notAlarm       : Bool
  notCal         : Bool
  notNotif       : Bool
  wakeScheduled  : Bool  -- Wake_Set
  deriving DecidableEq

-- Old (hole) gate:
def BruteOld (s : BagState) : Bool :=
  s.bag && s.notCharging && s.notWillSurv && s.notThaw && s.notAlarm && s.notCal && s.notNotif && s.wakeScheduled

-- New (fixed) gate: Wake_Set conjunct removed:
def BruteNew (s : BagState) : Bool :=
  s.bag && s.notCharging && s.notWillSurv && s.notThaw && s.notAlarm && s.notCal && s.notNotif

-- CLAIM (core inference): whenever the bag conditions hold, the fixed gate
-- fires regardless of wake scheduling. Formally: 7-way conjunction -> BruteNew.
def BagConditions (s : BagState) : Bool :=
  s.bag && s.notCharging && s.notWillSurv && s.notThaw && s.notAlarm && s.notCal && s.notNotif

theorem fixed_fires_independent_of_wake (s : BagState) :
    BagConditions s = true -> BruteNew s = true := by
  intro h
  unfold BruteNew BagConditions at *
  exact h

theorem fixed_ignores_wake (s : BagState) (w1 w2 : Bool) :
    BruteNew { s with wakeScheduled := w1 } = BruteNew { s with wakeScheduled := w2 } := by
  simp [BruteNew]

def holeState : BagState := {
  bag := true, notCharging := true, notWillSurv := true, notThaw := true,
  notAlarm := true, notCal := true, notNotif := true, wakeScheduled := false }

theorem hole_exists : BruteOld holeState = false ∧ BruteNew holeState = true := by
  decide

-- The fixed gate never depends on wakeScheduled. This is proved directly
-- from its definition: wakeScheduled is not a free variable of BruteNew.
theorem BruteNew_depends_only_on_bag_conditions (s : BagState) :
    BruteNew s = (s.bag && s.notCharging && s.notWillSurv && s.notThaw && s.notAlarm && s.notCal && s.notNotif) := rfl

-- A wake-independent characterization: BruteNew equals the wake-free
-- expression; dropping the wakeScheduled parameter by hand.
theorem BruteNew_wake_free (s : BagState) (w : Bool) :
    BruteNew { s with wakeScheduled := w } = BruteNew s := by
  rfl

#eval BruteOld holeState  -- false (hole)
#eval BruteNew holeState  -- true  (fixed)
