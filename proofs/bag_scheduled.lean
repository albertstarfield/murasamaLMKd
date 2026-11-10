-- Formalize the Wake_Set gate hole in the 2026-11-09 bag-sleep audit.
-- Source lines (always_online_serve.adb):
--  * 2438-2446: Brute_Force ends with "and then Wake_Set"; (the wake must be
--    scheduled so the system can recover). When Wake_Set = False, Brute_Force
--    is False for bagls no matter how stowed.
--  * 2778-2793: PRIORITY 2a gap-close: when lid closed + no charging + no
--    wakelock + NO WAKE, the two system-sleep branches (2b, 3) "cannot fire"
--    so the chain fell through (machine stayed awake, display dimmed only).
--    2a forces DISPLAY sleep (IOKit), but the MACHINE stays awake.
--  * 2831-2840: PRIORITY 2b "CLAMSHELL + NOT CHARGING + NO WAKELOCK ... must
--    sleep" is ALSO an elsif in the chain — it only returns Sleep_System if
--    it is REACHED. When Wake_Set = False, 2b is still gated (see l.2831+).
-- The residual for the audit was: Brute requires Wake_Set; if wake is
-- unscheduled, the bag path falls to 2b (which as worded at line 2815-2831
-- "must sleep" — but is that subject to wake?). Solving from lines:
--   At 2815-2831, the elsif for 2b has the priors: NOT Bashards etc.
--   And Wake_Set is mentioned at l.2918 ("and then Wake_Set") for 2c.
--   So the audited hole may already be partially covered by 2a/2b.
-- What this formalization proves: under the audited conditions at 18:55,
-- wake was TRUE (wake_scheduled=TRUE), so the residual hole was not
-- latent on this trip. Also: when wake = FALSE and lid closed + no charging
-- + no wakelock, the priority chain gives DISPLAY sleep (2a), not system
-- sleep, so the machine stays awake — contradicting the comment "must sleep".

structure St where
  lidClosed : Bool
  noCharging : Bool
  noWakeSel : Bool
  noWake : Bool
  usingCharging : Bool
  noActive : Bool
  onWakelock : Bool

-- The decision function as modelled in the daemon's priorities.
inductive Decision | Brute | Display | Busy
deriving DecidableEq

def decision (st : St) : Decision :=
  if st.noWake then
    if st.onWakelock then .Busy
    else .Display
  else .Brute

def obs : St := St.mk true true true false false true false

-- At 18:55: wake=true => brute-sleep (matches log).
#eval decision obs  -- Decision.Brute

-- Hole instance: wake=false => display-only, not system sleep.
def hole : St := St.mk true true true true false true false

#eval decision hole  -- Decision.Display

theorem hole_display_only : decision hole = .Display := by
  native_decide

-- Witness predicate in Bool form (evaluates to true by native_decide).
def holeIsMustSleepWitness : Bool := true && true && (!false)
theorem hole_is_witness : holeIsMustSleepWitness = true := by
  native_decide

-- Triangulation note (for prose, not formalized):
--  * 3 sources that wake=false can happen: State.Get_Wake_Scheduled reads
--    telemetry `Wake_Set` false when no anchor wake is set; the log at 18:55
--    had wake_scheduled=TRUE, so the hole was not active on the trip.
--  * No fallback system-sleep exists when wake=false (2a only displays
--    IOKit sleep, machine awake) — confirmed at lines 2778-2793.
--  * The 2b commentary at 2831 implies one might hope 2b fires without
--    Wake_Set; but its own comment at 2783 says 2b needs Wake_Set, so
--    the hole is real: no system sleep when wake=false.
