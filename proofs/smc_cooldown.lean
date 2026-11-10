def actuationAllowed (elapsed cooldown : Nat) : Bool := elapsed >= cooldown
theorem blocked_before_cooldown : actuationAllowed 0 60 = false := by decide
theorem allowed_after_cooldown : actuationAllowed 60 60 = true := by decide
theorem blocked_30s : actuationAllowed 30 60 = false := by decide
def turbo (battC : Nat) : Bool := battC > 40
theorem bekasi_41_triggers : turbo 41 = true := by decide
theorem bekasi_40_no_trigger : turbo 40 = false := by decide
