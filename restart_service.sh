#!/bin/bash

# 1. Clean up old C# / C++ launchd plist if present
OLD_PLIST_PATH="/Library/LaunchDaemons/com.xnu.murasamalmkd.plist"
if [ -f "$OLD_PLIST_PATH" ]; then
  echo "[+] Found old service com.xnu.murasamalmkd.plist. Unloading and removing..."
  sudo launchctl unload "$OLD_PLIST_PATH" 2>/dev/null
  sudo rm -f "$OLD_PLIST_PATH"
fi

# 2. Terminate any running old process instances
if pgrep -x "murasamalmkd" >/dev/null; then
  echo "[+] Stopping running instances of old daemon..."
  sudo pkill -x "murasamalmkd" 2>/dev/null
fi

# 3. Register and load the new Ada/SPARK & Python ML service
PLIST_NAME=com.twilightmigratory.murasamalmkd.plist
PLIST_PATH="/Library/LaunchDaemons/${PLIST_NAME}"
echo "[+] Copying new service plist to LaunchDaemons..."
sudo cp ${PLIST_NAME} ${PLIST_PATH}

echo "[+] Loading new service ${PLIST_NAME}..."
sudo launchctl unload "$PLIST_PATH" 2>/dev/null
sudo launchctl load "$PLIST_PATH"

echo "[SUCCESS] Service ${PLIST_NAME} successfully activated."
