Definition actuationAllowed (e c : nat) : bool := Nat.leb c e.
Theorem blocked : actuationAllowed 0 60 = false.
Proof. reflexivity. Qed.
Theorem allowed : actuationAllowed 60 60 = true.
Proof. reflexivity. Qed.
