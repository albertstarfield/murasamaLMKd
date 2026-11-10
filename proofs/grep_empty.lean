-- Core inference: "grep returned 0 matches" is NOT the same as "no content
-- exists". Formalize the claim as: if P (a proposition) is TRUE in the
-- corpus, then grep -c P >= 1. Counterexample: case mismatch, binary file,
-- symlink, or corpus changed between grep and read.
-- Empirically: system grep is case-sensitive and skips binary by default.

-- The inference that could fail: "no matches for P => P absent from corpus".
-- In logic: ¬(matches > 0) -> ¬(exists x, P x) is valid ONLY if grep is
-- a sound and complete decision procedure over the corpus. State it:
--   (forall corpus, grep corpus P = 0 -> not P in corpus)

-- Test: given a corpus function `contains : String -> Bool` and a grep
-- function `grepFound : String -> Bool`, UNDER THE PREMISE that grep is
-- complete (contains P = true -> grepFound P = true), the inference holds.
-- Prove that contrapositive; the premise is the step that could fail in
-- practice (binary/case/symlink), and is marked unproven by axiom here.

-- We model the corpus as a mapping from strings to presence.
structure Corpus where
  present : String -> Bool

-- A grep function is COMPLETE relative to P: every present string is found.
def CompleteFor (grepFound : String -> Bool) (c : Corpus) : Prop :=
  forall s, c.present s = true -> grepFound s = true

-- THEOREM (the valid inference): if grep is complete and reports 0, then
-- P is absent. We prove the contrapositive direction: present -> found.
theorem grep_complete_sound {P : String} {grepFound : String -> Bool}
    {c : Corpus} (h : CompleteFor grepFound c)
    (hp : c.present P = true) : grepFound P = true := h P hp

-- And the inference in the other direction requires the DECISION side:
-- grepFound P = false -> not present. This follows FROM COMPLETENESS:
theorem grep_zero_implies_absent {P : String} {grepFound : String -> Bool}
    {c : Corpus} (h : CompleteFor grepFound c)
    (hz : grepFound P = false) : c.present P = false := by
  -- From False (false = true), anything follows. Derive False from the
  -- existence of a present P: if present P were true, grepFound P would
  -- be true (h), contradicting hz.
  by_cases hp : c.present P = true
  · have hfound : grepFound P = true := h P hp
    rw [hz] at hfound
    -- false = true here; derive False from hfound : false = false? no:
    -- hfound is now `false = true` after rw? rw hz at hfound rewrites
    -- grepFound P in hfound's type grepFound P = true to `false = true`.
    exact absurd hfound (by simp)
  · -- not true => false (Bool dichotomy)
    cases hsub : c.present P with
    | true => simp [hsub] at hp
    | false => rfl

-- COUNTEREXAMPLE / REALITY CHECK (not provable here): grep's completeness
-- relative to the WHOLE /usr/local corpus is an empirical claim, and FAILS
-- on: binary files (no -a flag), unreadable symlinks, files outside the
-- scan root, and mid-scan file changes. Each of these is a premise
-- violation, not a logic error. The ASCII case matches the user's exact
-- string, so case-sensitivity is moot; binary/mtime races remain.
-- Marked: SYSTEM step unverifiable in Lean; replace with: re-run grep -a
-- -r -n (all files, including binary) and confirm 0 matches; also check
-- $cwd of the scan. See message body for the finding.

-- Dummy sanity the definitions are usable
#check grep_zero_implies_absent
