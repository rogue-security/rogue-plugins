# tests/lib/bridge.sh — sourced by suites that run under tests/conformance.sh in both modes.
#
# In native mode (ROGUE_TEST_BRIDGE=native) the native bridge talks HTTP itself, so a suite that
# records requests with a fake `curl` points the bridge at tests/capture_server.py instead, which
# writes the same capture files. bridge_capture <cap-dir> <code> [calls-file] sets up one run and
# prints the base URL to use; in script mode it prints nothing and the fake curl does the work.
bridge_native() { [ "${ROGUE_TEST_BRIDGE:-script}" = native ]; }

BRIDGE_CTRL=""
BRIDGE_URL=""
bridge_start() {
  bridge_native || return 0
  BRIDGE_CTRL="$(mktemp -d)"
  _port=$((RANDOM % 10000 + 40000))
  python3 "$(dirname "${BASH_SOURCE[0]}")/../capture_server.py" "$_port" "$BRIDGE_CTRL" &
  BRIDGE_PID=$!
  for _ in $(seq 1 50); do nc -z 127.0.0.1 "$_port" 2>/dev/null && break; sleep 0.1; done
  BRIDGE_URL="http://127.0.0.1:$_port"
}

bridge_stop() {
  [ -n "${BRIDGE_PID:-}" ] && { kill "$BRIDGE_PID"; wait "$BRIDGE_PID"; } 2>/dev/null
  [ -n "$BRIDGE_CTRL" ] && rm -rf "$BRIDGE_CTRL"
  return 0
}

bridge_capture() { # <cap-dir> <code> [calls-file]
  bridge_native || return 0
  printf '%s' "$1" > "$BRIDGE_CTRL/cap"
  printf '%s' "${2:-200}" > "$BRIDGE_CTRL/code"
  printf '%s' "${3:-}" > "$BRIDGE_CTRL/calls"
  printf '%s' "$BRIDGE_URL"
}

# bridge_pin <dest-plugin-root> <plugin-dir-name> — for suites that run a copied plugin tree: in
# native mode, carry over the hand-off library and the pin tests/conformance.sh wrote, when it
# selected that family. Without a pin the copy stays on its script, as it would for a user.
bridge_pin() {
  bridge_native || return 0
  _pin="$(dirname "${BASH_SOURCE[0]}")/../../plugins/$2/rogue-hook.json"
  [ -f "$_pin" ] || return 0
  mkdir -p "$1/scripts"
  cp "$_pin" "$1/rogue-hook.json"
  cp "$(dirname "${BASH_SOURCE[0]}")/../../plugins/$2/scripts/native-bridge.sh" "$1/scripts/"
}
