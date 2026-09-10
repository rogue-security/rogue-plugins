# Helper for tests/test_hook_logs.ps1 — NOT a test on its own.
#
# Dot-sources ONE dispatcher through its ROGUE_PS_LIB_ONLY seam (which loads the
# logging helpers without running the hook), calls Initialize-Logging with a
# caller-supplied credential map, optionally pre-seeds the log file to force a
# rotation, calls Log once, and prints KEY=value facts for the parent to assert
# on. Run in a child pwsh per case so the five dispatchers' identically named
# functions ($logFile, Log, Rotate-Log) can never collide in one session.
#
# -Creds takes JSON rather than a hashtable because it crosses a process boundary.
# It stands in for the map each dispatcher builds from the process env plus the
# first env file holding ROGUE_API_KEY: the point of
# the test is that Initialize-Logging reads THAT map, not $env: directly, which is
# what lets an env file relocate the log on Windows.
param(
    [Parameter(Mandatory)][string]$Dispatcher,   # path to a hook.ps1
    [string]$EventName = 'PreToolUse',
    # BASE64 of the UTF-8 JSON, not the JSON itself. Windows PowerShell 5.1 mangles
    # the double quotes when it builds a native command's argument list, so a
    # `{"ROGUE_API_KEY":"k"}` argument arrived as `{ROGUE_API_KEY:k}` and
    # ConvertFrom-Json failed with "Invalid JSON primitive". Base64 has no character
    # any shell or argument parser treats specially - the same reason the dispatchers
    # ship transcript tails and subagent names base64-encoded.
    [string]$CredsB64 = '',                      # base64 of a JSON object of ROGUE_* values
    [int]$SeedBytes = 0,                         # >0: pre-fill the log
    [string]$SeedPrevious = '',                  # non-empty: also create <log>.1
    # '<default>' = leave the dispatcher's own value alone; '<none>' = force it
    # EMPTY. A literal '' cannot be used for the second case: Windows PowerShell 5.1
    # DROPS an empty native-command argument, so `-Surface ''` reaches this script as
    # a bare `-Surface` and fails to bind ("Missing an argument for parameter").
    [string]$Surface = '<default>'               # override $script:surface before Log
)

# Parse BEFORE dot-sourcing, and never name this parameter `$Creds`: dot-sourcing
# runs the dispatcher in THIS scope, and hook.ps1 (antigravity) declares a
# file-scope `$creds = @{}`. PowerShell variable names are case-INSENSITIVE, so
# that assignment would silently overwrite our own parameter with an empty
# hashtable and every override in it would vanish.
# Snapshot BEFORE the dot-source, for exactly the reason spelled out above: the
# dispatcher declares a file-scope `$script:surface`, PowerShell variable names are
# case-INSENSITIVE, and dot-sourcing therefore overwrites this script's own
# `$Surface` parameter with the dispatcher's value. Read back afterwards it always
# equalled the default the dispatcher had just set, so the override silently did
# nothing - the same trap `$Creds` -> `$map` avoids one line below.
$surfaceOverride = $Surface

$map = @{}
$credsJson = '{}'
if ($CredsB64) {
    $credsJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($CredsB64))
}
foreach ($p in (ConvertFrom-Json $credsJson).PSObject.Properties) { $map[$p.Name] = [string]$p.Value }

$env:ROGUE_PS_LIB_ONLY = '1'
. $Dispatcher $EventName

Initialize-Logging $map

"LOGFILE=$logFile"
"CAP=$logMaxBytes"
if (-not $logFile) { return }

New-Item -ItemType Directory -Path (Split-Path $logFile) -Force | Out-Null
if ($SeedPrevious) {
    Set-Content -LiteralPath "$logFile.1" -Value $SeedPrevious -NoNewline
}
if ($SeedBytes -gt 0) {
    # -NoNewline so the byte count is exact; rotation compares against Length.
    Set-Content -LiteralPath $logFile -Value ('s' * $SeedBytes) -NoNewline
}
# The surface is resolved in the MAIN BODY (below the seam), which never runs here,
# so each dispatcher's file-scope default is what a probe sees: the constant for a
# single-surface plugin, empty for one that detects per session. `-Surface` sets it
# explicitly so the EMIT shape - token present, token omitted - is testable; the
# resolution itself is covered separately, against surface.ps1 and against the
# main body's wiring.
if ($surfaceOverride -ne '<default>') {
    $script:surface = if ($surfaceOverride -eq '<none>') { '' } else { $surfaceOverride }
}
"SURFACE=$($script:surface)"

Log 'outcome=probe'

$lines = @(Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue)
"LINES=$($lines.Count)"
"LAST=$($lines[-1])"
"ROTATED=$(Test-Path -LiteralPath ($logFile + '.1'))"
if (Test-Path -LiteralPath "$logFile.1") {
    "PREVIOUS=$((Get-Content -Raw -LiteralPath "$logFile.1") -replace '\s+$','')"
}
# First three bytes, so the parent can assert there is no UTF-8 BOM (EF BB BF).
# Windows PowerShell 5.1's `Add-Content -Encoding UTF8` writes one on create,
# which would corrupt the first record of every new/rotated log.
$bytes = [System.IO.File]::ReadAllBytes($logFile)
$head = if ($bytes.Length -ge 3) { $bytes[0..2] } else { $bytes }
"HEAD=$(($head | ForEach-Object { $_.ToString('X2') }) -join ' ')"
