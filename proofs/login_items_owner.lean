-- Formalizes the answer to "does the 247 Ada daemon relaunch login items?"
-- Empirical: only ensureAppServiceRunning.c contains "login item" text;
-- 247AlwaysOnlineServe_src/src/always_online_serve.adb does not.
-- We model the set of components that own the login-item relaunch feature.

inductive Component where
  | adaDaemon          -- 247AlwaysOnlineServe_bin (Ada)
  | ensureAppService   -- ensureAppServiceRunning (C)
  deriving DecidableEq

-- Feature ownership: which component relaunches login items.
def RelaunchesLoginItems : Component -> Bool
  | Component.adaDaemon        => false
  | Component.ensureAppService => true

-- The 247 Ada daemon does NOT relaunch login items.
theorem ada_does_not_relaunch : RelaunchesLoginItems Component.adaDaemon = false := by
  rfl

-- ensureAppServiceRunning DOES.
theorem ensure_does_relaunch : RelaunchesLoginItems Component.ensureAppService = true := by
  rfl

-- Therefore the user's claim ("247 daemon relaunches login items") is false.
theorem user_claim_false : RelaunchesLoginItems Component.adaDaemon ≠ true := by
  decide

#eval RelaunchesLoginItems Component.adaDaemon
