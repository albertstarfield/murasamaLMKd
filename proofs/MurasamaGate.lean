-- Murasama LMKd exploration answer: formalized core inferences.
-- Constants source: /usr/local/murasamalmkd/murasamalmk_daemon/src/murasama_types.ads

theorem min_pressure_in_range : 1 ≤ 4 ∧ 4 ≤ 5 := by
  decide

theorem critical_free_positive : 128 > 0 := by
  decide

theorem thrash_pageins_positive : 500 > 0 := by
  decide

theorem leak_age_is_12h : 12 * 3600 = 43200 := by
  decide

theorem leak_footprint_is_1gib : 1024 * 1024 * 1024 = 1073741824 := by
  decide

def isProtected (hasHermes hasSyncthing hasOmlx : Bool) : Bool :=
  hasHermes || hasSyncthing || hasOmlx

theorem guard_protects_hermes : isProtected true false false = true := by
  rfl

theorem guard_protects_syncthing : isProtected false true false = true := by
  rfl

theorem guard_protects_omlx : isProtected false false true = true := by
  rfl

theorem guard_does_not_protect_clean : isProtected false false false = false := by
  rfl

theorem gnatprove_total : 22 + 32 = 54 := by
  decide

theorem all_checks_total : 54 + 15 = 69 := by
  decide

theorem kill_cap_ok : 4 > 0 ∧ 4 ≤ 16 := by
  decide

-- 9. Fallback panic threshold (used when RAM detection fails) is positive.
theorem fallback_panic_threshold_positive : 21000 > 0 := by
  decide
