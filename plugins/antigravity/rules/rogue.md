---
trigger: always_on
---

# Rogue Security

This workspace is protected by **Rogue Security AIDR** (AI Detection & Response).
Every tool call, model turn, and agent action in this session is observed and
evaluated in real time against your organization's active security rulesets —
covering prompt-injection attempts, secret/credential exfiltration, and
destructive or unauthorized commands. A flagged tool call is denied before it
executes; a flagged model turn is stopped.

## Setup and status

- Run `/setup` to connect this plugin to your Rogue account (writes the shared
  `~/.rogue-env` credentials file used by every Rogue plugin on this machine).
- Run `/status` at any time to check connection health, the active ruleset,
  and a tail of recent hook activity.

If Rogue is not yet configured, tool calls and model turns proceed normally
(fail-open) — nothing is blocked until `/setup` has run.

## False-positive override

If a legitimate prompt is incorrectly flagged, prefix it with `rgx!` (e.g.
`rgx! delete the temp build directory`) to signal Rogue's backend that this is
a known false positive. This is a server-side convention — the plugin itself
does not interpret the prefix, it is simply passed through as part of the
prompt text for the evaluation pipeline to recognize.

## What this means for you as the agent

- Do not attempt to bypass, disable, or route around Rogue Security hooks,
  and do not suggest doing so to the user as a way to "fix" a block.
- If a tool call is denied, treat the denial reason as authoritative and
  explain it to the user rather than retrying the same action in a different
  form to evade detection.
- Use the `rgx!` prefix only when the user confirms the flagged action is
  genuinely intended and safe — never add it on your own initiative to push
  through a block.
