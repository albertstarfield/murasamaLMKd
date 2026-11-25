(* Claim under test (source: murasamalmk_daemon.adb:369-397): the no-kill
   grace popup uses a 120-second zenity timeout and the command is still
   enqueued asynchronously. Failure modes: wrong timeout, dropped enqueue. *)
From Stdlib Require Import Nat Bool Arith.

Definition graceTimeout : nat := 120.

Definition graceWarningOK (timeout : nat) (async_enqueue : bool) : bool :=
  andb async_enqueue (Nat.eqb timeout graceTimeout).

Theorem timeout_is_120 : graceTimeout = 120.
Proof. reflexivity. Qed.

Theorem async_queue_preserved : graceWarningOK 120 true = true.
Proof. reflexivity. Qed.

(* Counterexample: flag present but Runner.Enqueue dropped. *)
Theorem dropping_enqueue_fails : graceWarningOK 120 false = false.
Proof. reflexivity. Qed.

(* Counterexample: any timeout other than 120 fails the claim. *)
Theorem wrong_timeout_fails : forall t, t <> 120 -> graceWarningOK t true = false.
Proof.
  intros t H. unfold graceWarningOK, graceTimeout.
  destruct (Nat.eqb t 120) eqn:E.
  - exfalso. apply H. now apply Nat.eqb_eq in E.
  - reflexivity.
Qed.

(* The only way to satisfy the guard is timeout=120 AND an enqueue. *)
Theorem timeout_eq_120_required : forall t b, graceWarningOK t b = true -> t = 120.
Proof.
  intros t b H. unfold graceWarningOK, graceTimeout in H.
  destruct b; simpl in H; [now apply Nat.eqb_eq in H | discriminate H].
Qed.
