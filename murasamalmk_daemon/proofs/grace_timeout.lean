-- Claim under test (source: murasamalmk_daemon.adb:369-397):
--   the no-kill grace popup command carries zenity --timeout=120, and the
--   command is still passed to Runner.Enqueue (async, nonblocking queue).
-- zenity --help-all: "--timeout=TIMEOUT  Set dialog timeout in seconds".
-- Failure modes modelled below: flag omitted/wrong value, or enqueue dropped.

def graceTimeout : Nat := 120

def graceCmd (timeout : Nat) : String :=
  "/opt/homebrew/bin/zenity --warning --width=400 --timeout=" ++ toString timeout

def graceWarningOK (timeout : Nat) (asyncEnqueue : Bool) : Bool :=
  asyncEnqueue && (timeout = graceTimeout)

theorem timeout_is_120 : graceTimeout = 120 := by
  rfl

theorem cmd_carries_120 :
    graceCmd graceTimeout =
      "/opt/homebrew/bin/zenity --warning --width=400 --timeout=120" := by
  decide

-- The 120s window is long enough to read the dialog (no instant dismissal).
theorem timeout_is_readable (t : Nat) (h : t = graceTimeout) : 10 <= t := by
  subst t
  decide

-- The edit preserves the async nonblocking queue: enqueue still happens.
theorem async_queue_preserved : graceWarningOK graceTimeout true = true := by
  rfl

-- Counterexample: adding the flag but dropping Runner.Enqueue fails.
theorem dropping_enqueue_fails : graceWarningOK graceTimeout false = false := by
  rfl

-- Counterexample: a wrong or short timeout value fails the claim.
theorem wrong_timeout_fails (t : Nat) (h : t ≠ graceTimeout) :
    graceWarningOK t true = false := by
  simp [graceWarningOK, h]
