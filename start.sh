#!/bin/bash
set -e

echo "=== Murasama LMKd Bootstrap Launch Sequence ==="
cd /usr/local/murasamaLMKd/murasamalmk_daemon

# 1. Compile Objective-C bridge manually to ensure correct frameworks are linked
echo "[1/5] Compiling Objective-C bridge..."
mkdir -p obj/development
/usr/bin/clang -g -O2 -x objective-c -c src/macos_utils.m -o obj/development/macos_utils.o \
  -framework AppKit -framework Foundation -framework CoreGraphics -lproc \
  -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk

# 2. Compile the Ada/SPARK daemon binary using Alire
echo "[2/5] Compiling Ada/SPARK daemon..."
alr build

# 3. Setup Python virtual environment, auto-install dependencies, and verify type safety
echo "[3/5] Bootstrapping Python virtualenv and verifying type safety..."
if [ ! -d "python/venv" ]; then
  echo "[+] Virtual environment 'python/venv' not found. Creating..."
  python3 -m venv python/venv
fi

echo "[+] Activating venv and auto-installing required packages..."
source python/venv/bin/activate
pip install --upgrade pip
pip install numpy pandas scikit-learn

echo "[+] Running Python type checking (pyrefly)..."
/opt/homebrew/anaconda3/bin/pyrefly check python/ml_predictor.py
deactivate

# 4. Perform SPARK verification
echo "[4/5] Running formal SPARK verification (gnatprove)..."
alr exec -- gnatprove -P murasamalmk_daemon.gpr --level=0

# 5. Initialize telemetry and prediction flat files with safe defaults
echo "[5/5] Launching Daemon Processes..."
mkdir -p /usr/local/murasamaLMKd
touch /usr/local/murasamaLMKd/EARU_data.dat
echo -e "predicted_pressure:1\nrisk_level:low\ntarget_pid:0" > /usr/local/murasamaLMKd/ml_prediction.txt

# Start Python Machine Learning Predictor in background
echo "[+] Starting ML predictor in the background..."
/usr/local/murasamaLMKd/murasamalmk_daemon/python/venv/bin/python3 \
  /usr/local/murasamaLMKd/murasamalmk_daemon/python/ml_predictor.py > /var/log/murasamalmk_ml.log 2>&1 &

# Execute the Ada/SPARK daemon (replacing current process shell)
echo "[+] Unsheathing Murasama Daemon..."
exec /usr/local/murasamaLMKd/murasamalmk_daemon/bin/murasamalmk_daemon
