-- Formalizes the restart-gate inference from the 247 restart_service.sh run.
-- Claim (core inference): "sudo bash restart_service.sh restarted the
-- service" is proved iff (a) launchctl logged "restarted" (system claim)
-- AND (b) the rebuilt binary is staged as 247AlwaysOnlineServe_bin AND
-- (c) launchctl reports the daemon process (new PID).
-- The inference that could fail: RestartedClaim requires BOTH launchctl
-- exit status success AND pgrep returning the daemon PID; without either
-- condition the claim must be marked false (unproven step).
-- Empirics live in the log/ps outputs, NOT in this file: launchctl
-- "restarted" line + pgrep 81004 + strings binary — see test in prose.

structure RestartObs where
  launchctlRestarted : Bool
  binaryStaged       : Bool  -- strings/247AlwaysOnlineServe_bin fresh
  daemonRunning      : Bool  -- pgrep 81004 ../247AlwaysOnlineServe_bin
  deriving DecidableEq

def restartedClaim (o : RestartObs) : Bool :=
  o.launchctlRestarted && o.binaryStaged && o.daemonRunning

-- Observed 2026-11-09 19:52 run:
--  launchctl: "Service com.TwilightMigratory.247alwaysonlineserve.plist restarted. EXIT:0"
--  binary: staged to ../247AlwaysOnlineServe_bin (1675936 bytes); strings shows no-op guarantees
--  pgrep: 81004 ../247AlwaysOnlineServe_bin
def obs190952 : RestartObs := {
  launchctlRestarted := true, binaryStaged := true, daemonRunning := true }

#eval restartedClaim obs190952  -- expected: true

-- Theorems formalize the gate logic:
-- T1: claim implies each component (contrapositive: if any component false,
--     claim false).
theorem claim_implies_components (o : RestartObs)
    (h : restartedClaim o = true) :
    o.launchctlRestarted && o.binaryStaged && o.daemonRunning = true := h

-- T2: claim false if any component false (the step that could fail).
theorem missing_launchctl_false (o : RestartObs)
    (h : o.launchctlRestarted = false) : restartedClaim o = false := by
  unfold restartedClaim
  rw [h]
  simp

theorem missing_binary_false (o : RestartObs)
    (h : o.binaryStaged = false) : restartedClaim o = false := by
  unfold restartedClaim
  rw [h]
  simp

theorem missing_daemon_false (o : RestartObs)
    (h : o.daemonRunning = false) : restartedClaim o = false := by
  unfold restartedClaim
  rw [h]
  simp

-- T4 (monotone): adding components cannot un-restart the claim.
-- If launchctlRestarted=false, claim false regardless of the other bits.
theorem restart_is_conjunction :
    restartedClaim { launchctlRestarted := false, binaryStaged := true, daemonRunning := true } = false := by
  native_decide

theorem observer_proved : restartedClaim obs190952 = true := by
  native_decide
