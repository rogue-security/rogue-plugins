#!/usr/bin/env sh
# Contract test for THE BEACON THROTTLE in plugins/rogue/scripts/heartbeat.sh.
#
# heartbeat.sh is fired from two triggers with very different rates: SessionStart
# (once per session) and Stop (once per TURN). The throttle is the only thing
# standing between the Stop trigger and a /hooks/status POST on every single turn
# of every session in a fleet, so every branch of it is pinned here.
#
# No network and no mock server: a stub `curl` on PATH records one line per call,
# which is exactly the observable that matters ("did the beacon go out"). HOME is
# redirected per case, so the developer's real ~/.rogue/beacon is never touched.
#
# Run under dash as well as bash: `sh tests/test_heartbeat_sh.sh`.

set -u
REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SH="${SH:-sh}"
FAILS=0
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/rogue-hbtest.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT
trap 'rm -rf "$TMPROOT"; exit 130' INT
trap 'rm -rf "$TMPROOT"; exit 143' TERM

pass() { echo "  ok: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected [$2], got [$3])"; fi; }

# A self-contained plugin tree with a stub curl. The stub appends to $SB_CALLS
# rather than making a request, so "how many beacons went out" is a line count.
HOME_SB="$TMPROOT/home"
ROOT="$TMPROOT/root"
mkdir -p "$TMPROOT/bin" "$ROOT/.claude-plugin" "$ROOT/scripts" "$HOME_SB"
# beacon.sh is copied in as well, because the throttle IS that file: heartbeat.sh
# sources scripts/beacon.sh (a byte-identical copy of scripts/shared/beacon.sh, shared
# with the other four sh plugins) and degrades to an unthrottled beacon when it is
# absent. So a tree without it does not test a weaker throttle - it tests no throttle,
# and every case below passes while asserting nothing. That is exactly what happened
# the first time this suite met the extracted library.
cp "$REPO/plugins/rogue/scripts/protection.sh" "$REPO/plugins/rogue/scripts/heartbeat.sh" \
   "$REPO/plugins/rogue/scripts/surface.sh" \
   "$REPO/plugins/rogue/scripts/beacon.sh" \
   "$REPO/plugins/rogue/scripts/env-file.sh" \
   "$REPO/plugins/rogue/scripts/actor.sh" "$ROOT/scripts/"
echo '{"version":"9.9.9"}' > "$ROOT/.claude-plugin/plugin.json"
printf '#!/bin/sh\ncase "$*" in *hooks/protection/*) exit 22 ;; esac\necho POST >> "$SB_CALLS"\nexit 0\n' > "$TMPROOT/bin/curl"
chmod +x "$TMPROOT/bin/curl"
echo 'export ROGUE_API_KEY=k' > "$HOME_SB/.rogue-env"

STAMP="$HOME_SB/.rogue/beacon/.last-claude"

# beacons <trigger> <interval-or-empty> → number of beacon POSTs that went out.
# `env` rather than an assignment prefix: the interval is often empty, and a
# `${x:+VAR=$x}` prefix is NOT treated as an assignment by every shell - it silently
# became a command argument under zsh while this suite was being written, which made
# two cases pass for the wrong reason.
beacons() {
  : > "$TMPROOT/calls"
  env SB_CALLS="$TMPROOT/calls" PATH="$TMPROOT/bin:$PATH" HOME="$HOME_SB" \
      CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_CODE_ENTRYPOINT=cli \
      ROGUE_HEARTBEAT_MIN_INTERVAL="$2" \
      "$SH" "$ROOT/scripts/heartbeat.sh" "$1" >/dev/null 2>&1
  wc -l < "$TMPROOT/calls" | tr -d ' '
}
set_stamp() { mkdir -p "${STAMP%/*}"; printf '%s\n' "$1" > "$STAMP"; }
clear_stamp() { rm -rf "${STAMP%/*}"; }

echo "── SessionStart is NEVER throttled ───────────────────────────────────"
# The existing trigger must behave exactly as it did before the throttle existed.
# A new session is precisely when the roster wants an update: a re-install with a
# new version, or the same user on a different surface, both arrive this way.
clear_stamp
check "fires with no stamp on disk" "1" "$(beacons SessionStart '')"
set_stamp "$(date -u +%s)"
check "fires again immediately, stamp notwithstanding" "1" "$(beacons SessionStart '')"

echo "── Stop IS throttled ─────────────────────────────────────────────────"
set_stamp "$(date -u +%s)"
check "skipped inside the window" "0" "$(beacons Stop '')"
set_stamp 0
check "fires once the window has elapsed" "1" "$(beacons Stop '')"
clear_stamp
check "fires when no stamp exists yet" "1" "$(beacons Stop '')"

echo "── the interval knob ─────────────────────────────────────────────────"
# Numeric zero disables the throttle, a non-numeric value falls back to the
# default. Same rule as ROGUE_LOG_MAX_BYTES and ROGUE_SHIP_MIN_INTERVAL - one
# convention across the repo. Zero on a Stop trigger really does mean a beacon per
# turn; that is the knob doing what it says, and the DEFAULT is the fleet's guard.
set_stamp "$(date -u +%s)"
check "zero disables the throttle" "1" "$(beacons Stop 0)"
set_stamp "$(date -u +%s)"
check "a padded zero counts as zero too" "1" "$(beacons Stop 000)"
set_stamp "$(date -u +%s)"
check "a non-numeric value falls back to the default" "0" "$(beacons Stop abc)"
set_stamp "$(date -u +%s)"
# dash answers `-lt` on a value wider than a signed 64-bit int with "Illegal
# number" on stderr and a FALSE - which reads as "not throttled" and would loose a
# beacon on every turn. The clamp is what stops that.
check "a value too wide for int64 falls back to the default" "0" \
  "$(beacons Stop 99999999999999999999999)"
set_stamp "$(date -u +%s)"
check "a small interval still throttles inside its window" "0" "$(beacons Stop 3600)"

echo "── a stamp we cannot trust never silences the beacon ─────────────────"
# Every unreadable or unparseable case must answer "not throttled". The failure
# mode being avoided is a corrupt stamp that quietly stops presence reporting for
# a machine - which looks identical to an uninstalled plugin on the roster.
set_stamp "not-a-number"
check "a corrupt stamp does not throttle" "1" "$(beacons Stop '')"
set_stamp 99999999999
check "a stamp in the FUTURE does not throttle" "1" "$(beacons Stop '')"
set_stamp ""
check "an empty stamp does not throttle" "1" "$(beacons Stop '')"

echo "── the stamp is written before the request ───────────────────────────"
# Crash-loop guard as much as a rate limit: a beacon that hangs or dies must still
# cost the next turn its attempt, rather than retrying on every single one.
clear_stamp
beacons Stop '' >/dev/null
check "a fired beacon leaves a stamp behind" "yes" \
  "$([ -s "$STAMP" ] && echo yes || echo no)"
stamp_is_integer() { # a `case` nested in a command substitution is a parse error
  case "$(cat "$STAMP" 2>/dev/null)" in ''|*[!0-9]*) echo no ;; *) echo yes ;; esac
}
check "the stamp holds an epoch-seconds integer" "yes" "$(stamp_is_integer)"
check "the stamp directory is owner-only" "700" \
  "$(ls -ld "${STAMP%/*}" | awk '{print substr($1,2,9)}' \
     | sed 's/rwx/7/;s/r-x/5/;s/---/0/g' | tr -d '-')"

echo "── the unconfigured and no-session paths still short-circuit ─────────"
clear_stamp
: > "$TMPROOT/calls"
# `env -u`, because this suite is very likely being run FROM a Claude Code session,
# whose own CLAUDE_CODE_ENTRYPOINT is inherited by every child. Without the unset
# the "no session" case silently tests the "session" path and passes for the wrong
# reason - which is exactly what it did on the first run.
env -u CLAUDE_CODE_ENTRYPOINT \
    SB_CALLS="$TMPROOT/calls" PATH="$TMPROOT/bin:$PATH" HOME="$HOME_SB" \
    CLAUDE_PLUGIN_ROOT="$ROOT" "$SH" "$ROOT/scripts/heartbeat.sh" Stop >/dev/null 2>&1
check "no CLAUDE_CODE_ENTRYPOINT means no beacon" "0" \
  "$(wc -l < "$TMPROOT/calls" | tr -d ' ')"
check "and it leaves no stamp, so the next real turn is not skipped" "no" \
  "$([ -e "$STAMP" ] && echo yes || echo no)"

echo "── a missing beacon library fails OPEN, not closed ───────────────────"
# The library is sourced under an `-r` guard and the fallback is an unthrottled
# beacon, which is the safe direction: a beacon too often is noise, while a beacon
# never again is a roster row indistinguishable from an uninstalled plugin. This
# covers a partial install and an older tree that predates the extraction.
mv "$ROOT/scripts/beacon.sh" "$TMPROOT/beacon.sh.hidden"
set_stamp "$(date -u +%s)"
check "no beacon.sh means the Stop beacon still fires" "1" "$(beacons Stop '')"
mv "$TMPROOT/beacon.sh.hidden" "$ROOT/scripts/beacon.sh"
set_stamp "$(date -u +%s)"
check "and restoring it throttles again" "0" "$(beacons Stop '')"

echo "── the shared library is byte-identical across the sh plugins ────────"
# The five copies are generated by scripts/sync-shared-scripts.sh. An edit made to a
# plugin's copy is silently reverted by the next sync, and a machine whose plugins
# disagree about the interval or the stamp path throttles inconsistently.
for p in codex cursor copilot antigravity kiro; do
  if cmp -s "$REPO/scripts/shared/beacon.sh" "$REPO/plugins/$p/scripts/beacon.sh"; then
    pass "plugins/$p/scripts/beacon.sh matches scripts/shared/beacon.sh"
  else
    fail "plugins/$p/scripts/beacon.sh differs - run scripts/sync-shared-scripts.sh"
  fi
done

echo "── every sh plugin wires the throttle the same way ───────────────────"
# One line each, per plugin, for the three things that make the throttle actually
# apply. Each was a real way to get this wrong while the code still looked finished:
# a heartbeat that never reads its trigger argument throttles nothing; one that never
# calls the library throttles nothing; and a slug typo gives that plugin its own
# stamp file, so it and its own log shipper disagree about which agent they are.
#
# The claude plugin is covered behaviourally above, so this checks the four that only
# have wiring coverage. Slugs match the LOG FILE names, not the roster families -
# codex ships codex.log under family openai.
check_wiring() { # <file> <needle> <label>
  if grep -q "$2" "$1"; then pass "$3"; else fail "$3"; fi
}
for row in "codex:codex:SessionStart" "copilot:copilot:sessionStart" \
           "antigravity:antigravity:SessionStart" "kiro:kiro:SessionStart"; do
  p="${row%%:*}"; rest="${row#*:}"; slug="${rest%%:*}"; sess="${rest#*:}"
  HB="$REPO/plugins/$p/scripts/heartbeat.sh"
  check_wiring "$HB" 'scripts/beacon.sh' "$p heartbeat.sh sources the beacon library"
  check_wiring "$HB" "rogue_beacon_claim $slug" "$p claims the slot as '$slug'"
  check_wiring "$HB" "\"\$TRIGGER\" = \"$sess\"" "$p treats $sess as unthrottled"
done
# Cursor has no heartbeat.sh at all - its beacon is inline in the dispatcher, which is
# also the only plugin where a throttled beacon is worth a log line (the decision
# happens where the log is being written).
CUR="$REPO/plugins/cursor/scripts/hook.sh"
check_wiring "$CUR" 'scripts/beacon.sh' "cursor hook.sh sources the beacon library"
check_wiring "$CUR" 'rogue_beacon_claim cursor' "cursor claims the slot as 'cursor'"
check_wiring "$CUR" 'heartbeat=throttled' "cursor logs a throttled beacon"

echo "── every plugin fires a per-turn trigger at all ──────────────────────"
# The whole point of this change: on a session-start-only trigger a session left open
# for days produced exactly one beacon and one log upload for its entire lifetime.
check_wiring "$REPO/plugins/codex/scripts/hook.sh" 'heartbeat.sh" Stop' \
  "codex hook.sh spawns the Stop heartbeat"
check_wiring "$REPO/plugins/copilot/scripts/hook.sh" 'heartbeat.sh" agentStop' \
  "copilot hook.sh spawns the agentStop heartbeat"
check_wiring "$REPO/plugins/antigravity/scripts/hook.sh" '_hb_trigger="Stop"' \
  "antigravity hook.sh maps Stop to the per-turn trigger"
check_wiring "$REPO/plugins/cursor/scripts/hook.sh" 'stop)         hb_unthrottled=0' \
  "cursor hook.sh treats stop as the per-turn trigger"
check_wiring "$REPO/plugins/gemini/scripts/hook.mjs" 'fireHeartbeat("AfterAgent")' \
  "gemini hook.mjs fires the AfterAgent heartbeat"
check_wiring "$REPO/plugins/kiro/scripts/hook.sh" 'heartbeat.sh" "$ROGUE_INSTALL_AGENT" "$EVENT"' \
  "kiro hook.sh spawns the heartbeat with the surface and the trigger"
check_wiring "$REPO/plugins/kiro/scripts/hook.sh" 'SessionStart|Stop)' \
  "kiro hook.sh spawns it on SessionStart and Stop only"

echo "── the kiro heartbeat reports family kiro and the surface it was given ──"
# The surface is an install-time argument (no Kiro payload names it), so the
# heartbeat body must carry exactly what hook.sh sends as x-rogue-agent, or the
# backend keys two roster rows for one install. The stub curl records its
# arguments so the POSTed body is a grep away; the beacon throttle is the shared
# library, exercised above, so one Stop-inside-the-window case is enough here.
KIRO_ROOT="$TMPROOT/kiro"
KIRO_HOME="$TMPROOT/kiro-home"
mkdir -p "$KIRO_ROOT/scripts" "$KIRO_HOME" "$TMPROOT/kiro-bin"
cp "$REPO/plugins/kiro/scripts/protection.sh" "$REPO/plugins/kiro/scripts/heartbeat.sh" "$REPO/plugins/kiro/scripts/beacon.sh" \
   "$REPO/plugins/kiro/scripts/actor.sh" "$REPO/plugins/kiro/scripts/install-id.sh" \
   "$REPO/plugins/kiro/scripts/kiro-host.sh" "$REPO/plugins/kiro/scripts/env-file.sh" "$KIRO_ROOT/scripts/"
echo '{"name":"rogue","version":"9.9.9"}' > "$KIRO_ROOT/plugin.json"
printf '#!/bin/sh\ncase "$*" in *hooks/protection/*) exit 22 ;; esac\nprintf "%%s\\n" "$*" >> "$SB_CALLS"\nexit 0\n' > "$TMPROOT/kiro-bin/curl"
chmod +x "$TMPROOT/kiro-bin/curl"
# kiro-cli 2.21.0's shape: `--version` prints "kiro-cli <X.Y.Z>", and
# `settings chat.defaultAgent` prints the value (quoted, as the real CLI does)
# or errors out when none is set. The IDE has no CLI: its version is the app
# bundle's Info.plist, pointed at through ROGUE_KIRO_APP so the suite never
# reads /Applications.
# Every call is recorded, so a throttled beacon can be shown to spawn none.
cat > "$TMPROOT/kiro-bin/kiro-cli" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "${KIRO_CLI_LOG:-/dev/null}"
case "$1 $2" in
  "--version ")                echo "kiro-cli 2.21.0" ;;
  "settings chat.defaultAgent") [ -n "${KIRO_FAKE_DEFAULT:-}" ] && { echo "\"$KIRO_FAKE_DEFAULT\""; exit 0; }
                               echo "error: No value associated with chat.defaultAgent" >&2; exit 1 ;;
esac
exit 0
STUB
chmod +x "$TMPROOT/kiro-bin/kiro-cli"
KIRO_APP="$TMPROOT/Kiro.app"
mkdir -p "$KIRO_APP/Contents"
cat > "$KIRO_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleVersion</key><string>26030401</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.437</string>
</dict></plist>
PLIST
echo 'export ROGUE_API_KEY=k' > "$KIRO_HOME/.rogue-env"
KIRO_STAMP="$KIRO_HOME/.rogue/beacon/.last-kiro"
# kiro_beacon <surface> <trigger> → the recorded curl arguments (one line per call)
# `env -u` scrubs the developer's own ROGUE_* (this suite is very likely run from a
# shell that exports a real key): only the temp HOME's env file may configure it.
kiro_beacon() {
  : > "$TMPROOT/kiro-calls"; : > "$TMPROOT/kiro-cli-calls"
  env -u ROGUE_API_KEY -u ROGUE_BASE_URL -u ROGUE_ACTOR_EMAIL -u ROGUE_ACTOR_NAME \
      SB_CALLS="$TMPROOT/kiro-calls" KIRO_CLI_LOG="$TMPROOT/kiro-cli-calls" \
      PATH="$TMPROOT/kiro-bin:$PATH" HOME="$KIRO_HOME" \
      ROGUE_KIRO_APP="${ROGUE_KIRO_APP:-$TMPROOT/no-app}" KIRO_FAKE_DEFAULT="${KIRO_FAKE_DEFAULT:-}" \
      "$SH" "$KIRO_ROOT/scripts/heartbeat.sh" "$1" "$2" >/dev/null 2>&1
  cat "$TMPROOT/kiro-calls"
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
out="$(kiro_beacon kiro_ide SessionStart)"
check "SessionStart posts /hooks/status" "yes" "$(has "$out" "/api/v1/hooks/status")"
check "the body names family kiro" "yes" "$(has "$out" '"agent_family":"kiro"')"
check "the body carries the surface argument" "yes" "$(has "$out" '"agent":"kiro_ide"')"
check "the version comes from plugin.json" "yes" "$(has "$out" '"version":"9.9.9"')"
check "no app bundle → agent_version unknown, never blank" "yes" "$(has "$out" '"agent_version":"unknown"')"
check "the stamp slug is kiro (the log file's name)" "yes" "$([ -s "$KIRO_STAMP" ] && echo yes || echo no)"
check "Stop inside the window is throttled" "" "$(kiro_beacon kiro_ide Stop)"
rm -rf "${KIRO_STAMP%/*}"
check "an unrecognised surface falls back to kiro_cli" "yes" "$(has "$(kiro_beacon bogus Stop)" '"agent":"kiro_cli"')"
rm -rf "${KIRO_STAMP%/*}"
echo "── the kiro heartbeat reports the host's own version and the CLI default ──"
# Two versions ride one row: `version` is the plugin's, `agent_version` is the
# Kiro build it runs under - the CLI from `kiro-cli --version`, the IDE from
# the app bundle - so support can tell a plugin that is current from a Kiro that
# is not. The CLI also reports which agent is the default: on the 2.x engine
# only agents carrying the Rogue hooks are covered, so a machine whose default
# moved away from `rogue` is a machine the roster should show as uncovered.
out="$(KIRO_FAKE_DEFAULT=rogue kiro_beacon kiro_cli SessionStart)"
check "kiro_cli reports agent_version from kiro-cli --version" "yes" "$(has "$out" '"agent_version":"2.21.0"')"
check "kiro_cli reports the default agent, unquoted" "yes" "$(has "$out" '"default_agent":"rogue"')"
check "SessionStart asks kiro-cli for its version" "yes" "$(has "$(cat "$TMPROOT/kiro-cli-calls")" '--version')"
# Throttled means throttled: the probes are kiro-cli processes, and a per-turn
# Stop inside the window must spawn none of them - the claim comes first.
check "a Stop inside the window makes no request" "" "$(KIRO_FAKE_DEFAULT=rogue kiro_beacon kiro_cli Stop)"
check "and asks Kiro nothing (no kiro-cli process)" "" "$(cat "$TMPROOT/kiro-cli-calls")"
rm -rf "${KIRO_STAMP%/*}"
out="$(kiro_beacon kiro_cli SessionStart)"
check "no default set → no default_agent field" "no" "$(has "$out" 'default_agent')"
rm -rf "${KIRO_STAMP%/*}"
out="$(ROGUE_KIRO_APP="$KIRO_APP" kiro_beacon kiro_ide SessionStart)"
check "kiro_ide reports agent_version from the app bundle's Info.plist" "yes" "$(has "$out" '"agent_version":"1.0.437"')"
check "the IDE reports no default agent (that is a CLI setting)" "no" "$(has "$out" 'default_agent')"
rm -rf "${KIRO_STAMP%/*}"
out="$(KIRO_FAKE_DEFAULT=rogue kiro_beacon kiro_crew SessionStart)"
check "kiro_crew reports the CLI version (Crew drives kiro-cli)" "yes" "$(has "$out" '"agent_version":"2.21.0"')"
check "kiro_crew reports no default agent" "no" "$(has "$out" 'default_agent')"
rm -f "$KIRO_HOME/.rogue-env"
check "unconfigured is a no-op" "" "$(kiro_beacon kiro_cli SessionStart)"

echo "── hooks.json registers the Stop trigger ─────────────────────────────"
HJ="$REPO/plugins/rogue/hooks/hooks.json"
# The argument is what makes the throttle apply: heartbeat.sh defaults to
# SessionStart, so a Stop entry that forgot to pass it would beacon every turn.
check "Stop spawns the heartbeat with the Stop argument" "1" \
  "$(grep -c 'heartbeat.sh\\" Stop' "$HJ")"
check "SessionStart still spawns it with no argument" "1" \
  "$(grep -c 'heartbeat.sh\\" >/dev/null' "$HJ")"
check "the Stop heartbeat is detached" "1" \
  "$(grep -c 'nohup sh \\"\$CLAUDE_PLUGIN_ROOT/scripts/heartbeat.sh\\" Stop' "$HJ")"

echo
if [ "$FAILS" = 0 ]; then echo "ALL HEARTBEAT SH TESTS PASSED"; else echo "$FAILS failure(s)"; fi
exit "$FAILS"
