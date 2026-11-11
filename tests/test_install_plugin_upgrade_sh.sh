#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0

ok()  { echo "  ok: $1"; }
bad() { echo "FAIL [$1]: $2"; fails=$((fails + 1)); }
check() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}

BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
printf '{}\n200'
STUB
cat > "$BIN/fake-plugin-cli" <<'STUB'
#!/usr/bin/env bash
cli="$(basename "$0")"
snapshot="$HOME/$cli-marketplace-snapshot"
installed="$HOME/$cli-installed-version"
installed_slug="$HOME/$cli-installed-slug"
echo "$*" >> "$HOME/$cli.log"
[ -z "${FAKE_CLI_BROKEN:-}" ] || exit 1
case "$*" in
  "plugin marketplace add "*)
    if [ -f "$snapshot" ]; then
      [ "$cli" = copilot ] && exit 1
      exit 0
    fi
    printf '%s' "$PUBLISHED_VERSION" > "$snapshot" ;;
  "plugin marketplace update "*|"plugin marketplace upgrade "*)
    [ -f "$snapshot" ] || exit 1
    [ -z "${FAKE_REFRESH_BROKEN:-}" ] || exit 1
    printf '%s' "$PUBLISHED_VERSION" > "$snapshot" ;;
  "plugin list")
    [ -z "${FAKE_LIST_BROKEN:-}" ] || exit 1
    cat "$installed_slug" 2>/dev/null ;;
  "plugin install "*)
    [ -f "$installed" ] && exit 0
    cp "$snapshot" "$installed"
    printf '%s\n' "$3" > "$installed_slug" ;;
  "plugin update "*)
    [ -f "$installed" ] || exit 1
    [ -z "${FAKE_UPDATE_BROKEN:-}" ] || exit 1
    cp "$snapshot" "$installed" ;;
  "plugin add "*)
    cp "$snapshot" "$installed" ;;
esac
exit 0
STUB
chmod +x "$BIN/curl" "$BIN/fake-plugin-cli"
for cli in claude codex copilot; do ln -s fake-plugin-cli "$BIN/$cli"; done

OUT="$WORK/out"; ERR="$WORK/err"
run_install() {
  local home="$1"; shift
  mkdir -p "$home"
  set +e
  ( cd "$home" && env "$@" PATH="$BIN:$PATH" HOME="$home" NO_COLOR=1 ROGUE_NON_INTERACTIVE=1 \
      ROGUE_API_KEY=test-key bash "$REPO/install.sh" --claude --codex --copilot ) > "$OUT" 2> "$ERR"
  LAST_RC=$?
  set -e
}
installed_version() { cat "$1/$2-installed-version" 2>/dev/null || echo none; }

H="$WORK/fresh"
run_install "$H" PUBLISHED_VERSION=1.0.0
check "fresh: install exits 0" "0" "$LAST_RC"
[ "$LAST_RC" = 0 ] || cat "$ERR"
for cli in claude codex copilot; do
  check "fresh: $cli gets the published version" "1.0.0" "$(installed_version "$H" "$cli")"
done
check "fresh: claude installs the qualified plugin"  "1" "$(grep -cx 'plugin install rogue@rogue-marketplace' "$H/claude.log")"
check "fresh: copilot installs the qualified plugin" "1" "$(grep -cx 'plugin install rogue@rogue-copilot' "$H/copilot.log")"

rm -f "$H"/*.log
run_install "$H" PUBLISHED_VERSION=1.0.1
check "upgrade: install exits 0" "0" "$LAST_RC"
[ "$LAST_RC" = 0 ] || cat "$ERR"
for cli in claude codex copilot; do
  check "upgrade: $cli moves to the newly published version" "1.0.1" "$(installed_version "$H" "$cli")"
done
check "upgrade: claude refreshes its marketplace"  "1" "$(grep -cx 'plugin marketplace update rogue-marketplace' "$H/claude.log")"
check "upgrade: codex refreshes its marketplace"   "1" "$(grep -cx 'plugin marketplace upgrade rogue-marketplace' "$H/codex.log")"
check "upgrade: copilot refreshes its marketplace" "1" "$(grep -cx 'plugin marketplace update rogue-copilot' "$H/copilot.log")"
check "upgrade: claude and copilot report the update" "2" "$(grep -c 'Plugin updated' "$ERR" || :)"

run_install "$H" PUBLISHED_VERSION=1.0.2
for cli in claude codex copilot; do
  check "second upgrade: $cli moves again" "1.0.2" "$(installed_version "$H" "$cli")"
done

run_install "$H" PUBLISHED_VERSION=1.0.3 FAKE_UPDATE_BROKEN=1
[ "$LAST_RC" != 0 ] && ok "failed update: install fails" || bad "failed update: install fails" "exited 0"
check "failed update: claude stays on its version" "1.0.2" "$(installed_version "$H" claude)"
check "failed update: the error names the update command" "1" \
  "$(grep -c "Run 'claude plugin update rogue@rogue-marketplace' to see the error" "$ERR" || :)"
check "failed update: no success is reported" "0" "$(grep -c 'Plugin installed' "$ERR" || :)"

run_install "$H" PUBLISHED_VERSION=1.0.3 FAKE_LIST_BROKEN=1
[ "$LAST_RC" != 0 ] && ok "failed listing: install fails" || bad "failed listing: install fails" "exited 0"
check "failed listing: claude stays on its version" "1.0.2" "$(installed_version "$H" claude)"
check "failed listing: the error names the list command" "1" "$(grep -c "Run 'claude plugin list' to see the error" "$ERR" || :)"
check "failed listing: no success is reported" "0" "$(grep -c 'Plugin installed' "$ERR" || :)"

run_install "$H" PUBLISHED_VERSION=1.0.4 FAKE_REFRESH_BROKEN=1
check "failed refresh: claude stays on the last fetched version" "1.0.3" "$(installed_version "$H" claude)"
check "failed refresh: the warning says the plugin may not move" "3" "$(grep -c 'marketplace — the plugin may stay at its current version' "$ERR" || :)"

H="$WORK/broken"
run_install "$H" PUBLISHED_VERSION=1.0.0 FAKE_CLI_BROKEN=1
[ "$LAST_RC" != 0 ] && ok "broken: install fails" || bad "broken: install fails" "exited 0"
check "broken: the error names the command to retry" "1" \
  "$(grep -c "Run 'claude plugin list' to see the error" "$ERR" || :)"

[ "$fails" -eq 0 ] && echo "all plugin upgrade installer tests passed" || { echo "$fails failure(s)"; exit 1; }
