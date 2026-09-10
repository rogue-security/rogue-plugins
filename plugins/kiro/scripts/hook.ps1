# Rogue Security hook bridge for Kiro (IDE, CLI, Crew) - PowerShell implementation.
#
# Windows sibling of hook.sh. The installer writes the hook command as
#   powershell -NoProfile -ExecutionPolicy Bypass -File <root>\scripts\hook.ps1 <hookEvent> <surface>
# so this runs as a FILE ($PSScriptRoot is set) and must stay Windows PowerShell
# 5.1-compatible: Kiro does not ship pwsh 7.
#
# Reads one Kiro hook event JSON on stdin, POSTs it to /api/v1/hooks/kiro, and
# translates Rogue's decision into Kiro's NATIVE form, which is the exit code:
#
#   PreToolUse block         exit 2, reason on stderr, EMPTY stdout
#   UserPromptSubmit block   exit 0, {"decision":"block","reason":...} on stdout
#   Stop                     exit 0, empty stdout - ALWAYS (a block on Stop tells
#                            Kiro to keep working)
#   everything else          exit 0, empty stdout
#
# FAIL-OPEN IS SAFETY-CRITICAL: exit 2 is a hard deny, and stdout can be injected
# into the model's context, so on ANY error (missing key, network failure,
# timeout, non-200, empty body, an exception anywhere) this exits 0 with an
# empty stdout. $ErrorActionPreference is SilentlyContinue for that reason.
#
# Credential resolution: the first env file holding ROGUE_API_KEY is used alone,
# and its values override the process env:
#   1. C:\ProgramData\rogue\env  (machine, MDM-provisioned; mirrors /etc/rogue/env)
#   2. <root>\env                (bundled into a compiled customer plugin)
#   3. %USERPROFILE%\.rogue-env  (user / installer-written)

# $SurfaceArg, not $Surface: PowerShell variable names are case-insensitive, so
# the file-scope `$script:surface = ''` below would overwrite a parameter of that
# name before the main body validated it, and every event would go out as
# kiro_cli. Positional, so the hook file's `hook.ps1 <event> <surface>` is unchanged.
param([string]$EventName = '', [string]$SurfaceArg = '', [string]$PluginRoot = '')

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

function Write-Raw {
    param([string]$Text)
    if (-not $Text) { return }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}
function Dbg { param([string]$Msg) if ($env:ROGUE_DEBUG) { [Console]::Error.WriteLine("[rogue] $Msg") } }

function ConvertFrom-ShellQuoted {
    # Decode one shell "word" the way hook.sh would when it sources the env file,
    # so values round-trip across both bridges (POSIX single-quoted or bash %q).
    param([string]$Val)
    if ($null -eq $Val) { return $Val }
    $sb = [System.Text.StringBuilder]::new()
    $i = 0; $n = $Val.Length; $state = 'normal'
    while ($i -lt $n) {
        $c = $Val[$i]
        switch ($state) {
            'single' { if ($c -eq "'") { $state = 'normal' } else { [void]$sb.Append($c) } }
            'double' {
                if ($c -eq '"') { $state = 'normal' }
                elseif ($c -eq '\' -and ($i + 1) -lt $n -and ('"\$`'.IndexOf($Val[$i+1]) -ge 0)) { [void]$sb.Append($Val[$i+1]); $i++ }
                else { [void]$sb.Append($c) }
            }
            default {
                if ($c -eq "'") { $state = 'single' }
                elseif ($c -eq '"') { $state = 'double' }
                elseif ($c -eq '\' -and ($i + 1) -lt $n) { [void]$sb.Append($Val[$i+1]); $i++ }
                else { [void]$sb.Append($c) }
            }
        }
        $i++
    }
    return $sb.ToString()
}

# -- logging -----------------------------------------------------------------
# ONE FILE PER AGENT (mirrors hook.sh): %USERPROFILE%\.rogue\logs\kiro.log.
# Precedence: ROGUE_LOG_FILE -> ROGUE_LOG_DIR\kiro.log -> default, each read from
# the merged credential map so an env file can relocate the log. $HOME backs up
# USERPROFILE so this can be dot-sourced on macOS/Linux through the
# ROGUE_PS_LIB_ONLY seam (tests).
# The surface is an install-time argument resolved in the main body; the
# file-scope default is empty so a probe through the seam emits no token.
$script:surface = ''
$script:logFile = $null
$script:logMaxBytes = 10485760

function Initialize-Logging {
    param([hashtable]$Creds = @{})
    $f = $Creds['ROGUE_LOG_FILE']
    if (-not $f) {
        $d = $Creds['ROGUE_LOG_DIR']
        if (-not $d) {
            $userHome = $env:USERPROFILE
            if (-not $userHome) { $userHome = $HOME }
            if ($userHome) { $d = Join-Path (Join-Path $userHome '.rogue') 'logs' }
        }
        if ($d) { $f = Join-Path $d 'kiro.log' }
    }
    $script:logFile = $f
    # Size cap: numeric zero disables rotation, a non-numeric or oversized value
    # falls back to the default (TryParse, not a cast, so an int64 overflow is a
    # stated fallback rather than a swallowed error).
    $cap = $Creds['ROGUE_LOG_MAX_BYTES']
    $capValue = [int64]0
    if ($cap -match '^[0-9]+$' -and [int64]::TryParse($cap, [ref]$capValue)) { $script:logMaxBytes = $capValue }
    else { $script:logMaxBytes = 10485760 }
}

function Sanitize { param([string]$S) if ($null -eq $S) { return '' } ($S -replace '[\x00-\x1f\x7f]', '') }

function Rotate-Log {
    if (-not $logFile -or $logMaxBytes -le 0) { return }
    try {
        $fi = Get-Item -LiteralPath $logFile -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -ge $logMaxBytes) {
            # Delete the previous generation first: Move-Item -Force onto an
            # EXISTING destination is not reliable on Windows PowerShell 5.1.
            Remove-Item -LiteralPath "$logFile.1" -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $logFile -Destination "$logFile.1" -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Log {
    param([string]$Msg)
    try {
        if (-not $logFile) { return }
        $dir = Split-Path $logFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Rotate-Log
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        # BOM-less UTF-8 via AppendAllText: Add-Content -Encoding UTF8 writes a BOM
        # on create under 5.1, which breaks any parser anchored on the timestamp.
        $surfaceToken = if ($script:surface) { " surface=$($script:surface)" } else { '' }
        [System.IO.File]::AppendAllText(
            $logFile,
            "$stamp provider=kiro$surfaceToken event=$EventName $Msg`n",
            (New-Object System.Text.UTF8Encoding $false))
    } catch {}
}

# -- Kiro translation helpers (pure; unit-tested through the seam) -----------

# The canonical hook event, as the route's monitored/blocking tables spell it.
# The 2.x engine names the same events in camelCase (SessionStart is agentSpawn
# there). Unrecognised names pass through verbatim.
function ConvertTo-KiroEvent {
    param([string]$Name)
    switch -CaseSensitive ($Name) {
        'agentSpawn'       { return 'SessionStart' }
        'userPromptSubmit' { return 'UserPromptSubmit' }
        'preToolUse'       { return 'PreToolUse' }
        'postToolUse'      { return 'PostToolUse' }
        'stop'             { return 'Stop' }
    }
    return $Name
}

# A closed vocabulary; anything else is '' (no log token, kiro_cli on the wire).
function Get-KiroSurface {
    param([string]$Arg)
    if ($Arg -cin @('kiro_ide', 'kiro_cli', 'kiro_crew')) { return $Arg }
    return ''
}

# The 2.x engine sends no session_id in the body and exposes KIRO_SESSION_ID in
# the environment instead. Splice it in under the field the 3.0 engine uses,
# preserving the vendor's bytes (no re-serialisation). A body that already has
# the field, a value outside the bare token charset, or a body that is not an
# object comes back unchanged - fail-open to today's 2.x behaviour.
# "Already has the field" is a SUBSTRING check (no JSON parser here, in lockstep
# with hook.sh): a NESTED key of the same name skips the injection, which is the
# fail-open direction - the event is still recorded, without a session id.
# Prompt text cannot trip it: a quote inside a JSON string is escaped.
function Add-KiroSessionId {
    param([string]$Payload, [string]$SessionId)
    if (-not $Payload) { return $Payload }
    if ($Payload -match '"session_id"') { return $Payload }
    if (-not $SessionId -or $SessionId -notmatch '^[A-Za-z0-9_.:-]+$') { return $Payload }
    $body = $Payload.TrimEnd()
    if (-not $body.EndsWith('}')) { return $Payload }
    $pre = $body.Substring(0, $body.Length - 1).TrimEnd()
    $sep = if ($pre -eq '{') { '' } else { ',' }
    return $pre + $sep + '"session_id":"' + $SessionId + '"}'
}

# The 3.0 engine (the IDE runs the same one) loads the agent configs written for
# 2.x as well as the hook file, so it runs the bridge twice per event. The
# agent-hook copy gives itself away - a PascalCase hook_event_name under a
# camelCase trigger - and is dropped; the hook-file copy carries the same event
# to the same decision. The 2.x engine spells the body in camelCase: never dropped.
function Test-KiroDuplicateAgentHook {
    param([string]$TriggerArg, [string]$Payload)
    if ($TriggerArg -cnotin @('agentSpawn', 'userPromptSubmit', 'preToolUse', 'postToolUse', 'stop')) { return $false }
    try {
        $body = ConvertFrom-Json -InputObject $Payload -ErrorAction Stop
        return ($body -is [PSCustomObject] -and $body.hook_event_name -is [string] -and $body.hook_event_name -cmatch '^[A-Z]')
    } catch { return $false }
}

# STRICT shape match: the pair, not the substrings, so an allow that carries
# "block" as some other field's value never trips it.
function Test-KiroBlock {
    param([string]$Resp)
    return [bool]($Resp -match '"decision"\s*:\s*"block"')
}

function Get-KiroBlockReason {
    param([string]$Resp)
    $reason = ''
    try {
        $obj = ConvertFrom-Json $Resp -ErrorAction Stop
        if ($obj -and $obj.reason) { $reason = [string]$obj.reason }
    } catch {
        if ($Resp -match '"reason"\s*:\s*"((?:[^"\\]|\\.)*)"') {
            $reason = $Matches[1] -replace '\\n', "`n" -replace '\\"', '"' -replace '\\\\', '\'
        }
    }
    if (-not $reason) { $reason = 'Blocked by Rogue Security' }
    return $reason
}

# The decision table, as one value: what to exit with, what to write where, and
# what to log. Allow and every failure are the zero row. The route already
# answers {} where a block cannot apply (Stop, UserPromptSubmit off the IDE);
# this is the second fence.
function Resolve-KiroOutcome {
    param([string]$Event, [string]$Resp)
    $o = @{ ExitCode = 0; Stdout = ''; Stderr = ''; Outcome = 'allow'; Note = '' }
    if (-not $Resp -or -not (Test-KiroBlock $Resp)) { return $o }
    switch -CaseSensitive ($Event) {
        'PreToolUse' {
            $o.ExitCode = 2
            $o.Stderr = Get-KiroBlockReason $Resp
            $o.Outcome = 'block'
        }
        'UserPromptSubmit' {
            $o.Stdout = $Resp
            $o.Outcome = 'block'
        }
        default {
            # Stop and every audit-only event: recorded, never enforced.
            $o.Note = 'decision=block'
        }
    }
    return $o
}

function Initialize-KiroContext {
    # Windows PowerShell 5.1 may negotiate only TLS 1.0/1.1 by default; add TLS 1.2.
    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {}

    # Stand down on non-Windows (Kiro runs hook.sh there; this guards a stray pwsh).
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { exit 0 }

    $script:triggerArg = $EventName
    $script:EventName = ConvertTo-KiroEvent $EventName
    $script:surface = Get-KiroSurface $SurfaceArg
    $script:agent = if ($script:surface) { $script:surface } else { 'kiro_cli' }
    Dbg "event=$EventName surface=$agent"

    if (-not $PluginRoot -and $PSScriptRoot) { $script:PluginRoot = Split-Path -Parent $PSScriptRoot }
    if (-not $PluginRoot) { $script:PluginRoot = $env:KIRO_PLUGIN_ROOT }
    if (-not $PluginRoot) { try { $script:PluginRoot = (Get-Location).Path } catch { $script:PluginRoot = '.' } }

    # -- credential resolution ---------------------------------------------------
    $script:creds = @{}
    . ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $PluginRoot 'scripts/env-file.ps1'))))
    foreach ($k in 'ROGUE_API_KEY','ROGUE_ACTOR_EMAIL','ROGUE_ACTOR_NAME','ROGUE_BASE_URL','ROGUE_API_URL',
                   'ROGUE_LOG_FILE','ROGUE_LOG_DIR','ROGUE_LOG_MAX_BYTES','ROGUE_HOOK_TIMEOUT') {
        $val = [Environment]::GetEnvironmentVariable($k); if ($val) { $creds[$k] = $val }
    }
    # The first env file holding ROGUE_API_KEY is used alone: machine, bundled, user.
    foreach ($f in @('C:\ProgramData\rogue\env', (Join-Path $PluginRoot 'env'), (Join-Path $env:USERPROFILE '.rogue-env'))) {
        if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
        $fileVals = @{}
        foreach ($line in (Read-RogueEnvFile $f)) {
            if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
                $fileVals[$Matches[1]] = ConvertFrom-ShellQuoted ($Matches[2].Trim())
            }
        }
        if (-not $fileVals['ROGUE_API_KEY']) { continue }
        foreach ($k in $fileVals.Keys) { $creds[$k] = $fileVals[$k] }
        break
    }

    # After the credential files (so they can relocate the log), before the API-key
    # check (so an unconfigured install still records outcome=unconfigured).
    Initialize-Logging $creds
    Dbg "logFile=$logFile cap=$logMaxBytes"

    $script:apiKey = $creds['ROGUE_API_KEY']
    if (-not $apiKey) {
        Log 'outcome=unconfigured'
        exit 0
    }

    $script:url = $creds['ROGUE_API_URL']
    if (-not $url) {
        $baseUrl = $creds['ROGUE_BASE_URL']; if (-not $baseUrl) { $baseUrl = 'https://api.rogue.security' }
        $script:url = "$($baseUrl.TrimEnd('/'))/api/v1/hooks/kiro"
    }

    # curl budget in hook.sh; here the request timeout. The hook file gives the
    # command 10s, so 8s leaves room without letting Kiro's own timeout be what
    # fails us open. Zero falls back to the default: -TimeoutSec 0 means NO timeout.
    $script:timeoutSec = 8
    $t = $creds['ROGUE_HOOK_TIMEOUT']
    if ($t -match '^[0-9]{1,9}$' -and [int]$t -gt 0) { $script:timeoutSec = [int]$t }
}

function Resolve-KiroActor {
    # -- actor resolution (mirrors actor.sh) -------------------------------------
    $script:actorName = $creds['ROGUE_ACTOR_NAME']
    if (-not $actorName) { try { $script:actorName = (& git config --global user.name 2>$null | Out-String).Trim() } catch {} }
    if (-not $actorName) { $script:actorName = $env:USERNAME }

    $script:actorEmail = $creds['ROGUE_ACTOR_EMAIL']
    if (-not $actorEmail) { try { $script:actorEmail = (& git config --global user.email 2>$null | Out-String).Trim() } catch {} }
    if (-not $actorEmail) {
        if ($env:USERNAME -and $env:COMPUTERNAME) { $script:actorEmail = "$($env:USERNAME)@$($env:COMPUTERNAME)" }
        elseif ($env:USERNAME) { $script:actorEmail = $env:USERNAME } else { $script:actorEmail = $env:COMPUTERNAME }
    }
}

function Read-KiroPayload {
    param([System.IO.Stream]$InputStream = [Console]::OpenStandardInput())
    $bytes = New-Object System.IO.MemoryStream
    try {
        $InputStream.CopyTo($bytes)
        $payload = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes.ToArray())
    } finally { $bytes.Dispose() }
    if (-not $payload) { $payload = '{}' }
    return $payload.TrimStart([char]0xFEFF)
}

function Resolve-KiroInstall {
    # -- install identity: host + version (mirrors install-id.sh) ----------------
    $installError = @()
    $script:hostName = $env:COMPUTERNAME
    if (-not $hostName) { try { $script:hostName = [System.Net.Dns]::GetHostName() } catch { $script:hostName = '' } }
    if (-not $hostName) { $script:hostName = 'unknown'; $installError += 'host-unresolved' }

    $script:pluginVersion = 'unknown'
    $pluginJson = Join-Path $PluginRoot 'plugin.json'
    if (Test-Path -LiteralPath $pluginJson) {
        $m = [regex]::Match((Get-Content -Raw -LiteralPath $pluginJson), '"version"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)')
        if ($m.Success) { $script:pluginVersion = $m.Groups[1].Value }
        else { $installError += "version-unparsed:$pluginJson" }
    } else {
        $installError += "manifest-missing:$pluginJson"
    }
    if ($installError.Count) { Log "error=install-id $($installError -join ',')" }
}

function Start-KiroHeartbeat {
    # -- presence heartbeat (SessionStart unthrottled, Stop throttled) ------------
    # Detached; heartbeat.ps1 takes the surface and the trigger, as heartbeat.sh does.
    if ($EventName -eq 'SessionStart' -or $EventName -eq 'Stop') {
        $hb = Join-Path $PluginRoot 'scripts\heartbeat.ps1'
        if (Test-Path -LiteralPath $hb) {
            try {
                Start-Process -FilePath 'powershell' -WindowStyle Hidden `
                    -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$hb,$agent,$EventName | Out-Null
            } catch { Dbg "heartbeat spawn failed: $($_.Exception.Message)" }
        }
    }
}

function Send-KiroRequest {
    # -- POST (fail-open) --------------------------------------------------------
    $headers = @{
        'x-rogue-api-key'     = $apiKey
        'x-rogue-event'       = $EventName
        'x-rogue-agent'       = $agent
        'x-rogue-host'        = $hostName
        'x-rogue-version'     = $pluginVersion
        'x-rogue-actor-email' = $actorEmail
        'x-rogue-actor-name'  = $actorName
    }
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $script:resp = ''
    $script:code = '000'
    $script:requestRc = 1
    try {
        $r = Invoke-WebRequest -Uri $url -Method Post `
            -Headers $headers -ContentType 'application/json' -Body $bodyBytes `
            -UseBasicParsing -TimeoutSec $timeoutSec -ErrorAction Stop
        $script:requestRc = 0
        $script:code = [string]$r.StatusCode
        if ($r.StatusCode -eq 200) {
            try { $script:resp = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) }
            catch { $script:resp = [string]$r.Content }
        }
    } catch { Dbg "POST failed: $($_.Exception.Message)"; $script:resp = '' }
}

function Write-KiroDecision {
    # -- translate, log ONE line, answer Kiro -------------------------------------
    $o = Resolve-KiroOutcome $EventName $resp
    $respHead = if ($resp.Length -gt 400) { $resp.Substring(0, 400) } else { $resp }
    $note = if ($o.Note) { " $($o.Note)" } else { '' }
    Log "outcome=$($o.Outcome)$note http=$code rc=$requestRc raw=$(Sanitize $respHead)"

    if ($o.Stdout) { Write-Raw $o.Stdout }
    if ($o.Stderr) { [Console]::Error.WriteLine($o.Stderr) }
    exit $o.ExitCode
}

function Invoke-KiroHook {
    Initialize-KiroContext
    Resolve-KiroActor
    $payload = Read-KiroPayload
    $payload = Add-KiroSessionId $payload $env:KIRO_SESSION_ID
    if (Test-KiroDuplicateAgentHook $triggerArg $payload) {
        Log "outcome=duplicate engine=3.0 trigger=$triggerArg"
        exit 0
    }
    Resolve-KiroInstall
    Start-KiroHeartbeat
    Send-KiroRequest
    Write-KiroDecision
}

# Dot-sourcing through the test seam defines every function without running it.
if ($env:ROGUE_PS_LIB_ONLY) { return }
try { Invoke-KiroHook } catch { Dbg "bridge failed: $($_.Exception.Message)"; exit 0 }
