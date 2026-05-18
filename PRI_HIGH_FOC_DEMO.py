#!/usr/bin/env python3

import argparse
import os
import subprocess
import sys

# Console Colors
BLUE = "\033[94m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
RED = "\033[91m"
NC = "\033[0m"

XCODE_GAME_CTL = "/Applications/Xcode.app/Contents/Developer/usr/bin/gamepolicyctl"


def check_sudo():
    """Ensure the script is running with root privileges."""
    if os.geteuid() != 0:
        print(
            f"{RED}[!] Error: This script requires root privileges. Please run with sudo.{NC}"
        )
        sys.exit(1)


def get_process_tree(process_name):
    """Recursively map the entire process tree for a given application name."""
    print(f"{BLUE}[*] Mapping process tree for '{process_name}'...{NC}")

    # 1. Get the base PIDs
    try:
        # -x ensures exact match, -i makes it case-insensitive
        output = subprocess.check_output(["pgrep", "-xi", process_name], text=True)
        base_pids = output.strip().split("\n")
    except subprocess.CalledProcessError:
        print(f"{RED}[!] Could not find any active process named '{process_name}'.{NC}")
        return set()

    all_pids = set(base_pids)

    # 2. Recursively find children
    def fetch_children(pid):
        try:
            out = subprocess.check_output(["pgrep", "-P", str(pid)], text=True)
            children = out.strip().split("\n")
            for child in children:
                if child and child not in all_pids:
                    all_pids.add(child)
                    fetch_children(child)  # Dig deeper
        except subprocess.CalledProcessError:
            pass  # No children found for this PID

    for pid in base_pids:
        fetch_children(pid)

    return all_pids


def apply_priority(pids, priority):
    """Apply the specified renice value to a set of PIDs, failing silently on dead ones."""
    print(f"{GREEN}[*] Applying priority {priority} to {len(pids)} threads...{NC}")
    success_count = 0

    for pid in pids:
        try:
            # Route stdout/stderr to DEVNULL to keep the terminal clean
            subprocess.run(
                ["renice", str(priority), "-p", str(pid)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=True,
            )
            success_count += 1
        except subprocess.CalledProcessError:
            pass  # Skip if the child process died during execution

    print(
        f"{GREEN}[✓] Successfully optimized {success_count}/{len(pids)} active PIDs.{NC}"
    )


def toggle_game_mode(state):
    """Toggle the macOS Game Mode default behavior."""
    print(f"{BLUE}[*] Setting macOS Game Mode policy to: {state.upper()}{NC}")
    try:
        subprocess.run([XCODE_GAME_CTL, "game-mode", "set", state], check=True)
    except FileNotFoundError:
        print(
            f"{YELLOW}[!] Warning: gamepolicyctl not found at expected Xcode path.{NC}"
        )
        print(
            f"{YELLOW}[!] The OS toggle was skipped, but CPU priorities will still be applied.{NC}"
        )
    except subprocess.CalledProcessError:
        print(f"{RED}[!] Error executing gamepolicyctl.{NC}")


def main():
    parser = argparse.ArgumentParser(
        description="Zephyrine Game Mode & Priority Override"
    )
    parser.add_argument(
        "state",
        choices=["on", "auto"],
        help="Enable (on) or disable (auto) the override.",
    )
    parser.add_argument(
        "-p",
        "--process",
        required=True,
        help="Target process name (e.g., zed, hl2_osx)",
    )

    args = parser.parse_args()
    check_sudo()

    if args.state == "on":
        toggle_game_mode("on")
        pids = get_process_tree(args.process)
        if pids:
            # Force max priority automatically
            apply_priority(pids, -20)

    elif args.state == "auto":
        toggle_game_mode("auto")
        pids = get_process_tree(args.process)
        if pids:
            # Revert back to standard OS scheduling
            apply_priority(pids, 0)

    print(f"{GREEN}[✓] Operation complete.{NC}")


if __name__ == "__main__":
    main()
