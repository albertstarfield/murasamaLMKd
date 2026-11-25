From Stdlib Require Import ZArith.
Open Scope Z_scope.

Definition earlyStress (free total p ml : Z) : bool :=
  if Z.geb p 3 then true
  else if Z.ltb free 128 then true
  else if Z.leb (free * 4) total then
       if (Z.geb p 2 || Z.geb ml 4)%bool then true else false
  else false.

Theorem pressure_three_suffices : earlyStress 100 16384 3 1 = true.
Proof. reflexivity. Qed.
Theorem critical_free_at_pressure_one : earlyStress 100 16384 1 1 = true.
Proof. reflexivity. Qed.
Theorem low_free_at_pressure_two : earlyStress 3000 16384 2 1 = true.
Proof. reflexivity. Qed.
Theorem boundary_critical_free : earlyStress 128 16384 1 1 = false.
Proof. reflexivity. Qed.
Theorem counterexample_healthy : earlyStress 12000 16384 1 1 = false.
Proof. reflexivity. Qed.
