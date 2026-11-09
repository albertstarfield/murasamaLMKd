From Stdlib Require Import Bool Arith Lia.

Definition LEAK_MIN_FOOTPRINT_BYTES := 1024 * 1024 * 1024.
Definition LEAK_MIN_AGE_SECONDS := 12 * 3600.
Definition LEAK_MAX_KILLS_PER_CYCLE := 2.

Record Candidate := {
  ownerKnown : bool;
  hasUnderscore : bool;
  hasHomeDir : bool;
  footprintBytes : nat;
  ageSeconds : nat
}.

Definition shouldKill (c : Candidate) (enabled : bool) : bool :=
  ownerKnown c && negb (hasUnderscore c) && negb (hasHomeDir c) &&
  (Nat.ltb LEAK_MIN_FOOTPRINT_BYTES (footprintBytes c)) &&
  (Nat.ltb LEAK_MIN_AGE_SECONDS (ageSeconds c)) &&
  enabled.

Lemma no_kill_unknown_owner : forall c enabled,
  ownerKnown c = false -> shouldKill c enabled = false.
Proof. intros c enabled H. unfold shouldKill. rewrite H. rewrite andb_false_l. reflexivity. Qed.

Lemma no_kill_underscore : forall c enabled,
  hasUnderscore c = true -> shouldKill c enabled = false.
Proof. intros c enabled H. unfold shouldKill. rewrite H. simpl. rewrite andb_false_r. rewrite andb_false_l. reflexivity. Qed.

Lemma no_kill_home : forall c enabled,
  hasHomeDir c = true -> shouldKill c enabled = false.
Proof. intros c enabled H. unfold shouldKill. rewrite H. simpl. rewrite andb_false_r. rewrite andb_false_l. reflexivity. Qed.

Lemma no_kill_young : forall c enabled,
  ageSeconds c <= LEAK_MIN_AGE_SECONDS ->
  shouldKill c enabled = false.
Proof.
  intros c enabled H. unfold shouldKill.
  destruct (Nat.ltb LEAK_MIN_AGE_SECONDS (ageSeconds c)) eqn:E.
  - exfalso. unfold Nat.ltb in E. apply Nat.leb_le in E. lia.
  - rewrite andb_false_r. rewrite andb_false_l. reflexivity.
Qed.

Lemma dryrun_no_kill : forall c, shouldKill c false = false.
Proof. intros c. unfold shouldKill. destruct (ownerKnown c); simpl; try reflexivity.
  destruct (hasUnderscore c); simpl; try reflexivity.
  destruct (hasHomeDir c); simpl; try reflexivity.
  destruct (Nat.ltb LEAK_MIN_FOOTPRINT_BYTES (footprintBytes c)); simpl; try reflexivity.
  destruct (Nat.ltb LEAK_MIN_AGE_SECONDS (ageSeconds c)); simpl; reflexivity.
Qed.

Lemma no_kill_small_footprint : forall c enabled,
  footprintBytes c <= LEAK_MIN_FOOTPRINT_BYTES ->
  shouldKill c enabled = false.
Proof.
  intros c enabled H. unfold shouldKill.
  destruct (Nat.ltb LEAK_MIN_FOOTPRINT_BYTES (footprintBytes c)) eqn:E.
  - exfalso. unfold Nat.ltb in E. apply Nat.leb_le in E. lia.
  - rewrite andb_false_r. rewrite andb_false_l. reflexivity.
Qed.
