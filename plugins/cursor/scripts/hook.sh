#!/usr/bin/env sh
# Rogue Security hook dispatcher for Cursor — POSIX sh + curl implementation.
#
# Cross-platform sibling of hook.ps1. hooks.json fires BOTH an `sh` and a
# PowerShell entry for every event; exactly one does real work per machine:
#
#   • macOS / Linux / WSL         → this script runs (curl POST).
#   • native Windows + Git Bash   → this script STANDS DOWN (uname is MINGW/
#                                   MSYS/CYGWIN) so hook.ps1 owns Windows.
#   • native Windows, no Git Bash → `sh` is not found → the entry fails to
#                                   spawn (clean fail-open, no output); ps1 runs.
#
# Invoked via `sh`, NOT `bash`, on purpose: on Windows `bash` resolves to the
# WSL launcher stub (System32\bash.exe), which prints a UTF-16 "no installed
# distributions" notice that breaks Cursor's JSON parse of the hook output.
# There is no `sh.exe` stub, so `sh` cleanly "command not found"s on a bash-less
# Windows box. This script is kept POSIX-clean (tested under dash) as a result.
#
# The Git Bash stand-down matters because Git Bash's `~` maps to the Windows
# user profile — the SAME dir hook.ps1 reads — so without it both would POST.
#
# Pass-through: read the Cursor event payload from stdin, POST it to the Rogue
# AIDR backend, relay the server's response bytes verbatim. No client policy.
# The ONE exception is the file pre-image (see `augment_with_pre_image`), which
# adds a field the payload cannot express and never removes or rewrites one.
#
# Subagent identity rides in HEADERS for exactly that reason. A Cursor subagent's
# own events name only themselves, so `resolve_parent_session` reads the payload
# LOCALLY, looks the child's conversation id up as a FILENAME under Cursor's own
# transcript tree, and sends the parent id plus the child id as
# `x-rogue-parent-session-id` / `x-rogue-agent-id`. The parse result never
# reaches the POST, so the relayed body stays byte-for-byte what Cursor sent and
# `rogueFilePreImageB64` remains the single body exception.
#
# Fail-open everywhere: missing API key, missing curl, network error, non-200,
# empty body all yield `{}` on stdout, exit 0. Cursor
# must never block because Rogue infrastructure is unavailable.
#
# Credential resolution (later file wins; process env wins over all):
#   1. ${CURSOR_PLUGIN_ROOT}/env   (baked into a compiled customer plugin)
#   2. /etc/rogue/env              (MDM-provisioned)
#   3. ~/.rogue-env                (user / installer-written)

event="${1:-}"

emit() {
  # Relay the server response to Cursor verbatim. We deliberately do NOT validate
  # the JSON: a 200 from the Rogue API is always valid JSON, and if a malformed
  # body ever slips through, Cursor ignores it AND logs the raw output — which is
  # exactly what we want for debugging. Validating here would only let us swallow
  # that signal (turning it into `{}`) for no gain. Empty body -> `{}`.
  data="$1"
  trimmed="${data#"${data%%[![:space:]]*}"}"   # strip leading whitespace
  [ -z "$trimmed" ] && { printf '{}'; return; }
  printf '%s' "$data"
}

# Diagnostics to stderr when ROGUE_DEBUG is set (Cursor logs stderr separately).
dbg() { [ -n "${ROGUE_DEBUG:-}" ] && printf '[rogue] %s\n' "$*" >&2; return 0; }

# ── Git Bash stand-down: let hook.ps1 own native Windows ───────────────────
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) dbg "Git Bash (uname) -> stand down"; printf '{}'; exit 0 ;;
esac

[ -n "$event" ] || { printf '{}'; exit 0; }
dbg "event=$event"

# ── credential resolution (later file wins; process env wins over all) ─────
_penv_ROGUE_API_KEY="${ROGUE_API_KEY:-}"
_penv_ROGUE_ACTOR_EMAIL="${ROGUE_ACTOR_EMAIL:-}"
_penv_ROGUE_ACTOR_NAME="${ROGUE_ACTOR_NAME:-}"
_penv_ROGUE_BASE_URL="${ROGUE_BASE_URL:-}"

PLUGIN_ROOT="${CURSOR_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ]; then
  PLUGIN_ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" || PLUGIN_ROOT=""
fi

# Env files are bash-quoted (`export KEY=value`, written via printf %q), so
# sourcing them is correct.
for _f in "$PLUGIN_ROOT/env" /etc/rogue/env "$HOME/.rogue-env"; do
  if [ -n "$_f" ] && [ -r "$_f" ]; then dbg "cred file found: $_f"; . "$_f" 2>/dev/null
  else dbg "cred file absent: $_f"; fi
done

# process env wins over file values
[ -n "$_penv_ROGUE_API_KEY" ]     && ROGUE_API_KEY="$_penv_ROGUE_API_KEY"
[ -n "$_penv_ROGUE_ACTOR_EMAIL" ] && ROGUE_ACTOR_EMAIL="$_penv_ROGUE_ACTOR_EMAIL"
[ -n "$_penv_ROGUE_ACTOR_NAME" ]  && ROGUE_ACTOR_NAME="$_penv_ROGUE_ACTOR_NAME"
[ -n "$_penv_ROGUE_BASE_URL" ]    && ROGUE_BASE_URL="$_penv_ROGUE_BASE_URL"

API_KEY="${ROGUE_API_KEY:-}"
if [ -z "$API_KEY" ]; then
  dbg "no API key after cred resolution -> fail-open"
  if [ "$event" = "sessionStart" ]; then
    printf '%s' '{"additional_context": "Rogue Security plugin is installed but not configured. Run /rogue:setup to connect your API key."}'
  else
    printf '{}'
  fi
  exit 0
fi

BASE_URL="${ROGUE_BASE_URL:-https://api.rogue.security}"
BASE_URL="${BASE_URL%/}"
dbg "apiKey present (tail $(printf '%s' "$API_KEY" | tail -c 4 2>/dev/null)) baseUrl=$BASE_URL"

# ── actor resolution: explicit creds → git config → whoami/hostname ────────
_git_cfg() { git config --global "$1" 2>/dev/null; }

actor_name="${ROGUE_ACTOR_NAME:-}"
[ -n "$actor_name" ] || actor_name="$(_git_cfg user.name)"
[ -n "$actor_name" ] || actor_name="${USER:-${USERNAME:-$(whoami 2>/dev/null)}}"

actor_email="${ROGUE_ACTOR_EMAIL:-}"
[ -n "$actor_email" ] || actor_email="$(_git_cfg user.email)"
if [ -z "$actor_email" ]; then
  _u="${USER:-${USERNAME:-$(whoami 2>/dev/null)}}"
  _h="$(hostname 2>/dev/null)"
  if [ -n "$_u" ] && [ -n "$_h" ]; then actor_email="$_u@$_h"
  else actor_email="${_u:-$_h}"; fi
fi

# ── payload from stdin ─────────────────────────────────────────────────────
PAYLOAD="$(cat 2>/dev/null)"
[ -n "$PAYLOAD" ] || PAYLOAD='{}'
# Strip a leading UTF-8 BOM if present. Cursor on Windows prepends one to the
# hook payload (hook.ps1 handles it on the native path); a BOM-prefixed body is
# invalid JSON and the API rejects it with HTTP 400. No-op when absent.
_bom="$(printf '\357\273\277')"
PAYLOAD="${PAYLOAD#"$_bom"}"

# ── File pre-image (preToolUse only) ───────────────────────────────────────
# Cursor's preToolUse carries the FULL post-edit file and NO baseline, so the
# payload alone cannot say which part of the file this edit is responsible for.
# The file on disk still holds the PRE-edit content at this point, so we attach
# it as `rogueFilePreImageB64` and the API can compare the two.
#
# A NON-EXISTENT FILE YIELDS AN EMPTY PRE-IMAGE, AND THAT IS THE CREATE SIGNAL.
# No Cursor payload field distinguishes a create from an overwrite (`old_string`
# is "" for both an insertion into an existing file and a create), so this is the
# only mechanism that gets creates right. Do not add a separate `rogueFileExists`
# flag: two mechanisms for one fact, at double the lockstep cost.
#
# MULTI-HUNK EDITS NEED NO SPECIAL HANDLING, and this is load-bearing: Cursor
# emits one full preToolUse/afterFileEdit/postToolUse cycle PER HUNK, so by hunk
# 2 the file on disk already contains hunk 1 and the pre-image IS the correct
# per-hunk baseline. Never "fix" this into reading the whole turn's pre-state.
#
# Fail-open in every branch — a missing path, an unreadable file, a read error or
# an over-cap file leaves the relayed body byte-identical. Note that an over-cap
# file sends NO pre-image rather than a truncated one: a partial pre-image is
# WORSE than none, because it misrepresents the file's pre-edit state instead of
# admitting we don't know it.
PRE_IMAGE_MAX_BYTES=262144

# Every file the agent writes gets a pre-image, subject to the size cap above.
# The extension list below is the one exclusion: base64 of a PNG or a zip is
# pure payload with no text in it to compare, and binaries are also the files
# most likely to be large. An UNKNOWN extension is treated as text — the cost of
# shipping a binary we failed to recognize is bytes, while the cost of skipping
# a text file is losing the comparison entirely.
#
# COST: for a file write this roughly doubles the request body, since the event
# payload already carries the post-edit content. The size cap bounds the worst
# case; nothing is sent for a file above it.
_is_binary_path() {
  _base=$(printf '%s' "${1##*/}" | tr '[:upper:]' '[:lower:]')
  case "$_base" in
    # images
    *.png|*.jpg|*.jpeg|*.gif|*.bmp|*.tif|*.tiff|*.ico|*.icns|*.webp|*.avif|*.heic|*.psd) return 0 ;;
    # fonts
    *.ttf|*.otf|*.woff|*.woff2|*.eot) return 0 ;;
    # archives and packages
    *.zip|*.tar|*.gz|*.tgz|*.bz2|*.xz|*.zst|*.7z|*.rar|*.jar|*.war|*.ear) return 0 ;;
    *.whl|*.egg|*.nupkg|*.dmg|*.iso|*.pkg|*.deb|*.rpm) return 0 ;;
    # audio and video
    *.mp3|*.wav|*.flac|*.ogg|*.m4a|*.mp4|*.mov|*.avi|*.mkv|*.webm) return 0 ;;
    # compiled artifacts
    *.exe|*.dll|*.so|*.dylib|*.o|*.a|*.lib|*.obj|*.pdb|*.class|*.pyc|*.pyo|*.wasm|*.node|*.bin) return 0 ;;
    # documents and databases
    *.pdf|*.doc|*.docx|*.xls|*.xlsx|*.ppt|*.pptx|*.db|*.sqlite|*.sqlite3|*.mdb) return 0 ;;
  esac
  return 1
}

# One JSON string field: jq when it is on PATH, the text scan only when it is
# not. jq is preferred because it understands nesting and unescaping, both of
# which the scan gets only by luck — `file_path` sits under `tool_input` on a
# tool event, and the scan takes whichever copy appears first. The scan stays
# safe for this narrow use because a `"` inside a JSON string value is always
# backslash-escaped, so `"file_path":"…"` cannot match text that merely appears
# inside the file CONTENT the same payload carries.
#
# $1 body, $2 jq filter, $3 key for the fallback scan.
_json_string_field() {
  _jsf_key="$3"
  if command -v jq >/dev/null 2>&1; then
    if _jsf_val=$(printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null); then
      printf '%s' "$_jsf_val"
      return
    fi
  fi
  printf '%s' "$1" \
    | grep -o "\"$_jsf_key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" 2>/dev/null \
    | head -1 \
    | sed -e "s/^\"$_jsf_key\"[[:space:]]*:[[:space:]]*\"//" -e 's/"$//'
}

augment_with_pre_image() {
  _body="$1"
  # Only the file-writing tools have a file to pre-image. A preToolUse for
  # Shell, Read, Grep or an MCP call carries no relevant path, and reading one
  # off such a payload would be a wasted stat at best. `Edit` is listed
  # defensively — Cursor has only ever been observed sending `Write`.
  _tool="$(_json_string_field "$_body" '.tool_name' tool_name)"
  case "$_tool" in Write|Edit) : ;; *) printf '%s' "$_body"; return ;; esac
  _fp="$(_json_string_field "$_body" '.tool_input.file_path // .file_path' file_path)"
  # Absolute paths only. A relative path would resolve against the hook's cwd,
  # and a wrongly-"missing" file reads as a CREATE — the one wrong answer that
  # is worse than no answer, since it claims the whole file is new.
  case "$_fp" in /*) : ;; *) printf '%s' "$_body"; return ;; esac
  # A backslash means the JSON value carried an escape the fallback scan did not
  # unescape. Deliberate divergence from hook.ps1, which DOES unescape `\\` and
  # `\/`: this script only ever runs on POSIX, where a path needing either is
  # pathological, while on Windows every path arrives escaped.
  case "$_fp" in *\\*) printf '%s' "$_body"; return ;; esac
  if _is_binary_path "$_fp"; then printf '%s' "$_body"; return; fi

  if [ -e "$_fp" ]; then
    { [ -f "$_fp" ] && [ -r "$_fp" ]; } || { printf '%s' "$_body"; return; }
    _sz=$(wc -c < "$_fp" 2>/dev/null | tr -d ' ')
    case "$_sz" in ''|*[!0-9]*) printf '%s' "$_body"; return ;; esac
    if [ "$_sz" -gt "$PRE_IMAGE_MAX_BYTES" ]; then
      dbg "pre-image $_sz B over cap -> sending none"
      printf '%s' "$_body"; return
    fi
    if [ "$_sz" -eq 0 ]; then
      _b64=""
    else
      _b64=$(base64 < "$_fp" 2>/dev/null | tr -d '\r\n')
      [ -n "$_b64" ] || { printf '%s' "$_body"; return; }
    fi
  else
    _b64=""   # create
  fi
  dbg "pre-image attached for $_fp (${#_b64} b64 chars)"

  # Same jq-or-string-concat duality as the Copilot dispatcher: jq when it is on
  # PATH, otherwise strip the trailing `}`, append, re-close. base64 contains no
  # JSON-special characters, so the concat is safe.
  if command -v jq >/dev/null 2>&1; then
    _out=$(printf '%s' "$_body" | jq -c --arg b64 "$_b64" \
      '. + {rogueFilePreImageB64:$b64}' 2>/dev/null)
    # Only trust a complete object back; anything else falls through to concat.
    case "$_out" in '{'*'}') printf '%s' "$_out"; return ;; esac
  fi
  # Trim trailing whitespace so the single-'}' strip lands on the real closing
  # brace (mirrors the Copilot dispatcher and hook.ps1's TrimEnd()).
  _trimmed="${_body%"${_body##*[![:space:]]}"}"
  case "$_trimmed" in *'}') : ;; *) printf '%s' "$_body"; return ;; esac
  _pre="${_trimmed%\}}"
  # An empty object needs no separator ({} -> {"rogueFilePreImageB64":…}).
  if [ "$_pre" = "{" ]; then _sep=""; else _sep=","; fi
  printf '%s%s"rogueFilePreImageB64":"%s"}' "$_pre" "$_sep" "$_b64"
}

if [ "$event" = "preToolUse" ]; then
  PAYLOAD="$(augment_with_pre_image "$PAYLOAD")"
fi

# ── Subagent -> parent session attribution (headers only) ──────────────────
# A Cursor subagent's preToolUse / postToolUse / afterFileEdit /
# beforeShellExecution all fire hooks and all arrive with
# conversation_id == session_id == THE CHILD'S OWN id. No payload field names the
# parent, so persisted verbatim each subagent becomes its own orphaned session.
#
# The one place the link exists is Cursor's transcript tree, where THE CHILD'S ID
# IS THE FILENAME:
#
#   ~/.cursor/projects/<slug>/agent-transcripts/<parent>/subagents/<child>.jsonl
#
# so the parent is basename(dirname(dirname(hit))). That makes this a KEY LOOKUP,
# not a search: two concurrent subagents each carry their own id and each find
# their own file. Never rank by mtime, never "pick the newest file" — that is the
# one change that could attribute a child to the wrong parent.
#
# `transcript_path` is deliberately never read: it is JSON-null on ordinary
# parent events too (1,238 raw entries across 25+ real sessions), so branching on
# it would re-attribute main-agent traffic.
CURSOR_PROJECTS_DIR="$HOME/.cursor/projects"
PARENT_CACHE_DIR="$HOME/.rogue/cursor-parent"
SPAWN_MARKER_DIR="$HOME/.rogue/cursor-spawn"
SPAWN_MARKER_TTL=30          # seconds; the observed subagentStart lead is 3.96-6.45s
PARENT_ID=""
CHILD_ID=""

# `workspace_roots` is an ARRAY, so it needs its own reader rather than
# _json_string_field. jq when available; otherwise match the first string inside
# the array literal.
_workspace_root() {
  if command -v jq >/dev/null 2>&1; then
    if _wr=$(printf '%s' "$1" | jq -r '.workspace_roots[0] // empty' 2>/dev/null); then
      [ -n "$_wr" ] && { printf '%s' "$_wr"; return; }
    fi
  fi
  printf '%s' "$1" \
    | grep -o '"workspace_roots"[[:space:]]*:[[:space:]]*\[[[:space:]]*"[^"]*"' 2>/dev/null \
    | head -1 \
    | sed -e 's/.*"\([^"]*\)"$/\1/'
}

# Cursor's project-directory slug: the workspace path with the leading "/"
# stripped and every "/" and "." turned into "-".
_slugify_root() { printf '%s' "${1#/}" | tr '/.' '--'; }

# A conversation id is a uuid. Anything outside that charset is not one, and it
# would also be interpolated into a path — so reject it rather than glob with it.
_is_conversation_id() {
  case "$1" in
    ''|*[!A-Za-z0-9-]*) return 1 ;;
  esac
  return 0
}

# $1 = child conversation id, $2 = workspace slug (may be empty). Echoes the
# parent conversation id. Slug-scoping is an OPTIMIZATION, not the mechanism:
# slug derivation has real exceptions on disk (numeric slugs, `empty-window`,
# `.code-workspace`-derived names), so a miss falls back to a global glob that
# returns the SAME answer because the filename is the key.
_lookup_parent() {
  _lp_id="$1"
  if [ -n "$2" ]; then
    for _lp in "$CURSOR_PROJECTS_DIR/$2"/agent-transcripts/*/subagents/"$_lp_id.jsonl"; do
      [ -e "$_lp" ] || continue
      basename "$(dirname "$(dirname "$_lp")")"
      return 0
    done
  fi
  for _lp in "$CURSOR_PROJECTS_DIR"/*/agent-transcripts/*/subagents/"$_lp_id.jsonl"; do
    [ -e "$_lp" ] || continue
    basename "$(dirname "$(dirname "$_lp")")"
    return 0
  done
  return 1
}

# Seconds since epoch for a file's mtime. GNU stat first (it rejects -f cleanly
# on BSD, whereas BSD's -f would print a bogus value under GNU).
_mtime() {
  _mt=$(stat -c %Y "$1" 2>/dev/null) || _mt=$(stat -f %m "$1" 2>/dev/null) || return 1
  case "$_mt" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$_mt"
}

_marker_live_in() {
  [ -d "$1" ] || return 1
  _now=$(date +%s 2>/dev/null)
  case "$_now" in ''|*[!0-9]*) return 1 ;; esac
  for _mk in "$1"/*; do
    [ -f "$_mk" ] || continue
    _mkt=$(_mtime "$_mk") || continue
    _age=$((_now - _mkt))
    [ "$_age" -ge 0 ] && [ "$_age" -le "$SPAWN_MARKER_TTL" ] && return 0
  done
  return 1
}

# Any live marker under this workspace. The check is "is SOMETHING spawning",
# never "is MY parent spawning" — a child cannot know its parent before the
# lookup succeeds. Scoped per workspace because both sides derive the slug the
# same way from workspace_roots; unscoped only when this payload has no root.
_marker_live() {
  if [ -n "$1" ]; then _marker_live_in "$SPAWN_MARKER_DIR/$1"; return $?; fi
  for _md in "$SPAWN_MARKER_DIR"/*; do
    [ -d "$_md" ] || continue
    _marker_live_in "$_md" && return 0
  done
  return 1
}

# subagentStart fires ON THE PARENT (conversation_id == the parent's id, verified
# on all 9 real payloads) and 3.96-6.45s BEFORE the child's subagents/ file
# exists. That window is exactly what the marker covers: it tells a later,
# unresolved event that waiting is worth it. Every step is best-effort — a lost
# marker costs a wait that would not have happened, never a wrong answer.
mark_spawn() {
  [ -n "${HOME:-}" ] || return 0
  _ms_id=$(_json_string_field "$PAYLOAD" '.conversation_id' conversation_id)
  _is_conversation_id "$_ms_id" || return 0
  _ms_slug=$(_slugify_root "$(_workspace_root "$PAYLOAD")")
  [ -n "$_ms_slug" ] || _ms_slug="_"
  mkdir -p "$SPAWN_MARKER_DIR/$_ms_slug" 2>/dev/null || return 0
  : > "$SPAWN_MARKER_DIR/$_ms_slug/$_ms_id" 2>/dev/null || return 0
  dbg "spawn marker $_ms_slug/$_ms_id"
}

# Best-effort only. subagentStop carries no subagent_id and a killed subagent
# never emits one, so nothing may depend on this running; the TTL is what
# actually retires a marker.
clear_spawn() {
  [ -n "${HOME:-}" ] || return 0
  _cs_id=$(_json_string_field "$PAYLOAD" '.conversation_id' conversation_id)
  _is_conversation_id "$_cs_id" || return 0
  _cs_slug=$(_slugify_root "$(_workspace_root "$PAYLOAD")")
  [ -n "$_cs_slug" ] || _cs_slug="_"
  rm -f "$SPAWN_MARKER_DIR/$_cs_slug/$_cs_id" 2>/dev/null
  return 0
}

# Sets PARENT_ID/CHILD_ID when this event belongs to a subagent. Fail-open in
# every branch: unresolved leaves both empty and the POST is exactly today's.
resolve_parent_session() {
  [ -n "${HOME:-}" ] || return 0
  _rp_id=$(_json_string_field "$PAYLOAD" '.conversation_id' conversation_id)
  _is_conversation_id "$_rp_id" || return 0

  # Cache, mirroring the Copilot dispatcher's submap: a subagent fires 18-223
  # hooks per spawn and Cursor REUSES a child id across re-spawns, so the scan
  # runs once per subagent, ever. Only a subagent's first hook can miss.
  _rp_cache="$PARENT_CACHE_DIR/$_rp_id"
  if [ -r "$_rp_cache" ]; then
    PARENT_ID=$(cat "$_rp_cache" 2>/dev/null)
    if [ -n "$PARENT_ID" ]; then
      CHILD_ID="$_rp_id"
      dbg "parent cache hit"
      return 0
    fi
  fi

  _rp_slug=$(_slugify_root "$(_workspace_root "$PAYLOAD")")
  PARENT_ID=$(_lookup_parent "$_rp_id" "$_rp_slug") || PARENT_ID=""
  if [ -z "$PARENT_ID" ]; then
    # The child's file is born 0.811-1.627s after its first hook, and its
    # creation is INDEPENDENT of hook returns (one spawn's file appeared 2.40s
    # before any blocking hook fired), so this wait cannot self-deadlock.
    # hooks.json allows 120s per hook, so ~3s is 2.5% of the budget.
    #
    # NEVER spin without a live marker: a brand-new TOP-LEVEL conversation has no
    # directory of its own for ~9s and so looks exactly like an unresolved child.
    # Setting the ceiling to 0 rather than branching mirrors Copilot's
    # `[ -d "$COPILOT_STATE_DIR" ] || _max=0`.
    _rp_n=0
    _rp_max=${ROGUE_CURSOR_PARENT_ITERS:-30}   # ~3s at 0.1s/iter
    _marker_live "$_rp_slug" || _rp_max=0
    while [ "$_rp_n" -lt "$_rp_max" ]; do
      sleep 0.1
      PARENT_ID=$(_lookup_parent "$_rp_id" "$_rp_slug") && [ -n "$PARENT_ID" ] && break
      PARENT_ID=""
      _rp_n=$((_rp_n + 1))
    done
  fi

  [ -n "$PARENT_ID" ] || return 0
  CHILD_ID="$_rp_id"
  mkdir -p "$PARENT_CACHE_DIR" 2>/dev/null
  printf '%s' "$PARENT_ID" > "$_rp_cache" 2>/dev/null
  return 0
}

# Only the events a subagent actually fires resolve. sessionStart / sessionEnd /
# subagentStart / subagentStop are parent-side: they already carry the parent's
# own conversation id, so resolving would be pointless and waiting would tax
# every session start.
case "$event" in
  subagentStart)           mark_spawn ;;
  subagentStop)            clear_spawn ;;
  sessionStart|sessionEnd) : ;;
  *)                       resolve_parent_session ;;
esac

# ── POST (fail-open) ───────────────────────────────────────────────────────
command -v curl >/dev/null 2>&1 || { dbg "curl not found -> {}"; printf '{}'; exit 0; }

URL="$BASE_URL/api/v1/hooks/cursor"
dbg "POST $URL actor=$actor_email parent=${PARENT_ID:-none}"
# The two identity headers are appended as ARGUMENTS, never as conditional
# VALUES: to curl `-H "x-rogue-parent-session-id: "` means "send it empty" and
# `-H "x-rogue-parent-session-id:"` means "suppress this header entirely", so
# neither spelling can express "do not send it". Rebuilding the argument list
# with `set --` is the only shape that omits the header. They are always sent
# together or not at all, and never on a main-agent event.
set -- -H 'Content-Type: application/json' \
  -H "x-rogue-api-key: $API_KEY" \
  -H "x-rogue-event: $event" \
  -H "x-rogue-actor-email: $actor_email" \
  -H "x-rogue-actor-name: $actor_name" \
  -H 'x-rogue-source: cursor'
if [ -n "$PARENT_ID" ] && [ -n "$CHILD_ID" ]; then
  set -- "$@" -H "x-rogue-parent-session-id: $PARENT_ID" -H "x-rogue-agent-id: $CHILD_ID"
fi
# -f makes curl emit nothing and exit non-zero on HTTP >= 400, giving us
# fail-open on non-200 for free.
RESP="$(printf '%s' "$PAYLOAD" | curl -fsS --max-time 10 -X POST \
  "$@" \
  --data-binary @- "$URL" 2>/dev/null)"; _rc=$?
dbg "curl rc=$_rc resp_len=${#RESP}"
[ "$_rc" -eq 0 ] || RESP=""

# ── presence heartbeat (sessionStart only, fire-and-forget) ────────────────
# POSTs /api/v1/hooks/status so this install shows in the dashboard's Coding
# Agents roster (Connected / version / host / user). Pure side-effect: the POST
# runs in a detached double-fork with all fds redirected, so neither the relayed
# response below nor session start ever waits on it, and the response is
# ignored. Creds/actor were already resolved above.
if [ "$event" = "sessionStart" ]; then
  # Plugin version from the manifest, without python/jq.
  HB_VER="unknown"
  HB_PJ="$PLUGIN_ROOT/.cursor-plugin/plugin.json"
  if [ -r "$HB_PJ" ]; then
    _v=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$HB_PJ" 2>/dev/null \
          | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    [ -n "$_v" ] && HB_VER="$_v"
  fi
  HB_HOST=$(hostname 2>/dev/null) || HB_HOST=unknown
  [ -n "$HB_HOST" ] || HB_HOST=unknown
  # `agent` is "cursor" (not a display label): the server keys its latest-version
  # lookup (PLUGIN_REPOS) on this value, so the roster can flag outdated installs.
  hb_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
  HB_BODY=$(printf '{"agent_family":"cursor","agent":"cursor","version":"%s","host":"%s","actor_email":"%s","actor_name":"%s"}' \
    "$(hb_esc "$HB_VER")" "$(hb_esc "$HB_HOST")" "$(hb_esc "$actor_email")" "$(hb_esc "$actor_name")")
  dbg "heartbeat POST $BASE_URL/api/v1/hooks/status ver=$HB_VER host=$HB_HOST"
  ( curl -fsS --max-time 10 -X POST \
      -H 'Content-Type: application/json' \
      -H "x-rogue-api-key: $API_KEY" \
      -H 'x-rogue-source: cursor' \
      -d "$HB_BODY" \
      "$BASE_URL/api/v1/hooks/status" \
      </dev/null >/dev/null 2>&1 & )
fi

emit "$RESP"
exit 0
