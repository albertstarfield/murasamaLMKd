From Stdlib Require Import ZArith Lia.
Open Scope Z_scope.

Definition stable (pressure free_mb : Z) : bool :=
  if (Z.leb pressure 2 && Z.geb free_mb 512)%bool then true else false.

Definition window (cap : Z) : Z := Z.min cap 60.

Theorem window_whitelist_capped : window 21600 = 60.
Proof. unfold window. reflexivity. Qed.
Theorem window_normal_capped : window 60 = 60.
Proof. unfold window. reflexivity. Qed.
Theorem stable_at_pressure_two : stable 2 600 = true.
Proof. unfold stable. reflexivity. Qed.
Theorem unstable_at_pressure_three : stable 3 600 = false.
Proof. unfold stable. reflexivity. Qed.
Theorem release_when_stable :
  (if (stable 2 600 || Z.geb 600 21600)%bool then true else false) = true.
Proof. unfold stable. reflexivity. Qed.
