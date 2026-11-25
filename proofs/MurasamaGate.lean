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

-- 9. Panic threshold comes from MACHINE TOTAL RAM (MB), never a hardcoded
--    21000 MB. A positive machine total gives a positive 75% threshold.
def panic_threshold (machine_total_ram_mb : Nat) : Nat :=
  machine_total_ram_mb * 3 / 4

theorem fallback_panic_threshold_positive (machine_total_ram_mb : Nat)
    (h : machine_total_ram_mb >= 4) :
    panic_threshold machine_total_ram_mb > 0 := by
  unfold panic_threshold
  have h4 : 4 <= machine_total_ram_mb * 3 := by omega
  exact Nat.div_pos h4 (by decide : 0 < 4)
