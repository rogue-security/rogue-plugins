# Rogue Security - Muse Code hook bridge for Windows (sibling of hook.sh).
# Posts the native Muse event to Rogue and relays the API's native response;
# any failure prints {} so Muse continues (fail-open).
# Usage: hook.ps1 EventName
param([string]$EventName = 'unknown')
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$PluginRoot = Split-Path -Parent $PSScriptRoot
$UserHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }

function Write-Out {
    param([string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text + "`n")
    $stdout = [Console]::OpenStandardOutput(); $stdout.Write($bytes, 0, $bytes.Length); $stdout.Flush()
}
function Clean { param([string]$S) ([string]$S -replace '[\x00-\x1f\x7f]', '') }

# Decode one shell word the way hook.sh sees it when sourcing the env file.
function ConvertFrom-ShellQuoted {
    param([string]$Val)
    $sb = [Text.StringBuilder]::new(); $state = 'normal'
    for ($i = 0; $i -lt $Val.Length; $i++) {
        $c = $Val[$i]
        switch ($state) {
            'single' { if ($c -eq "'") { $state = 'normal' } else { [void]$sb.Append($c) } }
            'double' {
                if ($c -eq '"') { $state = 'normal' }
                elseif ($c -eq '\' -and ($i + 1) -lt $Val.Length -and ('"\$`'.IndexOf($Val[$i + 1]) -ge 0)) { [void]$sb.Append($Val[$i + 1]); $i++ }
                else { [void]$sb.Append($c) }
            }
            default {
                if ($c -eq "'") { $state = 'single' }
                elseif ($c -eq '"') { $state = 'double' }
                elseif ($c -eq '\' -and ($i + 1) -lt $Val.Length) { [void]$sb.Append($Val[$i + 1]); $i++ }
                else { [void]$sb.Append($c) }
            }
        }
    }
    return $sb.ToString()
}

$creds = @{}
foreach ($k in 'ROGUE_API_KEY', 'ROGUE_BASE_URL', 'ROGUE_ACTOR_EMAIL', 'ROGUE_ACTOR_NAME', 'ROGUE_LOG_FILE', 'ROGUE_LOG_DIR') {
    $v = [Environment]::GetEnvironmentVariable($k); if ($v) { $creds[$k] = $v }
}
try { . ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $PluginRoot 'scripts/env-file.ps1') -ErrorAction Stop))) }
catch { function Read-RogueEnvFile { param([string]$Path) } }
# The first trusted env file holding ROGUE_API_KEY is used alone: machine, bundled, user.
foreach ($f in @('C:\ProgramData\rogue\env', (Join-Path $PluginRoot 'env'), (Join-Path $UserHome '.rogue-env'))) {
    $vals = @{}
    foreach ($line in (Read-RogueEnvFile $f)) {
        if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.*)$') { $vals[$Matches[1]] = ConvertFrom-ShellQuoted $Matches[2].Trim() }
    }
    if (([string]$vals['ROGUE_API_KEY']).Trim()) { foreach ($k in $vals.Keys) { $creds[$k] = $vals[$k] }; break }
}

$logFile = $creds['ROGUE_LOG_FILE']
if (-not $logFile) {
    $logDir = if ($creds['ROGUE_LOG_DIR']) { $creds['ROGUE_LOG_DIR'] } else { [IO.Path]::Combine($UserHome, '.rogue', 'logs') }
    $logFile = Join-Path $logDir 'muse.log'
}
function Log {
    param([string]$Msg)
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $logFile) | Out-Null
        $fi = Get-Item -LiteralPath $logFile
        if ($fi -and $fi.Length -ge 10485760) { Remove-Item -LiteralPath "$logFile.1" -Force; Move-Item -LiteralPath $logFile -Destination "$logFile.1" -Force }
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        [IO.File]::AppendAllText($logFile, "$stamp provider=muse surface=muse_code event=$EventName $Msg`n", (New-Object Text.UTF8Encoding($false)))
    } catch {}
}

try {
    $apiKey = $creds['ROGUE_API_KEY']
    if (-not $apiKey) { Log 'outcome=unconfigured'; Write-Out '{}'; exit 0 }

    $actor = @{ Email = [string]$creds['ROGUE_ACTOR_EMAIL']; Name = [string]$creds['ROGUE_ACTOR_NAME'] }
    try {
        . ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $PluginRoot 'scripts/actor.ps1') -ErrorAction Stop)))
        $actor = Resolve-RogueSharedActor $creds $PluginRoot
    } catch {}
    $hostName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [Net.Dns]::GetHostName() }
    $version = 'unknown'
    $m = [regex]::Match([string](Get-Content -Raw -LiteralPath (Join-Path $PluginRoot 'plugin.json')), '"version"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)')
    if ($m.Success) { $version = $m.Groups[1].Value }

    $in = New-Object IO.MemoryStream
    [Console]::OpenStandardInput().CopyTo($in)
    $body = $in.ToArray()
    if (-not $body.Length) { $body = [Text.Encoding]::UTF8.GetBytes('{}') }

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $baseUrl = if ($creds['ROGUE_BASE_URL']) { $creds['ROGUE_BASE_URL'].TrimEnd('/') } else { 'https://api.rogue.security' }
    $headers = @{
        'x-rogue-api-key' = $apiKey; 'x-rogue-event' = $EventName; 'x-rogue-agent' = 'muse_code'
        'x-rogue-host' = Clean $hostName; 'x-rogue-version' = $version
        'x-rogue-actor-email' = Clean $actor.Email; 'x-rogue-actor-name' = Clean $actor.Name
    }
    $code = '000'; $resp = ''
    try {
        $r = Invoke-WebRequest -Uri "$baseUrl/api/v1/hooks/muse" -Method Post -Headers $headers -ContentType 'application/json' `
            -Body $body -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        $code = [string]$r.StatusCode
        $resp = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    } catch {
        if ($_.Exception.Response) { $code = [string][int]$_.Exception.Response.StatusCode }
    }
    if ($code -ne '200') { Log "outcome=fail-open http=$code"; Write-Out '{}'; exit 0 }

    # The API already answers in Muse's native form ({} allows); Muse ignores output it cannot parse.
    if (-not $resp.Trim()) { $resp = '{}' }
    $outcome = if ($resp.Trim() -eq '{}') { 'allow' } else { 'block' }
    $raw = Clean $resp
    Log "outcome=$outcome http=$code raw=$($raw.Substring(0, [Math]::Min(400, $raw.Length)))"
    Write-Out $resp.Trim()

    if ($EventName -in 'SessionStart', 'Stop', 'SessionEnd') {
        $ship = Join-Path $PluginRoot 'scripts/ship-logs.ps1'
        # Its own try: a failure here must not print a second response.
        if (Test-Path -LiteralPath $ship) { try {
            $env:ROGUE_ACTOR_EMAIL = [string]$actor.Email; $env:ROGUE_ACTOR_NAME = [string]$actor.Name
            $env:ROGUE_SHIPPER_SCRIPT = $ship; $env:ROGUE_SHIPPER_ROOT = $PluginRoot; $env:ROGUE_SHIPPER_VERSION = $version
            $inner = '& ([scriptblock]::Create((Get-Content -Raw -LiteralPath $env:ROGUE_SHIPPER_SCRIPT))) $env:ROGUE_SHIPPER_ROOT muse $env:ROGUE_SHIPPER_VERSION muse'
            $psExe = (Get-Process -Id $PID).Path; if (-not $psExe) { $psExe = 'powershell' }
            Start-Process -FilePath $psExe -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand',
                ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))) -WindowStyle Hidden | Out-Null
        } catch {} }
    }
} catch { Log 'outcome=fail-open reason=bridge-error'; Write-Out '{}' }
exit 0
