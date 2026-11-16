# Usage: detach.ps1 <script> [arg]
# Native-Windows twin of detach.sh: starts a plugin script in a hidden, detached
# PowerShell so slow work (heartbeat, auto-update) never delays Claude Code.
param([string]$Script = '', [string]$Arg = '')
$ErrorActionPreference = 'SilentlyContinue'
if ($Script) {
    # Windows PowerShell 5.1 joins -ArgumentList unquoted, so quote the path.
    $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$Script`"")
    if ($Arg) { $argv += $Arg }
    Start-Process powershell -WindowStyle Hidden -ArgumentList $argv
}
exit 0
