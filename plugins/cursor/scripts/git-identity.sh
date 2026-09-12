#!/usr/bin/env sh
# Sourceable (POSIX sh clean). Sets ROGUE_GIT_EMAIL / ROGUE_GIT_NAME from the
# global git config FILES. The git binary is never run: on a Mac without the
# Command Line Tools, `git` is a stub that opens the installer dialog.
#
# Same rule as git-identity.ps1 and gemini's shared.mjs: $XDG_CONFIG_HOME/git/config,
# then ~/.gitconfig, a later value overriding an earlier one as git does, each file
# followed by its [include] path entries (one level; includeIf is not evaluated).

# Print "E<email>" and "N<name>" (one line each) for the config files given as
# arguments, scanned in order. One awk process for both files and both keys: this
# runs on every hook event. awk reads stdin from /dev/null: an
# `[include] path = /dev/stdin` would otherwise drain the hook payload the bridge
# has not read yet. `bom` is passed in from the shell so its length is counted in
# whatever locale awk runs under.
_rogue_gitcfg_scan() {
  awk -v home="$HOME" -v bom="$(printf '\357\273\277')" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    # git syntax: a backslash escapes the next character, quotes toggle a region in
    # which # and ; are literal, and a comment ends the value outside one.
    function value(s,   out, i, c, q, n) {
      s = trim(s); out = ""; q = 0; n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\" && i < n) { i++; out = out substr(s, i, 1) }
        else if (c == "\"") q = !q
        else if (!q && (c == "#" || c == ";")) break
        else out = out c
      }
      return trim(out)
    }
    function scan(file, depth,   line, dir, sect, l, eq, k, v, inc) {
      dir = (index(file, "/") ? file : "./" file); sub(/\/[^\/]*$/, "", dir)
      while ((getline line < file) > 0) {
        if (index(line, bom) == 1) line = substr(line, length(bom) + 1)
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
        } else if (sect == "user" && v != "") {
          if (k == "email") email = v
          else if (k == "name") name = v
        }
      }
      close(file)
    }
    BEGIN { for (i = 1; i < ARGC; i++) scan(ARGV[i], 0); print "E" email; print "N" name }
  ' "$@" </dev/null 2>/dev/null
}

rogue_git_identity() {
  ROGUE_GIT_EMAIL=""
  ROGUE_GIT_NAME=""
  { IFS= read -r ROGUE_GIT_EMAIL; IFS= read -r ROGUE_GIT_NAME; } <<EOF || :
$(_rogue_gitcfg_scan "${XDG_CONFIG_HOME:-$HOME/.config}/git/config" "$HOME/.gitconfig")
EOF
  ROGUE_GIT_EMAIL="${ROGUE_GIT_EMAIL#E}"
  ROGUE_GIT_NAME="${ROGUE_GIT_NAME#N}"
  return 0
}
