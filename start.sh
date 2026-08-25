#!/bin/bash


#disabled for now
#sleep 9999
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

# 1. Build only if binary is missing or source is newer than binary
if [ ! -f "${BIN_PATH}" ] || [ "${DAEMON_DIR}/src/murasamalmk_daemon.adb" -nt "${BIN_PATH}" ]; then
  echo "[BUILD] Binary missing or stale. Compiling..."
  cd "${DAEMON_DIR}"

  # Compile Objective-C bridge
  mkdir -p obj/development
  /usr/bin/clang -g -O2 -x objective-c -c src/macos_utils.m -o obj/development/macos_utils.o \
    -framework AppKit -framework Foundation -framework CoreGraphics -lproc \
    -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk 2>/dev/null

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
