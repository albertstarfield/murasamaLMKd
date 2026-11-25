(* Grace STOP/CONT policy axiom test; Rocq mirror of grace_policy.lean. *)
From Stdlib Require Import ZArith Lia Bool.
Open Scope Z_scope.

Definition shouldGrace (grad free ml : Z) : bool :=
  (grad >? 5) && ((grad * 120 >? free) || (ml >=? 4)).

Definition wardenKills (holdActive : bool) : bool := negb holdActive.

Example linear_prediction_graces : shouldGrace 100 2048 1 = true.
Proof. vm_compute. reflexivity. Qed.

Example ml_early_graces : shouldGrace 6 2048 4 = true.
Proof. vm_compute. reflexivity. Qed.

(* COUNTEREXAMPLE: at the boundary gradient with no ML warning, grace is off. *)
Example boundary_not_graced : shouldGrace 5 2048 1 = false.
Proof. vm_compute. reflexivity. Qed.

Example hold_means_no_warden_kill : wardenKills true = false.
Proof. vm_compute. reflexivity. Qed.

Example no_hold_allows_warden_kill : wardenKills false = true.
Proof. vm_compute. reflexivity. Qed.
