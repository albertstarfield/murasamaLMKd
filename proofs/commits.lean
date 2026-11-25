-- Formalizes the commit summary: 4 repos, each with a distinct HEAD commit.
-- Empirical step (git log output) is not formalizable; replaced by direct
-- `git rev-parse HEAD` reads this turn.

structure Repo where
  name   : String
  hash   : String
  deriving DecidableEq

def repos : List Repo := [
  { name := "EnvironmentalAwareReferentialUnit", hash := "d9e3c34" },
  { name := "murasamaLMKd",                     hash := "03992eb" },
  { name := "amaryllisautotask_driver",         hash := "5b720ea" },
  { name := "247AlwaysOnlineServe",             hash := "d86e937" }
]

-- Claim: exactly 4 repos committed, all hashes distinct.
def AllDistinct (rs : List Repo) : Prop :=
  rs.length = 4 ∧ (rs.map (·.hash)).Nodup

theorem repos_count : repos.length = 4 := by
  unfold repos
  rfl

-- Hashes are pairwise distinct (checked by decide on the concrete list).
theorem hashes_distinct : (repos.map (·.hash)).Nodup := by
  unfold repos
  decide

-- Counterexample: if two repos shared a hash, the claim would fail.
def bad : List Repo := [
  { name := "a", hash := "abc" },
  { name := "b", hash := "abc" }
]
theorem bad_not_distinct : ¬ (bad.map (·.hash)).Nodup := by
  unfold bad
  decide

#eval repos.length
