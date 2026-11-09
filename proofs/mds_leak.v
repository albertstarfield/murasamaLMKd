From Stdlib Require Import Bool Arith Lia NArith.

(* Use N for the huge byte quantities; isMds etc. stay bool. *)
Definition GEN_MIN_N := 1073741824%N.           (* 1 GiB *)
Definition MDS_MIN_N := 536870912%N.            (* 512 MiB *)
Definition AGE_MIN_N := 43200%N.

Record Cand := {
  ownerKnown : bool; hasUnderscore : bool; hasHomeDir : bool;
  isMds : bool; footprintN : N; ageN : N
}.

Definition mdsSpecialActive (flagDisabled : bool) : bool := negb flagDisabled.

Definition underscoreExempt (c : Cand) (flagDisabled : bool) : bool :=
  hasUnderscore c && negb (isMds c && mdsSpecialActive flagDisabled).

Definition footprintOK (c : Cand) : bool :=
  if isMds c then N.ltb MDS_MIN_N (footprintN c)
  else            N.ltb GEN_MIN_N (footprintN c).

Definition shouldKill (c : Cand) (enabled flagDisabled : bool) : bool :=
  ownerKnown c && negb (underscoreExempt c flagDisabled) &&
  negb (hasHomeDir c) && footprintOK c && N.ltb AGE_MIN_N (ageN c) && enabled.

Definition mds555 := {| ownerKnown := true; hasUnderscore := true;
  hasHomeDir := false; isMds := true; footprintN := 9341763584%N;
  ageN := 421752%N |}.
Definition mds388 := {| ownerKnown := true; hasUnderscore := false;
  hasHomeDir := false; isMds := false; footprintN := 80740352%N;
  ageN := 421754%N |}.
Definition mds600 := {| ownerKnown := true; hasUnderscore := true;
  hasHomeDir := false; isMds := true; footprintN := 629145600%N;
  ageN := 172800%N |}.

Lemma mds555_killed : shouldKill mds555 true false = true.
Proof. vm_compute. reflexivity. Qed.

Lemma mds388_not_killed : shouldKill mds388 true false = false.
Proof. vm_compute. reflexivity. Qed.

Lemma mds600_flag_exempt : shouldKill mds600 true true = false.
Proof. vm_compute. reflexivity. Qed.

Lemma mds600_flag_absent_killed : shouldKill mds600 true false = true.
Proof. vm_compute. reflexivity. Qed.

Lemma mds_flag_exempt : forall c enabled,
  isMds c = true -> hasUnderscore c = true ->
  shouldKill c enabled true = false.
Proof.
  intros c enabled Hm Hu. unfold shouldKill, underscoreExempt, mdsSpecialActive.
  rewrite Hm, Hu. simpl. rewrite andb_false_r. rewrite andb_false_l. reflexivity.
Qed.

Lemma mds_below_512 : forall c enabled flagDisabled,
  isMds c = true ->
  (footprintN c <= MDS_MIN_N)%N ->
  shouldKill c enabled flagDisabled = false.
Proof.
  intros c enabled flagDisabled Hm Hfp. unfold shouldKill, footprintOK.
  rewrite Hm.
  assert (Hb : N.ltb MDS_MIN_N (footprintN c) = false).
  { apply N.ltb_ge. exact Hfp. }
  rewrite Hb. rewrite andb_false_r. rewrite andb_false_l. reflexivity.
Qed.

Lemma mds_unknown_never : forall c enabled flagDisabled,
  ownerKnown c = false -> shouldKill c enabled flagDisabled = false.
Proof.
  intros c enabled flagDisabled H. unfold shouldKill. rewrite H.
  rewrite andb_false_l. reflexivity.
Qed.

Lemma mds_home_never : forall c enabled flagDisabled,
  hasHomeDir c = true -> shouldKill c enabled flagDisabled = false.
Proof.
  intros c enabled flagDisabled H. unfold shouldKill. rewrite H. simpl.
  rewrite andb_false_r. rewrite andb_false_l. reflexivity.
Qed.

Lemma dryrun : forall c flagDisabled, shouldKill c false flagDisabled = false.
Proof.
  intros c flagDisabled. unfold shouldKill.
  destruct (ownerKnown c); destruct (underscoreExempt c flagDisabled);
  destruct (hasHomeDir c); destruct (footprintOK c);
  destruct (N.ltb AGE_MIN_N (ageN c)); simpl; reflexivity.
Qed.
