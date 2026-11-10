-- Model: Index returns Natural (0 = not found), Positive starts at 1.
-- Parse_Float_After takes Start_Pos : Positive.
-- When Index = 0, the value 0 is outside Positive's range => Range check failed.
def isPositive (n : Int) : Bool := n >= 1
-- The call in smc_files.adb:505 is Parse_Float_After(Content, Index(Content, "cpu_usage": ), 0.0)
-- Index() can return 0. But Parse_Float_After expects Positive.
-- In Ada, subtype Range = 1 .. Natural'Last, so passing 0 raises Constraint_Error.
theorem index_zero_is_not_positive : isPositive 0 = false := by decide
theorem index_one_is_positive : isPositive 1 = true := by decide
-- Why does it trigger only now? The JSON field cpu_usage may be missing from EARU_data.dat
-- OR the parser hit a truncated read (Length < actual). We verify via file check.
-- Also: Index returns 0 if pattern not found, hence if cpu_usage absent, Index=0 and we pass
-- it directly to Parse_Float_After. That's the bug at line 505, NOT inside Parse_Float_After.
def safeParse (idx : Int) : String :=
  if isPositive idx then "parse from idx" else "return Default"
theorem missing_field_returns_default : safeParse 0 = "return Default" := by decide
theorem present_field_parses : safeParse 123 = "parse from idx" := by decide
