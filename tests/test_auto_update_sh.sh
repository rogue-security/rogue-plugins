#!/usr/bin/env bash
# Unit tests for plugins/rogue/scripts/auto-update.sh.
#
# Black-box: the script is driven end to end with a fake `curl` on PATH and a
# throwaway HOME, because what matters is the DECISION (did it run the
# installer?), not any single helper.
#
# The regression this guards: the old version string-compared the release tag
# against "v${installed}", which cannot tell newer from older. Once the tag stops
# being a version, that comparison would re-run the installer every 24h forever
# whenever the manifest sat BEHIND the install.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/plugins/rogue/scripts/auto-update.sh"

# Run the script under the shell PRODUCTION uses, not the one its shebang names.
# hooks.json fires it as `sh "$CLAUDE_PLUGIN_ROOT/scripts/auto-update.sh"`, and an
# explicit interpreter overrides the `#!/usr/bin/env bash` line entirely - so on
# Ubuntu this really executes under dash. Running the test with bash would leave
# a bashism in the version compare undetected by every gate: the "Shell scripts
# parse" step keys off the shebang and checks it with `bash -n` for the same
# reason. CI runs this file twice, TEST_SH=sh and TEST_SH=dash.
SH="${TEST_SH:-sh}"
command -v "$SH" >/dev/null 2>&1 || { echo "SKIP: $SH not available"; exit 0; }
echo "== auto-update.sh under $SH =="
fails=0

ok() { echo "  ok: $1"; }
bad() { echo "FAIL [$1]: $2"; fails=$((fails + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A plugin tree carrying a known installed version.
PLUGIN_ROOT="$WORK/plugin"
mkdir -p "$PLUGIN_ROOT/.claude-plugin"
echo '{"name":"rogue","version":"1.0.28"}' > "$PLUGIN_ROOT/.claude-plugin/plugin.json"

# Fake curl: serves $MANIFEST_BODY for the versions.json URL, and for anything
# else (the installer fetch) writes a marker file so the test can tell whether
# the upgrade path was taken. Never touches the network.
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  *versions.json)
    if [ -n "${MANIFEST_BODY:-}" ]; then printf '%s' "$MANIFEST_BODY"; exit 0; fi
    exit 22 ;;
  *)
    echo "INSTALLER-FETCHED" > "$MARKER"
    echo "true"   # harmless script for the caller to pipe into bash
    exit 0 ;;
esac
STUB
chmod +x "$BIN/curl"

run() { # run <manifest-body> [VAR=VALUE ...]
  body="$1"; shift
  home="$WORK/home.$$.$RANDOM"
  mkdir -p "$home"
  marker="$home/marker"
  env -i PATH="$BIN:$PATH" HOME="$home" MARKER="$marker" \
    MANIFEST_BODY="$body" CLAUDE_CODE_ENTRYPOINT=cli \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$@" \
    "$SH" "$SCRIPT" >/dev/null 2>&1
  LAST_LOG="$home/.rogue/auto-update.log"
  [ -f "$marker" ] && echo ran || echo skipped
}

M() { printf '{"schema":1,"plugins":{"claude":"%s","codex":"1.0.2"}}' "$1"; }

# Installed 1.0.28 vs manifest 1.0.29 -> upgrade.
[ "$(run "$(M 1.0.29)")" = ran ] \
  && ok "newer manifest runs the installer" \
  || bad "newer manifest runs the installer" "installer was not fetched"

# Equal -> no upgrade.
[ "$(run "$(M 1.0.28)")" = skipped ] \
  && ok "equal version does not run the installer" \
  || bad "equal version does not run the installer" "installer was fetched"

# OLDER manifest -> no upgrade. This is the anti-loop property: string equality
# would have treated "different" as "newer" and reinstalled every 24h.
[ "$(run "$(M 1.0.27)")" = skipped ] \
  && ok "older manifest does not run the installer" \
  || bad "older manifest does not run the installer" "installer was fetched"

# Minor and major ordering, not lexical: 1.0.9 < 1.0.10 and 1.9.0 < 1.10.0.
echo '{"name":"rogue","version":"1.0.9"}' > "$PLUGIN_ROOT/.claude-plugin/plugin.json"
[ "$(run "$(M 1.0.10)")" = ran ] \
  && ok "1.0.9 -> 1.0.10 is an upgrade (numeric, not lexical)" \
  || bad "1.0.9 -> 1.0.10 is an upgrade" "installer was not fetched"
echo '{"name":"rogue","version":"1.9.0"}' > "$PLUGIN_ROOT/.claude-plugin/plugin.json"
[ "$(run "$(M 1.10.0)")" = ran ] \
  && ok "1.9.0 -> 1.10.0 is an upgrade" \
  || bad "1.9.0 -> 1.10.0 is an upgrade" "installer was not fetched"
echo '{"name":"rogue","version":"1.0.28"}' > "$PLUGIN_ROOT/.claude-plugin/plugin.json"

# A manifest with no claude key, or garbage, must fail OPEN (do nothing) rather
# than reinstall on a guess.
[ "$(run '{"schema":1,"plugins":{"codex":"1.0.2"}}')" = skipped ] \
  && ok "manifest without a claude key does nothing" \
  || bad "manifest without a claude key does nothing" "installer was fetched"
[ "$(run 'not json at all')" = skipped ] \
  && ok "unparseable manifest does nothing" \
  || bad "unparseable manifest does nothing" "installer was fetched"
[ "$(run '')" = skipped ] \
  && ok "unreachable manifest does nothing" \
  || bad "unreachable manifest does nothing" "installer was fetched"

# There is no opt-out: the removed flags no longer stop an update.
[ "$(run "$(M 1.0.29)" ROGUE_AUTO_UPDATE=0)" = ran ] \
  && ok "ROGUE_AUTO_UPDATE=0 no longer stops the updater" \
  || bad "ROGUE_AUTO_UPDATE=0 no longer stops the updater" "installer was not fetched"
[ "$(run "$(M 1.0.29)" ROGUE_PLUGIN_VERSION=r2026.08.20)" = ran ] \
  && ok "ROGUE_PLUGIN_VERSION no longer stops the updater" \
  || bad "ROGUE_PLUGIN_VERSION no longer stops the updater" "installer was not fetched"
# A compiled customer bundle carries its own env file and is replaced by its admin.
echo 'export ROGUE_API_KEY=bundled' > "$PLUGIN_ROOT/env"
[ "$(run "$(M 1.0.29)")" = skipped ] \
  && ok "a compiled bundle is left to its admin" \
  || bad "a compiled bundle is left to its admin" "installer was fetched"
rm -f "$PLUGIN_ROOT/env"

# hooks-matcher.ts in rogue-ui whitelists our own updater by matching a repo slug
# AND one of these env markers. Losing either makes Rogue's own hook read as a
# suspicious hook on every install in the field.
grep -q 'ROGUE_PLUGIN_REPO' "$SCRIPT" \
  && ok "keeps the ROGUE_PLUGIN_REPO marker (hooks-matcher whitelist)" \
  || bad "keeps the ROGUE_PLUGIN_REPO marker" "env var is gone"
grep -qE 'rogue-security/rogue-plugins|ROGUE_PLUGIN_REPO' "$SCRIPT" \
  && ok "keeps a repo slug in a URL (hooks-matcher whitelist)" \
  || bad "keeps a repo slug in a URL" "no repo reference found"

# The tag must no longer be consulted at all.
grep -q 'tag_name' "$SCRIPT" \
  && bad "no longer reads tag_name" "tag_name still referenced" \
  || ok "no longer reads tag_name"

echo ""
if [ "$fails" = 0 ]; then echo "auto-update.sh: all checks passed (SH=$SH)"; else
  echo "auto-update.sh: $fails failure(s) (SH=$SH)"; exit 1; fi
