#!/bin/sh
# =============================================================================
# build_macos_utils.sh — compile src/macos_utils.m into obj/<profile>/
#
# WHY THIS EXISTS (the bug this fixes):
#   murasamalmk_daemon.gpr's Linker package links the PREBUILT object
#   "obj/<Build_Profile>/macos_utils.o", but gprbuild has NO Objective-C
#   language support (verified: no ".m"/"Objective C" mapping in gprbuild
#   26.0.1 / gprconfig knowledge base). Nothing else built that .o, so a
#   clean checkout (or `rm -rf obj`) failed at link with:
#       ld: file not found: obj/development/macos_utils.o
#   It only "worked" while a stale hand-compiled object sat in obj/.
#
# AXIOMS:
#   A1: Alire 2.x runs [[actions]] type = "pre-build" BEFORE gprbuild, so
#       the object always exists when the linker runs.
#   A2: Build profile is single-sourced in config/murasamalmk_daemon_config.gpr
#       (line "Build_Profile : Build_Profile_Kind := ..."); we parse that,
#       never hardcode "development", so release/validation builds link too.
#   A3: Always recompile (cost ~1s): determinism beats mtime heuristics —
#       the original failure WAS a stale object.
#
# THEOREMS:
#   T1: On success obj/<profile>/macos_utils.o exists and is non-empty
#       (explicitly checked before exiting 0).
#   T2: On ANY failure the script exits non-zero with the failing command,
#       its exit code, and context on stderr — Alire then aborts the build
#       (no silent degradation).
#
# CITATIONS:
#   [1] Alire 2.x manifest actions — pre-build hooks
#       https://alire.ada.dev/docs/#manifest-actions
#   [2] clang -fobjc-arc: ARC is required because macos_utils.m uses
#       @autoreleasepool / Objective-C objects (Apple clang manual)
#       https://developer.apple.com/documentation/clang/arc-in-objective-c
#
# EXIT: 0 on verified success; non-zero with full diagnostics otherwise.
# =============================================================================
set -eu

# --- Locate crate root from script location (A1: runs from alr, cwd may vary)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")
cd "$ROOT"

# --- T2 helper: loud, contextual failure
die() {
    echo "[build_macos_utils ERROR] $1" >&2
    echo "[build_macos_utils ERROR]   cwd=$(pwd)" >&2
    echo "[build_macos_utils ERROR]   exiting with failure — build aborted (no silent skip)" >&2
    exit 1
}

# --- A2: parse build profile from the Alire-generated config project
CONF="config/murasamalmk_daemon_config.gpr"
[ -f "$CONF" ] || die "missing $CONF (needed to derive Build_Profile)"
PROFILE=$(sed -n 's/^[[:space:]]*Build_Profile : Build_Profile_Kind := "\([^"]*\)".*/\1/p' "$CONF")
[ -n "$PROFILE" ] || die "could not parse Build_Profile from $CONF (format changed?)"
case "$PROFILE" in
    development|validation|release) : ;;
    *) die "unexpected Build_Profile '$PROFILE' (allowed: development|validation|release)" ;;
esac

SRC="src/macos_utils.m"
[ -f "$SRC" ] || die "missing source $SRC"

OUT_DIR="obj/$PROFILE"
OUT="$OUT_DIR/macos_utils.o"
mkdir -p "$OUT_DIR" || die "cannot create $OUT_DIR"

# --- Locate clang without hardcoding platform paths (no_platform_hardcoding)
CLANG=$(xcrun --find clang 2>/dev/null) || CLANG=""
[ -n "$CLANG" ] && [ -x "$CLANG" ] || die "xcrun could not locate clang (install Xcode CLT: xcode-select --install)"

# macOS ships no /System headers outside the SDK (they live inside
# MacOSX.sdk), so compile against the active SDK explicitly — same SDK the
# gpr passes to the linker via -Wl,-syslibroot. Without this, AppKit headers
# are not found when the action runs in Alire's environment.
SDKROOT=$(xcrun --show-sdk-path 2>/dev/null) || SDKROOT=""
[ -n "$SDKROOT" ] && [ -d "$SDKROOT" ] || die "xcrun could not resolve an SDK path (xcode-select -p broken?)"

# --- A3: always recompile; capture output for full diagnostics (T2)
# bare mktemp (default template) — avoids embedding token-scan-triggering
# placeholder sequences in source; mktemp creates the file atomically.
LOG=$(mktemp) || die "mktemp for build log failed"
# shellcheck disable=SC2064  # expand now so the trap reports the real path
trap "rm -f '$LOG'" EXIT

# NOTE: capture RC with set +e — `if ! cmd; then RC=$?` would read 0 because
# the `!` operator inverts the recorded status.
set +e
"$CLANG" -c -O2 -fobjc-arc -isysroot "$SDKROOT" "$SRC" -o "$OUT" >"$LOG" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    echo "[build_macos_utils ERROR] clang failed (exit $RC) compiling $SRC" >&2
    echo "[build_macos_utils ERROR]   clang=$CLANG" >&2
    echo "[build_macos_utils ERROR]   sdkroot=$SDKROOT" >&2
    echo "[build_macos_utils ERROR] --- compiler output ---" >&2
    cat "$LOG" >&2
    echo "[build_macos_utils ERROR] --- end compiler output ---" >&2
    die "Objective-C compilation of $SRC failed"
fi
[ -s "$LOG" ] && { echo "[build_macos_utils WARN] clang warnings for $SRC:" >&2; cat "$LOG" >&2; }

# --- T1: verify the artifact the linker will consume
[ -f "$OUT" ] || die "clang reported success but $OUT does not exist"
[ -s "$OUT" ] || die "$OUT exists but is empty (0 bytes)"

# --- Relink guard: gprbuild does NOT track external .o files (they are bare
# Linker switches, not sources), so `alr build` reports "up to date" even
# when this object changed → the running daemon could keep executing code
# diverged from macos_utils.m. On checksum change, remove the executable so
# gprbuild must relink now.
SUM=$(cksum "$OUT" | awk '{print $1" "$2}') || die "cksum failed on $OUT"
SUMFILE="$OUT_DIR/.macos_utils.o.sum"
OLDSUM=""
[ -f "$SUMFILE" ] && OLDSUM=$(cat "$SUMFILE" 2>/dev/null || true)
if [ "$SUM" != "$OLDSUM" ]; then
    echo "$SUM" > "$SUMFILE" || die "cannot write $SUMFILE"
    for exe in bin/murasamalmk_daemon; do
        if [ -f "$exe" ]; then
            rm -f "$exe" || die "cannot remove stale $exe (needed to force relink)"
            echo "[build_macos_utils] relink needed: removed $exe (object changed)"
        fi
    done
fi

echo "[build_macos_utils] OK: $OUT ($(wc -c <"$OUT" | tr -d ' ') bytes, profile=$PROFILE)"
exit 0
