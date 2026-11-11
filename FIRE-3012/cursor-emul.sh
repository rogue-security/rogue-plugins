# Replays the exact spawn forms from the Cursor bundles (desktop: $SHELL -c cmd, payload on stdin; CLI: cmd + heredoc).
P='{"hook_event_name":"preToolUse"}'
for SH in ${SHELLS}; do
  printf '%s' "$P" | $SH -c '~/.rogue-spike-3012/bin/rogue-hook cursor desktop-K1-final' >/dev/null; echo "$SH desktop final exit=$?"
  $SH -c "~/.rogue-spike-3012/bin/rogue-hook cursor cli-K1-final <<'CURSOR_HOOK_EOF'
$P
CURSOR_HOOK_EOF" >/dev/null; echo "$SH cli final exit=$?"
  $SH -c "~/.rogue-spike-3012/bin/rogue-hook cursor cli-K2-guarded ; exit 0 <<'CURSOR_HOOK_EOF'
$P
CURSOR_HOOK_EOF" < /dev/null >/dev/null; echo "$SH cli guarded exit=$?"
  printf '%s' "$P" | $SH -c '~/.rogue-spike-3012/bin/missing cursor desktop-M1' 2>/dev/null; echo "$SH desktop missing exit=$?"
done
