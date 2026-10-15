#!/usr/bin/env bash
# Rogue Security - Muse Code hook installer. No Node, jq or Python: Muse loads
# Rogue's hooks from a Rogue-owned managed hooks file, so settings.json only gains
# one `managed_hooks_path` member, inserted and removed as text.
#
# Usage: bash install.sh [--uninstall | --status]
set -u

EVENTS="SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse PostToolUseFailure Stop SessionEnd SubagentStart SubagentStop"
ROOT="$HOME/.rogue/plugins/muse"
HOOKS="$ROOT/hooks.json"
SETTINGS="${XDG_CONFIG_HOME:-$HOME/.config}/muse/settings.json"
MODE="${1:-install}"

die() { echo "$*" >&2; exit 1; }

case "$(uname -s)" in Darwin|Linux) ;; *) die "Muse hook installation supports macOS and Linux only" ;; esac
case "$MODE" in install|--uninstall|--status) ;; *) die "usage: bash install.sh [--uninstall | --status]" ;; esac
# Paths are written into JSON strings unescaped; refuse the characters that would need escaping.
case "$HOOKS$SETTINGS" in *'"'*|*'\'*|*[[:cntrl:]]*) die "Unsupported character in $HOOKS or $SETTINGS" ;; esac

render_hooks() {
  local q sep='' e
  # Shell-quoted for Muse, then JSON-escaped: a quote in the path becomes '\'' and its backslash \\.
  q="'$(printf '%s' "$ROOT/scripts/hook.sh" | sed "s/'/'\\\\\\\\''/g")'"
  printf '{\n  "hooks": {'
  for e in $EVENTS; do
    printf '%s\n    "%s": [{"hooks": [{"type": "command", "command": "bash %s %s", "timeout": 6}]}]' "$sep" "$e" "$q" "$e"
    sep=','
  done
  printf '\n  }\n}\n'
}

# Prints the managed_hooks_path value; exit 2 when the member exists but is not a plain string.
pointer() {
  [ -f "$SETTINGS" ] || return 1
  grep -q '"managed_hooks_path"' "$SETTINGS" || return 1
  sed -n 's/.*"managed_hooks_path"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p' "$SETTINGS" | head -n1 | grep . || return 2
}

if [ "$MODE" = --status ]; then
  [ "$(pointer)" = "$HOOKS" ] || die "Muse settings do not point managed_hooks_path at $HOOKS"
  render_hooks | cmp -s - "$HOOKS" || die "Missing or modified $HOOKS"
  for f in hook.sh env-file.sh actor.sh install-id.sh; do [ -r "$ROOT/scripts/$f" ] || die "Missing $ROOT/scripts/$f"; done
  echo "Muse hooks installed. Start a new session to verify live traffic."
  exit 0
fi

[ ! -e "$SETTINGS" ] || [ -f "$SETTINGS" ] || die "Refusing non-regular file: $SETTINGS"
mkdir -p -m 700 "$(dirname "$SETTINGS")" || die "Cannot create $(dirname "$SETTINGS")"
LOCK="$SETTINGS.rogue-lock"
mkdir "$LOCK" 2>/dev/null || die "Another Muse installer is running, or a previous run was interrupted. If no installer is running, remove $LOCK and retry."
TMP=""
trap 'rm -rf "$LOCK" ${TMP:+"$TMP"}' EXIT
umask 077

# Writes stdin over settings.json atomically, unless Muse changed it meanwhile.
replace_settings() {
  TMP="$SETTINGS.rogue-$$"
  cat > "$TMP" || die "Cannot write $TMP"
  if [ -n "$ORIGINAL" ]; then cmp -s "$ORIGINAL" "$SETTINGS" || die "Muse settings changed during installation; retry"
  else [ ! -e "$SETTINGS" ] || die "Muse settings changed during installation; retry"; fi
  [ -z "$ORIGINAL" ] || cp "$ORIGINAL" "$SETTINGS.rogue-backup"
  mv -f "$TMP" "$SETTINGS" || die "Cannot replace $SETTINGS"
  TMP=""
}

# awk ends every line with a newline; drop the final one when the original had none, as Muse writes it.
match_eol() {
  local out; out="$(cat; echo x)"; out="${out%x}"
  [ -z "$(tail -c1 "$ORIGINAL")" ] || out="${out%$'\n'}"
  printf '%s' "$out"
}

ORIGINAL=""
if [ -f "$SETTINGS" ]; then
  ORIGINAL="$(mktemp)" && cp "$SETTINGS" "$ORIGINAL" || die "Cannot read $SETTINGS"
  trap 'rm -rf "$LOCK" "$ORIGINAL" ${TMP:+"$TMP"}' EXIT
fi
CURRENT="$(pointer)"; RC=$?
[ "$RC" != 2 ] || die "Unrecognized managed_hooks_path in $SETTINGS; leaving it unchanged"

if [ "$MODE" = --uninstall ]; then
  rm -f "$HOOKS"
  if [ "$CURRENT" = "$HOOKS" ]; then
    # Drops our member's line; when it was the last member, the comma before it goes too.
    awk -v p="$HOOKS" '
      { line[NR] = $0 }
      END {
        for (i = 1; i <= NR; i++) {
          t = line[i]; sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
          if (t == "\"managed_hooks_path\": \"" p "\"," ) { drop[i] = 1; continue }
          if (t == "\"managed_hooks_path\": \"" p "\"") {
            drop[i] = 1
            for (j = i - 1; j > 0 && line[j] ~ /^[[:space:]]*$/; j--) ;
            if (j > 0) sub(/,[[:space:]]*$/, "", line[j])
          }
        }
        for (i = 1; i <= NR; i++) if (!drop[i]) print line[i]
      }' "$ORIGINAL" | match_eol > "$ORIGINAL.out"
    if cmp -s "$ORIGINAL" "$ORIGINAL.out"; then
      echo "Left managed_hooks_path in $SETTINGS; it points at a removed file, which Muse ignores."
    else
      replace_settings < "$ORIGINAL.out"
    fi
    rm -f "$ORIGINAL.out"
  fi
  echo "Removed Rogue Muse hooks; credentials and other settings preserved."
  exit 0
fi

[ -z "$CURRENT" ] || [ "$CURRENT" = "$HOOKS" ] || die "Muse already loads managed hooks from $CURRENT; leaving it unchanged. Add Rogue's hooks from $HOOKS to that file, or remove the setting and retry."

SOURCE="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
if [ "$SOURCE" != "$ROOT" ]; then
  mkdir -p "$ROOT" && cp -R "$SOURCE/scripts" "$SOURCE/plugin.json" "$ROOT/" || die "Cannot copy the bridge to $ROOT"
fi
render_hooks > "$HOOKS.tmp" && mv -f "$HOOKS.tmp" "$HOOKS" || die "Cannot write $HOOKS"

if [ -z "$CURRENT" ]; then
  if [ -z "$ORIGINAL" ] || ! grep -q '[^[:space:]]' "$ORIGINAL"; then
    printf '{\n  "schema_version": 1,\n  "managed_hooks_path": "%s"\n}\n' "$HOOKS" | replace_settings
  elif [ "$(tr -d '[:space:]' < "$ORIGINAL")" = '{}' ]; then
    printf '{\n  "managed_hooks_path": "%s"\n}\n' "$HOOKS" | replace_settings
  else
    [ "$(tr -d '[:space:]' < "$ORIGINAL" | head -c1)" = '{' ] || die "Muse settings must be a JSON object: $SETTINGS"
    # The first non-blank character is the object's opening brace; insert right after it.
    awk -v p="$HOOKS" '
      !done && (i = index($0, "{")) { print substr($0, 1, i) "\n  \"managed_hooks_path\": \"" p "\","; $0 = substr($0, i + 1); done = 1; if ($0 ~ /^[[:space:]]*$/) next }
      { print }' "$ORIGINAL" | match_eol | replace_settings
  fi
fi
echo "Installed Rogue Muse hooks in $HOOKS (managed_hooks_path in $SETTINGS). Start a new Muse session."
