#!/usr/bin/env bash
# compile-customer-plugin.sh bakes the bundle's env file. A fake curl serves a release tarball made
# from plugins/rogue, so this runs offline.
#
# ROGUE_AUTO_UPDATE=0 stays in that file although the current updater ignores it: a bundle compiled
# --from an older release carries that release's updater, which stands down only on this line.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0
check() { # <label> <needle> <haystack>
  case "$3" in *"$2"*) echo "  ok: $1" ;; *) echo "FAIL: $1 ([$2] not in [$3])"; fails=$((fails + 1)) ;; esac
}

mkdir -p "$T/src/rogue-plugin-claude/plugins" "$T/bin"
cp -R "$REPO/plugins/rogue" "$T/src/rogue-plugin-claude/plugins/"
tar -czf "$T/release.tar.gz" -C "$T/src" rogue-plugin-claude
# Only the tarball download is expected (--from skips the latest-release lookup).
cat > "$T/bin/curl" <<EOF
#!/bin/sh
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && { cp "$T/release.tar.gz" "\$2"; exit 0; }; shift; done
exit 1
EOF
chmod +x "$T/bin/curl"

echo "the compiled env file"
PATH="$T/bin:$PATH" bash "$REPO/scripts/compile-customer-plugin.sh" \
  --key rsk_test --from v9.9.9 --out "$T/bundle.zip" >/dev/null 2>&1 || { echo "FAIL: compile exited $?"; exit 1; }
ENV_FILE="$(python3 -c 'import sys, zipfile; print(zipfile.ZipFile(sys.argv[1]).read("env").decode())' "$T/bundle.zip")"
check "carries the API key" "export ROGUE_API_KEY=rsk_test" "$ENV_FILE"
check "carries the mode" "export ROGUE_PRETOOLUSE_ON_BLOCK=ask" "$ENV_FILE"
check "keeps older updaters from updating the bundle" "export ROGUE_AUTO_UPDATE=0" "$ENV_FILE"

[ "$fails" -eq 0 ] || { echo "FAIL: $fails check(s)"; exit 1; }
echo "OK: compiled customer bundle"
