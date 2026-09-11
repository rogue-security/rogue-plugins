#!/usr/bin/env sh
# Sourceable (POSIX sh clean). Sets ROGUE_GIT_EMAIL / ROGUE_GIT_NAME from the
# global git config FILES. The git binary is never run: on a Mac without the
# Command Line Tools, `git` is a stub that opens the installer dialog.
#
# Same rule as git-identity.ps1 and gemini's shared.mjs: $XDG_CONFIG_HOME/git/config,
# then ~/.gitconfig, a later value overriding an earlier one as git does, each file
# followed by its [include] path entries (one level; includeIf is not evaluated).

# Print the last value of [$2] $3 in git config file $1 and its includes.
_rogue_gitcfg_value() {
  [ -r "$1" ] || return 0
  awk -v main="$1" -v dir="${1%/*}" -v home="$HOME" -v section="$2" -v key="$3" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function value(s) {
      s = trim(s)
      if (substr(s, 1, 1) == "\"") { s = substr(s, 2); sub(/".*$/, "", s); return s }
      sub(/[ \t]*[#;].*$/, "", s); return trim(s)
    }
    function scan(file, depth,   line, sect, l, eq, k, v, inc) {
      while ((getline line < file) > 0) {
        l = trim(line)
        if (l == "" || l ~ /^[#;]/) continue
        if (substr(l, 1, 1) == "[") {
          sect = substr(l, 2); sub(/\].*$/, "", sect); sub(/[ \t"].*$/, "", sect)
          sect = tolower(sect); continue
        }
        eq = index(l, "=")
        if (eq == 0) continue
        k = tolower(trim(substr(l, 1, eq - 1)))
        v = value(substr(l, eq + 1))
        if (sect == "include" && k == "path" && depth == 0) {
          inc = v
          if (inc ~ /^~\//) inc = home substr(inc, 2)
          else if (inc !~ /^\//) inc = dir "/" inc
          scan(inc, 1)
        } else if (sect == section && k == key && v != "") found = v
      }
      close(file)
    }
    BEGIN { scan(main, 0); if (found != "") print found }
  ' 2>/dev/null
}

rogue_git_identity() {
  ROGUE_GIT_EMAIL=""
  ROGUE_GIT_NAME=""
  for _rogue_gc in "${XDG_CONFIG_HOME:-$HOME/.config}/git/config" "$HOME/.gitconfig"; do
    _rogue_gv=$(_rogue_gitcfg_value "$_rogue_gc" user email)
    [ -n "$_rogue_gv" ] && ROGUE_GIT_EMAIL="$_rogue_gv"
    _rogue_gv=$(_rogue_gitcfg_value "$_rogue_gc" user name)
    [ -n "$_rogue_gv" ] && ROGUE_GIT_NAME="$_rogue_gv"
  done
  unset _rogue_gc _rogue_gv
  return 0
}
