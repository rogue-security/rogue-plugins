#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SH="${TEST_SH:-sh}"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
fails=0

check() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok: $1"
  else echo "FAIL: $1 (expected [$2], got [$3])"; fails=$((fails + 1)); fi
}

seed() { # <env-file>
  cat > "$1" <<'SEED'
# Managed by the rogue Claude plugin. Read by hook subprocesses at runtime.
# Delete this file to revoke credentials.
export ROGUE_API_KEY='stale-key'
export ROGUE_ACTOR_EMAIL='stale@example.com'
export ROGUE_ACTOR_NAME='Stale'
# our self-hosted API
export ROGUE_BASE_URL='http://localhost:8007'
export ROGUE_LOG_DIR='/var/log/rogue'
export ROGUE_HEARTBEAT_MIN_INTERVAL=60
SEED
}

sourced() { # <env-file> <var>
  "$SH" -c '. "$1"; eval "printf %s \"\$$2\""' _ "$1" "$2"
}

count_lines() { grep -c "$2" "$1" || :; }

posix_env="$SANDBOX/posix.env"
seed "$posix_env"
"$SH" -c '. "$1"; rogue_write_env_file "$2" ROGUE_API_KEY "posix-key" ROGUE_ACTOR_EMAIL "p@x.io" ROGUE_ACTOR_NAME "P"' \
  _ "$REPO/scripts/shared/env-file.sh" "$posix_env"
check "posix: key replaced"   "posix-key"             "$(sourced "$posix_env" ROGUE_API_KEY)"
check "posix: base url kept"  "http://localhost:8007" "$(sourced "$posix_env" ROGUE_BASE_URL)"

for plugin in rogue codex cursor copilot antigravity; do
  script="$REPO/plugins/$plugin/scripts/setup.sh"
  env_file="$SANDBOX/$plugin/.rogue-env"; mkdir -p "${env_file%/*}"
  seed "$env_file"
  HOME="${env_file%/*}" bash "$script" "new-key" "new@example.com" "New Name" >/dev/null

  check "$plugin: api key replaced"       "new-key"                 "$(sourced "$env_file" ROGUE_API_KEY)"
  check "$plugin: actor email replaced"   "new@example.com"         "$(sourced "$env_file" ROGUE_ACTOR_EMAIL)"
  check "$plugin: actor name replaced"    "New Name"                "$(sourced "$env_file" ROGUE_ACTOR_NAME)"
  check "$plugin: base url kept"          "http://localhost:8007"   "$(sourced "$env_file" ROGUE_BASE_URL)"
  check "$plugin: log dir kept"           "/var/log/rogue"          "$(sourced "$env_file" ROGUE_LOG_DIR)"
  check "$plugin: beacon interval kept"   "60"                      "$(sourced "$env_file" ROGUE_HEARTBEAT_MIN_INTERVAL)"
  check "$plugin: user comment kept"      "1"                       "$(count_lines "$env_file" '^# our self-hosted API$')"
  check "$plugin: one api key line"       "1"                       "$(count_lines "$env_file" '^export ROGUE_API_KEY=')"
  check "$plugin: one header line"        "1"                       "$(count_lines "$env_file" 'Read by hook subprocesses')"
  check "$plugin: mode 600"               "600"                     "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$env_file")"
done

codex_env="$SANDBOX/codex-surface/.rogue-env"; mkdir -p "${codex_env%/*}"
seed "$codex_env"
printf "export ROGUE_CODEX_SURFACE='codex_cli'\n" >> "$codex_env"
HOME="${codex_env%/*}" bash "$REPO/plugins/codex/scripts/setup.sh" \
  "k" "e@x.io" "N" "codex_app" >/dev/null
check "codex: surface replaced"     "codex_app" "$(sourced "$codex_env" ROGUE_CODEX_SURFACE)"
check "codex: one surface line"     "1"         "$(count_lines "$codex_env" '^export ROGUE_CODEX_SURFACE=')"
check "codex: base url kept"        "http://localhost:8007" "$(sourced "$codex_env" ROGUE_BASE_URL)"

if command -v node >/dev/null 2>&1; then
  gem_env="$SANDBOX/gemini/.rogue-env"; mkdir -p "${gem_env%/*}"
  seed "$gem_env"
  HOME="${gem_env%/*}" node "$REPO/plugins/gemini/scripts/setup.mjs" \
    "new-key" "new@example.com" "New Name" >/dev/null
  check "gemini: api key replaced"  "new-key"               "$(sourced "$gem_env" ROGUE_API_KEY)"
  check "gemini: base url kept"     "http://localhost:8007" "$(sourced "$gem_env" ROGUE_BASE_URL)"
  check "gemini: one header line"   "1"                     "$(count_lines "$gem_env" 'Read by hook subprocesses')"

  sh_env="$SANDBOX/rogue-compare/.rogue-env"; mkdir -p "${sh_env%/*}"
  seed "$sh_env"
  HOME="${sh_env%/*}" bash "$REPO/plugins/rogue/scripts/setup.sh" \
    "new-key" "new@example.com" "New Name" >/dev/null
  if cmp -s "$sh_env" "$gem_env"; then echo "  ok: sh and node writers agree byte for byte"
  else echo "FAIL: sh and node writers disagree"; diff "$sh_env" "$gem_env" || :; fails=$((fails + 1)); fi
else
  echo "  skip: node not installed (gemini writer)"
fi

odd_env="$SANDBOX/odd/.rogue-env"; mkdir -p "${odd_env%/*}"
seed "$odd_env"
HOME="${odd_env%/*}" bash "$REPO/plugins/rogue/scripts/setup.sh" \
  "key'with'quotes" "o'brien@example.com" "O'Brien" >/dev/null
check "quoted key round-trips"   "key'with'quotes"     "$(sourced "$odd_env" ROGUE_API_KEY)"
check "quoted name round-trips"  "O'Brien"             "$(sourced "$odd_env" ROGUE_ACTOR_NAME)"
check "quoted seed still kept"   "http://localhost:8007" "$(sourced "$odd_env" ROGUE_BASE_URL)"

fresh_env="$SANDBOX/fresh/nested/.rogue-env"
HOME="${fresh_env%/*}" bash "$REPO/plugins/rogue/scripts/setup.sh" \
  "k" "e@x.io" "N" >/dev/null
check "fresh file written"   "k"   "$(sourced "$fresh_env" ROGUE_API_KEY)"
check "fresh file mode 600"  "600" "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$fresh_env")"

inst_env="$SANDBOX/install.env"
seed "$inst_env"
ROGUE_INSTALL_LIB_ONLY=1 ENV_FILE="$inst_env" bash -c '
  . "$1"
  ENV_FILE="$2"
  ROGUE_API_KEY="installer-key"
  ROGUE_ACTOR_EMAIL="i@example.com"
  ROGUE_ACTOR_NAME="Installer"
  ROGUE_BASE_URL="http://localhost:8007"
  write_env_file >/dev/null 2>&1
' _ "$REPO/install.sh" "$inst_env"
check "install.sh: key replaced"      "installer-key"         "$(sourced "$inst_env" ROGUE_API_KEY)"
check "install.sh: base url kept"     "http://localhost:8007" "$(sourced "$inst_env" ROGUE_BASE_URL)"
check "install.sh: one base url line" "1"                     "$(count_lines "$inst_env" '^export ROGUE_BASE_URL=')"
check "install.sh: log dir kept"      "/var/log/rogue"        "$(sourced "$inst_env" ROGUE_LOG_DIR)"
check "install.sh: one header line"   "1"                     "$(count_lines "$inst_env" 'Read by hook subprocesses')"

quo_env="$SANDBOX/install-quote.env"
seed "$quo_env"
q_key="key'quote"
q_name="O'Brien"
ROGUE_INSTALL_LIB_ONLY=1 Q_KEY="$q_key" Q_NAME="$q_name" bash -c '
  . "$1"
  ENV_FILE="$2"
  ROGUE_API_KEY="$Q_KEY"
  ROGUE_ACTOR_EMAIL="e@x.io"
  ROGUE_ACTOR_NAME="$Q_NAME"
  write_env_file >/dev/null 2>&1
' _ "$REPO/install.sh" "$quo_env"
check "install.sh: quoted key round-trips"  "$q_key"  "$(sourced "$quo_env" ROGUE_API_KEY)"
check "install.sh: quoted name round-trips" "$q_name" "$(sourced "$quo_env" ROGUE_ACTOR_NAME)"

auto_env="$SANDBOX/auto-update.env"
seed "$auto_env"
ROGUE_INSTALL_LIB_ONLY=1 bash -c '
  . "$1"
  ENV_FILE="$2"
  NON_INTERACTIVE=1
  ROGUE_API_KEY="rotated-key"
  configure_credentials >/dev/null 2>&1
' _ "$REPO/install.sh" "$auto_env"
check "auto-update path: key rotated"  "rotated-key"           "$(sourced "$auto_env" ROGUE_API_KEY)"
check "auto-update path: base url kept" "http://localhost:8007" "$(sourced "$auto_env" ROGUE_BASE_URL)"
check "auto-update path: log dir kept"  "/var/log/rogue"        "$(sourced "$auto_env" ROGUE_LOG_DIR)"

flag_env="$SANDBOX/base-url-flag.env"
seed "$flag_env"
ROGUE_INSTALL_LIB_ONLY=1 ROGUE_BASE_URL="https://staging.example.com" bash -c '
  . "$1"
  ENV_FILE="$2"
  NON_INTERACTIVE=1
  ROGUE_API_KEY="k"
  configure_credentials >/dev/null 2>&1
' _ "$REPO/install.sh" "$flag_env"
check "explicit base url wins" "https://staging.example.com" "$(sourced "$flag_env" ROGUE_BASE_URL)"

back_env="$SANDBOX/base-url-back-to-saas.env"
seed "$back_env"
ROGUE_INSTALL_LIB_ONLY=1 ROGUE_BASE_URL="https://api.rogue.security" bash -c '
  . "$1"
  ENV_FILE="$2"
  NON_INTERACTIVE=1
  ROGUE_API_KEY="k"
  configure_credentials >/dev/null 2>&1
' _ "$REPO/install.sh" "$back_env"
check "explicit default clears stale custom url" "0" "$(count_lines "$back_env" '^export ROGUE_BASE_URL=')"
check "explicit default keeps other settings"    "/var/log/rogue" "$(sourced "$back_env" ROGUE_LOG_DIR)"

argv_env="$SANDBOX/base-url-argv.env"
seed "$argv_env"
ROGUE_INSTALL_LIB_ONLY=1 bash -c '
  . "$1"
  ENV_FILE="$2"
  NON_INTERACTIVE=1
  ROGUE_API_KEY="k"
  parse_args --base-url https://api.rogue.security
  configure_credentials >/dev/null 2>&1
' _ "$REPO/install.sh" "$argv_env"
check "--base-url default clears stale custom url" "0" "$(count_lines "$argv_env" '^export ROGUE_BASE_URL=')"

keep_env="$SANDBOX/base-url-untouched.env"
seed "$keep_env"
ROGUE_INSTALL_LIB_ONLY=1 bash -c '
  . "$1"
  ENV_FILE="$2"
  NON_INTERACTIVE=1
  ROGUE_API_KEY="k"
  configure_credentials >/dev/null 2>&1
' _ "$REPO/install.sh" "$keep_env"
check "silent run keeps on-disk base url" "http://localhost:8007" "$(sourced "$keep_env" ROGUE_BASE_URL)"

only_env="$SANDBOX/only-managed.env"
cat > "$only_env" <<'ONLY'
# Managed by the Rogue plugins. Read by hook subprocesses at runtime.
# Delete this file to revoke credentials.
export ROGUE_API_KEY='stale-key'
export ROGUE_ACTOR_EMAIL='stale@example.com'
export ROGUE_ACTOR_NAME='Stale'
ONLY
set +e
"$SH" -ec '. "$1"; rogue_write_env_file "$2" ROGUE_API_KEY "k" ROGUE_ACTOR_EMAIL "e@x.io" ROGUE_ACTOR_NAME "N"' \
  _ "$REPO/scripts/shared/env-file.sh" "$only_env"
only_rc=$?
set -e
check "empty preserve set succeeds"  "0" "$only_rc"
check "empty preserve set rewrites"  "k" "$(sourced "$only_env" ROGUE_API_KEY)"
check "empty preserve set one header" "1" "$(count_lines "$only_env" 'Read by hook subprocesses')"

ro_dir="$SANDBOX/readonly"
mkdir -p "$ro_dir"
ro_env="$ro_dir/rogue.env"
seed "$ro_env"
before="$(cat "$ro_env")"
chmod 500 "$ro_dir"
if : 2>/dev/null > "$ro_dir/.probe"; then
  rm -f "$ro_dir/.probe"
  chmod 700 "$ro_dir"
  echo "  skip: directory is writable anyway (running as root?)"
else
set +e
"$SH" -c '. "$1"; rogue_write_env_file "$2" ROGUE_API_KEY "should-not-land" ROGUE_ACTOR_EMAIL "x@y.z" ROGUE_ACTOR_NAME "X"' \
  _ "$REPO/scripts/shared/env-file.sh" "$ro_env" >/dev/null 2>&1
ro_rc=$?
set -e
chmod 700 "$ro_dir"
check "failed write reports failure"   "1"        "$ro_rc"
check "failed write keeps the old file" "$before" "$(cat "$ro_env")"
check "failed write leaves no temp"     "0"       "$(find "$ro_dir" -name '*.rogue-tmp.*' | wc -l | tr -d ' ')"
fi

u8_env="$SANDBOX/nonascii.env"
cat > "$u8_env" <<'U8'
export ROGUE_API_KEY='stale-key'
export ROGUE_LOG_DIR='/var/log/café'
U8
for pass in 1 2; do
  "$SH" -c '. "$1"; rogue_write_env_file "$2" ROGUE_API_KEY "new-key" ROGUE_ACTOR_EMAIL "e@x.io" ROGUE_ACTOR_NAME "José Müller"' \
    _ "$REPO/scripts/shared/env-file.sh" "$u8_env"
  check "non-ASCII actor name round-trips (pass $pass)" "José Müller" "$(sourced "$u8_env" ROGUE_ACTOR_NAME)"
  check "non-ASCII preserved line intact (pass $pass)"  "/var/log/café"   "$(sourced "$u8_env" ROGUE_LOG_DIR)"
done

crlf_env="$SANDBOX/crlf.env"
printf 'export ROGUE_API_KEY=%s\r\nexport ROGUE_BASE_URL=%s\r\nexport ROGUE_LOG_DIR=%s\r\n' \
  "'stale'" "'http://localhost:8007'" "'/var/log/rogue'" > "$crlf_env"
"$SH" -c '. "$1"; rogue_write_env_file "$2" ROGUE_API_KEY "new-key" ROGUE_ACTOR_EMAIL "e@x.io" ROGUE_ACTOR_NAME "N"' \
  _ "$REPO/scripts/shared/env-file.sh" "$crlf_env"
check "crlf: no CR survives the merge" "0"                       "$(tr -cd '\r' < "$crlf_env" | wc -c | tr -d ' ')"
check "crlf: base url usable"          "http://localhost:8007"   "$(sourced "$crlf_env" ROGUE_BASE_URL)"
check "crlf: log dir usable"           "/var/log/rogue"          "$(sourced "$crlf_env" ROGUE_LOG_DIR)"

unread_probe="$SANDBOX/unreadable-probe"
: > "$unread_probe"
chmod 000 "$unread_probe"
if cat "$unread_probe" >/dev/null 2>&1; then
  echo "  skip: mode 000 is readable anyway (running as root?)"
else
  impls="shared install"
  command -v node >/dev/null 2>&1 && impls="$impls node"
  for impl in $impls; do
    unread_env="$SANDBOX/unreadable-$impl/.rogue-env"; mkdir -p "${unread_env%/*}"
    seed "$unread_env"
    before="$(cat "$unread_env")"
    chmod 000 "$unread_env"
    set +e
    if [ "$impl" = shared ]; then
      "$SH" -c '. "$1"; rogue_write_env_file "$2" ROGUE_API_KEY "should-not-land" ROGUE_ACTOR_EMAIL "x@y.z" ROGUE_ACTOR_NAME "X"' \
        _ "$REPO/scripts/shared/env-file.sh" "$unread_env" >/dev/null 2>&1
    elif [ "$impl" = install ]; then
      ROGUE_INSTALL_LIB_ONLY=1 bash -c '
        . "$1"
        ENV_FILE="$2"
        ROGUE_API_KEY="should-not-land"; ROGUE_ACTOR_EMAIL="x@y.z"; ROGUE_ACTOR_NAME="X"
        write_env_file
      ' _ "$REPO/install.sh" "$unread_env" >/dev/null 2>&1
    else
      HOME="${unread_env%/*}" node "$REPO/plugins/gemini/scripts/setup.mjs" \
        "should-not-land" "x@y.z" "X" >/dev/null 2>&1
    fi
    unread_rc=$?
    set -e
    chmod 600 "$unread_env"
    check "$impl: unreadable file fails the write"  "1"       "$([ "$unread_rc" = 0 ] && echo 0 || echo 1)"
    check "$impl: unreadable file left intact"      "$before" "$(cat "$unread_env")"
    check "$impl: unreadable file leaves no temp"   "0"       "$(find "$SANDBOX/unreadable-$impl" -name '*.rogue-tmp.*' | wc -l | tr -d ' ')"
  done
fi
chmod 600 "$unread_probe"

def_env="$SANDBOX/install-default.env"
ROGUE_INSTALL_LIB_ONLY=1 bash -c '
  . "$1"
  ENV_FILE="$2"
  ROGUE_API_KEY="k"; ROGUE_ACTOR_EMAIL="e@x.io"; ROGUE_ACTOR_NAME="N"
  write_env_file >/dev/null 2>&1
' _ "$REPO/install.sh" "$def_env"
check "install.sh: default base url not written" "0" "$(count_lines "$def_env" '^export ROGUE_BASE_URL=')"

nl_env="$SANDBOX/linebreak.env"
seed "$nl_env"
nl_before="$(cat "$nl_env")"
NL_NAME="$(printf 'a\nb')"
set +e
"$SH" -c '. "$1"; rogue_write_env_file "$2" ROGUE_API_KEY "k" ROGUE_ACTOR_EMAIL "e@x.io" ROGUE_ACTOR_NAME "$3"' \
  _ "$REPO/scripts/shared/env-file.sh" "$nl_env" "$NL_NAME" >/dev/null 2>&1
nl_rc=$?
set -e
check "shared: line break in a value is refused" "1"           "$([ "$nl_rc" = 0 ] && echo 0 || echo 1)"
check "shared: line break leaves the file alone" "$nl_before"  "$(cat "$nl_env")"

cr_env="$SANDBOX/carriage.env"
seed "$cr_env"
set +e
"$SH" -c '. "$1"; rogue_write_env_file "$2" ROGUE_API_KEY "$3" ROGUE_ACTOR_EMAIL "e@x.io" ROGUE_ACTOR_NAME "N"' \
  _ "$REPO/scripts/shared/env-file.sh" "$cr_env" "$(printf 'k\rx')" >/dev/null 2>&1
cr_rc=$?
set -e
check "shared: carriage return in a value is refused" "1" "$([ "$cr_rc" = 0 ] && echo 0 || echo 1)"

for plugin in rogue codex cursor copilot antigravity; do
  pnl_env="$SANDBOX/linebreak-$plugin/.rogue-env"; mkdir -p "${pnl_env%/*}"
  seed "$pnl_env"
  pnl_before="$(cat "$pnl_env")"
  set +e
  HOME="${pnl_env%/*}" bash "$REPO/plugins/$plugin/scripts/setup.sh" "k" "e@x.io" "$NL_NAME" >/dev/null 2>&1
  pnl_rc=$?
  set -e
  check "$plugin: line break refused"            "1"            "$([ "$pnl_rc" = 0 ] && echo 0 || echo 1)"
  check "$plugin: line break leaves file intact" "$pnl_before"  "$(cat "$pnl_env")"
done

if command -v node >/dev/null 2>&1; then
  gnl_env="$SANDBOX/linebreak-gemini/.rogue-env"; mkdir -p "${gnl_env%/*}"
  seed "$gnl_env"
  gnl_before="$(cat "$gnl_env")"
  set +e
  HOME="${gnl_env%/*}" node "$REPO/plugins/gemini/scripts/setup.mjs" "k" "e@x.io" "$NL_NAME" >/dev/null 2>&1
  gnl_rc=$?
  set -e
  check "gemini: line break refused"            "1"           "$([ "$gnl_rc" = 0 ] && echo 0 || echo 1)"
  check "gemini: line break leaves file intact" "$gnl_before" "$(cat "$gnl_env")"
fi

inl_env="$SANDBOX/linebreak-install.env"
seed "$inl_env"
inl_before="$(cat "$inl_env")"
set +e
ROGUE_INSTALL_LIB_ONLY=1 NL_NAME="$NL_NAME" bash -c '
  . "$1"
  ENV_FILE="$2"
  ROGUE_API_KEY="k"; ROGUE_ACTOR_EMAIL="e@x.io"; ROGUE_ACTOR_NAME="$NL_NAME"
  write_env_file
' _ "$REPO/install.sh" "$inl_env" >/dev/null 2>&1
inl_rc=$?
set -e
check "install.sh: line break refused"            "1"           "$([ "$inl_rc" = 0 ] && echo 0 || echo 1)"
check "install.sh: line break leaves file intact" "$inl_before" "$(cat "$inl_env")"

mdm_env="$SANDBOX/mdm-base-url.env"
cat > "$mdm_env" <<'MDM'
export ROGUE_API_KEY='onbox'
export ROGUE_LOG_DIR='/var/log/rogue'
MDM
mdm_etc="$SANDBOX/mdm-etc-env"
printf "export ROGUE_BASE_URL='https://mdm.example'\n" > "$mdm_etc"
mdm_install="$SANDBOX/install-mdm.sh"
sed "s#/etc/rogue/env#$mdm_etc#g" "$REPO/install.sh" > "$mdm_install"
mdm_home="$SANDBOX/mdm-home"
mkdir -p "$mdm_home"
set +e
env -u CLAUDE_CODE_USER_EMAIL -u ROGUE_API_KEY -u ROGUE_BASE_URL \
    -u ROGUE_ACTOR_EMAIL -u ROGUE_ACTOR_NAME \
    HOME="$mdm_home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    ROGUE_INSTALL_LIB_ONLY=1 bash -c '
  . "$1"
  ENV_FILE="$2"
  NON_INTERACTIVE=1
  configure_credentials >/dev/null 2>&1
' _ "$mdm_install" "$mdm_env"
mdm_rc=$?
set -e
check "no actor identity anywhere still completes"     "0"                "$mdm_rc"
check "mdm base url not copied into the per-user file" "0"                "$(count_lines "$mdm_env" '^export ROGUE_BASE_URL=')"
check "mdm run still keeps other settings"             "/var/log/rogue"   "$(sourced "$mdm_env" ROGUE_LOG_DIR)"
check "mdm run still rotated the key"                  "onbox"            "$(sourced "$mdm_env" ROGUE_API_KEY)"

[ "$fails" = 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all env-file writer checks passed"
