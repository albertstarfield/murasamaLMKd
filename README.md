# Murasama LMKd

macOS memory-pressure and thrashing-mitigation daemon.

Monitors system memory in real time. When pressure crosses critical thresholds, it kills the processes causing the most harm and notifies the user.

## What It Does

- **Thrashing Detection** — Tracks pageins/s and decompressions/s. If either exceeds sustained thresholds, it temporarily boosts the frontmost app's priority and throttles background hogs.
- **Bloodshed Mode** — At memory pressure level 4+ (or free memory below 128 MB, or violent allocation spikes), it identifies the top 3 memory consumers and kills the one with the least allocation activity (or highest accumulated kill weight).
- **ML Predictor** — A Python sidecar forecasts future memory pressure. If the model predicts level 4/5 and current pressure is already elevated, bloodshed triggers preemptively.
- **Weight Tracking** — Processes that get killed accumulate a weight score. Heavier processes are more likely to be targeted on subsequent triggers.
- **Game Mode** — Automatically enables macOS game mode for the frontmost app during thrashing mitigation.
- **Telemetry** — Exports JSON metrics every 2 seconds for external monitoring.

## Architecture

```
start.sh                          launchd entry point
├─ murasamalmk_daemon              main daemon binary
│  ├─ src/macos_utils.m            Objective-C bridge (Mach/libproc APIs)
│  └─ python/ml_predictor.py       ML prediction sidecar
├─ murasama_check.py               sidecar health checker
└─ restart_service.sh              service lifecycle management
```

## Configuration

Thresholds are defined in `murasamalmk_daemon/src/murasama_types.ads`:

| Constant | Value | Description |
|---|---|---|
| `CRITICAL_FREE_MB` | 128.0 | Free memory threshold (MB) |
| `PANIC_VELOCITY_MB_S` | dynamic = 75% of machine total RAM (MB) | Wired memory velocity trigger (MB/s), detected at runtime via `get_total_ram_mb_c`; there is no hardcoded 21000 MB fallback — if detection fails the velocity gate is disabled and logged |
| `THRASHING_THRESHOLD_PAGEINS` | 500 | Pageins/s to trigger thrashing mitigation |
| `THRASHING_THRESHOLD_DECOMP` | 10000 | Decompressions/s to trigger thrashing mitigation |
| `MIN_PRESSURE_LEVEL_TO_KILL` | 4 | Minimum OS pressure level for bloodshed |

## Installation

```bash
# Build and install the launchd service
sudo ./restart_service.sh
```

Requires:
- macOS 14+
- Xcode command line tools (for `gamepolicyctl`)
- Homebrew (`zenity` for notifications)

## Service Management

```bash
# Start
sudo launchctl load /Library/LaunchDaemons/com.twilightmigratory.murasamalmkd.plist

# Stop
sudo launchctl unload /Library/LaunchDaemons/com.twilightmigratory.murasamalmkd.plist

# Logs
tail -f /var/log/murasamalmkd.log
```

## License

Hippocratic License 3.0 — see [LICENSE.md](LICENSE.md)

## Author

Made by **Albert Starfield Wahyu Suryo Samudro** `<albertstarfield2001@gmail.com>`
