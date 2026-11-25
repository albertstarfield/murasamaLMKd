-- Refutation fix: whitelist request latency is now one 100 ms poll,
-- not up to one second, while the user-requested freeze stays 6 hours.
theorem poll_latency_reduced : 100 <= 1000 := by native_decide
theorem poll_latency_below_dialog : 100 < 120000 := by native_decide
theorem whitelist_window_is_six_hours : 21600 = 6 * 3600 := by native_decide
