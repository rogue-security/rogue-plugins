# tests/lib/bridge.sh — sourced by suites that run under tests/conformance.sh in both modes.
#
# In native mode (ROGUE_TEST_BRIDGE=native) the native bridge talks HTTP itself, so a suite that
# records requests with a fake `curl` points the bridge at tests/capture_server.py instead, which
# writes the same capture files. bridge_capture <cap-dir> <code> [calls-file] sets up one run and
# prints the base URL to use; in script mode it prints nothing and the fake curl does the work.
bridge_native() { [ "${ROGUE_TEST_BRIDGE:-script}" = native ]; }

BRIDGE_CTRL=""
BRIDGE_URL=""
# The server picks a free port and reports it once listening; a server that dies or stays silent
# stops the suite rather than letting it talk to whatever else holds a port.
bridge_start() {
  bridge_native || return 0
  BRIDGE_CTRL="$(mktemp -d)"
  python3 "$(dirname "${BASH_SOURCE[0]}")/../capture_server.py" 0 "$BRIDGE_CTRL" &
  BRIDGE_PID=$!
  for _ in $(seq 1 100); do
    [ -s "$BRIDGE_CTRL/port" ] && break
    kill -0 "$BRIDGE_PID" 2>/dev/null || break
    sleep 0.1
  done
  if [ ! -s "$BRIDGE_CTRL/port" ]; then
    if kill -0 "$BRIDGE_PID" 2>/dev/null; then
      echo "FAIL: capture server did not report its port within 10s" >&2
    else
      echo "FAIL: capture server exited before reporting its port" >&2
    fi
    bridge_stop
    exit 1
  fi
  BRIDGE_URL="http://127.0.0.1:$(cat "$BRIDGE_CTRL/port")"
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
