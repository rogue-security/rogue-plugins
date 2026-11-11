$log = Join-Path $env:USERPROFILE '.rogue-spike-3012\calls.log'
Set-Content -Path $log -Value $null
Set-Location (Join-Path $env:USERPROFILE 'fire3012-work')
$null | claude -p "Run the shell command: echo spike3012" --model haiku --setting-sources project --plugin-dir (Join-Path $env:USERPROFILE 'fire3012-claude-final') --allowedTools "Bash(echo *)" --output-format stream-json --verbose --include-hook-events 2>&1 | Out-File -Encoding utf8 (Join-Path $env:USERPROFILE 'fire3012-claude-final.jsonl')
"claude exit=$LASTEXITCODE"
$env:CODEX_HOME = Join-Path $env:USERPROFILE 'fire3012-codexhome'
Copy-Item (Join-Path $env:USERPROFILE 'fire3012-codex-final-hooks.json') (Join-Path $env:CODEX_HOME 'hooks.json') -Force
$null | codex exec --dangerously-bypass-hook-trust --skip-git-repo-check --json "Run the shell command: echo spike3012" 2>&1 | Out-File -Encoding utf8 (Join-Path $env:USERPROFILE 'fire3012-codex-final.jsonl')
"codex exit=$LASTEXITCODE"
"--- cursor desktop wrapper, final + missing"
$tmp = Join-Path $env:TEMP 'fire3012-payload.json'; Set-Content -LiteralPath $tmp -Value '{"hook_event_name":"preToolUse"}' -NoNewline -Encoding UTF8
$oxe = '; if ($null -eq $LASTEXITCODE -and @($Error | Where-Object { $_.Exception -is [System.Management.Automation.CommandNotFoundException] }).Count -gt 0) { exit 127 }'
foreach ($cmd in @('~/.rogue-spike-3012/bin/rogue-hook cursor preToolUse-K1-final', '~/.rogue-spike-3012/bin/missing cursor preToolUse-M1')) {
  $wrapped = "`$OutputEncoding = [System.Text.UTF8Encoding]::new(`$false); try { `$global:cursorHookConsoleInputEncoding = [Console]::InputEncoding; [Console]::InputEncoding = `$OutputEncoding } catch { }; Get-Content -LiteralPath '$tmp' -Raw -Encoding UTF8 | & { `$input | $cmd }" + $oxe
  $out = powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -c $wrapped 2>$null
  "cmd=[$cmd] stdout=[$out] exit=$LASTEXITCODE"
}
"=== calls.log"
Get-Content $log
