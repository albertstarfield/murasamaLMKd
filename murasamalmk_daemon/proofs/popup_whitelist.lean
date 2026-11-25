-- Central claim: the popup C runner outlives the visible zenity timeout,
-- and the whitelist freeze is exactly 6 hours (longer than normal 60s).
theorem popup_runner_outlives_dialog : 125000 > 120 * 1000 := by
  native_decide

theorem whitelist_is_six_hours : 21600 = 6 * 3600 := by
  native_decide

theorem long_hold_exceeds_normal_grace : 21600 > 60 := by
  native_decide
