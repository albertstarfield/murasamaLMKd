-- Central claim of this turn: the critical-free disjunct closes the
-- refutation hole, while the strict boundary and the grace gate remain.
def earlyStressFixed (free total p ml : Int) : Bool :=
  p >= 3 || free < 128 || (free * 4 <= total && (p >= 2 || ml >= 4))

def shouldGraceFixed (gradient free ml : Int) : Bool :=
  gradient > 5 && (gradient * 120 > free || ml >= 4)

theorem refutationCounterexampleNowFires :
    earlyStressFixed 100 16384 1 1 = true := by
  native_decide

theorem strictBoundaryStaysFalse :
    earlyStressFixed 128 16384 1 1 = false := by
  native_decide

theorem slowGrowerStillFailsGrace :
    shouldGraceFixed 1 100 1 = false := by
  native_decide

theorem fastGrowerPassesGrace :
    shouldGraceFixed 6 100 1 = true := by
  native_decide
