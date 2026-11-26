# Cortex Code auto-loads this plugin for CLI and Desktop; no user settings are edited.
param([switch]$Uninstall, [switch]$Status)
$ErrorActionPreference = 'Stop'
$UserHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$CortexDir = if ($env:CORTEX_HOME) { $env:CORTEX_HOME } elseif ($env:SNOWFLAKE_HOME) { Join-Path $env:SNOWFLAKE_HOME 'cortex' } else { [IO.Path]::Combine($UserHome, '.snowflake', 'cortex') }
$Dest = [IO.Path]::Combine($CortexDir, 'plugins', 'rogue-security')
$Source = Split-Path -Parent $PSScriptRoot
$Events = @('SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PermissionRequest', 'PostToolUse', 'Stop', 'SubagentStart', 'SubagentStop', 'SessionEnd')
$Utf8 = New-Object Text.UTF8Encoding($false)

function Get-HookCommand {
    param([string]$EventName)
    $hook = ([IO.Path]::Combine($Dest, 'scripts', 'hook.ps1')).Replace("'", "''")
    # Cortex runs command hooks through powershell.exe on native Windows.
    return "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath '$hook'))) '$($Dest.Replace("'", "''"))' $EventName"
}

if ($Status) {
    if (-not (Test-Path -LiteralPath ([IO.Path]::Combine($Dest, '.cortex-plugin', 'plugin.json')) -PathType Leaf)) { throw 'Missing Cortex plugin manifest' }
    $doc = [IO.File]::ReadAllText([IO.Path]::Combine($Dest, 'hooks', 'hooks.json')) | ConvertFrom-Json
    foreach ($event in $Events) {
        $hooks = @($doc.hooks.$event)[0].hooks
        if (@($hooks).Count -ne 1 -or $hooks[0].command -cne (Get-HookCommand $event) -or $hooks[0].timeout -ne 10) { throw "Missing or modified $event hook" }
    }
    foreach ($file in 'hook.ps1', 'env-file.ps1', 'actor.ps1', 'git-identity.ps1', 'ship-logs.ps1') {
        if (-not (Test-Path -LiteralPath ([IO.Path]::Combine($Dest, 'scripts', $file)) -PathType Leaf)) { throw "Missing $file" }
    }
    Write-Output "Cortex Code hooks installed in $Dest. Start a new session to verify live traffic."
    exit 0
}

New-Item -ItemType Directory -Force -Path (Split-Path $Dest) | Out-Null
$Lock = Join-Path (Split-Path $Dest) '.rogue-security.lock'
New-Item -ItemType Directory -Path $Lock -ErrorAction Stop | Out-Null
$New = Join-Path (Split-Path $Dest) ".rogue-security.new-$PID"
$Old = "$New.old"
try {
    if ($Uninstall) {
        if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force }
        Write-Output 'Removed Rogue Cortex Code hooks and bundled env; shared credentials and Cortex settings preserved.'
    } else {
        New-Item -ItemType Directory -Path $New | Out-Null
        foreach ($dir in '.cortex-plugin', 'hooks', 'scripts') { Copy-Item -LiteralPath (Join-Path $Source $dir) -Destination $New -Recurse -Force }
        # The native bridge pin travels with the scripts; a bundle without one stays on them.
        $pin = Join-Path $Source 'rogue-hook.json'
        if (Test-Path -LiteralPath $pin -PathType Leaf) { Copy-Item -LiteralPath $pin -Destination $New -Force }
        $map = [ordered]@{}
        foreach ($event in $Events) {
            $map[$event] = @([ordered]@{ matcher = '*'; hooks = @([ordered]@{ type = 'command'; command = (Get-HookCommand $event); timeout = 10 }) })
        }
        [IO.File]::WriteAllText([IO.Path]::Combine($New, 'hooks', 'hooks.json'), ([ordered]@{ hooks = $map } | ConvertTo-Json -Depth 10), $Utf8)
        $envSource = if (Test-Path -LiteralPath (Join-Path $Dest 'env')) { $Dest } else { $Source }
        if (Test-Path -LiteralPath (Join-Path $envSource 'env')) { Copy-Item -LiteralPath (Join-Path $envSource 'env') -Destination $New }
        if (Test-Path -LiteralPath $Dest) { Move-Item -LiteralPath $Dest -Destination $Old }
        try { Move-Item -LiteralPath $New -Destination $Dest }
        catch {
            if ((Test-Path -LiteralPath $Old) -and -not (Test-Path -LiteralPath $Dest)) { Move-Item -LiteralPath $Old -Destination $Dest }
            throw
        }
        Write-Output "Installed Rogue Cortex Code hooks in $Dest. Start a new CLI or Desktop session."
    }
} finally {
    if (Test-Path -LiteralPath $New) { Remove-Item -LiteralPath $New -Recurse -Force }
    if ((Test-Path -LiteralPath $Old) -and (Test-Path -LiteralPath $Dest)) { Remove-Item -LiteralPath $Old -Recurse -Force }
    Remove-Item -LiteralPath $Lock -Recurse -Force
}
