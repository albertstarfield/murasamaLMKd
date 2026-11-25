From Stdlib Require Import ZArith.
Open Scope Z_scope.

Definition earlyStressFixed (free total p ml : Z) : bool :=
  if Z.geb p 3 then true
  else if Z.ltb free 128 then true
  else if Z.leb (free * 4) total then
       if (Z.geb p 2 || Z.geb ml 4)%bool then true else false
  else false.

Definition shouldGraceFixed (gradient free ml : Z) : bool :=
  if Z.gtb gradient 5 then
    if (Z.gtb (gradient * 120) free || Z.geb ml 4)%bool then true else false
  else false.

Theorem refutation_counterexample_now_fires :
  earlyStressFixed 100 16384 1 1 = true.
Proof. reflexivity. Qed.

Theorem strict_boundary_stays_false :
  earlyStressFixed 128 16384 1 1 = false.
Proof. reflexivity. Qed.

Theorem slow_grower_still_fails_grace :
  shouldGraceFixed 1 100 1 = false.
Proof. reflexivity. Qed.

Theorem fast_grower_passes_grace :
  shouldGraceFixed 6 100 1 = true.
Proof. reflexivity. Qed.
