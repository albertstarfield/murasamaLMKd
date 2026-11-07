#!/bin/bash

# Disable? Uncomment this
#sleep 99999
#exit



# Murasama LMKd - Daemon Launch Script
# This script is executed by launchd (KeepAlive).
# It starts the ML predictor and the Ada/SPARK daemon.
set -e

DAEMON_DIR="/usr/local/murasamaLMKd/murasamalmk_daemon"
BIN_PATH="${DAEMON_DIR}/bin/murasamalmk_daemon"
ALR="/usr/local/bin/alr"
LOG_DIR="/tmp"

# Export PATH so launchd subprocesses can find tools
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

echo "=== Murasama LMKd Launch ==="

# 1. Build only if binary is missing or ANY source is newer than binary.
#    (Audit 🟡26: previously only murasamalmk_daemon.adb was checked, so edits
#     to other Ada sources or the ObjC bridge silently skipped rebuilds.)
STALE_SRC=$(find "${DAEMON_DIR}/src" -type f \( -name '*.adb' -o -name '*.ads' -o -name '*.m' -o -name '*.h' \) -newer "${BIN_PATH}" 2>/dev/null | head -n 1)
if [ ! -f "${BIN_PATH}" ] || [ -n "${STALE_SRC}" ]; then
  echo "[BUILD] Binary missing or stale (newest offender: ${STALE_SRC:-<none>}). Compiling..."
  cd "${DAEMON_DIR}"

  # Compile Objective-C bridge (stderr NOT silenced: build failures must surface)
  mkdir -p obj/development
  /usr/bin/clang -g -O2 -x objective-c -c src/macos_utils.m -o obj/development/macos_utils.o \
    -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk

  # Compile Ada/SPARK daemon
  "${ALR}" build 2>&1
  echo "[BUILD] Done."
else
  echo "[SKIP] Binary up to date: ${BIN_PATH}"
fi

# 2. Initialize data files
mkdir -p "${DAEMON_DIR}"
echo -e "predicted_pressure:1\nrisk_level:low\ntarget_pid:0" > "${DAEMON_DIR}/ml_prediction.txt"

# 3. Launch the Ada/SPARK daemon (replaces this shell)
#    The daemon now manages the ML predictor sidecar internally.
echo "[DAEMON] Unsheathing Murasama Daemon..."
exec "${BIN_PATH}"
