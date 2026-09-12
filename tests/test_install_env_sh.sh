#!/usr/bin/env bash
# tests/test_install_env_sh.sh — install.sh and the machine env file.
#
# A keyed, root-owned /etc/rogue/env is read alone by every hook, so on such a
# machine the installer prompts for nothing and writes no ~/.rogue-env; it prints
# which file is in use, validates the file's key, and installs the plugins as
# before. With the machine file absent, present without ROGUE_API_KEY, or keyed
# but not root-owned/mode 644 (Kiro and the log shipper skip it), the prompt and
# the user env file write are as they were. install.sh runs from a COPY whose
# /etc/rogue/env literal points into the sandbox, and a `stat` shim on PATH
# reports that file as root-owned (the only way to stage the machine candidate
# without root).
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

BIN="$WORK/bin"; mkdir -p "$BIN"
# `curl -o <file> <url>` hands the installer the locally built Cursor tarball;
# any other call is the key validation POST and answers `{}` with CURL_CODE.
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; esac; shift; done
if [ -n "$out" ]; then cp "$TARBALL" "$out"; exit 0; fi
printf '{}\n%s' "${CURL_CODE:-200}"
STUB
# The machine file is reported as owned by ROGUE_TEST_MACHINE_OWNER (root by
# default) with its real mode; every other path goes to the real stat.
REAL_STAT="$(command -v stat)"
cat > "$BIN/stat" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "\$ROGUE_TEST_MACHINE_ENV" ]; then
    if "$REAL_STAT" --version >/dev/null 2>&1; then mode="\$("$REAL_STAT" -c %a "\$a")"; else mode="\$("$REAL_STAT" -f %Lp "\$a")"; fi
    printf '%s %s\n' "\${ROGUE_TEST_MACHINE_OWNER:-0}" "\$mode"; exit 0
  fi
done
exec "$REAL_STAT" "\$@"
STUB
chmod +x "$BIN/curl" "$BIN/stat"
export ROGUE_TEST_MACHINE_ENV="$MACHINE"

stage="$WORK/stage/rogue-plugin-cursor/plugins"
mkdir -p "$stage"
cp -R "$REPO/plugins/cursor" "$stage/cursor"
TARBALL="$WORK/rogue-plugin-cursor.tar.gz"
tar -czf "$TARBALL" -C "$WORK/stage" rogue-plugin-cursor
export TARBALL

seed_machine() { # <line>...
  printf '%s\n' "$@" > "$MACHINE"
  chmod 644 "$MACHINE"
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
count() { grep -c -- "$1" "$ERR" || :; }
no_user_file() { # <label> <home>
  [ -e "$2/.rogue-env" ] && bad "$1: no user env file" "$2/.rogue-env was written" || ok "$1: no user env file"
}

# ═════════════════════════════════════════════════════════════════════════════
# 1. Trusted machine env file with a key: no prompt, no user env file, the key is
#    validated, plugin installed
# ═════════════════════════════════════════════════════════════════════════════
seed_machine "export ROGUE_API_KEY='machine-key'" "export ROGUE_ACTOR_EMAIL='mdm@example.com'"
H="$WORK/home1"
run_install "$H" ROGUE_API_KEY=""
check "keyed machine file: install exits 0" "0" "$LAST_RC"
[ "$LAST_RC" = 0 ] || cat "$ERR"
no_user_file "keyed machine file" "$H"
check "keyed machine file: no credential prompt" "0" "$(prompted)"
check "keyed machine file: output names the machine file once" "1" "$(count "machine env file $MACHINE")"
check "keyed machine file: the machine key is validated" "1" "$(count 'Key validated')"
check "keyed machine file: no ignored-key warning" "0" "$(count 'is ignored')"
[ -f "$H/.cursor/plugins/local/rogue/.cursor-plugin/plugin.json" ] && ok "keyed machine file: plugin still installed" \
  || bad "keyed machine file: plugin still installed" "$(cat "$ERR")"

# A key passed by the caller goes nowhere (the machine file is read alone) and
# the installer says so.
H="$WORK/home1b"
run_install "$H" ROGUE_API_KEY="passed-key"
check "keyed machine file + passed key: install exits 0" "0" "$LAST_RC"
no_user_file "keyed machine file + passed key" "$H"
check "keyed machine file + passed key: warns that the key is ignored" "1" "$(count "API key / base URL is ignored: $MACHINE")"

# Interactive: the prompt is skipped even with a terminal and typed input.
H="$WORK/home1c"
printf 'typed-key\n\n\n' > "$WORK/input1"
run_configure "$H" "$WORK/input1" ROGUE_API_KEY=""
check "keyed machine file, interactive: exits 0" "0" "$LAST_RC"
check "keyed machine file, interactive: no prompt" "0" "$(prompted)"
no_user_file "keyed machine file, interactive" "$H"

# A revoked machine key is loud but does not stop the install.
H="$WORK/home1d"
run_install "$H" ROGUE_API_KEY="" CURL_CODE=401
check "keyed machine file, key rejected: install exits 0" "0" "$LAST_RC"
check "keyed machine file, key rejected: warning names the file" "1" "$(count "key in $MACHINE is invalid (HTTP 401)")"
no_user_file "keyed machine file, key rejected" "$H"
[ -f "$H/.cursor/plugins/local/rogue/.cursor-plugin/plugin.json" ] && ok "keyed machine file, key rejected: plugin still installed" \
  || bad "keyed machine file, key rejected: plugin still installed" "$(cat "$ERR")"

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
check "no machine file: output does not name a machine file" "0" "$(count 'machine env file')"

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
check "keyless machine file: output does not name a machine file" "0" "$(count 'machine env file')"

H="$WORK/home3b"
printf 'typed-key\n\n\n' > "$WORK/input3"
run_configure "$H" "$WORK/input3" ROGUE_API_KEY=""
check "keyless machine file, interactive: prompts for the key" "1" "$(prompted)"
check "keyless machine file, interactive: typed key written" "export ROGUE_API_KEY='typed-key'" "$(grep '^export ROGUE_API_KEY=' "$H/.rogue-env" || :)"

# ═════════════════════════════════════════════════════════════════════════════
# 4. Keyed machine env file that Kiro and the log shipper would skip (group/other
#    writable, or not root-owned): a warning names it, then as in 2
# ═════════════════════════════════════════════════════════════════════════════
seed_machine "export ROGUE_API_KEY='machine-key'"
chmod 666 "$MACHINE"
H="$WORK/home4"
run_install "$H" ROGUE_API_KEY="passed-key"
check "writable machine file: install exits 0" "0" "$LAST_RC"
[ "$LAST_RC" = 0 ] || cat "$ERR"
check "writable machine file: warning names the file" "1" "$(count "$MACHINE holds ROGUE_API_KEY but is not root-owned")"
check "writable machine file: user env file holds the passed key" "export ROGUE_API_KEY='passed-key'" "$(grep '^export ROGUE_API_KEY=' "$H/.rogue-env" || :)"
check "writable machine file: not named as the credential source" "0" "$(count 'Credentials come from the machine env file')"

H="$WORK/home4b"
printf 'typed-key\n\n\n' > "$WORK/input4"
run_configure "$H" "$WORK/input4" ROGUE_API_KEY=""
check "writable machine file, interactive: prompts for the key" "1" "$(prompted)"
check "writable machine file, interactive: typed key written" "export ROGUE_API_KEY='typed-key'" "$(grep '^export ROGUE_API_KEY=' "$H/.rogue-env" || :)"

chmod 644 "$MACHINE"
H="$WORK/home4c"
run_install "$H" ROGUE_API_KEY="passed-key" ROGUE_TEST_MACHINE_OWNER="$(id -u)"
check "user-owned machine file: warning names the file" "1" "$(count "$MACHINE holds ROGUE_API_KEY but is not root-owned")"
check "user-owned machine file: user env file holds the passed key" "export ROGUE_API_KEY='passed-key'" "$(grep '^export ROGUE_API_KEY=' "$H/.rogue-env" || :)"

echo
if [ "$fails" -eq 0 ]; then echo "all install env-file tests passed"; else echo "$fails FAILED"; exit 1; fi
