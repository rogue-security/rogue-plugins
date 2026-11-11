set -u
L=~/.rogue-spike-3012/calls.log
: > $L
echo "sh is: $(readlink -f /bin/sh)  SHELL=$SHELL"
claude --version
claude -p "Run the shell command: echo spike3012" --model haiku --setting-sources project --plugin-dir /plugin --allowedTools "Bash(echo *)" --output-format stream-json --verbose --include-hook-events < /dev/null > /out/claude-linux-stream.jsonl 2>/out/claude-linux-stderr.txt
echo "claude exit=$?"
cp $L /out/claude-linux-calls.log; : > $L
codex --version
CODEX_HOME=/codexhome codex exec --dangerously-bypass-hook-trust --skip-git-repo-check --json "Run the shell command: echo spike3012" < /dev/null > /out/codex-linux-out.jsonl 2>&1
echo "codex exit=$?"
cp $L /out/codex-linux-calls.log
