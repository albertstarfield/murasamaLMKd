From Stdlib Require Import ZArith.
Open Scope Z_scope.

Theorem popup_runner_outlives_dialog : 125000 > 120 * 1000.
Proof. reflexivity. Qed.

Theorem whitelist_is_six_hours : 21600 = 6 * 3600.
Proof. reflexivity. Qed.

Theorem long_hold_exceeds_normal_grace : 21600 > 60.
Proof. reflexivity. Qed.
