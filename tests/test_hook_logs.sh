#!/usr/bin/env sh
# Cross-plugin contract test for THE HOOK LOG (see CLAUDE.md § "The hook log").
#
# One file per agent under ~/.rogue/logs/, one shared line format, one rotation
# policy — across all six dispatchers. This suite exists because that contract is
# duplicated six times (the repo has no shared library) and a copy/paste drift in
# any one of them is invisible until someone reads a customer's log.
#
# Everything here runs on the UNCONFIGURED path (ROGUE_API_KEY empty), so no mock
# server and no network are needed: a dispatcher with no key still logs
# `outcome=unconfigured` and fails open. HOME is redirected per case so the
# developer's real ~/.rogue is never touched.
#
# Run under dash as well as bash: `sh tests/test_hook_logs.sh`.
# Set SH=dash to force a specific shell for the dispatchers under test.

set -u
REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SH="${SH:-sh}"
FAILS=0
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/rogue-logtest.XXXXXX")"
# Split, not one trap for all three: a bare `trap 'rm -rf …' INT` runs the handler
# and then CONTINUES with the next statement, so a Ctrl-C would delete the fixtures
# and let every remaining case run against them.
trap 'rm -rf "$TMPROOT"' EXIT
trap 'rm -rf "$TMPROOT"; exit 130' INT
trap 'rm -rf "$TMPROOT"; exit 143' TERM

pass() { echo "  ok: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected [$2], got [$3])"; fi
}

# ── the six dispatchers ────────────────────────────────────────────────────
# Each row: slug | event name | invocation (run with cwd=$REPO, env prefixed).
# Keep the event names in each agent's own casing — the log line echoes them
# verbatim, and a case slip is exactly the kind of drift this suite catches.
dispatch() { # dispatch <slug> <event>  → runs the dispatcher for <slug>
  case "$1" in
    claude)
      CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$REPO/plugins/rogue" \
        "$SH" "$REPO/plugins/rogue/scripts/hook.sh" "$2" ;;
    codex)
      PLUGIN_ROOT="$REPO/plugins/codex" \
        "$SH" "$REPO/plugins/codex/scripts/hook.sh" "$2" ;;
    cursor)
      CURSOR_PLUGIN_ROOT="$REPO/plugins/cursor" \
        "$SH" "$REPO/plugins/cursor/scripts/hook.sh" "$2" ;;
    copilot)
      PLUGIN_ROOT="$REPO/plugins/copilot" \
        "$SH" "$REPO/plugins/copilot/scripts/hook.sh" "$2" ;;
    antigravity)
      PLUGIN_ROOT="$REPO/plugins/antigravity" \
        "$SH" "$REPO/plugins/antigravity/scripts/hook.sh" "$2" ;;
    gemini)
      node "$REPO/plugins/gemini/scripts/hook.mjs" "$2" ;;
    kiro)
      # The surface is an install-time argument, not detected: the hook file
      # names it after the event.
      "$SH" "$REPO/plugins/kiro/scripts/hook.sh" "$2" kiro_cli ;;
  esac
}

event_for() { # the dispatchers' own casing for a pre-tool event
  case "$1" in
    claude|antigravity) echo PreToolUse ;;
    codex|kiro)         echo PreToolUse ;;
    cursor|copilot)     echo preToolUse ;;
    gemini)             echo BeforeTool ;;
  esac
}

SLUGS='claude codex cursor copilot antigravity gemini kiro'

# `gemini` needs node; skip it (loudly) rather than failing the suite on a box
# without it — every other dispatcher is pure sh + curl.
if ! command -v node >/dev/null 2>&1; then
  echo "NOTE: node not found — skipping the gemini dispatcher"
  SLUGS='claude codex cursor copilot antigravity kiro'
fi

# fire <slug> <home> [VAR=value ...] — run the dispatcher in an isolated HOME.
# ROGUE_LOG_FILE / ROGUE_LOG_DIR / ROGUE_LOG_MAX_BYTES are blanked unless a caller
# overrides them, so a value exported in the developer's own shell can't leak in
# and mask a default-path regression.
fire() {
  _slug=$1; _home=$2; shift 2
  ( cd "$REPO" || exit 1
    export HOME="$_home" ROGUE_API_KEY='' ROGUE_LOG_FILE='' ROGUE_LOG_DIR='' ROGUE_LOG_MAX_BYTES=''
    for _kv in "$@"; do export "${_kv?}"; done
    printf '{}' | dispatch "$_slug" "$(event_for "$_slug")" >/dev/null 2>&1 )
}

# What landed under <home>, as a sorted space-separated list of relative paths.
tree_of() { find "$1" -type f 2>/dev/null | sed "s|^$1||" | sort | tr '\n' ' '; }

echo "== default path: one file per agent under ~/.rogue/logs/"
for slug in $SLUGS; do
  home="$TMPROOT/default-$slug"; mkdir -p "$home"
  fire "$slug" "$home"
  check "$slug writes only ~/.rogue/logs/$slug.log" "/.rogue/logs/$slug.log " "$(tree_of "$home")"
done

# The surface each dispatcher stamps on an UNCONFIGURED probe, i.e. with the
# harness's own environment. Empty means "no token on that line", which is a real
# expected value and not a gap:
#   claude  - CLAUDE_CODE_ENTRYPOINT is set by `fire` below, as the real client does
#   codex   - ROGUE_CODEX_SURFACE unset defaults to codex_cli, matching heartbeat.sh
#   cursor / copilot / gemini - single-surface plugins, so a constant
#   kiro    - the surface argument the hook file was written with (kiro_cli here)
#   antigravity - resolved from the payload's transcriptPath, and the unconfigured
#     path exits BEFORE stdin is read, so there is nothing to resolve from. The
#     token is optional precisely so this line can simply omit it.
surface_for() {
  case "$1" in
    claude)      echo cli ;;
    codex)       echo codex_cli ;;
    cursor)      echo cursor ;;
    copilot)     echo github_copilot ;;
    gemini)      echo gemini_cli ;;
    kiro)        echo kiro_cli ;;
    antigravity) echo '' ;;
  esac
}

echo
echo "== line format: '<ts> provider=<slug> [surface=<slug>] event=<Event> …'"
for slug in $SLUGS; do
  home="$TMPROOT/fmt-$slug"; mkdir -p "$home"
  ev=$(event_for "$slug")
  sf=$(surface_for "$slug")
  fire "$slug" "$home"
  line=$(cat "$home/.rogue/logs/$slug.log" 2>/dev/null)
  # Timestamp must be a UTC ISO-8601 second-precision stamp, no fractional part:
  # the shipper's line splitter and the backend's parser both key off it. The
  # surface token sits directly after provider= and before event=, so a reader
  # scanning for the next `key=` finds the whole value.
  case "$line" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z" provider=$slug${sf:+ surface=$sf} event=$ev "*)
      pass "$slug line is '<ts> provider=$slug${sf:+ surface=$sf} event=$ev …'" ;;
    *)
      fail "$slug line shape [$line]" ;;
  esac
  # An undetermined surface omits the WHOLE token. `surface=` with nothing after
  # it, or `surface=unknown`, would both be worse than saying nothing - a reader
  # cannot tell either from a real value.
  case "$line" in
    *"surface="*)
      if [ -n "$sf" ]; then pass "$slug stamped surface=$sf"
      else fail "$slug emitted a surface token with no surface to report [$line]"; fi ;;
    *)
      if [ -n "$sf" ]; then fail "$slug lost its surface token [$line]"
      else pass "$slug omits the token when the surface is unknown"; fi ;;
  esac
  case "$line" in
    *surface=unknown*|*"surface= "*) fail "$slug wrote a placeholder surface [$line]" ;;
    *) pass "$slug never writes a placeholder surface" ;;
  esac
  case "$line" in
    *outcome=unconfigured*) pass "$slug logs outcome=unconfigured with no API key" ;;
    *) fail "$slug missing outcome=unconfigured [$line]" ;;
  esac
done

echo
echo "== the surface token tracks the SURFACE, not the plugin"
# claude is the only plugin whose surface varies per session, and all three of its
# surfaces write to the SAME claude.log - which is the entire reason the token
# exists. The mapping is shared with heartbeat.sh (plugins/rogue/scripts/surface.sh),
# so these slugs and the roster labels cannot drift apart.
# Indexed, not named after the entrypoint: macOS is case-insensitive, so `cli` and
# `CLI` would share one sandbox and the second case would read the first's line.
_sfi=0
for pair in 'cli:cli' 'desktop:desktop' 'cowork:cowork' 'vscode-extension:cli' 'CLI:cli'; do
  ep=${pair%%:*}; want=${pair#*:}
  _sfi=$((_sfi + 1))
  home="$TMPROOT/sf-$_sfi"; mkdir -p "$home"
  ( cd "$REPO" || exit 1
    export HOME="$home" ROGUE_API_KEY='' ROGUE_LOG_FILE='' ROGUE_LOG_DIR='' ROGUE_LOG_MAX_BYTES=''
    export CLAUDE_CODE_ENTRYPOINT="$ep" CLAUDE_PLUGIN_ROOT="$REPO/plugins/rogue"
    printf '{}' | "$SH" "$REPO/plugins/rogue/scripts/hook.sh" PreToolUse >/dev/null 2>&1 )
  got=$(sed -n 's/.*provider=claude surface=\([a-z_]*\) event=.*/\1/p' "$home/.rogue/logs/claude.log" 2>/dev/null)
  check "CLAUDE_CODE_ENTRYPOINT=$ep stamps surface=$want" "$want" "$got"
done

# The heartbeat's roster label for the same entrypoint, from the same table. If
# these two ever disagree, a log line and the roster row for one session name
# different surfaces - worse than the line naming none.
for pair in 'cli:Claude Code - CLI' 'desktop:Claude Code - Desktop' 'cowork:Claude Cowork'; do
  ep=${pair%%:*}; want=${pair#*:}
  got=$(CLAUDE_CODE_ENTRYPOINT="$ep" "$SH" -c '. "$1"; rogue_surface_label' _ "$REPO/plugins/rogue/scripts/surface.sh" 2>/dev/null)
  check "...and heartbeat reports \"$want\" for it" "$want" "$got"
done

# The AGENT ID projection - the roster's `agent` and the x-rogue-agent header, and
# the THIRD consumer of this one table. It must be a stable snake_case id, never a
# display label: the id doubles as the backend's PLUGIN_REPOS key, so a label there
# resolves no latest version and every row reads as up to date.
for pair in 'cli:claude_code' 'desktop:claude_code_desktop' 'cowork:claude_cowork' ':claude_code'; do
  ep=${pair%%:*}; want=${pair#*:}
  got=$(CLAUDE_CODE_ENTRYPOINT="$ep" "$SH" -c '. "$1"; rogue_surface_agent_id' _ "$REPO/plugins/rogue/scripts/surface.sh" 2>/dev/null)
  check "...and the roster agent id for \"${ep:-(unset)}\" is $want" "$want" "$got"
done

# CLAUDE_CODE_IS_COWORK wins over the entrypoint, in ALL THREE projections.
# Cowork spawns Claude Code with CLAUDE_CODE_ENTRYPOINT=local-agent - NOT a *cowork*
# value - so matching the entrypoint alone files every LOCAL Cowork session under the
# CLI. That misfiling is what put Cowork installs in the wrong roster row, and it is
# also what would stop the Cowork-only block modal firing (see hook.sh's
# _rogue_want_alert, which gates on the agent id).
for fn_want in 'rogue_surface_slug:cowork' 'rogue_surface_agent_id:claude_cowork' 'rogue_surface_label:Claude Cowork'; do
  fn=${fn_want%%:*}; want=${fn_want#*:}
  got=$(CLAUDE_CODE_IS_COWORK=1 CLAUDE_CODE_ENTRYPOINT=local-agent \
    "$SH" -c ". \"\$1\"; $fn" _ "$REPO/plugins/rogue/scripts/surface.sh" 2>/dev/null)
  check "IS_COWORK=1 + entrypoint=local-agent -> $fn = $want" "$want" "$got"
done
# ...and without it, the same entrypoint is just the CLI - the arm only triggers on
# the explicit Cowork marker, never on any local-agent-ish entrypoint.
got=$(CLAUDE_CODE_ENTRYPOINT=local-agent "$SH" -c '. "$1"; rogue_surface_agent_id' _ "$REPO/plugins/rogue/scripts/surface.sh" 2>/dev/null)
check "entrypoint=local-agent WITHOUT the marker is claude_code" "claude_code" "$got"

echo
echo "== ROGUE_LOG_DIR relocates, keeping the per-agent basename"
for slug in $SLUGS; do
  home="$TMPROOT/dir-$slug"; mkdir -p "$home"
  fire "$slug" "$home" "ROGUE_LOG_DIR=$home/custom"
  check "$slug honors ROGUE_LOG_DIR" "/custom/$slug.log " "$(tree_of "$home")"
done

echo
echo "== ROGUE_LOG_FILE (exact path) beats ROGUE_LOG_DIR"
for slug in $SLUGS; do
  home="$TMPROOT/file-$slug"; mkdir -p "$home"
  fire "$slug" "$home" "ROGUE_LOG_FILE=$home/exact.log" "ROGUE_LOG_DIR=$home/custom"
  check "$slug honors ROGUE_LOG_FILE over ROGUE_LOG_DIR" "/exact.log " "$(tree_of "$home")"
done

echo
echo "== rotation at ROGUE_LOG_MAX_BYTES"
for slug in $SLUGS; do
  home="$TMPROOT/rot-$slug"; mkdir -p "$home/.rogue/logs"
  logf="$home/.rogue/logs/$slug.log"
  # 30 lines x ~12 bytes = ~350B, comfortably over the 100B cap below. (An
  # earlier version of this test seeded 99 bytes against a 100 byte cap and
  # "failed" — the boundary is `>=`, so keep the seed clearly above it.)
  i=0; while [ "$i" -lt 30 ]; do echo "OLD-LINE-$i" >> "$logf"; i=$((i + 1)); done
  fire "$slug" "$home" "ROGUE_LOG_MAX_BYTES=100"
  cur=$(wc -l < "$logf" 2>/dev/null | tr -d '[:space:]')
  old=$(wc -l < "$logf.1" 2>/dev/null | tr -d '[:space:]')
  check "$slug rotated the old log to $slug.log.1" "30" "${old:-missing}"
  check "$slug started a fresh $slug.log" "1" "${cur:-missing}"
done

echo
echo "== ROGUE_LOG_MAX_BYTES=0 disables rotation"
for slug in $SLUGS; do
  home="$TMPROOT/norot-$slug"; mkdir -p "$home/.rogue/logs"
  logf="$home/.rogue/logs/$slug.log"
  i=0; while [ "$i" -lt 30 ]; do echo "OLD-LINE-$i" >> "$logf"; i=$((i + 1)); done
  fire "$slug" "$home" "ROGUE_LOG_MAX_BYTES=0"
  cur=$(wc -l < "$logf" 2>/dev/null | tr -d '[:space:]')
  rotated=$([ -e "$logf.1" ] && echo yes || echo no)
  check "$slug appended instead of rotating" "31" "${cur:-missing}"
  check "$slug created no $slug.log.1" "no" "$rotated"
done

echo
echo "== ~/.rogue-env can relocate the log (env FILE, not just process env)"
# Only the env file holding ROGUE_API_KEY is read, so the case stages one (with a
# dead local base URL, so the configured dispatcher POSTs nowhere real), and every
# dispatcher resolves its log destination AFTER reading that file. The
# process-env cases above cannot catch a dispatcher that reads its own environment
# too early: `plugins/gemini/scripts/hook.mjs` did exactly that (module-level
# consts, while loadEnvFiles() runs later and returns a merged object WITHOUT
# mutating process.env), so ~/.rogue-env was silently ignored there.
for slug in $SLUGS; do
  home="$TMPROOT/envfile-$slug"; mkdir -p "$home/custom"
  printf 'export ROGUE_API_KEY=k\nexport ROGUE_BASE_URL=http://127.0.0.1:1\nexport ROGUE_LOG_DIR=%s\n' \
    "$home/custom" > "$home/.rogue-env"
  chmod 600 "$home/.rogue-env"
  fire "$slug" "$home"
  got=$(find "$home" -name '*.log' 2>/dev/null | sed "s|^$home||" | sort | tr '\n' ' ')
  check "$slug honors ROGUE_LOG_DIR from ~/.rogue-env" "/custom/$slug.log " "$got"
done

echo
echo "== a zero-padded zero cap (00) disables rotation, like 0"
# sh compares with `-ge`, so a `case` glob that only matched a bare "0" left "00"
# looking like a positive number and rotated on EVERY write. PowerShell's
# [int64]'00' and Node's Number("00") are both 0, so all three must agree.
for slug in $SLUGS; do
  home="$TMPROOT/cap00-$slug"; mkdir -p "$home/.rogue/logs"
  logf="$home/.rogue/logs/$slug.log"
  i=0; while [ "$i" -lt 30 ]; do echo "OLD-LINE-$i" >> "$logf"; i=$((i + 1)); done
  fire "$slug" "$home" "ROGUE_LOG_MAX_BYTES=00"
  rotated=$([ -e "$logf.1" ] && echo yes || echo no)
  check "$slug treats 00 as rotation-disabled" "no" "$rotated"
  check "$slug appended instead of rotating" "31" "$(wc -l < "$logf" 2>/dev/null | tr -d '[:space:]')"
done

echo
echo "== a non-numeric cap falls back to the default, it does NOT disable"
# A typo must never leave the log growing unbounded. Seed just over the 10 MiB
# default so "fell back to the default" is distinguishable from "disabled".
for slug in $SLUGS; do
  home="$TMPROOT/capbad-$slug"; mkdir -p "$home/.rogue/logs"
  logf="$home/.rogue/logs/$slug.log"
  head -c 10485761 /dev/zero | tr '\0' 'x' > "$logf"
  fire "$slug" "$home" "ROGUE_LOG_MAX_BYTES=not-a-number"
  rotated=$([ -e "$logf.1" ] && echo yes || echo no)
  check "$slug still rotates at the 10 MiB default" "yes" "$rotated"
done

echo
echo "== an oversized cap falls back to the default, it does NOT disable rotation"
# dash's `[ "$cap" -gt 0 ]` prints "Illegal number" to stderr and answers FALSE
# (rotation off, log unbounded) and Node's Number() yields Infinity, which no
# file size ever reaches - both are live bugs. PowerShell already landed on the
# default, but only because its cast error is swallowed by
# $ErrorActionPreference = 'SilentlyContinue'. Seeded just over 10 MiB so
# "clamped to the default" is distinguishable from "disabled".
_huge=$(: ; i=0; v=''; while [ "$i" -lt 400 ]; do v="${v}9"; i=$((i + 1)); done; printf '%s' "$v")
for slug in $SLUGS; do
  home="$TMPROOT/caphuge-$slug"; mkdir -p "$home/.rogue/logs"
  logf="$home/.rogue/logs/$slug.log"
  head -c 10485761 /dev/zero | tr '\0' 'x' > "$logf"
  fire "$slug" "$home" "ROGUE_LOG_MAX_BYTES=$_huge"
  rotated=$([ -e "$logf.1" ] && echo yes || echo no)
  check "$slug clamps an unrepresentable cap to the 10 MiB default" "yes" "$rotated"
done

echo
echo "== the log is not world-readable"
# The line carries the server's block reason, which quotes the content that
# tripped the rule, so a default-umask 0644 log would expose it to every other
# account on the box. Dir 0700, file 0600. Windows has no counterpart: another
# standard user cannot read %USERPROFILE%.
for slug in $SLUGS; do
  home="$TMPROOT/perm-$slug"; mkdir -p "$home"
  fire "$slug" "$home"
  logf="$home/.rogue/logs/$slug.log"
  # `ls -l` not `stat`: BSD and GNU stat take different flags (same reason the
  # dispatchers size the log with `wc -c`).
  fmode=$(ls -l "$logf" 2>/dev/null | cut -c1-10)
  dmode=$(ls -ld "$home/.rogue/logs" 2>/dev/null | cut -c1-10)
  check "$slug log file is owner-only" "-rw-------" "$fmode"
  check "$slug log dir is owner-only" "drwx------" "$dmode"
done

echo
echo "== rotation replaces an EXISTING .1 rather than failing"
for slug in $SLUGS; do
  home="$TMPROOT/rot2-$slug"; mkdir -p "$home/.rogue/logs"
  logf="$home/.rogue/logs/$slug.log"
  echo "STALE-PREVIOUS-GENERATION" > "$logf.1"
  i=0; while [ "$i" -lt 30 ]; do echo "OLD-LINE-$i" >> "$logf"; i=$((i + 1)); done
  fire "$slug" "$home" "ROGUE_LOG_MAX_BYTES=100"
  if grep -q 'STALE-PREVIOUS-GENERATION' "$logf.1" 2>/dev/null; then
    fail "$slug left the stale .1 in place — rotation silently no-oped"
  else
    pass "$slug replaced the previous .1 generation"
  fi
done

echo
echo "== the log starts with the timestamp: no UTF-8 BOM, no leading blank"
# PowerShell 5.1's `Add-Content -Encoding UTF8` writes EF BB BF on create, which
# would break any parser anchored on the timestamp; the sh side must never grow
# one either, so both halves of the suite assert it.
for slug in $SLUGS; do
  home="$TMPROOT/bom-$slug"; mkdir -p "$home"
  fire "$slug" "$home"
  head3=$(od -An -tx1 -N3 "$home/.rogue/logs/$slug.log" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//')
  case "$head3" in
    "ef bb bf") fail "$slug log starts with a UTF-8 BOM" ;;
    *)          pass "$slug log has no UTF-8 BOM (head: $head3)" ;;
  esac
done

echo
echo "== no dispatcher writes the legacy shared ~/.rogue/hook.log"
for slug in $SLUGS; do
  home="$TMPROOT/legacy-$slug"; mkdir -p "$home"
  fire "$slug" "$home"
  legacy=$([ -e "$home/.rogue/hook.log" ] && echo yes || echo no)
  check "$slug leaves ~/.rogue/hook.log alone" "no" "$legacy"
done

echo
if [ "$FAILS" -eq 0 ]; then
  echo "All hook-log contract tests passed (SH=$SH)."
  exit 0
fi
echo "$FAILS failure(s)."
exit 1
