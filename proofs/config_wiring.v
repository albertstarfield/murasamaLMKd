(* Axiom test for the Ada/SPARK wiring predicates added 2026-11-25.
   Rocq scratch-paper mirror of proofs/config_wiring.lean. *)
From Stdlib Require Import ZArith Lia.
Open Scope Z_scope.

Record MemConfig := {
  sys_idle   : Z;
  app_idle   : Z;
  wired_pct  : Z;
  kill_count : Z;
  window_s   : Z;
  delay_ms   : Z
}.

Definition desired : MemConfig :=
  {| sys_idle := 10; app_idle := 10; wired_pct := 25;
     kill_count := 0; window_s := 600; delay_ms := 500 |}.

Definition complete (c : MemConfig) : Prop :=
  sys_idle c >= 0 /\ app_idle c >= 0 /\ wired_pct c >= 0 /\
  kill_count c >= 0 /\ window_s c >= 0 /\ delay_ms c >= 0.

Definition matchesDesired (c : MemConfig) : Prop := complete c /\ c = desired.
Definition headChanged : MemConfig :=
  {| sys_idle := 10; app_idle := 10; wired_pct := 25;
     kill_count := 1; window_s := 600; delay_ms := 500 |}.
Definition daemonOwns (c : MemConfig) : Prop := kill_count c = 0.

Definition validEARU (t h p : Z) : Prop :=
  -100 <= t /\ t <= 100 /\ 0 <= h /\ h <= 100 /\ 500 <= p /\ p <= 1100.

Definition earuUsable (ok : bool) (t h p : Z) : Prop := ok = true /\ validEARU t h p.

Theorem matches_implies_owns : forall c, matchesDesired c -> daemonOwns c.
Proof.
  intros c H. destruct H as [Hc Heq]. rewrite Heq.
  unfold daemonOwns, desired; simpl. reflexivity.
Qed.

(* COUNTEREXAMPLE: count=1 closes the daemon's bloodshed gate. *)
Theorem count_one_closes_daemon_gate :
  ~ daemonOwns headChanged.
Proof. unfold daemonOwns; simpl; discriminate. Qed.

Theorem real_reading_is_usable : earuUsable true 22 89 1013.
Proof. unfold earuUsable, validEARU; simpl.
  split; [reflexivity | repeat split; lia].
Qed.

Theorem zero_pressure_rejected : ~ earuUsable true 22 89 0.
Proof.
  unfold earuUsable, validEARU; simpl; lia.
Qed.
