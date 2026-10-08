#!/usr/bin/env bash
# Unit tests for scripts/plugin-versions.sh — the ONLY reader of the seven plugin
# version files.
#
# This script's output is the contract the backend resolves "outdated" from, so a
# regression here is silent in the worst way: a missing key reads as "up to date"
# forever, and a malformed value makes semver.coerce return null, which also reads
# as "up to date". Both must fail the BUILD instead.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/scripts/plugin-versions.sh"
fails=0

ok() { echo "  ok: $1"; }
bad() { echo "FAIL [$1]: $2"; fails=$((fails + 1)); }

# ── Against the real tree ────────────────────────────────────────────────────
out=$(bash "$SCRIPT" "$REPO" 2>/dev/null) || { bad "real tree" "exited non-zero"; out=""; }

flat=$(printf '%s' "$out" | tr -d ' \t\n\r')

for slug in claude codex cursor copilot gemini antigravity kiro muse; do
  case "$flat" in
    *"\"$slug\":\""*) ok "emits $slug" ;;
    *) bad "emits $slug" "key missing from: $out" ;;
  esac
done

case "$flat" in
  *'"schema":1'*) ok "carries schema 1" ;;
  *) bad "carries schema 1" "not found in: $out" ;;
esac

# Exactly seven plugin keys — an extra key means a plugin was added without a
# matching backend mapping, which resolves to null (never outdated).
keys=$(printf '%s' "$flat" | grep -oE '"[a-z]+":"[0-9]+\.[0-9]+\.[0-9]+"' | wc -l | tr -d ' ')
if [ "$keys" = "8" ]; then ok "exactly eight plugin versions"; else
  bad "exactly eight plugin versions" "found $keys"; fi

# Every value must be a bare X.Y.Z. "unknown", "v1.2.3" and "1.2" all coerce
# wrong on the consumer side.
bogus=$(printf '%s' "$flat" | grep -oE '"[a-z]+":"[^"]*"' | grep -vE '"schema"' \
  | grep -vE '"[a-z]+":"[0-9]+\.[0-9]+\.[0-9]+"' || true)
if [ -z "$bogus" ]; then ok "all values are bare X.Y.Z"; else
  bad "all values are bare X.Y.Z" "$bogus"; fi

# Every value must equal what that plugin's OWN version file says — all seven, not
# a sample. The slug-to-file mapping is hand-written per plugin, so a slug reading
# from the wrong file produces a valid-looking X.Y.Z that every other check here
# accepts. That is precisely the bug this manifest exists to end: a version key
# that reads as something it is not.
expect_json() { # <slug> <path-relative-to-repo>
  _exp=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$REPO/$2" \
    | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  if [ -z "$_exp" ]; then bad "$1 matches its manifest" "could not read a version from $2"; return; fi
  case "$flat" in
    *"\"$1\":\"$_exp\""*) ok "$1 matches $2 ($_exp)" ;;
    *) bad "$1 matches $2" "expected $_exp in: $out" ;;
  esac
}

expect_json claude  plugins/rogue/.claude-plugin/plugin.json
expect_json codex   plugins/codex/.codex-plugin/plugin.json
expect_json cursor  plugins/cursor/.cursor-plugin/plugin.json
expect_json copilot plugins/copilot/plugin.json
expect_json gemini  plugins/gemini/gemini-extension.json

# Antigravity is the one plugin whose version is NOT in a JSON manifest: its CLI
# schema is additionalProperties:false, so the version of record is a bare file.
agv_expected=$(head -n1 "$REPO/plugins/antigravity/VERSION" | tr -d ' \r\n')
case "$flat" in
  *"\"antigravity\":\"$agv_expected\""*) ok "antigravity matches its VERSION file ($agv_expected)" ;;
  *) bad "antigravity matches its VERSION file" "expected $agv_expected in: $out" ;;
esac

# Kiro carries BOTH: plugin.json is the version of record (every runtime reader
# - install-id.sh, hook.ps1, heartbeat.ps1 - takes it from there) and a bare
# VERSION file beside it for operators and the release page. Two files is one
# drift waiting to happen, so the manifest reader refuses to publish while
# they disagree rather than picking one.
kiro_file=$(head -n1 "$REPO/plugins/kiro/VERSION" 2>/dev/null | tr -d ' \r\n')
kiro_json=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$REPO/plugins/kiro/plugin.json" \
  | head -1 | sed -E 's/.*"([^"]*)"$/\1/')
if [ -n "$kiro_file" ] && [ "$kiro_file" = "$kiro_json" ]; then ok "kiro VERSION file mirrors plugin.json ($kiro_file)"; else
  bad "kiro VERSION file mirrors plugin.json" "VERSION=[$kiro_file] plugin.json=[$kiro_json]"; fi

# ── Fail-hard cases, against fixture trees ───────────────────────────────────
# A build that emits a manifest with a hole is worse than a build that fails:
# the hole is invisible and reads as "up to date".
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/plugins/rogue/.claude-plugin" "$fixture/plugins/codex/.codex-plugin" \
         "$fixture/plugins/cursor/.cursor-plugin" "$fixture/plugins/copilot" \
         "$fixture/plugins/gemini" "$fixture/plugins/antigravity" "$fixture/plugins/kiro" "$fixture/plugins/muse"
echo '{"version":"1.2.3"}' > "$fixture/plugins/rogue/.claude-plugin/plugin.json"
echo '{"version":"2.3.4"}' > "$fixture/plugins/codex/.codex-plugin/plugin.json"
echo '{"version":"3.4.5"}' > "$fixture/plugins/cursor/.cursor-plugin/plugin.json"
echo '{"version":"9.9.9"}' > "$fixture/plugins/kiro/plugin.json"
echo '9.9.9' > "$fixture/plugins/kiro/VERSION"
echo '{"version":"0.1.0"}' > "$fixture/plugins/muse/plugin.json"
echo '{"version":"4.5.6"}' > "$fixture/plugins/copilot/plugin.json"
echo '{"version":"5.6.7"}' > "$fixture/plugins/gemini/gemini-extension.json"
echo '6.7.8' > "$fixture/plugins/antigravity/VERSION"

out=$(bash "$SCRIPT" "$fixture" 2>/dev/null) || bad "complete fixture tree succeeds" "exited non-zero"
flat=$(printf '%s' "$out" | tr -d ' \t\n\r')
for mapping in claude:1.2.3 codex:2.3.4 cursor:3.4.5 copilot:4.5.6 gemini:5.6.7 antigravity:6.7.8 kiro:9.9.9 muse:0.1.0; do
  slug=${mapping%%:*}; expected=${mapping#*:}
  case "$flat" in
    *"\"$slug\":\"$expected\""*) ok "$slug reads its own fixture ($expected)" ;;
    *) bad "$slug reads its own fixture" "$out" ;;
  esac
done

rm -f "$fixture/plugins/gemini/gemini-extension.json"
if bash "$SCRIPT" "$fixture" >/dev/null 2>&1; then
  bad "missing manifest fails" "exited 0"; else ok "missing manifest fails"; fi
echo '{"version":"9.9.9"}' > "$fixture/plugins/gemini/gemini-extension.json"

echo '{"name":"rogue"}' > "$fixture/plugins/copilot/plugin.json"
if bash "$SCRIPT" "$fixture" >/dev/null 2>&1; then
  bad "manifest with no version fails" "exited 0"; else ok "manifest with no version fails"; fi
echo '{"version":"9.9.9"}' > "$fixture/plugins/copilot/plugin.json"

: > "$fixture/plugins/antigravity/VERSION"
if bash "$SCRIPT" "$fixture" >/dev/null 2>&1; then
  bad "empty VERSION file fails" "exited 0"; else ok "empty VERSION file fails"; fi
echo '9.9.9' > "$fixture/plugins/antigravity/VERSION"

# A kiro VERSION file that disagrees with plugin.json, or is missing, fails the
# build: publishing either value would be a manifest asserting a version half
# the plugin does not carry.
echo '9.9.8' > "$fixture/plugins/kiro/VERSION"
if bash "$SCRIPT" "$fixture" >/dev/null 2>&1; then
  bad "kiro VERSION drift fails" "exited 0 with VERSION 9.9.8 vs plugin.json 9.9.9"; else ok "kiro VERSION drift fails"; fi
rm -f "$fixture/plugins/kiro/VERSION"
if bash "$SCRIPT" "$fixture" >/dev/null 2>&1; then
  bad "missing kiro VERSION fails" "exited 0"; else ok "missing kiro VERSION fails"; fi
echo '9.9.9' > "$fixture/plugins/kiro/VERSION"

# ── The whole field must be validated, not a substring ───────────────────────
# Both readers used to extract a THREE-FIELD SUBSTRING out of the value and throw
# the rest away, so "1.2.3-beta" was published as "1.2.3" — a manifest stating a
# version the plugin does not have. That is the same silent-lie class this whole
# manifest exists to end, and it defeated the documented build-hard guarantee.
# Antigravity's was worse: a `[0-9]*.[0-9]*.[0-9]*` GLOB, where `*` is a wildcard,
# so "1a.2b.3c" and "9.9.9junk" were accepted and emitted VERBATIM.
CV_JSON="$fixture/plugins/copilot/plugin.json"
for bogus in '1.2.3-beta' '1.2.3+build7' '1.2.3.4' '1.2' '1.2.3beta' 'v1.2.3' '1.2.3 '; do
  printf '{"version":"%s"}\n' "$bogus" > "$CV_JSON"
  if got=$(bash "$SCRIPT" "$fixture" 2>/dev/null); then
    emitted=$(printf '%s' "$got" | tr -d ' \t\n\r' \
      | grep -oE '"copilot":"[^"]*"' | sed -E 's/.*:"//; s/"$//')
    bad "JSON version '$bogus' fails the build" "exited 0 and published '$emitted'"
  else
    ok "JSON version '$bogus' fails the build"
  fi
done
echo '{"version":"9.9.9"}' > "$CV_JSON"

AGV="$fixture/plugins/antigravity/VERSION"
for bogus in '1.2.3-beta' '1a.2b.3c' '9.9.9junk' '1.2.3.4.5' '1.2.3-' '1.2' 'v1.2.3'; do
  printf '%s\n' "$bogus" > "$AGV"
  if got=$(bash "$SCRIPT" "$fixture" 2>/dev/null); then
    emitted=$(printf '%s' "$got" | tr -d ' \t\n\r' \
      | grep -oE '"antigravity":"[^"]*"' | sed -E 's/.*:"//; s/"$//')
    bad "VERSION '$bogus' fails the build" "exited 0 and published '$emitted'"
  else
    ok "VERSION '$bogus' fails the build"
  fi
done

# ...and the shapes that MUST still pass: surrounding whitespace and a CRLF line
# ending are stripped, not rejected. Tightening validation must not start failing
# a VERSION file that a Windows editor saved.
printf '  1.2.3  \n' > "$AGV"
if bash "$SCRIPT" "$fixture" 2>/dev/null | tr -d ' \t\n\r' | grep -q '"antigravity":"1.2.3"'; then
  ok "VERSION tolerates surrounding whitespace"; else
  bad "VERSION tolerates surrounding whitespace" "did not yield 1.2.3"; fi
printf '1.2.3\r\n' > "$AGV"
if bash "$SCRIPT" "$fixture" 2>/dev/null | tr -d ' \t\n\r' | grep -q '"antigravity":"1.2.3"'; then
  ok "VERSION tolerates a CRLF line ending"; else
  bad "VERSION tolerates a CRLF line ending" "did not yield 1.2.3"; fi
# Wide numbers are legitimate semver and must not be rejected.
printf '11.22.33\n' > "$AGV"
if bash "$SCRIPT" "$fixture" 2>/dev/null | tr -d ' \t\n\r' | grep -q '"antigravity":"11.22.33"'; then
  ok "multi-digit fields are accepted"; else
  bad "multi-digit fields are accepted" "11.22.33 was rejected"; fi
echo '9.9.9' > "$AGV"

# A JSON manifest whose FIRST version field is bogus must fail, not skip ahead to
# a later well-formed one — the first is the authoritative field.
printf '{"version":"1.2.3-beta","other":{"version":"9.9.9"}}\n' > "$CV_JSON"
if bash "$SCRIPT" "$fixture" >/dev/null 2>&1; then
  bad "a bogus first version field fails" "exited 0, so it read a later field"; else
  ok "a bogus first version field fails"; fi
echo '{"version":"9.9.9"}' > "$CV_JSON"

# ── build-release.sh must publish the manifest, not re-read the files ────────
# Two readers is how the manifest and the tarballs drift apart.
if grep -qE '\|\| echo "unknown"' "$REPO/scripts/build-release.sh"; then
  bad "no soft-fail version read" "build-release.sh still has || echo \"unknown\""
else
  ok "no soft-fail version read"
fi

reads=$(grep -cE 'grep -oE .\"version\"' "$REPO/scripts/build-release.sh" || true)
if [ "$reads" = "0" ]; then ok "build-release.sh does not re-read version files"; else
  bad "build-release.sh does not re-read version files" "$reads direct read(s) remain"; fi

if grep -q 'plugin-versions.sh' "$REPO/scripts/build-release.sh"; then
  ok "build-release.sh calls plugin-versions.sh"
else
  bad "build-release.sh calls plugin-versions.sh" "no reference found"
fi

if grep -q 'versions.json' "$REPO/scripts/build-release.sh"; then
  ok "build-release.sh writes versions.json"
else
  bad "build-release.sh writes versions.json" "no reference found"
fi

echo ""
if [ "$fails" = 0 ]; then echo "plugin-versions.sh: all checks passed"; else
  echo "plugin-versions.sh: $fails failure(s)"; exit 1; fi
