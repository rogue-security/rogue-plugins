#!/usr/bin/env bash
# tests/test_install_env_sh.sh — install.sh and the machine env file.
#
# A keyed /etc/rogue/env is read alone by every hook, so on such a machine the
# installer prompts for nothing and writes no ~/.rogue-env; it prints which file
# is in use and installs the plugins as before. With the machine file absent, or
# present without ROGUE_API_KEY, the prompt and the user env file write are as
# they were. install.sh runs from a COPY whose /etc/rogue/env literal points into
# the sandbox (the only way to stage the machine candidate without root).
#
#   bash tests/test_install_env_sh.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0

ok()  { echo "  ok: $1"; }
bad() { echo "FAIL [$1]: $2"; fails=$((fails + 1)); }
check() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}

MACHINE="$WORK/machine-env"
INSTALLER="$WORK/install.sh"
sed "s#/etc/rogue/env#$MACHINE#g" "$REPO/install.sh" > "$INSTALLER"
grep -q "MACHINE_ENV_FILE=\"$MACHINE\"" "$INSTALLER" || { echo "the machine path was not redirected"; exit 1; }

# `curl -o <file> <url>` hands the installer the locally built Cursor tarball;
# any other call is the key validation POST and answers like an empty 200.
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; esac; shift; done
if [ -n "$out" ]; then cp "$TARBALL" "$out"; exit 0; fi
printf '{}\n200'
STUB
chmod +x "$BIN/curl"

stage="$WORK/stage/rogue-plugin-cursor/plugins"
mkdir -p "$stage"
cp -R "$REPO/plugins/cursor" "$stage/cursor"
TARBALL="$WORK/rogue-plugin-cursor.tar.gz"
tar -czf "$TARBALL" -C "$WORK/stage" rogue-plugin-cursor
export TARBALL

seed_machine() { # <line>...
  printf '%s\n' "$@" > "$MACHINE"
}

OUT="$WORK/out"; ERR="$WORK/err"
# run_install <home> [VAR=value ...] — a full non-interactive `--cursor` install.
run_install() {
  local home="$1"; shift
  mkdir -p "$home"
  set +e
  ( cd "$home" && env "$@" PATH="$BIN:$PATH" HOME="$home" NO_COLOR=1 ROGUE_NON_INTERACTIVE=1 \
      bash "$INSTALLER" --cursor ) > "$OUT" 2> "$ERR"
  LAST_RC=$?
  set -e
}

# run_configure <home> <input-file> [VAR=value ...] — configure_credentials alone,
# interactive, with the terminal (fd 3) fed from <input-file>.
run_configure() {
  local home="$1" input="$2"; shift 2
  mkdir -p "$home"
  set +e
  ( cd "$home" && env "$@" PATH="$BIN:$PATH" HOME="$home" NO_COLOR=1 ROGUE_INSTALL_LIB_ONLY=1 \
      bash -c '. "$1"; NON_INTERACTIVE=0; HAVE_TTY=1; exec 3<"$2"; agents="cursor"; configure_credentials' _ "$INSTALLER" "$input" ) > "$OUT" 2> "$ERR"
  LAST_RC=$?
  set -e
}

prompted() { grep -c 'Rogue API key' "$ERR" || :; }

# ═════════════════════════════════════════════════════════════════════════════
# 1. Machine env file with a key: no prompt, no user env file, plugin installed
# ═════════════════════════════════════════════════════════════════════════════
seed_machine "export ROGUE_API_KEY='machine-key'" "export ROGUE_ACTOR_EMAIL='mdm@example.com'"
H="$WORK/home1"
run_install "$H" ROGUE_API_KEY=""
check "keyed machine file: install exits 0" "0" "$LAST_RC"
[ "$LAST_RC" = 0 ] || cat "$ERR"
[ -e "$H/.rogue-env" ] && bad "keyed machine file: no user env file" "$H/.rogue-env was written" \
  || ok "keyed machine file: no user env file"
check "keyed machine file: no credential prompt" "0" "$(prompted)"
check "keyed machine file: output names the machine file once" "1" "$(grep -c "machine env file $MACHINE" "$ERR" || :)"
[ -f "$H/.cursor/plugins/local/rogue/.cursor-plugin/plugin.json" ] && ok "keyed machine file: plugin still installed" \
  || bad "keyed machine file: plugin still installed" "$(cat "$ERR")"

# A key passed by the caller changes nothing: the machine file is read alone.
H="$WORK/home1b"
run_install "$H" ROGUE_API_KEY="passed-key"
check "keyed machine file + passed key: install exits 0" "0" "$LAST_RC"
[ -e "$H/.rogue-env" ] && bad "keyed machine file + passed key: no user env file" "written" \
  || ok "keyed machine file + passed key: no user env file"

# Interactive: the prompt is skipped even with a terminal and typed input.
H="$WORK/home1c"
printf 'typed-key\n\n\n' > "$WORK/input1"
run_configure "$H" "$WORK/input1" ROGUE_API_KEY=""
check "keyed machine file, interactive: exits 0" "0" "$LAST_RC"
check "keyed machine file, interactive: no prompt" "0" "$(prompted)"
[ -e "$H/.rogue-env" ] && bad "keyed machine file, interactive: no user env file" "written" \
  || ok "keyed machine file, interactive: no user env file"

# ═════════════════════════════════════════════════════════════════════════════
# 2. No machine env file: unchanged — the passed key lands in ~/.rogue-env, and an
#    interactive run prompts
# ═════════════════════════════════════════════════════════════════════════════
rm -f "$MACHINE"
H="$WORK/home2"
run_install "$H" ROGUE_API_KEY="passed-key"
check "no machine file: install exits 0" "0" "$LAST_RC"
[ "$LAST_RC" = 0 ] || cat "$ERR"
check "no machine file: user env file holds the passed key" "export ROGUE_API_KEY='passed-key'" "$(grep '^export ROGUE_API_KEY=' "$H/.rogue-env" || :)"
check "no machine file: output does not name a machine file" "0" "$(grep -c 'machine env file' "$ERR" || :)"

H="$WORK/home2b"
printf 'typed-key\n\n\n' > "$WORK/input2"
run_configure "$H" "$WORK/input2" ROGUE_API_KEY=""
check "no machine file, interactive: exits 0" "0" "$LAST_RC"
check "no machine file, interactive: prompts for the key" "1" "$(prompted)"
check "no machine file, interactive: typed key written" "export ROGUE_API_KEY='typed-key'" "$(grep '^export ROGUE_API_KEY=' "$H/.rogue-env" || :)"

# ═════════════════════════════════════════════════════════════════════════════
# 3. Machine env file without a key: unchanged, as in 2
# ═════════════════════════════════════════════════════════════════════════════
seed_machine "export ROGUE_ACTOR_EMAIL='mdm@example.com'" "# ROGUE_API_KEY='commented-out'" "export ROGUE_API_KEY="
H="$WORK/home3"
run_install "$H" ROGUE_API_KEY="passed-key"
check "keyless machine file: install exits 0" "0" "$LAST_RC"
[ "$LAST_RC" = 0 ] || cat "$ERR"
check "keyless machine file: user env file holds the passed key" "export ROGUE_API_KEY='passed-key'" "$(grep '^export ROGUE_API_KEY=' "$H/.rogue-env" || :)"
check "keyless machine file: output does not name a machine file" "0" "$(grep -c 'machine env file' "$ERR" || :)"

H="$WORK/home3b"
printf 'typed-key\n\n\n' > "$WORK/input3"
run_configure "$H" "$WORK/input3" ROGUE_API_KEY=""
check "keyless machine file, interactive: prompts for the key" "1" "$(prompted)"
check "keyless machine file, interactive: typed key written" "export ROGUE_API_KEY='typed-key'" "$(grep '^export ROGUE_API_KEY=' "$H/.rogue-env" || :)"

echo
if [ "$fails" -eq 0 ]; then echo "all install env-file tests passed"; else echo "$fails FAILED"; exit 1; fi
