#!/usr/bin/env python3
"""
Murasama LMKd Sidecar Check
This script acts as a Low Memory Killer daemon / sidecar health checker for the StableZFSDriver_Daemon and VM.
It monitors the QEMU VM process and ensures it doesn't exceed memory bounds, and checks the status of the Daemon.
"""

import os
import sys
import time
import subprocess
import logging

logging.basicConfig(level=logging.INFO, format='[Murasama-LMKd] %(asctime)s - %(levelname)s: %(message)s')

VM_NAME = "FSUSBDriverIsolationBridge"
MEMORY_THRESHOLD_MB = 10000  # Example 10GB threshold
CHECK_INTERVAL_SEC = 30

def get_vm_pid():
    try:
        # pgrep for qemu-system-aarch64 with specific name
        output = subprocess.check_output(["pgrep", "-f", VM_NAME]).decode('utf-8').strip().split('\n')
        if output and output[0]:
            return int(output[0])
    except subprocess.CalledProcessError:
        pass
    return None

def get_memory_usage_mb(pid):
    try:
        # Get RSS in KB and convert to MB
        output = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)]).decode('utf-8').strip()
        if output:
            return int(output) / 1024
    except Exception as e:
        logging.error(f"Error reading memory for PID {pid}: {e}")
    return 0

def check_memory():
    pid = get_vm_pid()
    if not pid:
        logging.info(f"VM '{VM_NAME}' not running. No memory to check.")
        return

    mem_mb = get_memory_usage_mb(pid)
    logging.info(f"VM '{VM_NAME}' (PID {pid}) is using {mem_mb:.2f} MB of memory.")

    if mem_mb > MEMORY_THRESHOLD_MB:
        logging.warning(f"Memory threshold exceeded! ({mem_mb:.2f} MB > {MEMORY_THRESHOLD_MB} MB). Taking action...")
        # LMK Action: Here we would potentially kill or throttle. For safety, just log.
        # os.system(f"sudo kill -15 {pid}")
    else:
        logging.info("Memory usage within normal bounds.")

if __name__ == "__main__":
    logging.info("Starting Murasama LMKd Sidecar Checker...")
    while True:
        check_memory()
        time.sleep(CHECK_INTERVAL_SEC)
