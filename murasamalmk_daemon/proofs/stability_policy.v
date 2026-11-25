(* Rocq mirror of stability_policy.lean: the hold-until-stable grace policy.
   Source: murasama_grace.adb:239-324, murasama_types.ads:304-312. *)
From Stdlib Require Import Nat Bool Lia PeanoNat Compare_dec.

Definition freezeWindow (hold : nat) : nat := Nat.min hold 60.

Definition stillFrozen (systemStable : bool) (totalHeld cap : nat) : bool :=
  if systemStable then false else if totalHeld <? cap then true else false.

Definition releaseAllowed (gradAbove : bool) (quietProbes : nat)
  (longHold : bool) : bool :=
  andb (andb (negb gradAbove) (Nat.eqb 3 (Nat.min quietProbes 3)))
       (negb longHold).

Lemma window_le_60 : forall hold, freezeWindow hold <= 60.
Proof. intros hold. unfold freezeWindow. lia. Qed.

Example full_hold_is_capped : freezeWindow 21600 = 60.
Proof. vm_compute. reflexivity. Qed.

Lemma thrash_keeps_frozen : forall total cap, total < cap ->
  stillFrozen false total cap = true.
Proof.
  intros total cap H. unfold stillFrozen. simpl.
  destruct (total <? cap) eqn:E; [reflexivity | exfalso].
  apply (proj1 (Nat.ltb_nlt total cap) E). exact H.
Qed.

Lemma stable_releases : forall total cap, stillFrozen true total cap = false.
Proof. intros total cap. reflexivity. Qed.

Lemma cap_forces_probe : forall cap, stillFrozen false cap cap = false.
Proof.
  intro cap. unfold stillFrozen. simpl.
  destruct (cap <? cap) eqn:E; [exfalso | reflexivity].
  apply (proj1 (Nat.ltb_lt cap cap) E). lia.
Qed.

(* Refutation of an early release: quiet-gradient guard must be true. *)
Lemma release_requires_quiet : forall g s l, releaseAllowed g s l = true -> g = false.
Proof.
  intros g s l H. unfold releaseAllowed in H.
  destruct g; simpl in H; [discriminate H | reflexivity].
Qed.

(* Refutation of release during an active user-requested freeze. *)
Lemma release_forbids_long_hold : forall g s, releaseAllowed g s true = false.
Proof. intros g s. reflexivity. Qed.
