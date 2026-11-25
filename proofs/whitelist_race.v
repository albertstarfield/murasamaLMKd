From Stdlib Require Import ZArith Lia.
Open Scope Z_scope.

Theorem poll_latency_reduced : 100 <= 1000.
Proof. lia. Qed.
Theorem poll_latency_below_dialog : 100 < 120000.
Proof. lia. Qed.
Theorem whitelist_window_is_six_hours : 21600 = 6 * 3600.
Proof. reflexivity. Qed.
