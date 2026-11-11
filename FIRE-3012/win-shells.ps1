$log = Join-Path $env:USERPROFILE '.rogue-spike-3012\calls.log'
Set-Content -Path $log -Value $null
$payload = '{"hook_event_name":"PreToolUse"}'
$gb = 'C:\Program Files\Git\bin\bash.exe'
"HOME(env)=$env:HOME HOMEDRIVE=$env:HOMEDRIVE HOMEPATH=$env:HOMEPATH PS_HOME=$HOME"
"--- 1 powershell 5.1, tilde, from another cwd"
Push-Location C:\Windows\Temp
$payload | powershell -NoProfile -NonInteractive -Command '~/.rogue-spike-3012/bin/rogue-hook claude PS51-tilde' ; "exit=$LASTEXITCODE"
"--- 2 git bash -c tilde"
$payload | & $gb -c '~/.rogue-spike-3012/bin/rogue-hook claude GB-tilde' ; "exit=$LASTEXITCODE"
& $gb -c 'echo "gb HOME=$HOME"; uname -s'
"--- 3 git bash -c HOME quoted"
$payload | & $gb -c '"$HOME/.rogue-spike-3012/bin/rogue-hook" claude GB-home' ; "exit=$LASTEXITCODE"
"--- 4 cmd percent"
$payload | cmd /d /s /c '"%USERPROFILE%\.rogue-spike-3012\bin\rogue-hook.exe" claude CMD-percent' ; "exit=$LASTEXITCODE"
"--- 5 cmd tilde"
$payload | cmd /d /s /c '~/.rogue-spike-3012/bin/rogue-hook claude CMD-tilde' ; "exit=$LASTEXITCODE"
"--- 6 powershell, cursor desktop wrapper"
$tmp = Join-Path $env:TEMP 'fire3012-payload.json'; Set-Content -LiteralPath $tmp -Value $payload -NoNewline -Encoding UTF8
$cmd = "~/.rogue-spike-3012/bin/rogue-hook cursor CursorWrap-tilde"
$wrapped = "`$OutputEncoding = [System.Text.UTF8Encoding]::new(`$false); Get-Content -LiteralPath '$tmp' -Raw -Encoding UTF8 | & { `$input | $cmd }"
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $wrapped ; "exit=$LASTEXITCODE"
"--- 7 powershell, unix-only HOME quoted string (wrong-shell form)"
$payload | powershell -NoProfile -NonInteractive -Command '"$HOME/.rogue-spike-3012/bin/rogue-hook" claude PS51-homequoted' ; "exit=$LASTEXITCODE"
"--- 8 git bash, percent form (wrong-shell form)"
$payload | & $gb -c '"%USERPROFILE%\.rogue-spike-3012\bin\rogue-hook.exe" claude GB-percent' ; "exit=$LASTEXITCODE"
"--- 9 powershell, missing binary + ; exit 0"
$payload | powershell -NoProfile -NonInteractive -Command '~/.rogue-spike-3012/bin/missing claude PS51-missing ; exit 0' ; "exit=$LASTEXITCODE"
"--- 10 powershell, missing binary"
$payload | powershell -NoProfile -NonInteractive -Command '~/.rogue-spike-3012/bin/missing claude PS51-missing' 2>$null ; "exit=$LASTEXITCODE"
Pop-Location
"=== calls.log"
Get-Content $log
