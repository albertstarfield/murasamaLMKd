Definition killDecision (p : nat) (z : bool) : bool := Nat.leb 4 p.
Theorem kill_independent : forall p z1 z2, killDecision p z1 = killDecision p z2.
Proof. intros p z1 z2. unfold killDecision. reflexivity. Qed.
Theorem no_block : forall p, killDecision p false = Nat.leb 4 p.
Proof. intros p. reflexivity. Qed.
Theorem p4 : killDecision 4 false = true.
Proof. reflexivity. Qed.
