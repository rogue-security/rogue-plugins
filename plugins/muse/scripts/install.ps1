# Rogue Security - Muse Code hook installer for Windows. Muse loads Rogue's hooks
# from a Rogue-owned managed hooks file, so settings.json only gains one
# `managed_hooks_path` member, inserted and removed as text to keep the user's formatting.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 [-Uninstall | -Status]
param([switch]$Uninstall, [switch]$Status)
$ErrorActionPreference = 'Stop'

$Events = @('SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PermissionRequest', 'PostToolUse', 'PostToolUseFailure', 'Stop', 'SessionEnd', 'SubagentStart', 'SubagentStop')
$UserHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$Root = [IO.Path]::Combine($UserHome, '.rogue', 'plugins', 'muse')
$Hooks = [IO.Path]::Combine($Root, 'hooks.json')
$ConfigHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { [IO.Path]::Combine($UserHome, '.config') }
$Settings = [IO.Path]::Combine($ConfigHome, 'muse', 'settings.json')
$Utf8 = New-Object System.Text.UTF8Encoding($false)

$Lock = "$Settings.rogue-lock"
$script:locked = $false
# Releases the lock itself: Windows PowerShell 5.1 can skip `finally` on `exit`.
function Fail {
    param([string]$Message)
    if ($script:locked) { Remove-Item -LiteralPath $Lock -Force -Recurse -ErrorAction SilentlyContinue }
    [Console]::Error.WriteLine($Message); exit 1
}

# A scriptblock rather than -File: a Group Policy AllSigned execution policy overrides -ExecutionPolicy Bypass.
function Get-HookCommand {
    param([string]$EventName)
    $hook = ([IO.Path]::Combine($Root, 'scripts', 'hook.ps1')).Replace("'", "''")
    return "powershell -NoProfile -NonInteractive -Command `"& ([scriptblock]::Create((Get-Content -Raw -LiteralPath '$hook'))) '$($Root.Replace("'", "''"))' $EventName`""
}

function Get-HooksJson {
    $map = [ordered]@{}
    foreach ($e in $Events) {
        $map[$e] = @([ordered]@{ hooks = @([ordered]@{ type = 'command'; command = (Get-HookCommand $e); timeout = 6 }) })
    }
    return ([ordered]@{ hooks = $map } | ConvertTo-Json -Depth 10) + "`n"
}

# The managed_hooks_path value, $null when absent; fails on anything but an object with a string pointer.
function Get-Pointer {
    param([string]$Text)
    if (-not $Text.Trim()) { return $null }
    try { $config = $Text | ConvertFrom-Json } catch { Fail "Muse settings are not valid JSON: $Settings" }
    if ($config -isnot [System.Management.Automation.PSCustomObject]) { Fail "Muse settings must be a JSON object: $Settings" }
    $member = $config.PSObject.Properties['managed_hooks_path']
    if (-not $member) { return $null }
    if ($member.Value -isnot [string] -or -not $member.Value) { Fail "Unrecognized managed_hooks_path in $Settings; leaving it unchanged" }
    return $member.Value
}

$original = if (Test-Path -LiteralPath $Settings -PathType Leaf) { [IO.File]::ReadAllText($Settings, $Utf8) } else { $null }

if ($Status) {
    if ($null -eq $original -or (Get-Pointer $original) -ne $Hooks) { Fail "Muse settings do not point managed_hooks_path at $Hooks" }
    # Compared as parsed values: Windows PowerShell 5.1 and PowerShell 7 format JSON differently.
    try { $doc = [IO.File]::ReadAllText($Hooks, $Utf8) | ConvertFrom-Json } catch { Fail "Missing or invalid $Hooks" }
    foreach ($e in $Events) {
        $h = @($doc.hooks.$e)[0].hooks
        if (@($h).Count -ne 1 -or $h[0].command -ne (Get-HookCommand $e) -or $h[0].timeout -ne 6) { Fail "Missing or modified $e hook in $Hooks" }
    }
    foreach ($f in 'hook.ps1', 'env-file.ps1', 'actor.ps1') {
        if (-not (Test-Path -LiteralPath ([IO.Path]::Combine($Root, 'scripts', $f)))) { Fail "Missing $Root\scripts\$f" }
    }
    Write-Output 'Muse hooks installed. Start a new session to verify live traffic.'
    exit 0
}

if ((Test-Path -LiteralPath $Settings) -and -not (Test-Path -LiteralPath $Settings -PathType Leaf)) { Fail "Refusing non-regular file: $Settings" }
New-Item -ItemType Directory -Force -Path (Split-Path $Settings) | Out-Null
try { New-Item -ItemType Directory -Path $Lock | Out-Null; $script:locked = $true }
catch { Fail "Another Muse installer is running, or a previous run was interrupted. If no installer is running, remove $Lock and retry." }

function Set-Settings {
    param([string]$Text)
    $now = if (Test-Path -LiteralPath $Settings -PathType Leaf) { [IO.File]::ReadAllText($Settings, $Utf8) } else { $null }
    if ($now -cne $original) { Fail 'Muse settings changed during installation; retry' }
    if ($null -ne $original) { [IO.File]::WriteAllText("$Settings.rogue-backup", $original, $Utf8) }
    $temp = "$Settings.rogue-$PID"
    [IO.File]::WriteAllText($temp, $Text, $Utf8)
    Move-Item -LiteralPath $temp -Destination $Settings -Force
}

try {
    $current = if ($null -eq $original) { $null } else { Get-Pointer $original }
    $quoted = [regex]::Escape(($Hooks | ConvertTo-Json))

    if ($Uninstall) {
        Remove-Item -LiteralPath $Hooks -Force -ErrorAction SilentlyContinue
        if ($current -eq $Hooks) {
            $member = "`"managed_hooks_path`"\s*:\s*$quoted"
            # Own line with a trailing comma, else a last member with the comma before it.
            $updated = [regex]::Replace($original, "(?m)^[ \t]*$member[ \t]*,[ \t]*\r?\n", '', 1)
            if ($updated -eq $original) { $updated = [regex]::Replace($original, ",\s*$member", '', 1) }
            $ok = $updated -ne $original
            if ($ok) { try { $ok = -not (($updated | ConvertFrom-Json).PSObject.Properties['managed_hooks_path']) } catch { $ok = $false } }
            if ($ok) { Set-Settings $updated }
            else { Write-Output "Left managed_hooks_path in $Settings; it points at a removed file, which Muse ignores." }
        }
        Write-Output 'Removed Rogue Muse hooks; credentials and other settings preserved.'
        return
    }

    if ($current -and $current -ne $Hooks) { Fail "Muse already loads managed hooks from $current; leaving it unchanged. Add Rogue's hooks from $Hooks to that file, or remove the setting and retry." }

    $source = Split-Path -Parent $PSScriptRoot
    if ($source -ne $Root) {
        New-Item -ItemType Directory -Force -Path $Root | Out-Null
        Copy-Item -Recurse -Force -Path ([IO.Path]::Combine($source, 'scripts')), ([IO.Path]::Combine($source, 'plugin.json')) -Destination $Root
    }
    [IO.File]::WriteAllText("$Hooks.tmp", (Get-HooksJson), $Utf8)
    Move-Item -LiteralPath "$Hooks.tmp" -Destination $Hooks -Force

    if (-not $current) {
        $pointer = '"managed_hooks_path": ' + ($Hooks | ConvertTo-Json)
        if ($null -eq $original -or -not $original.Trim()) {
            Set-Settings "{`n  `"schema_version`": 1,`n  $pointer`n}`n"
        } else {
            $nl = if ($original.Contains("`r`n")) { "`r`n" } else { "`n" }
            $i = $original.IndexOf('{')
            $rest = $original.Substring($i + 1)
            $separator = if ($rest.Trim().StartsWith('}')) { '' } else { ',' }
            Set-Settings ($original.Substring(0, $i + 1) + "$nl  $pointer$separator" + $rest)
        }
    }
    Write-Output "Installed Rogue Muse hooks in $Hooks (managed_hooks_path in $Settings). Start a new Muse session."
} finally {
    Remove-Item -LiteralPath $Lock -Force -Recurse -ErrorAction SilentlyContinue
}
