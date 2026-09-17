#!/usr/bin/env sh

# Only the current user or root may supply executable configuration. System
# configuration must belong to root; neither group nor other may write it.
rogue_env_is_trusted() (
  [ -f "$1" ] && [ -r "$1" ] || exit 1
  info=$(stat -Lc '%u %a' "$1" 2>/dev/null) || info=$(stat -Lf '%u %Lp' "$1" 2>/dev/null) || exit 1
  owner=${info%% *}; mode=${info#* }
  case "$owner:$mode" in *[!0-9:]*|:*) exit 1 ;; esac
  case "$1:${2:-0}" in /etc/rogue/env:*|*:1) [ "$owner" = 0 ] || exit 1 ;; esac
  [ "$owner" = 0 ] || [ "$owner" = "$(id -u)" ] || exit 1
  [ "$((0$mode & 022))" = 0 ]
)

# A candidate file "holds a key" when ROGUE_API_KEY is assigned a non-empty
# value - the same test every reader makes before selecting it.
rogue_env_has_key() { # rogue_env_has_key <file>
  [ -r "$1" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?ROGUE_API_KEY=[\"']?[^\"'[:space:]]" "$1"
}

rogue_source_env() {
  if rogue_env_is_trusted "$1" "${2:-0}"; then
    . "$1"
  fi
  return 0
}

rogue_env_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

rogue_env_preserved() {
  _rogue_env_rc=0
  _rogue_env_kept="$(grep -Ev \
    -e "^[[:space:]]*(export[[:space:]]+)?(${2})[[:space:]]*=" \
    -e '^[[:space:]]*# (Managed by the [Rr]ogue|Delete this file to revoke credentials)' \
    "$1")" || _rogue_env_rc=$?
  [ "$_rogue_env_rc" -le 1 ] || return 1

  [ -z "$_rogue_env_kept" ] || printf '%s\n' "$_rogue_env_kept" | tr -d '\r'
}

rogue_env_has_break() {
  _rogue_env_nl='
'
  _rogue_env_cr="$(printf '\r')"
  case "$1" in
    *"$_rogue_env_nl"*|*"$_rogue_env_cr"*) return 0 ;;
  esac
  return 1
}

rogue_write_env_file() {
  _env_file="$1"; shift
  [ "$#" -ge 2 ] || return 2

  _env_dir="$(dirname "$_env_file")"
  [ -d "$_env_dir" ] || mkdir -p "$_env_dir" || return 1

  _env_keys=""
  _env_managed=""
  while [ "$#" -ge 2 ]; do
    if rogue_env_has_break "$2"; then
      printf 'rogue: refusing to write %s: the value for %s contains a line break\n' \
        "$_env_file" "$1" >&2
      return 3
    fi
    _env_keys="${_env_keys}${_env_keys:+|}$1"
    _env_managed="${_env_managed}export $1=$(rogue_env_quote "$2")
"
    shift 2
  done

  _env_tmp="${_env_file}.rogue-tmp.$$"
  (
    umask 077
    {
      printf '# Managed by the Rogue plugins. Read by hook subprocesses at runtime.\n' &&
      printf '# Delete this file to revoke credentials.\n' &&
      printf '%s' "$_env_managed" &&
      { [ ! -f "$_env_file" ] || rogue_env_preserved "$_env_file" "$_env_keys"; }
    } > "$_env_tmp"
  ) || { rm -f "$_env_tmp"; return 1; }

  mv -f "$_env_tmp" "$_env_file" || { rm -f "$_env_tmp"; return 1; }
  chmod 600 "$_env_file" 2>/dev/null || :
}
