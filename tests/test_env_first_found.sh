#!/usr/bin/env bash
# tests/test_env_first_found.sh — the env file rule on every sh reader: the first
# of machine (/etc/rogue/env) -> bundled (<root>/env) -> user (~/.rogue-env) that
# holds ROGUE_API_KEY is used ALONE, and its values override the process env.
#
# Each plugin runs from a COPY whose /etc/rogue/env literal is redirected into the
# sandbox (the only way to stage the machine candidate without root), with a fake
# curl on PATH that records the request instead of sending it. env-file.sh is left
# untouched on purpose: its /etc/rogue/env case is the root-owner rule, not a read.
#
#   TEST_SH=dash bash tests/test_env_first_found.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SH="${TEST_SH:-sh}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0
check() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok: $1"
  else echo "FAIL: $1 (expected [$2], got [$3])"; fails=$((fails + 1)); fi
}

MACHINE="$T/machine-env"
mkdir -p "$T/bin" "$T/plugins"
cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
# Records every -H header and every URL to $CURL_CAP; answers like an empty 200.
prev=""
for a in "$@"; do
  case "$prev" in -H) printf 'H %s\n' "$a" >> "$CURL_CAP" ;; esac
  case "$a" in http://*|https://*) printf 'U %s\n' "$a" >> "$CURL_CAP" ;; esac
  prev="$a"
done
printf '{}\n200'
EOF
chmod +x "$T/bin/curl"

for p in rogue codex cursor copilot antigravity kiro; do
  cp -R "$REPO/plugins/$p" "$T/plugins/$p"
  rm -f "$T/plugins/$p/env"
  for f in "$T/plugins/$p"/scripts/*.sh; do
    case "$f" in */env-file.sh) continue ;; esac
    sed "s#/etc/rogue/env#$MACHINE#g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
done
[ "$(grep -l "$MACHINE" "$T"/plugins/*/scripts/hook.sh | wc -l | tr -d ' ')" = 6 ] \
  || { echo "FAIL: the machine path was not redirected in every hook.sh"; exit 1; }

envf() { # <path> <line>... — mode 600 so the trusted readers (kiro, shipper) accept it
  _p="$1"; shift
  printf '%s\n' "$@" > "$_p"
  chmod 600 "$_p"
}

# run <reader> <home> [VAR=value ...] — the request lands in $CAP.
run() {
  _reader="$1"; _home="$2"; shift 2
  CAP="$T/cap.$_reader.$RANDOM"; : > "$CAP"
  ( cd "$T" || exit 1
    export HOME="$_home" PATH="$T/bin:$PATH" CURL_CAP="$CAP"
    export ROGUE_API_KEY='' ROGUE_BASE_URL='' ROGUE_ACTOR_EMAIL='amos@example.com' ROGUE_ACTOR_NAME=''
    export ROGUE_LOG_FILE='' ROGUE_LOG_DIR='' ROGUE_SHIP_MIN_INTERVAL=0
    for kv in "$@"; do export "${kv?}"; done
    case "$_reader" in
      rogue-hook)   CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$T/plugins/rogue" \
                      "$SH" plugins/rogue/scripts/hook.sh PreToolUse ;;
      codex-hook)   PLUGIN_ROOT="$T/plugins/codex" "$SH" plugins/codex/scripts/hook.sh PreToolUse ;;
      cursor-hook)  CURSOR_PLUGIN_ROOT="$T/plugins/cursor" "$SH" plugins/cursor/scripts/hook.sh preToolUse ;;
      copilot-hook) "$SH" plugins/copilot/scripts/hook.sh preToolUse ;;
      antigravity-hook) "$SH" plugins/antigravity/scripts/hook.sh PreToolUse ;;
      kiro-hook)    "$SH" plugins/kiro/scripts/hook.sh PreToolUse kiro_cli ;;
      rogue-heartbeat)   CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$T/plugins/rogue" \
                           "$SH" plugins/rogue/scripts/heartbeat.sh SessionStart ;;
      codex-heartbeat)   PLUGIN_ROOT="$T/plugins/codex" "$SH" plugins/codex/scripts/heartbeat.sh SessionStart ;;
      copilot-heartbeat) "$SH" plugins/copilot/scripts/heartbeat.sh sessionStart ;;
      antigravity-heartbeat) "$SH" plugins/antigravity/scripts/heartbeat.sh antigravity_ide SessionStart ;;
      kiro-heartbeat)    "$SH" plugins/kiro/scripts/heartbeat.sh kiro_cli SessionStart ;;
      ship-logs)    "$SH" plugins/rogue/scripts/ship-logs.sh "$T/plugins/rogue" claude 9.9.9 claude ;;
    esac < "$PAYLOAD" > /dev/null 2>&1 ) || :
}
key_sent()  { sed -n 's/^H x-rogue-api-key: //p' "$CAP" | head -1; }
host_sent() { sed -n 's#^U \(https\{0,1\}://[^/]*\).*#\1#p' "$CAP" | head -1; }

plugin_of() { case "$1" in ship-logs) echo rogue ;; *) echo "${1%%-*}" ;; esac; }

new_home() { # <name> — a HOME with the log the shipper drains
  _h="$T/home-$1"; rm -rf "$_h"; mkdir -p "$_h/.rogue/logs"
  echo "2026-01-01T00:00:00Z provider=claude event=PreToolUse" > "$_h/.rogue/logs/claude.log"
  printf '%s' "$_h"
}

READERS='rogue-hook codex-hook cursor-hook copilot-hook antigravity-hook kiro-hook
rogue-heartbeat codex-heartbeat copilot-heartbeat antigravity-heartbeat kiro-heartbeat
ship-logs'

for reader in $READERS; do
  p="$(plugin_of "$reader")"
  bundled="$T/plugins/$p/env"
  case "$reader" in
    kiro-hook) PAYLOAD="$REPO/tests/fixtures/kiro/cli3-PreToolUse-execute_bash.json" ;;
    *)         PAYLOAD=/dev/null; [ -f "$T/empty.json" ] || printf '{}' > "$T/empty.json"; PAYLOAD="$T/empty.json" ;;
  esac
  echo "== $reader ($SH)"

  # All three files carry a key: the machine file alone configures the reader, and
  # the user file's base URL has no effect.
  home="$(new_home "$reader-a")"
  envf "$MACHINE" 'export ROGUE_API_KEY=machine-key' 'export ROGUE_BASE_URL=http://machine.invalid'
  envf "$bundled" 'export ROGUE_API_KEY=bundled-key' 'export ROGUE_BASE_URL=http://bundled.invalid'
  envf "$home/.rogue-env" 'export ROGUE_API_KEY=user-key' 'export ROGUE_BASE_URL=http://user.invalid'
  run "$reader" "$home" ROGUE_API_KEY=process-key
  check "$reader: machine file wins with all three present" "machine-key" "$(key_sent)"
  check "$reader: nothing merged from the user file"        "http://machine.invalid" "$(host_sent)"

  # A machine file without ROGUE_API_KEY is skipped whole; the bundled file is next.
  home="$(new_home "$reader-b")"
  envf "$MACHINE" 'export ROGUE_BASE_URL=http://machine.invalid'
  envf "$bundled" 'export ROGUE_API_KEY=bundled-key' 'export ROGUE_BASE_URL=http://bundled.invalid'
  envf "$home/.rogue-env" 'export ROGUE_API_KEY=user-key' 'export ROGUE_BASE_URL=http://user.invalid'
  run "$reader" "$home"
  check "$reader: keyless machine file is skipped"           "bundled-key" "$(key_sent)"
  check "$reader: ...and contributes nothing"                "http://bundled.invalid" "$(host_sent)"

  # An empty ROGUE_API_KEY, quoted or bare, does not select the file (the ps1 and
  # mjs readers parse the value; the sh gate must agree with them).
  home="$(new_home "$reader-e")"
  envf "$MACHINE" "export ROGUE_API_KEY=''" 'export ROGUE_BASE_URL=http://machine.invalid'
  envf "$bundled" 'ROGUE_API_KEY=' 'export ROGUE_BASE_URL=http://bundled.invalid'
  envf "$home/.rogue-env" 'export ROGUE_API_KEY=user-key' 'export ROGUE_BASE_URL=http://user.invalid'
  run "$reader" "$home"
  check "$reader: an empty key line does not select the file"  "user-key" "$(key_sent)"
  check "$reader: ...and contributes nothing either"          "http://user.invalid" "$(host_sent)"

  # The chosen file overrides the process env; keys it does not set are kept.
  home="$(new_home "$reader-c")"
  rm -f "$MACHINE" "$bundled"
  envf "$home/.rogue-env" 'export ROGUE_API_KEY=user-key'
  run "$reader" "$home" ROGUE_API_KEY=process-key ROGUE_BASE_URL=http://process.invalid
  check "$reader: the chosen file overrides the process env" "user-key" "$(key_sent)"
  check "$reader: process env kept for keys the file lacks"  "http://process.invalid" "$(host_sent)"

  # No file holds a key: the process env is what remains.
  home="$(new_home "$reader-d")"
  rm -f "$MACHINE" "$bundled"
  run "$reader" "$home" ROGUE_API_KEY=process-key ROGUE_BASE_URL=http://process.invalid
  check "$reader: process env alone still configures"        "process-key" "$(key_sent)"
done

echo "== statusline ($SH)"
home="$(new_home statusline)"
envf "$MACHINE" 'export ROGUE_BASE_URL=http://machine.invalid'
envf "$home/.rogue-env" 'export ROGUE_API_KEY=user-key'
out="$(HOME="$home" ROGUE_API_KEY='' "$SH" "$T/plugins/rogue/scripts/statusline.sh")"
case "$out" in *🟢*) got=green ;; *) got=other ;; esac
check "statusline: keyless machine file falls through to the user key" green "$got"
envf "$MACHINE" 'export ROGUE_API_KEY=""'
out="$(HOME="$home" ROGUE_API_KEY='' "$SH" "$T/plugins/rogue/scripts/statusline.sh")"
case "$out" in *🟢*) got=green ;; *) got=other ;; esac
check "statusline: an empty machine key falls through to the user key" green "$got"
rm -f "$home/.rogue-env"
out="$(HOME="$home" ROGUE_API_KEY='' "$SH" "$T/plugins/rogue/scripts/statusline.sh")"
case "$out" in *🔴*) got=red ;; *) got=other ;; esac
check "statusline: a keyless machine file alone is unconfigured" red "$got"

[ "$fails" = 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all env-file first-found checks passed"
