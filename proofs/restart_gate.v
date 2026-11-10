Require Import Bool.

Record RestartObs := {
  launchctlRestarted : bool;
  binaryStaged : bool;
  daemonRunning : bool
}.

Definition restartedClaim (o : RestartObs) : bool :=
  launchctlRestarted o && binaryStaged o && daemonRunning o.

Definition obs190952 := {| launchctlRestarted := true; binaryStaged := true; daemonRunning := true |}.

Lemma claim_true : restartedClaim obs190952 = true.
Proof. reflexivity. Qed.

Lemma missing_launchctl_false : forall o,
  launchctlRestarted o = false -> restartedClaim o = false.
Proof. intros o H. unfold restartedClaim. rewrite H. reflexivity. Qed.

Lemma missing_binary_false : forall o,
  binaryStaged o = false -> restartedClaim o = false.
Proof. intros o H. unfold restartedClaim. rewrite H. destruct (launchctlRestarted o); destruct (daemonRunning o); reflexivity. Qed.

Lemma missing_daemon_false : forall o,
  daemonRunning o = false -> restartedClaim o = false.
Proof. intros o H. unfold restartedClaim. rewrite H. destruct (launchctlRestarted o); destruct (binaryStaged o); reflexivity. Qed.

Lemma restart_is_conjunction :
  restartedClaim {| launchctlRestarted := false; binaryStaged := true; daemonRunning := true |} = false.
Proof. reflexivity. Qed.
