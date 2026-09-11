#!/usr/bin/env bash
# tests/test_actor_sh.sh — the actor identity cascade: plugins/rogue/scripts/actor.sh
# (Claude: screens the Cowork sandbox identity, ranks CLAUDE_CODE_USER_EMAIL above
# git) and scripts/shared/actor.sh (codex/copilot/antigravity/kiro, tested through
# the synced codex copy). Both read the git identity from the config FILES via
# scripts/git-identity.sh, so a stub `git` ahead of PATH is a tripwire: on a Mac
# without the Command Line Tools `git` is a stub that opens the installer dialog,
# and a hook must never trigger it.
#
# Three fallback levels per bridge: env file → git config files → login@hostname.
#
# actor.sh is sourced by hook.sh, which hooks.json invokes via `sh`; override with
# TEST_SH=dash to exercise strict POSIX (Debian/Ubuntu /bin/sh) and catch bashisms.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROGUE_ACTOR="$REPO/plugins/rogue/scripts/actor.sh"
SHARED_ACTOR="$REPO/plugins/codex/scripts/actor.sh"
SH="${TEST_SH:-sh}"

STUB="$(mktemp -d)"
FAKE_HOME="$(mktemp -d)"
TRIPWIRE="$STUB/git-invoked"
cleanup() { rm -rf "$STUB" "$FAKE_HOME"; }
trap cleanup EXIT

# hostname / whoami stubs make the login@host level deterministic; `git` records
# every invocation and fails, so a cascade that still shells out is caught twice.
cat > "$STUB/hostname" <<'EOF'
#!/bin/sh
[ -n "${STUB_HOSTNAME:-}" ] || exit 1
printf '%s\n' "$STUB_HOSTNAME"
EOF
cat > "$STUB/whoami" <<'EOF'
#!/bin/sh
[ -n "${STUB_WHOAMI:-}" ] || exit 1
printf '%s\n' "$STUB_WHOAMI"
EOF
cat > "$STUB/git" <<EOF
#!/bin/sh
echo "git \$*" >> "$TRIPWIRE"
exit 1
EOF
chmod +x "$STUB/hostname" "$STUB/whoami" "$STUB/git"

# Writes the [user] section GIT_EMAIL / GIT_NAME describe into ~/.gitconfig (no
# file at all when both are empty), after clearing every git config file.
write_gitconfig() {
  rm -rf "$FAKE_HOME/.gitconfig" "$FAKE_HOME/.gitconfig-work" "$FAKE_HOME/.config"
  if [ -n "$GIT_EMAIL" ] || [ -n "$GIT_NAME" ]; then
    {
      echo "[user]"
      if [ -n "$GIT_EMAIL" ]; then printf '\temail = %s\n' "$GIT_EMAIL"; fi
      if [ -n "$GIT_NAME" ];  then printf '\tname = %s\n'  "$GIT_NAME";  fi
    } > "$FAKE_HOME/.gitconfig"
  fi
}

# Source the actor script under test in a fresh shell and print what it resolved.
# Empty is passed instead of unset on purpose: the cascade must treat both alike.
# USER/USERNAME are cleared so the login level goes through the whoami stub.
resolve() {
  HOME="$FAKE_HOME" XDG_CONFIG_HOME= PATH="$STUB:$PATH" USER="${LOGIN_ENV:-}" USERNAME= \
  CLAUDE_PLUGIN_ROOT="${ROOT_DIR:-$REPO/plugins/rogue}" PLUGIN_ROOT="${ROOT_DIR:-$REPO/plugins/codex}" \
  ROGUE_ACTOR_EMAIL="${SEED_EMAIL:-}" ROGUE_ACTOR_NAME="${SEED_NAME:-}" \
  CLAUDE_CODE_USER_EMAIL="${HOST_EMAIL:-}" \
  STUB_HOSTNAME="${HOST_NAME:-}" STUB_WHOAMI="${WHO:-}" \
    "$SH" -c '. "$1"; printf "%s|%s" "$ROGUE_ACTOR_EMAIL" "$ROGUE_ACTOR_NAME"' _ "$ACTOR"
}

assert_actor() {
  local expected="$1" label="$2" actual
  write_gitconfig
  actual="$(resolve)"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL [$label]: expected <$expected> but got <$actual>" >&2; exit 1
  fi
  echo "  ok: $label"
}

# Every case sets the whole environment explicitly, so no state leaks between them.
scenario() {
  SEED_EMAIL=""; SEED_NAME=""; HOST_EMAIL=""; LOGIN_ENV=""; ROOT_DIR=""
  GIT_EMAIL=""; GIT_NAME=""; HOST_NAME="devbox"; WHO="jane"
}

echo "── plugins/rogue/scripts/actor.sh ──"
ACTOR="$ROGUE_ACTOR"

# ── Case 1: normal dev machine — real git identity, no host email (no regression)
scenario
GIT_EMAIL="jane@corp.com"; GIT_NAME="Jane Dev"
assert_actor "jane@corp.com|Jane Dev" "git identity from ~/.gitconfig wins when CLAUDE_CODE_USER_EMAIL is absent"

# ── Case 2: CLAUDE_CODE_USER_EMAIL outranks a real git identity ───────────────
scenario
HOST_EMAIL="real.user@corp.com"
GIT_EMAIL="jane@corp.com"; GIT_NAME="Jane Dev"
assert_actor "real.user@corp.com|real.user" "CLAUDE_CODE_USER_EMAIL beats git config (name = local-part)"

# ── Case 3: the Cowork sandbox — synthetic git identity is rejected ───────────
scenario
HOST_EMAIL="real.user@corp.com"
GIT_EMAIL="noreply@anthropic.com"; GIT_NAME="Claude"; WHO="claude"; HOST_NAME="sandbox"
assert_actor "real.user@corp.com|real.user" "synthetic git identity rejected in favor of CLAUDE_CODE_USER_EMAIL"

# ── Case 4: a POISONED ROGUE_ACTOR_* (old compiled bundle pre-seed) is rejected
# This is the field-repair path: bundles built before this fix bake
# `: "${ROGUE_ACTOR_EMAIL:=$(git config --global user.email)}"` into
# ${CLAUDE_PLUGIN_ROOT}/env, which hook.sh sources BEFORE actor.sh.
scenario
SEED_EMAIL="noreply@anthropic.com"; SEED_NAME="Claude"
HOST_EMAIL="real.user@corp.com"
GIT_EMAIL="noreply@anthropic.com"; GIT_NAME="Claude"; WHO="claude"
assert_actor "real.user@corp.com|real.user" "poisoned ROGUE_ACTOR_* rejected, CLAUDE_CODE_USER_EMAIL used"

# ── Case 5: a legitimate ROGUE_ACTOR_* still wins outright ────────────────────
scenario
SEED_EMAIL="mdm@corp.com"; SEED_NAME="MDM Provisioned"
HOST_EMAIL="real.user@corp.com"; GIT_EMAIL="jane@corp.com"; GIT_NAME="Jane Dev"
assert_actor "mdm@corp.com|MDM Provisioned" "explicit ROGUE_ACTOR_* (MDM/setup) keeps top precedence"

# ── Case 6: everything synthetic → the unknown marker, never a plausible name ─
scenario
SEED_EMAIL="noreply@anthropic.com"; SEED_NAME="claude code"
GIT_EMAIL="noreply@anthropic.com"; GIT_NAME="Claude"
WHO="claude"; HOST_NAME="sandbox-7f3a"
assert_actor "unknown@sandbox-7f3a|unknown" "all-synthetic input yields the unknown marker (hostname kept as domain)"

# ── Case 7: no hostname either → plain unknown ────────────────────────────────
scenario
GIT_NAME="Claude"; WHO="claude"; HOST_NAME=""
assert_actor "unknown|unknown" "plain unknown when hostname is unavailable"

# ── Case 8: synthetic matching is case/whitespace-insensitive ─────────────────
scenario
SEED_NAME="  CLAUDE   Code "; SEED_EMAIL="  NoReply@Anthropic.COM "
GIT_EMAIL="jane@corp.com"; GIT_NAME="Jane Dev"
assert_actor "jane@corp.com|Jane Dev" "synthetic match ignores case and surrounding/repeated whitespace"

# ── Case 9: whitespace-only values are rejected like empties ──────────────────
scenario
SEED_NAME="   "; SEED_EMAIL="  "
GIT_EMAIL="jane@corp.com"; GIT_NAME="Jane Dev"
assert_actor "jane@corp.com|Jane Dev" "whitespace-only ROGUE_ACTOR_* rejected"

# ── Case 10: only EXACT synthetic values are rejected — real humans pass ──────
scenario
GIT_EMAIL="claude.dubois@corp.com"; GIT_NAME="Claudia Claude-Smith"
assert_actor "claude.dubois@corp.com|Claudia Claude-Smith" "names merely containing 'claude' are NOT rejected"

# ── Case 11: fields resolve independently (synthetic email, real git name) ────
scenario
GIT_EMAIL="noreply@anthropic.com"; GIT_NAME="Jane Dev"; HOST_NAME="devbox"
assert_actor "jane@devbox|Jane Dev" "email and name cascades are independent"

# ── Case 12: no git identity → login@hostname / login, never blank ────────────
scenario
GIT_EMAIL=""; GIT_NAME=""; WHO="jane"; HOST_NAME="devbox"
assert_actor "jane@devbox|jane" "login@hostname and login when no git identity exists"

# ── Case 13: the synthetic host email must not leak in through its local-part ─
# Screening the full address but splitting it first would report the actor as
# "noreply": that local-part is not itself on the screen list, so the whole
# address has to be rejected BEFORE the split.
scenario
HOST_EMAIL="noreply@anthropic.com"
GIT_EMAIL=""; GIT_NAME=""; WHO="claude"; HOST_NAME="sandbox-7f3a"
assert_actor "unknown@sandbox-7f3a|unknown" "synthetic CLAUDE_CODE_USER_EMAIL yields no name at all"

# ── Case 14: a real address whose local-part is itself synthetic ─────────────
scenario
HOST_EMAIL="claude@corp.com"
GIT_EMAIL=""; GIT_NAME=""; WHO="jane"; HOST_NAME="devbox"
assert_actor "claude@corp.com|jane" "real address kept as email, unusable local-part falls through"

# ── Case 15: $USER outranks whoami for the login level ───────────────────────
scenario
LOGIN_ENV="envuser"; WHO="jane"
assert_actor "envuser@devbox|envuser" "USER from the environment is the login when set"

# ── Case 16: [include] path is followed, one level ────────────────────────────
scenario
write_gitconfig
printf '[include]\n\tpath = ~/.gitconfig-work\n' > "$FAKE_HOME/.gitconfig"
printf '[user]\n\temail = work@corp.com\n\tname = "Work Me"\n' > "$FAKE_HOME/.gitconfig-work"
actual="$(resolve)"
[ "$actual" = "work@corp.com|Work Me" ] || { echo "FAIL [include]: got <$actual>" >&2; exit 1; }
echo "  ok: identity inside an [include] path file is used (quoted value unwrapped)"

# ── Case 17: [includeIf] is not evaluated ─────────────────────────────────────
scenario
write_gitconfig
printf '[includeIf "gitdir:~/work/"]\n\tpath = ~/.gitconfig-work\n' > "$FAKE_HOME/.gitconfig"
printf '[user]\n\temail = never@corp.com\n' > "$FAKE_HOME/.gitconfig-work"
actual="$(resolve)"
[ "$actual" = "jane@devbox|jane" ] || { echo "FAIL [includeIf]: got <$actual>" >&2; exit 1; }
echo "  ok: a conditional include is skipped"

# ── Case 18: $XDG_CONFIG_HOME/git/config is read; ~/.gitconfig overrides it ──
scenario
write_gitconfig
mkdir -p "$FAKE_HOME/.config/git"
printf '[user]\n\temail = xdg@corp.com\n\tname = Xdg Me\n' > "$FAKE_HOME/.config/git/config"
actual="$(resolve)"
[ "$actual" = "xdg@corp.com|Xdg Me" ] || { echo "FAIL [xdg]: got <$actual>" >&2; exit 1; }
echo "  ok: XDG config is used when ~/.gitconfig is absent"
printf '[user]\n\temail = home@corp.com\n' > "$FAKE_HOME/.gitconfig"
actual="$(resolve)"
[ "$actual" = "home@corp.com|Xdg Me" ] || { echo "FAIL [xdg override]: got <$actual>" >&2; exit 1; }
echo "  ok: ~/.gitconfig overrides the XDG value, field by field"

# ── Case 19: a damaged install (no git-identity.sh) still resolves an actor ──
scenario
ROOT_DIR="$FAKE_HOME"
GIT_EMAIL="jane@corp.com"; GIT_NAME="Jane Dev"
assert_actor "jane@devbox|jane" "missing git-identity.sh degrades to login@hostname"

echo "── scripts/shared/actor.sh (codex copy) ──"
ACTOR="$SHARED_ACTOR"

scenario
SEED_EMAIL="mdm@corp.com"; SEED_NAME="MDM Provisioned"
GIT_EMAIL="jane@corp.com"; GIT_NAME="Jane Dev"
assert_actor "mdm@corp.com|MDM Provisioned" "env file actor wins over the git identity"

scenario
GIT_EMAIL="jane@corp.com"; GIT_NAME="Jane Dev"
assert_actor "jane@corp.com|Jane Dev" "git identity from ~/.gitconfig when the env file has none"

scenario
SEED_EMAIL="mdm@corp.com"
GIT_EMAIL="jane@corp.com"; GIT_NAME="Jane Dev"
assert_actor "mdm@corp.com|Jane Dev" "fields resolve independently"

scenario
assert_actor "jane@devbox|jane" "login@hostname and login when no git identity exists"

scenario
HOST_NAME=""
assert_actor "jane|jane" "login alone when the hostname is unavailable"

# ── The git binary was never run, in any case above ──────────────────────────
if [ -s "$TRIPWIRE" ]; then
  echo "FAIL [git tripwire]: the cascade invoked git:" >&2; cat "$TRIPWIRE" >&2; exit 1
fi
echo "  ok: git binary never invoked"

echo
echo "All actor cascade tests passed (SH=$SH)."
