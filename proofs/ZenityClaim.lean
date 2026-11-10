-- Claim under test: "Zenity is impossible" / "uses zenity => invalid/illegal"
-- Local source: murasamalmk_daemon.adb:316 "silent no-op if missing";
-- :319-340 Queue_Zenity_Warning (notify only); :597ff Handle_Bloodshed kill path
-- calls Kill_C directly; zenity is enqueued after, not a precondition.
def killDecision (_zenityPresent : Bool) (pressure : Nat) : Bool :=
  pressure >= 4
theorem kill_independent_of_zenity (p : Nat) :
    killDecision true p = killDecision false p := by rfl
theorem unrecoverable_iff_pressure_ge_4 : killDecision false 4 = true := by decide
theorem thrash_example : killDecision true 5 = true := by decide
theorem no_trigger_below_4 : killDecision true 3 = false := by decide
theorem absence_never_blocks : killDecision false 4 = true := by decide
