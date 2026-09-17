#!/usr/bin/env bash
# Executes the bash block that skills/status/SKILL.md tells Claude to run, with
# the network stubbed, and asserts what it would POST to /hooks/status.
#
# Why a test for a markdown file: /rogue:status does not just print — it upserts
# a roster row, and the backend fingerprints that row on host|actor|family|agent.
# So the block has to resolve the actor exactly as the hooks do. It used to post
# ${ROGUE_ACTOR_*} straight out of the env files, which in a sandbox (or from a
# bundle compiled before the cascade fix) is Anthropic's synthetic identity —
# registering a second, wrongly-attributed row for the same install.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO/plugins/rogue/skills/status/SKILL.md"
ACTOR="$REPO/plugins/rogue/scripts/actor.sh"
# The skill resolves the surface through the SHARED table (scripts/surface.sh), the
# same one the hooks and the heartbeat read, rather than inlining a third copy of
# the cascade — so the fake plugin root has to carry it exactly as a real install
# does. Without it the skill falls back to its damaged-install literal and the
# Cowork case silently reports claude_code.
SURFACE="$REPO/plugins/rogue/scripts/surface.sh"
SH="${TEST_SH:-sh}"
fails=0

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
FAKE_HOME="$STAGE/home"
PLUGIN="$FAKE_HOME/.claude/plugins/rogue-marketplace/rogue"
mkdir -p "$PLUGIN/.claude-plugin" "$PLUGIN/scripts" "$STAGE/bin"
printf '{\n  "name": "rogue",\n  "version": "9.9.9"\n}\n' > "$PLUGIN/.claude-plugin/plugin.json"
cp "$ACTOR" "$PLUGIN/scripts/actor.sh"
cp "$SURFACE" "$PLUGIN/scripts/surface.sh"
cp "$REPO/plugins/rogue/scripts/git-identity.sh" "$PLUGIN/scripts/git-identity.sh"

# `env -i` clears USER, so the login level of the cascade ends at whoami; pin it.
cat > "$STAGE/bin/whoami" <<'EOF'
#!/bin/sh
echo jane
EOF
chmod +x "$STAGE/bin/whoami"

# The credential file a compiled bundle leaves behind, carrying the pre-seed that
# poisons ROGUE_ACTOR_* with the sandbox's git identity.
cat > "$STAGE/env.sh" <<'EOF'
export ROGUE_API_KEY=rsk_test
export ROGUE_ACTOR_EMAIL=noreply@anthropic.com
export ROGUE_ACTOR_NAME=Claude
EOF

# curl stub: print the request so the test can assert on it, send nothing.
cat > "$STAGE/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@"
EOF
chmod +x "$STAGE/bin/curl"

# Pull the block out of the doc and point its hardcoded /tmp env path at ours,
# so the test never reads or writes a real user's file.
extract() { # extract <marker> <outfile> — the bash block containing <marker>
  awk -v m="$1" '/^```bash$/{inb=1; buf=""; next} /^```$/{if (inb && buf ~ m) {printf "%s", buf; exit} inb=0} inb{buf = buf $0 "\n"}' \
    "$SKILL" | sed 's|/tmp/rogue-source-env.sh|'"$STAGE"'/env.sh|' > "$2"
  [ -s "$2" ] || { echo "FAIL: could not extract the block matching /$1/ from SKILL.md"; exit 1; }
  "$SH" -n "$2" || { echo "FAIL: extracted block ($1) is not valid POSIX sh"; exit 1; }
}
extract 'hooks\/status' "$STAGE/step2.sh"
extract 'Actor email'    "$STAGE/step4.sh"

run() { # run [VAR=VALUE ...] -> the stubbed request
  env -i HOME="$FAKE_HOME" PATH="$STAGE/bin:$PATH" "$@" "$SH" "$STAGE/step2.sh" 2>&1
}
run4() { # run4 [VAR=VALUE ...] -> what Step 4 reports to the user
  env -i HOME="$FAKE_HOME" PATH="$STAGE/bin:$PATH" "$@" "$SH" "$STAGE/step4.sh" 2>&1
}

assert_has() { # assert_has <needle> <haystack> <desc>
  case "$2" in
    *"$1"*) echo "  ok: $3" ;;
    *) echo "FAIL [$3]: expected to find <$1>"; fails=$((fails + 1)) ;;
  esac
}
assert_lacks() {
  case "$2" in
    *"$1"*) echo "FAIL [$3]: found <$1>, which must not be sent"; fails=$((fails + 1)) ;;
    *) echo "  ok: $3" ;;
  esac
}

echo "status skill Step 2 ($SH)"

# ── the poisoned env file must not reach the roster ────────────────────────
out=$(run CLAUDE_CODE_USER_EMAIL=real.user@corp.com CLAUDE_CODE_IS_COWORK=1)
assert_has  '"actor_email":"real.user@corp.com"' "$out" "actor email comes from the cascade, not the env file"
assert_has  '"actor_name":"real.user"'           "$out" "actor name comes from the cascade"
assert_lacks 'noreply@anthropic.com'             "$out" "poisoned ROGUE_ACTOR_EMAIL never posted"
assert_lacks '"actor_name":"Claude"'             "$out" "poisoned ROGUE_ACTOR_NAME never posted"

# ── the contract the route actually accepts ────────────────────────────────
assert_has 'POST'                                "$out" "request is a POST"
assert_has 'Content-Type: application/json'      "$out" "JSON content type sent"
assert_has '"agent_family":"claude"'             "$out" "agent_family present (the route 400s without it)"
assert_has '"version":"9.9.9"'                   "$out" "version read from the plugin manifest"
assert_has '"agent":"claude_cowork"'             "$out" "Cowork surface id, matching install-id.sh"
assert_lacks 'x-rogue-agent-family'              "$out" "no pre-JSON x-rogue-agent-* headers"

# ── the roster host must never go out blank ───────────────────────────────
# The row is fingerprinted on host|actor|family|agent, so a status run that
# posts an empty host opens a second row for an install whose hooks post a real
# one. Same property the Windows half gets from its COMPUTERNAME -> DNS cascade.
cat > "$STAGE/bin/hostname" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$STAGE/bin/hostname"
out=$(run CLAUDE_CODE_USER_EMAIL=real.user@corp.com)
assert_has '"host":"unknown"' "$out" "unresolvable hostname posts the unknown marker, not an empty host"
rm -f "$STAGE/bin/hostname"

# ── same block outside Cowork ──────────────────────────────────────────────
out=$(run CLAUDE_CODE_ENTRYPOINT=cli)
assert_has '"agent":"claude_code"'               "$out" "CLI surface id when not in Cowork"

# ── Step 4 must report what Step 2 posted, not the raw env file ───────────
# Otherwise the command registers the right row and then tells the user their
# actor is Claude <noreply@anthropic.com>, or claims blank actor headers when the
# cascade in fact resolved a real identity.
out=$(run4 CLAUDE_CODE_USER_EMAIL=real.user@corp.com)
assert_has  'Actor email: real.user@corp.com' "$out" "Step 4 shows the resolved email"
assert_has  'Actor name:  real.user'          "$out" "Step 4 shows the resolved name"
assert_lacks 'Actor email: noreply@anthropic.com' "$out" "Step 4 never shows the rejected env-file email"
assert_lacks 'Actor name:  Claude'                "$out" "Step 4 never shows the rejected env-file name"
assert_has  'note: env file holds'            "$out" "Step 4 flags that the env file was superseded"

# With no identity anywhere, the login stands in — not "(unset)", which used to be
# followed by advice claiming events POST with blank actor headers.
out=$(run4)
assert_has  'Actor email: jane@' "$out" "Step 4 reports login@host when nothing else resolves"
assert_has  'Actor name:  jane'  "$out" "Step 4 reports the login as the name"
assert_lacks '(unset)'           "$out" "Step 4 never reports an unset actor"

# The git identity comes from ~/.gitconfig as a file, the same as the hooks read it.
printf '[user]\n\temail = jane@corp.com\n\tname = Jane Dev\n' > "$FAKE_HOME/.gitconfig"
out=$(run4)
assert_has  'Actor email: jane@corp.com' "$out" "Step 4 reports the ~/.gitconfig identity"
assert_has  'Actor name:  Jane Dev'      "$out" "Step 4 reports the ~/.gitconfig name"
rm -f "$FAKE_HOME/.gitconfig"

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all status skill tests passed"
