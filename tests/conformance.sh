#!/usr/bin/env bash
# tests/conformance.sh — the bridge conformance suite: the process-level tests that hold a bridge
# to its contract (stdout, exit code, requests, files on disk), run against either bridge.
#
#   tests/conformance.sh                                   script bridges (what CI runs today)
#   tests/conformance.sh --native path/to/rogue-hook        the native bridge, every family
#   tests/conformance.sh --native BIN --family claude --family codex
#   tests/conformance.sh --native BIN --family codex --suite test_ship_logs.sh
#
# Native mode goes through the REAL hand-off: it installs BIN as the pinned version under a
# temporary ROGUE_NATIVE_BRIDGE_DIR and writes a temporary rogue-hook.json pin into each selected
# plugin that has none, so every script bridge of a selected family execs the binary exactly as it
# would on a user's machine. Unselected families keep no pin and stay on their scripts, which lets
# the cross-family suites run against a binary that serves only some families. A wrapper counts
# hand-offs; a native run with none fails, so it can never pass silently on the script path.
#
# The same cases and expectations run in both modes. A native-only difference must be written into
# the test it affects, keyed on ROGUE_TEST_BRIDGE=native, with the reason.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE_BIN=""
FAMILIES=()
ONLY=()
while [ $# -gt 0 ]; do
  case "$1" in
    --native) NATIVE_BIN="$2"; shift 2 ;;
    --family) FAMILIES+=("$2"); shift 2 ;;
    --suite) ONLY+=("$2"); shift 2 ;;
    *) echo "usage: $0 [--native BIN] [--family F]... [--suite FILE]..." >&2; exit 2 ;;
  esac
done
[ ${#FAMILIES[@]} -gt 0 ] || FAMILIES=(claude codex cursor copilot gemini antigravity kiro muse)

# family -> plugin directory and the suites that exercise it.
plugin_dir() { case "$1" in claude) echo rogue ;; *) echo "$1" ;; esac; }
suites() {
  case "$1" in
    claude) echo "test_hook_sh.sh test_heartbeat_sh.sh" ;;
    cursor) echo "test_hook_sh_cursor.sh" ;;
    copilot) echo "test_hook_sh_copilot.sh" ;;
    kiro) echo "test_hook_sh_kiro.sh test_heartbeat_sh.sh test_status_kiro_sh.sh" ;;
    antigravity) echo "test_hook_sh_antigravity.sh" ;;
    muse) echo "test_muse_sh.sh" ;;
    gemini) echo "test_hook_mjs.mjs" ;;
    codex) echo "test_hook_sh_codex.sh" ;;
  esac
}
SHARED_SUITES="test_hook_logs.sh test_ship_logs.sh"

PINNED=()
WORK=""
cleanup() {
  for p in ${PINNED[@]+"${PINNED[@]}"}; do rm -f "$p"; done
  [ -n "$WORK" ] && rm -rf "$WORK"
}
trap cleanup EXIT

if [ -n "$NATIVE_BIN" ]; then
  [ -x "$NATIVE_BIN" ] || { echo "not executable: $NATIVE_BIN" >&2; exit 2; }
  NATIVE_BIN="$(cd "$(dirname "$NATIVE_BIN")" && pwd)/$(basename "$NATIVE_BIN")"
  WORK="$(mktemp -d)"
  export ROGUE_NATIVE_BRIDGE_DIR="$WORK/bin"
  export ROGUE_TEST_BRIDGE=native
  COUNTER="$WORK/handoffs"
  : > "$COUNTER"
  for f in "${FAMILIES[@]}"; do
    pin="$REPO/plugins/$(plugin_dir "$f")/rogue-hook.json"
    if [ -f "$pin" ]; then
      ver="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$pin" | head -n 1)"
    else
      ver="0.0.0-conformance"
      printf '{\n  "version": "%s",\n  "sha256": {}\n}\n' "$ver" > "$pin"
      PINNED+=("$pin")
    fi
    if [ ! -e "$ROGUE_NATIVE_BRIDGE_DIR/$ver/rogue-hook" ]; then
      mkdir -p "$ROGUE_NATIVE_BRIDGE_DIR/$ver"
      printf '#!/bin/sh\necho "$*" >> "%s"\nexec "%s" "$@"\n' "$COUNTER" "$NATIVE_BIN" \
        > "$ROGUE_NATIVE_BRIDGE_DIR/$ver/rogue-hook"
      chmod 755 "$ROGUE_NATIVE_BRIDGE_DIR/$ver/rogue-hook"
    fi
  done
  echo "native bridge: $("$NATIVE_BIN" --version) for: ${FAMILIES[*]}"
else
  export ROGUE_TEST_BRIDGE=script
fi

RUN=()
for f in "${FAMILIES[@]}"; do for s in $(suites "$f"); do RUN+=("$s"); done; done
for s in $SHARED_SUITES; do RUN+=("$s"); done
[ ${#ONLY[@]} -eq 0 ] || RUN=("${ONLY[@]}")

failed=()
for s in $(printf '%s\n' "${RUN[@]}" | awk '!seen[$0]++'); do
  echo "=== $s"
  case "$s" in
    *.mjs) node --test "$REPO/tests/$s" ;;
    *) bash "$REPO/tests/$s" ;;
  esac || failed+=("$s")
done

if [ -n "$NATIVE_BIN" ]; then
  n="$(wc -l < "$COUNTER" | tr -d ' ')"
  echo "native hand-offs: $n"
  [ "$n" -gt 0 ] || failed+=("no hand-off reached the native bridge")
fi
if [ ${#failed[@]} -gt 0 ]; then
  printf 'FAIL: %s\n' "${failed[@]}"
  exit 1
fi
echo "OK: conformance (${ROGUE_TEST_BRIDGE})"
