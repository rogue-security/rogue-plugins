#Requires -Version 5.1
<#
.SYNOPSIS
    Rogue Security - one-line installer for Claude Code (Windows).
.DESCRIPTION
    iwr -useb https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/install.ps1 | iex

    With credentials via environment variables (non-interactive):
    $env:ROGUE_API_KEY='rsk_xxx'; $env:ROGUE_ACTOR_EMAIL='you@co.com'; iwr -useb https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/install.ps1 | iex
    A key passed this way is ignored when C:\ProgramData\rogue\env already holds
    one: that file is read alone.

    Direct invocation with flags:
    .\install.ps1 -ApiKey rsk_xxx -Email you@co.com -Name 'Your Name'
    .\install.ps1 -NonInteractive

    Installs the plugin through the official Claude CLI (marketplace add + plugin
    install) - the same mechanism as install.sh - validates and stores your API
    key, and confirms your actor identity.

    Unlike the runtime hooks (which fail OPEN so Claude Code never hangs on Rogue
    infrastructure), this installer fails LOUD: a half-finished install should be
    visible, not silent.
.PARAMETER ApiKey
    Rogue API key (rsk_...).
.PARAMETER Email
    Actor email address.
.PARAMETER Name
    Actor display name.
.PARAMETER BaseUrl
    Override the API base URL (default: https://api.rogue.security).
.PARAMETER PluginRepo
    Marketplace source repo (default: qualifire-dev/rogue-plugins).
.PARAMETER NonInteractive
    Fail / skip prompts rather than ask for missing values.
.PARAMETER Claude
    Install only for Claude Code (combine with -Codex/-Cursor to pick a set).
.PARAMETER Codex
    Install only for OpenAI Codex.
.PARAMETER Cursor
    Install only for Cursor.
.PARAMETER Gemini
    Install only for Gemini CLI.
.PARAMETER Copilot
    Install only for GitHub Copilot CLI.
.PARAMETER Antigravity
    Install only for Google Antigravity.
.PARAMETER Kiro
    Install only for Kiro (IDE, CLI on both engines). With no agent switch, every detected agent is installed.
#>
[CmdletBinding()]
param(
    [string]$ApiKey,
    [string]$Email,
    [string]$Name,
    [string]$BaseUrl,
    [string]$PluginRepo,
    [switch]$NonInteractive,
    [switch]$Claude,
    [switch]$Codex,
    [switch]$Cursor,
    [switch]$Gemini,
    [switch]$Copilot,
    [switch]$Antigravity,
    [switch]$Kiro
)

$ErrorActionPreference = 'Stop'

$ROGUE_BASE_URL_DEFAULT = 'https://api.rogue.security'
$MarketplaceName = 'rogue-marketplace'
$CopilotMarketplaceName = 'rogue-copilot'
$PluginName      = 'rogue'
$EnvFile = Join-Path $env:USERPROFILE '.rogue-env'
$MachineEnvFile = 'C:\ProgramData\rogue\env'

# Merge env vars -> params (explicit params win).
if (-not $ApiKey)     { $ApiKey     = $env:ROGUE_API_KEY }
if (-not $Email)      { $Email      = $env:ROGUE_ACTOR_EMAIL }
if (-not $Name)       { $Name       = $env:ROGUE_ACTOR_NAME }
$BaseUrlExplicit = [bool]$BaseUrl -or [bool]$env:ROGUE_BASE_URL
if (-not $BaseUrl)    { $BaseUrl    = if ($env:ROGUE_BASE_URL) { $env:ROGUE_BASE_URL } else { $ROGUE_BASE_URL_DEFAULT } }
if (-not $PluginRepo) { $PluginRepo = if ($env:ROGUE_PLUGIN_REPO) { $env:ROGUE_PLUGIN_REPO } else { 'qualifire-dev/rogue-plugins' } }
if ($env:ROGUE_NON_INTERACTIVE) { $NonInteractive = $true }

function Log  { param([string]$M) Write-Host "-> $M" -ForegroundColor Cyan }
function Ok   { param([string]$M) Write-Host "v  $M" -ForegroundColor Green }
function Warn2{ param([string]$M) Write-Host "!  $M" -ForegroundColor Yellow }
function Die  { param([string]$M) Write-Host "x  $M" -ForegroundColor Red; exit 1 }

# -- Kiro (IDE / CLI / Crew) -----------------------------------------------------
# Kiro has no plugin CLI and no marketplace (mirrors install.sh). The bridge is
# copied to %USERPROFILE%\.rogue\plugins\kiro - OUTSIDE every Kiro path - and the
# files that point Kiro at it are written by the functions below. Measured on
# kiro-cli 2.21.0 / IDE 1.0.437 (FIRE-2030):
#
#   %USERPROFILE%\.kiro\hooks\rogue.json   IDE 1.x + the 3.0 engine. Universal v1,
#                                          every monitored event, NO matcher (`*` is
#                                          an invalid regex there).
#   <agent>.json "hooks": [...]            The 2.x engine (the default) reads hooks
#                                          from agent configs ONLY: merged into every
#                                          custom agent, plus a `rogue` agent created
#                                          through kiro-cli and made the default when
#                                          the user set none (ADR 0001).
#
# The Crew wrappers are POSIX shell scripts and are not written here. No Kiro
# payload names its surface, so each file fixes the bridge's surface argument:
# hook file -> kiro_ide (the IDE reads nothing else, and the prompt block is
# IDE-only), agent configs -> kiro_cli. The 3.0 engine loads BOTH: the bridge
# drops the agent-hook copy there, so each event is recorded once, labelled
# kiro_ide - the one known mislabel until FIRE-2038 finds a run-time signal.
#
# Paths are built with [IO.Path]::Combine, not 'a\b' literals: the unit tests load
# these functions on Linux through the ROGUE_INSTALL_LIB_ONLY seam, where a
# backslash is an ordinary filename character.
$KiroHookTimeout   = 10
$KiroFileEvents    = @('SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop',
                       'PostFileCreate', 'PostFileSave', 'PostFileDelete')
$KiroAgentTriggers = @('agentSpawn', 'userPromptSubmit', 'preToolUse', 'postToolUse', 'stop')

function Get-KiroBridgeCommand {
    param([string]$PluginDir, [string]$EventName, [string]$Surface)
    $bridge = [System.IO.Path]::Combine($PluginDir, 'scripts', 'hook.ps1')
    return "powershell -NoProfile -ExecutionPolicy Bypass -File `"$bridge`" $EventName $Surface"
}

# The hooks array both Kiro formats share:
# [{name, trigger, action:{type:"command", command}, timeout}].
function New-KiroHookEntries {
    param([string]$PluginDir, [string]$Surface, [string[]]$Triggers)
    $entries = @()
    foreach ($t in $Triggers) {
        $entries += [ordered]@{
            name    = "rogue-$t"
            trigger = $t
            action  = [ordered]@{ type = 'command'; command = (Get-KiroBridgeCommand $PluginDir $t $Surface) }
            timeout = $KiroHookTimeout
        }
    }
    # No unary comma: callers collect the entries with @(), and a comma-wrapped
    # array would land inside it as ONE element - serialising hooks as [[...]].
    return $entries
}

# UTF-8 without BOM: Windows PowerShell 5.1's Set-Content -Encoding UTF8 writes one,
# and a BOM is not JSON.
# PowerShell 5.1 silently stringifies objects beyond ConvertTo-Json's limit.
# Reject those configurations before touching the user's file.
function Assert-KiroJsonDepth {
    param($Value, [int]$Depth = 0)
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return }
    if ($Depth -gt 100) { throw 'Kiro agent configuration exceeds the supported JSON depth (100).' }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($child in $Value.Values) { Assert-KiroJsonDepth $child ($Depth + 1) }
    } elseif ($Value -is [System.Collections.IList]) {
        foreach ($child in $Value) { Assert-KiroJsonDepth $child ($Depth + 1) }
    } else {
        foreach ($property in $Value.PSObject.Properties) { Assert-KiroJsonDepth $property.Value ($Depth + 1) }
    }
}

function Write-KiroJsonFile {
    param([string]$Path, $Document)
    Assert-KiroJsonDepth $Document
    $json = $Document | ConvertTo-Json -Depth 100 -ErrorAction Stop
    [System.IO.File]::WriteAllText($Path, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Write-KiroHookFile {
    param([string]$PluginDir, [string]$HooksDir)
    New-Item -ItemType Directory -Path $HooksDir -Force | Out-Null
    $doc = [ordered]@{ version = 'v1'; hooks = @(New-KiroHookEntries $PluginDir 'kiro_ide' $KiroFileEvents) }
    $path = Join-Path $HooksDir 'rogue.json'
    Write-KiroJsonFile $path $doc
    return $path
}

function Test-KiroOwnedHook {
    param($Hook)
    if ($null -eq $Hook) { return $false }
    $name = $Hook.name
    return ($name -is [string] -and $name.StartsWith('rogue-'))
}

# Merge Rogue's hooks into one agent config, keeping every other field and every
# hook that is not ours (ours are the `rogue-*` names, so a re-run replaces its own
# entries instead of stacking them). Returns 'merged', 'unparseable' (not a JSON
# object) or 'not-array' (a `hooks` block in some other form); never throws, so
# one bad file cannot stop the run.
function Merge-KiroAgentHooks {
    param([string]$File, [object[]]$Entries)
    try { $cfg = Get-Content -Raw -LiteralPath $File -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { return 'unparseable' }
    if ($null -eq $cfg -or $cfg -is [array] -or $cfg -isnot [PSCustomObject]) { return 'unparseable' }
    $prop = $cfg.PSObject.Properties['hooks']
    $kept = @()
    if ($prop) {
        if ($prop.Value -isnot [System.Collections.IList]) { return 'not-array' }
        $kept = @($prop.Value | Where-Object { -not (Test-KiroOwnedHook $_) })
    }
    $merged = @($kept + $Entries)
    if ($prop) { $prop.Value = $merged }
    else { $cfg | Add-Member -NotePropertyName hooks -NotePropertyValue $merged }
    try { Write-KiroJsonFile $File $cfg }
    catch { Warn2 "Leaving $File unchanged: $($_.Exception.Message)"; return 'unparseable' }
    return 'merged'
}

function Merge-KiroAgentDirs {
    param([string[]]$Dirs, [object[]]$Entries)
    foreach ($dir in $Dirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File)) {
            switch (Merge-KiroAgentHooks $f.FullName $Entries) {
                'merged'      { Ok "Agent hooks merged -> $($f.FullName)" }
                'unparseable' { Warn2 "Skipping $($f.FullName) - not a JSON object (fix it and re-run to add the Rogue hooks)." }
                'not-array'   { Warn2 "Skipping $($f.FullName) - its hooks block is not the array form (fix it and re-run to add the Rogue hooks)." }
            }
        }
    }
}

# kiro-cli is a native command: it writes its errors to stderr and answers in the
# exit code, both of which $ErrorActionPreference = 'Stop' would turn into a
# terminating error. Run it under Continue and hand back both channels.
function Invoke-KiroCli {
    param([string[]]$CliArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $errFile = [System.IO.Path]::GetTempFileName()
    $code = 1; $out = ''; $err = ''
    try {
        $out = (& kiro-cli @CliArgs 2>$errFile | Out-String).Trim()
        $code = $LASTEXITCODE
        $err = (Get-Content -Raw -LiteralPath $errFile -ErrorAction SilentlyContinue)
    } catch { $err = $_.Exception.Message }
    finally {
        $ErrorActionPreference = $prev
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
    return @{ Output = $out; Error = $err; ExitCode = $code }
}

# ADR 0001: the built-in default agent cannot carry hooks, so a `rogue` agent is
# created from Kiro's own defaults. Returns $true when the config exists afterwards.
function Install-KiroRogueAgent {
    $cfg = [System.IO.Path]::Combine($env:USERPROFILE, '.kiro', 'agents', 'rogue.json')
    if (Test-Path -LiteralPath $cfg) { return $true }
    # `agent create` opens the editor on the new file (install.sh points it at
    # `true`); a command that returns at once keeps the installer from blocking
    # on an editor window. Unverified on Windows hardware (FIRE-2038).
    $prevEditor = $env:EDITOR; $prevVisual = $env:VISUAL
    $env:EDITOR = 'cmd /c exit'; $env:VISUAL = $env:EDITOR
    try { $res = Invoke-KiroCli @('agent', 'create', '--name', 'rogue') }
    finally { $env:EDITOR = $prevEditor; $env:VISUAL = $prevVisual }
    if (-not (Test-Path -LiteralPath $cfg)) {
        # kiro-cli 2.21.0 refuses `agent create` when it is not logged in, so this
        # is the ordinary first-run path on a fresh machine.
        Warn2 "kiro-cli agent create --name rogue failed - plain 'kiro-cli chat' on the 2.x engine will carry no Rogue hooks."
        if ($res.Error) { Log $res.Error }
        Log 'If kiro-cli is not logged in, run kiro-cli login and re-run this installer; the default agent is left as it is.'
        return $false
    }
    Ok 'Agent rogue created via kiro-cli agent create'
    return $true
}

# The merged config carries our entries under their `rogue-*` names.
function Test-KiroAgentCarriesHooks {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return $false }
    return [bool]((Get-Content -Raw -LiteralPath $File) -match '"rogue-preToolUse"')
}

# The default becomes `rogue` ONLY when the user set none; a default the user chose
# is left alone and reported, because changing it would silently change which agent
# every `kiro-cli chat` runs.
function Set-KiroDefaultAgent {
    $current = Invoke-KiroCli @('settings', 'chat.defaultAgent')
    if ($current.ExitCode -eq 0 -and $current.Output) {
        Ok "Default agent already set ($($current.Output)) - left unchanged."
        if ($current.Output -ne 'rogue' -and $current.Output -ne '"rogue"') {
            Log 'On the 2.x engine only agents with the Rogue hooks are covered; switch with: kiro-cli agent set-default rogue'
        }
        return
    }
    $set = Invoke-KiroCli @('agent', 'set-default', 'rogue')
    if ($set.ExitCode -eq 0) { Ok 'Default agent set to rogue (no default was set)' }
    else { Warn2 "kiro-cli agent set-default rogue failed - run it by hand so plain 'kiro-cli chat' carries the Rogue hooks." }
}

# Everything after the bridge copy: the hook file, the rogue agent, the merges,
# and the default - switched only to a `rogue` agent that exists AND carries the
# hooks after the merge: pointing the CLI at an agent `agent create` never wrote
# (not logged in, say) would break every plain `kiro-cli chat`.
function Install-KiroHooks {
    param([string]$PluginDir, [string]$WorkspaceDir)
    $hooksDir = [System.IO.Path]::Combine($env:USERPROFILE, '.kiro', 'hooks')
    $hookFile = Write-KiroHookFile $PluginDir $hooksDir
    Ok "Hook file written -> $hookFile"
    $agentEntries = @(New-KiroHookEntries $PluginDir 'kiro_cli' $KiroAgentTriggers)
    $haveAgent = $false
    if (Get-Command kiro-cli -ErrorAction SilentlyContinue) {
        $haveAgent = Install-KiroRogueAgent
    } else {
        Log "kiro-cli not on PATH - the IDE and the 3.0 engine load $hookFile directly."
    }
    Merge-KiroAgentDirs @(
        [System.IO.Path]::Combine($env:USERPROFILE, '.kiro', 'agents'),
        [System.IO.Path]::Combine($WorkspaceDir, '.kiro', 'agents')
    ) $agentEntries
    if (-not $haveAgent) { return }
    $rogueCfg = [System.IO.Path]::Combine($env:USERPROFILE, '.kiro', 'agents', 'rogue.json')
    if (Test-KiroAgentCarriesHooks $rogueCfg) { Set-KiroDefaultAgent }
    else { Warn2 "$rogueCfg carries no Rogue hooks after the merge - the default agent is left as it is." }
}

# Kiro ships no `kiro` binary on PATH: the CLI is `kiro-cli`, the IDE installs
# under %LOCALAPPDATA%\Programs\Kiro, and both keep their state under %USERPROFILE%\.kiro.
function Test-KiroInstalled {
    if (Get-Command kiro-cli -ErrorAction SilentlyContinue) { return $true }
    if ($env:LOCALAPPDATA -and (Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\Kiro'))) { return $true }
    return [bool](Test-Path (Join-Path $env:USERPROFILE '.kiro'))
}

# -- Credentials ---------------------------------------------------------------
function ConvertFrom-ShellQuoted {
    param([string]$Val)
    if ($null -eq $Val) { return $Val }
    $sb = [System.Text.StringBuilder]::new()
    $i = 0; $n = $Val.Length
    $state = 'normal'   # normal | single | double
    while ($i -lt $n) {
        $c = $Val[$i]
        switch ($state) {
            'single' {
                if ($c -eq "'") { $state = 'normal' } else { [void]$sb.Append($c) }
            }
            'double' {
                if ($c -eq '"') { $state = 'normal' }
                elseif ($c -eq '\' -and ($i + 1) -lt $n -and ('"\$`'.IndexOf($Val[$i+1]) -ge 0)) {
                    [void]$sb.Append($Val[$i+1]); $i++
                } else { [void]$sb.Append($c) }
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

function Test-EnvFileHasKey {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*(?:export\s+)?ROGUE_API_KEY=["'']?[^"''\s]') { return $true }
    }
    return $false
}

function Read-EnvFileValues {
    param([string]$Path)
    $vals = @{}
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
            $vals[$Matches[1]] = ConvertFrom-ShellQuoted $Matches[2].Trim()
        }
    }
    return $vals
}

# Same rule as Test-RogueEnvFile -System (scripts/shared/env-file.ps1), inlined
# because this installer is one downloaded file: owned by SYSTEM or Administrators
# (root off Windows), writable by nobody else.
function Test-MachineEnvTrusted {
    param([string]$Path)
    try {
        if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
            $info = & stat -Lc '%u %a' $Path 2>$null
            if ($LASTEXITCODE -ne 0) { $info = & stat -Lf '%u %Lp' $Path 2>$null }
            if ($LASTEXITCODE -ne 0 -or $info -notmatch '^(\d+) ([0-7]+)$') { return $false }
            return ($Matches[1] -eq '0' -and ([Convert]::ToInt32($Matches[2], 8) -band 18) -eq 0)
        }
        if ($PSVersionTable.PSVersion.Major -eq 5) {
            Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
        }
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $admins = @('S-1-5-18', 'S-1-5-32-544')
        $trusted = @($admins) + [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if ($acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -notin $admins) { return $false }
        $write = [System.Security.AccessControl.FileSystemRights]'Write, Delete, ChangePermissions, TakeOwnership, DeleteSubdirectoriesAndFiles'
        foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $write) -and
                $rule.IdentityReference.Value -notin $trusted) { return $false }
        }
        return $true
    } catch { return $false }
}

# Load existing creds from the user env file when it holds ROGUE_API_KEY, as the
# dispatcher reads it.
function Load-ExistingCreds {
    if (-not (Test-EnvFileHasKey $script:EnvFile)) { return }
    $vals = Read-EnvFileValues $script:EnvFile
    if (-not $script:ApiKey) { $script:ApiKey = $vals['ROGUE_API_KEY'] }
    if (-not $script:Email -and $vals['ROGUE_ACTOR_EMAIL']) { $script:Email = $vals['ROGUE_ACTOR_EMAIL'] }
    if (-not $script:Name -and $vals['ROGUE_ACTOR_NAME']) { $script:Name = $vals['ROGUE_ACTOR_NAME'] }
    if (-not $script:BaseUrlExplicit -and $vals['ROGUE_BASE_URL']) { $script:BaseUrl = $vals['ROGUE_BASE_URL'] }
}

function Read-ApiKey {
    if ($NonInteractive) {
        Warn2 'No API key set and running non-interactively - skipping key setup.'
        Warn2 'Run /rogue:setup inside Claude Code to connect your key later.'
        return
    }
    $secure = Read-Host 'Rogue API key (rsk_...)' -AsSecureString
    $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    # BSTR is UTF-16 everywhere; PtrToStringAuto decodes it as UTF-8 off Windows.
    $script:ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    if (-not $script:ApiKey) { Die 'API key cannot be empty.' }
}

# Actor identity: git config -> env fallbacks (mirrors actor.sh).
function Resolve-Actor {
    if (-not $script:Email) { try { $script:Email = (& git config --global user.email 2>$null | Out-String).Trim() } catch {} }
    if (-not $script:Name)  { try { $script:Name  = (& git config --global user.name 2>$null | Out-String).Trim() } catch {} }
    if (-not $script:Email -and $env:CLAUDE_CODE_USER_EMAIL) { $script:Email = $env:CLAUDE_CODE_USER_EMAIL }
    if (-not $script:Email) { $script:Email = "$env:USERNAME@$env:COMPUTERNAME" }
    if (-not $script:Name)  { $script:Name  = $env:USERNAME }
    Log "Actor: $script:Name <$script:Email>"
}

# Validate the key AND register this install via /api/v1/hooks/status (the same
# heartbeat the SessionStart hook calls), so the dashboard roster row is deduped.
function Register-ApiKey {
    param([string]$Key, [string]$Url, [string]$ActorEmail, [string]$MachineFile)
    Log 'Validating API key...'
    try {
        $hostName = $env:COMPUTERNAME; if (-not $hostName) { $hostName = 'unknown' }
        # /api/v1/hooks/status has side effects (it registers/updates the roster
        # row), so register under an agent actually being installed — a Copilot-
        # only or Codex-only install must NOT create a bogus Claude roster row.
        # Prefer claude when it's a target (its heartbeat backs the row,
        # preserving prior behavior); otherwise use the first selected agent.
        # Values mirror each heartbeat.
        $scFamily = 'claude'; $scAgent = 'claude_code'
        if ($hasClaude)      { $scFamily = 'claude';  $scAgent = 'claude_code' }
        elseif ($hasCodex)   { $scFamily = 'openai';  $scAgent = 'codex_cli' }
        elseif ($hasCursor)  { $scFamily = 'cursor';  $scAgent = 'cursor' }
        elseif ($hasGemini)  { $scFamily = 'gemini';  $scAgent = 'gemini_cli' }
        elseif ($hasCopilot) { $scFamily = 'copilot'; $scAgent = 'github_copilot' }
        elseif ($hasKiro)    { $scFamily = 'kiro';    $scAgent = 'kiro_cli' }
        $body = @{ agent_family = $scFamily; agent = $scAgent; host = $hostName; actor_email = $ActorEmail } | ConvertTo-Json -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $resp = Invoke-WebRequest -Uri "$($Url.TrimEnd('/'))/api/v1/hooks/status" -Method Post `
            -Headers @{ 'x-rogue-api-key' = $Key } -ContentType 'application/json' `
            -Body $bytes -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        if ($resp.StatusCode -eq 200) { Ok 'Key validated.'; return }
        if ($MachineFile) { Warn2 "Unexpected response (HTTP $($resp.StatusCode)) validating the key in $MachineFile" }
        else { Warn2 "Unexpected response (HTTP $($resp.StatusCode)) - saving without verification." }
    } catch {
        $code = $null
        if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch {} }
        if ($code -eq 401 -or $code -eq 403) {
            # Nothing is saved on the machine path, so a bad key can only be reported.
            if ($MachineFile) { Warn2 "The key in $MachineFile is invalid (HTTP $code) - every hook fails open until the MDM script pushes a valid one"; return }
            if ($NonInteractive) { Die "Invalid API key (HTTP $code)." }
            Warn2 "Invalid key (HTTP $code) - saving anyway. Verify it at https://app.rogue.security/settings/api-keys"
        } elseif ($MachineFile) {
            Warn2 "Could not reach $Url to validate the key in $MachineFile"
        } else {
            Warn2 "Could not reach $Url to validate - saving without verification."
        }
    }
}

function Format-EnvVal { param([string]$Val) return "'" + $Val.Replace("'", "'\''") + "'" }

function Write-UserEnvFile {
    $managed = @('ROGUE_API_KEY', 'ROGUE_ACTOR_EMAIL', 'ROGUE_ACTOR_NAME')
    if ($BaseUrlExplicit) { $managed += 'ROGUE_BASE_URL' }
    foreach ($pair in @(@('ROGUE_API_KEY', $ApiKey), @('ROGUE_ACTOR_EMAIL', $Email),
                        @('ROGUE_ACTOR_NAME', $Name), @('ROGUE_BASE_URL', $BaseUrl))) {
        if ([string]$pair[1] -match "[`r`n]") {
            Die "Refusing to write ${EnvFile}: the value for $($pair[0]) contains a line break"
        }
    }
    $envLines = @(
        '# Managed by the Rogue plugins. Read by hook subprocesses at runtime.',
        '# Delete this file to revoke credentials.',
        "export ROGUE_API_KEY=$(Format-EnvVal $ApiKey)",
        "export ROGUE_ACTOR_EMAIL=$(Format-EnvVal $Email)",
        "export ROGUE_ACTOR_NAME=$(Format-EnvVal $Name)"
    )
    if ($BaseUrlExplicit -and $BaseUrl -ne $ROGUE_BASE_URL_DEFAULT) {
        $envLines += "export ROGUE_BASE_URL=$(Format-EnvVal $BaseUrl)"
    }
    if (Test-Path -LiteralPath $EnvFile) {
        $owned = '^\s*(?:export\s+)?(?:' + ($managed -join '|') + ')\s*='
        $header = '^\s*# (Managed by the [Rr]ogue|Delete this file to revoke credentials)'
        foreach ($line in (Get-Content -LiteralPath $EnvFile -Encoding UTF8 -ErrorAction Stop)) {
            if ($line -match $owned -or $line -match $header) { continue }
            $envLines += $line
        }
    }
    $envDir = Split-Path $EnvFile
    if ($envDir -and -not (Test-Path $envDir)) { New-Item -ItemType Directory -Path $envDir -Force | Out-Null }
    $envTmp = "$EnvFile.rogue-tmp.$PID"
    try {
        [System.IO.File]::WriteAllText($envTmp, (($envLines -join "`n") + "`n"),
            (New-Object System.Text.UTF8Encoding($false)))
        try {
            $acl = Get-Acl $envTmp
            $acl.SetAccessRuleProtection($true, $false)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                [System.Security.Principal.WindowsIdentity]::GetCurrent().Name, 'FullControl', 'Allow')
            $acl.SetAccessRule($rule); Set-Acl $envTmp $acl
        } catch { Warn2 "Could not restrict permissions on $EnvFile (non-fatal)." }
        Move-Item -LiteralPath $envTmp -Destination $EnvFile -Force
    } catch {
        Remove-Item -LiteralPath $envTmp -Force -ErrorAction SilentlyContinue
        Die "Could not write $EnvFile"
    }
    Ok "Credentials written to $EnvFile"
}

# The dispatchers read a keyed machine env file alone, so on such a machine the
# user env file is never consulted: no prompt, no write, and a key passed to the
# installer goes nowhere. The key is still validated the way the hooks will use it.
function Use-MachineEnvFile {
    $script:CredentialSource = $script:MachineEnvFile
    Ok "Credentials come from the machine env file $script:MachineEnvFile - no API key prompt, $script:EnvFile not written."
    if ($script:ApiKey -or $script:BaseUrlExplicit) {
        Warn2 "The passed API key / base URL is ignored: $script:MachineEnvFile is read alone. Rotate it through the MDM script (docs/deployment.md, Rotating the API key)."
    }
    $vals = Read-EnvFileValues $script:MachineEnvFile
    $url = if ($vals['ROGUE_BASE_URL']) { $vals['ROGUE_BASE_URL'] } else { $ROGUE_BASE_URL_DEFAULT }
    if ($vals['ROGUE_ACTOR_EMAIL']) { $script:Email = $vals['ROGUE_ACTOR_EMAIL'] }
    Resolve-Actor
    Register-ApiKey -Key $vals['ROGUE_API_KEY'] -Url $url -ActorEmail $script:Email -MachineFile $script:MachineEnvFile
}

function Configure-Credentials {
    if (Test-EnvFileHasKey $script:MachineEnvFile) {
        if (Test-MachineEnvTrusted $script:MachineEnvFile) { Use-MachineEnvFile; return }
        # Kiro and the log shipper skip an untrusted machine file, so the user file
        # must still be written for them.
        Warn2 "$script:MachineEnvFile holds ROGUE_API_KEY but is not owned by SYSTEM/Administrators or is writable by others - Kiro and log shipping ignore it; configuring $script:EnvFile instead."
    }
    $script:CredentialSource = $script:EnvFile
    Load-ExistingCreds
    if (-not $script:ApiKey) { Read-ApiKey }
    Resolve-Actor
    if (-not $script:ApiKey) { return }
    Register-ApiKey -Key $script:ApiKey -Url $script:BaseUrl -ActorEmail $script:Email
    Write-UserEnvFile
}


# Test seam: load only the functions above (tests/test_install_kiro_ps1.ps1,
# tests/test_install_env_ps1.ps1).
if ($env:ROGUE_INSTALL_LIB_ONLY) { return }

try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

Write-Host ""
Write-Host "Rogue Security (Windows)" -ForegroundColor Cyan

# Agent selection. -Claude/-Codex/-Cursor pick an explicit set; with none, auto-detect
# every supported agent. claude/codex ship a CLI on PATH; Cursor's `cursor` command is
# opt-in, so detection also accepts %USERPROFILE%\.cursor. An explicitly selected CLI
# agent still needs its binary; Cursor is a plain file copy, so it installs regardless.
# Antigravity has no `antigravity` binary on PATH — detect the `agy` CLI or its data
# dirs under %USERPROFILE%\.gemini (IDE and/or manual-CLI installs).
$explicit = $Claude -or $Codex -or $Cursor -or $Gemini -or $Copilot -or $Antigravity -or $Kiro
if ($explicit) {
    $hasClaude      = [bool]$Claude
    $hasCodex       = [bool]$Codex
    $hasCursor      = [bool]$Cursor
    $hasGemini      = [bool]$Gemini
    $hasCopilot     = [bool]$Copilot
    $hasAntigravity = [bool]$Antigravity
    $hasKiro        = [bool]$Kiro
    if ($hasClaude -and -not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Die "-Claude requested but the 'claude' CLI is not on PATH. Install Claude Code (https://claude.com/code) first."
    }
    if ($hasCodex -and -not (Get-Command codex -ErrorAction SilentlyContinue)) {
        Die "-Codex requested but the 'codex' CLI is not on PATH. Install OpenAI Codex first."
    }
    if ($hasGemini -and -not (Get-Command gemini -ErrorAction SilentlyContinue)) {
        Die "-Gemini requested but the 'gemini' CLI is not on PATH. Install Gemini CLI (https://geminicli.com) first."
    }
    if ($hasCopilot -and -not (Get-Command copilot -ErrorAction SilentlyContinue)) {
        Die "-Copilot requested but the 'copilot' CLI is not on PATH. Install GitHub Copilot CLI (https://github.com/github/copilot-cli) first."
    }
    if ($hasAntigravity -and -not ((Get-Command agy -ErrorAction SilentlyContinue) -or (Test-Path (Join-Path $env:USERPROFILE '.gemini\antigravity*')))) {
        Die "-Antigravity requested but no Antigravity install was detected (looked for: agy CLI, %USERPROFILE%\.gemini\antigravity*). Install Google Antigravity first."
    }
    if ($hasKiro -and -not (Test-KiroInstalled)) {
        Die "-Kiro requested but no Kiro install was detected (looked for: kiro-cli, %LOCALAPPDATA%\Programs\Kiro, %USERPROFILE%\.kiro). Install Kiro (https://kiro.dev) first."
    }
} else {
    $hasClaude      = [bool](Get-Command claude -ErrorAction SilentlyContinue)
    $hasCodex       = [bool](Get-Command codex  -ErrorAction SilentlyContinue)
    $hasCursor      = [bool](Get-Command cursor -ErrorAction SilentlyContinue) -or (Test-Path (Join-Path $env:USERPROFILE '.cursor'))
    $hasGemini      = [bool](Get-Command gemini -ErrorAction SilentlyContinue)
    $hasCopilot     = [bool](Get-Command copilot -ErrorAction SilentlyContinue)
    $hasAntigravity = [bool](Get-Command agy -ErrorAction SilentlyContinue) -or (Test-Path (Join-Path $env:USERPROFILE '.gemini\antigravity*'))
    $hasKiro        = Test-KiroInstalled
    if (-not ($hasClaude -or $hasCodex -or $hasCursor -or $hasGemini -or $hasCopilot -or $hasAntigravity -or $hasKiro)) {
        Die "No supported coding agent found (looked for: claude, codex, cursor, gemini, copilot, antigravity, kiro). Install Claude Code (https://claude.com/code), OpenAI Codex, Cursor (https://cursor.com), Gemini CLI (https://geminicli.com), GitHub Copilot CLI (https://github.com/github/copilot-cli), Google Antigravity, or Kiro (https://kiro.dev) first."
    }
}
# Claude shells out to git to clone the marketplace; git is required only for it.
if ($hasClaude -and -not (Get-Command git -ErrorAction SilentlyContinue)) {
    Die "git not found. Install Git for Windows (https://git-scm.com/download/win) first."
}

Configure-Credentials

# Install through each agent's CLI marketplace (cross-platform; same monorepo for
# both — Claude reads .claude-plugin/marketplace.json, Codex reads
# .agents/plugins/marketplace.json; marketplace `rogue-marketplace` + plugin
# `rogue` are identical). `claude`/`codex` are native commands — a non-zero exit
# does NOT throw, so gate on $LASTEXITCODE.
if ($hasClaude) {
    Write-Host ""
    Write-Host "Rogue Security - Claude Code" -ForegroundColor Cyan
    Log "Adding marketplace $PluginRepo"
    $mktOk = $false
    try { & claude plugin marketplace add $PluginRepo 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $mktOk = $true } } catch {}
    if ($mktOk) { Ok 'Marketplace added' }
    else {
        try { & claude plugin marketplace update $MarketplaceName 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $mktOk = $true } } catch {}
        if ($mktOk) { Ok 'Marketplace updated' }
        else { Warn2 'Could not add or update marketplace (continuing - it may already be present).' }
    }
    Log "Installing plugin $PluginName@$MarketplaceName"
    $installed = $false
    try { & claude plugin install "$PluginName@$MarketplaceName" 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $installed = $true } } catch {}
    if (-not $installed) {
        try { & claude plugin update $PluginName 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $installed = $true } } catch {}
    }
    if (-not $installed) { Die "claude plugin install failed. Run 'claude plugin install $PluginName@$MarketplaceName' to see the error." }
    Ok 'Plugin installed'
}

if ($hasCodex) {
    Write-Host ""
    Write-Host "Rogue Security - OpenAI Codex" -ForegroundColor Cyan
    Log "Adding marketplace $PluginRepo"
    $mktOk = $false
    try { & codex plugin marketplace add $PluginRepo 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $mktOk = $true } } catch {}
    if ($mktOk) { Ok 'Marketplace added' }
    else {
        try { & codex plugin marketplace upgrade $MarketplaceName 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $mktOk = $true } } catch {}
        if ($mktOk) { Ok 'Marketplace updated' }
        else { Warn2 'Could not add or update Codex marketplace (continuing - it may already be present).' }
    }
    Log "Installing plugin $PluginName@$MarketplaceName"
    # Codex uses `plugin add` (not `install`); idempotent re-add is fine.
    $installed = $false
    try { & codex plugin add "$PluginName@$MarketplaceName" 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $installed = $true } } catch {}
    if (-not $installed) { Die "codex plugin add failed. Run 'codex plugin add $PluginName@$MarketplaceName' to see the error." }
    Ok 'Plugin installed'
    Warn2 'Codex skips untrusted hooks - open /hooks in Codex and trust the Rogue entries once.'
}

# Cursor has no plugin CLI: install is a file copy into
# %USERPROFILE%\.cursor\plugins\local\rogue. Download the release tarball, extract
# with `tar` (bundled in Windows 10+), and copy plugins\cursor into place. The Team
# Marketplace is the separate, admin-driven managed path; this does not touch it.
if ($hasCursor) {
    Write-Host ""
    Write-Host "Rogue Security - Cursor" -ForegroundColor Cyan
    # Cursor ships dual dispatchers (sh + PowerShell) like Claude/Codex; the runtime
    # is the same shell stack, so no extra prerequisite check beyond tar (below).
    $asset = 'rogue-plugin-cursor.tar.gz'
    if ($env:ROGUE_PLUGIN_VERSION) {
        $url = "https://github.com/$PluginRepo/releases/download/$($env:ROGUE_PLUGIN_VERSION)/$asset"
    } else {
        $url = "https://github.com/$PluginRepo/releases/latest/download/$asset"
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-cursor-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    # Non-fatal: Cursor is detected from %USERPROFILE%\.cursor (present for nearly
    # every developer), so a missing release asset or download error must NOT abort
    # the run and break the Claude/Codex installs above. Warn and continue.
    try {
        Log "Downloading plugin $asset"
        $tarball = Join-Path $tmp 'p.tar.gz'
        Invoke-WebRequest -Uri $url -OutFile $tarball -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        & tar -xzf $tarball -C $tmp
        if ($LASTEXITCODE -ne 0) { throw "Could not extract the Cursor plugin tarball (is 'tar' available?)." }
        $src = Get-ChildItem -Path $tmp -Recurse -Directory -Filter 'cursor' |
            Where-Object { Test-Path (Join-Path $_.FullName '.cursor-plugin\plugin.json') } |
            Select-Object -First 1
        if (-not $src) { throw "Cursor plugin manifest missing in download." }
        $dest = Join-Path $env:USERPROFILE '.cursor\plugins\local\rogue'
        if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item -Recurse -Force (Join-Path $src.FullName '*') $dest
        Ok "Plugin installed -> $dest"
        Warn2 'Fully quit and reopen Cursor, then run /rogue:status to verify.'
    } catch {
        Warn2 "Cursor plugin not installed ($($_.Exception.Message)). If the asset isn't published yet, re-run the installer once it is."
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

# Gemini has a native extension CLI, but `gemini extensions install <github-url>`
# expects the manifest at the source root, which the monorepo root is not. So we
# download the release tarball (whose top dir IS the extension, manifest at root),
# extract it with `tar` (bundled in Windows 10+), and `gemini extensions install
# <dir>`. Gemini makes its own managed copy, so the temp dir is disposable.
# Re-running upgrades (uninstall-then-install). Non-fatal.
if ($hasGemini) {
    Write-Host ""
    Write-Host "Rogue Security - Gemini CLI" -ForegroundColor Cyan
    $asset = 'rogue-plugin-gemini.tar.gz'
    if ($env:ROGUE_PLUGIN_VERSION) {
        $url = "https://github.com/$PluginRepo/releases/download/$($env:ROGUE_PLUGIN_VERSION)/$asset"
    } else {
        $url = "https://github.com/$PluginRepo/releases/latest/download/$asset"
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-gemini-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    # GEMINI_CLI_TRUST_WORKSPACE=true is Gemini's documented headless bypass for
    # its folder-trust gate (default-ON): without it the install prompts "Do you
    # trust the files in this folder?" for our own just-extracted temp dir, the
    # prompt is invisible here (output piped to Out-Null), the non-interactive
    # default is No, and the install aborts with 'Installation aborted: Folder
    # "..." is not trusted.' Captured/restored so it never leaks into the user's
    # shell session (iwr | iex runs in-session). No persistent trust granted.
    $prevGeminiTrust = $env:GEMINI_CLI_TRUST_WORKSPACE
    try {
        Log "Downloading extension $asset"
        $tarball = Join-Path $tmp 'p.tar.gz'
        Invoke-WebRequest -Uri $url -OutFile $tarball -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        & tar -xzf $tarball -C $tmp
        if ($LASTEXITCODE -ne 0) { throw "Could not extract the Gemini extension tarball (is 'tar' available?)." }
        $src = Get-ChildItem -Path $tmp -Recurse -File -Filter 'gemini-extension.json' | Select-Object -First 1
        if (-not $src) { throw "Gemini manifest missing in download." }
        $srcDir = $src.Directory.FullName
        # Reinstall cleanly so a re-run upgrades. Ignore uninstall errors (first run).
        $env:GEMINI_CLI_TRUST_WORKSPACE = 'true'
        try { & gemini extensions uninstall rogue 2>&1 | Out-Null } catch {}
        & gemini extensions install $srcDir --consent 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "gemini extensions install failed." }
        Ok "Extension installed via gemini extensions install"
        Warn2 'Gemini skips untrusted hooks - open /hooks in Gemini CLI and trust the Rogue entries once, then restart Gemini CLI.'
    } catch {
        Warn2 "Gemini extension not installed ($($_.Exception.Message)). If the asset isn't published yet, re-run the installer once it is."
    } finally {
        if ($null -eq $prevGeminiTrust) {
            Remove-Item Env:GEMINI_CLI_TRUST_WORKSPACE -ErrorAction SilentlyContinue
        } else {
            $env:GEMINI_CLI_TRUST_WORKSPACE = $prevGeminiTrust
        }
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

# Antigravity has no marketplace-add command. Like Gemini, the release tarball's
# top dir IS the plugin (manifest at its root — see scripts/build-release.sh), so
# download it, extract with `tar` (bundled in Windows 10+), and copy it into the
# IDE's global plugin dir (%USERPROFILE%\.gemini\config\plugins\rogue). If the
# `agy` CLI is present, also register it natively (uninstall-then-install so a
# re-run upgrades); otherwise, if a manual-CLI plugins dir exists, copy there too.
# Non-fatal: a failed Antigravity install must not abort the run.
if ($hasAntigravity) {
    Write-Host ""
    Write-Host "Rogue Security - Google Antigravity" -ForegroundColor Cyan
    $asset = 'rogue-plugin-antigravity.tar.gz'
    if ($env:ROGUE_PLUGIN_VERSION) {
        $url = "https://github.com/$PluginRepo/releases/download/$($env:ROGUE_PLUGIN_VERSION)/$asset"
    } else {
        $url = "https://github.com/$PluginRepo/releases/latest/download/$asset"
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-antigravity-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        Log "Downloading plugin $asset"
        $tarball = Join-Path $tmp 'p.tar.gz'
        Invoke-WebRequest -Uri $url -OutFile $tarball -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        & tar -xzf $tarball -C $tmp
        if ($LASTEXITCODE -ne 0) { throw "Could not extract the Antigravity plugin tarball (is 'tar' available?)." }
        $src = Get-ChildItem -Path $tmp -Recurse -File -Filter 'plugin.json' |
            Where-Object { Test-Path (Join-Path $_.Directory.FullName 'hooks.json') } |
            Select-Object -First 1
        if (-not $src) { throw "Antigravity plugin manifest missing in download." }
        $srcDir = $src.Directory.FullName

        # IDE global copy.
        $ideDir = Join-Path $env:USERPROFILE '.gemini\config\plugins\rogue'
        if (Test-Path $ideDir) { Remove-Item -Recurse -Force $ideDir }
        New-Item -ItemType Directory -Path $ideDir -Force | Out-Null
        Copy-Item -Recurse -Force (Join-Path $srcDir '*') $ideDir
        Ok "Plugin installed -> $ideDir"

        # CLI: native install if `agy` is present, else manual copy if the CLI dir exists.
        #
        # A failure here is not fatal: the global copy above is the shared plugins dir
        # all three surfaces read, so the CLI keeps loading the plugin from there. What
        # it must not print is a dead recovery command — $srcDir lives under $tmp, which
        # the finally block deletes on the way out. Mirrors install.sh.
        if (Get-Command agy -ErrorAction SilentlyContinue) {
            try { & agy plugin uninstall rogue 2>&1 | Out-Null } catch {}
            $agyErr = (& agy plugin install $srcDir 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0) {
                Ok "Plugin installed via agy plugin install"
            } else {
                Warn2 "agy plugin install failed - the CLI still loads the plugin from $ideDir."
                if ($agyErr) { Log $agyErr }
                Log "To retry the native registration: agy plugin install '$ideDir'"
            }
        } else {
            $cliPlugins = Join-Path $env:USERPROFILE '.gemini\antigravity-cli\plugins'
            if (Test-Path $cliPlugins) {
                $cliDir = Join-Path $cliPlugins 'rogue'
                if (Test-Path $cliDir) { Remove-Item -Recurse -Force $cliDir }
                New-Item -ItemType Directory -Path $cliDir -Force | Out-Null
                Copy-Item -Recurse -Force (Join-Path $srcDir '*') $cliDir
                Ok "Plugin installed -> $cliDir"
            }
        }
        Warn2 'Fully quit and reopen Antigravity, then run /rogue:status to verify.'
    } catch {
        Warn2 "Antigravity plugin not installed ($($_.Exception.Message)). If the asset isn't published yet, re-run the installer once it is."
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

# Kiro: download the release tarball (top dir IS the plugin), copy it to
# %USERPROFILE%\.rogue\plugins\kiro, then write the hook wiring (see the Kiro
# helpers near the top). Non-fatal: a failed Kiro install must not abort the run.
if ($hasKiro) {
    Write-Host ""
    Write-Host "Rogue Security - Kiro" -ForegroundColor Cyan
    $asset = 'rogue-plugin-kiro.tar.gz'
    if ($env:ROGUE_PLUGIN_VERSION) {
        $url = "https://github.com/$PluginRepo/releases/download/$($env:ROGUE_PLUGIN_VERSION)/$asset"
    } else {
        $url = "https://github.com/$PluginRepo/releases/latest/download/$asset"
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-kiro-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        Log "Downloading plugin $asset"
        $tarball = Join-Path $tmp 'p.tar.gz'
        Invoke-WebRequest -Uri $url -OutFile $tarball -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        & tar -xzf $tarball -C $tmp
        if ($LASTEXITCODE -ne 0) { throw "Could not extract the Kiro plugin tarball (is 'tar' available?)." }
        $src = Get-ChildItem -Path $tmp -Recurse -File -Filter 'plugin.json' |
            Where-Object { Test-Path ([System.IO.Path]::Combine($_.Directory.FullName, 'scripts', 'hook.ps1')) } |
            Select-Object -First 1
        if (-not $src) { throw "Kiro plugin manifest missing in download." }
        $pluginDir = [System.IO.Path]::Combine($env:USERPROFILE, '.rogue', 'plugins', 'kiro')
        if (Test-Path $pluginDir) { Remove-Item -Recurse -Force $pluginDir }
        New-Item -ItemType Directory -Path $pluginDir -Force | Out-Null
        Copy-Item -Recurse -Force (Join-Path $src.Directory.FullName '*') $pluginDir
        Ok "Plugin installed -> $pluginDir"
        Install-KiroHooks -PluginDir $pluginDir -WorkspaceDir (Get-Location).Path
        Warn2 'Kiro loads hooks at start: restart the IDE and open a new kiro-cli chat. IDE hooks never run in an untrusted workspace.'
        Log "Verify with: powershell -NoProfile -ExecutionPolicy Bypass -File `"$pluginDir\scripts\status.ps1`""
    } catch {
        Warn2 "Kiro plugin not installed ($($_.Exception.Message)). If the asset isn't published yet, re-run the installer once it is."
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

# Copilot has a native plugin CLI (marketplace add + install NAME@MARKETPLACE),
# same model as Claude/Codex. But Copilot reads BOTH .github/plugin/marketplace.json
# and .claude-plugin/marketplace.json from the monorepo, so its marketplace uses a
# DISTINCT name (rogue-copilot) and we install rogue@rogue-copilot to disambiguate.
# `copilot` is a native command — a non-zero exit does NOT throw, so gate on $LASTEXITCODE.
if ($hasCopilot) {
    Write-Host ""
    Write-Host "Rogue Security - GitHub Copilot CLI" -ForegroundColor Cyan
    Log "Adding marketplace $PluginRepo"
    $mktOk = $false
    try { & copilot plugin marketplace add $PluginRepo 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $mktOk = $true } } catch {}
    if ($mktOk) { Ok 'Marketplace added' }
    else {
        try { & copilot plugin marketplace update $CopilotMarketplaceName 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $mktOk = $true } } catch {}
        if ($mktOk) { Ok 'Marketplace updated' }
        else { Warn2 'Could not add or update Copilot marketplace (continuing - it may already be present).' }
    }
    Log "Installing plugin $PluginName@$CopilotMarketplaceName"
    $installed = $false
    try { & copilot plugin install "$PluginName@$CopilotMarketplaceName" 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $installed = $true } } catch {}
    if (-not $installed) {
        try { & copilot plugin update $PluginName 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $installed = $true } } catch {}
    }
    if (-not $installed) { Die "copilot plugin install failed. Run 'copilot plugin install $PluginName@$CopilotMarketplaceName' to see the error." }
    Ok 'Plugin installed'
    Warn2 'Copilot skips untrusted hooks - open /hooks in Copilot CLI and trust the Rogue entries once.'
    # Mirrors install.sh: Rogue reaches JetBrains only through Copilot's
    # CLI/Agent provider. The IDE's built-in "Local" agent runs its own hook
    # engine that refuses plugin-provided hooks (zero coverage), and no hook ever
    # runs there to warn from - the installer is the only place we can say it.
    if ($env:APPDATA -and (Test-Path -LiteralPath (Join-Path $env:APPDATA 'JetBrains'))) {
        Warn2 "In JetBrains, pick Copilot's CLI/Agent provider - the built-in Local agent ignores installed plugins, so Rogue would see nothing."
    }
}

Write-Host @"

v Rogue Security installed.

  Credentials:  $CredentialSource

Next steps:
  1. Fully quit and reopen each agent (hooks load credentials at session start).
  2. Run /rogue:status inside the agent to verify.
  3. AIDR dashboard: https://app.rogue.security/aidr

Re-running this installer upgrades the plugins and is safe.
"@ -ForegroundColor Green
