#!/usr/bin/env pwsh
# tests/test_env_first_found.ps1 - the env file rule on the PowerShell readers: the
# first of machine (C:\ProgramData\rogue\env) -> bundled (<root>\env) -> user
# (%USERPROFILE%\.rogue-env) that holds ROGUE_API_KEY is used ALONE, and its values
# override the process env.
#
# The loaders reachable through the ROGUE_PS_LIB_ONLY seam (the shared shipper's
# Import-ShipEnv, antigravity's and kiro's Import-Credentials) are exercised for real,
# with the machine path literal redirected into the sandbox by editing the script TEXT
# before it is dot-sourced - the only way to stage that candidate without admin
# rights. The dispatchers whose credential block runs at file scope, past the seam,
# get a structural check on the same three properties instead.
#
#   pwsh -NoProfile -File tests/test_env_first_found.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$script:fails = 0
$script:count = 0
function Check {
    param([string]$Label, $Expected, $Actual)
    $script:count++
    if ("$Expected" -ceq "$Actual") { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL: $Label (expected [$Expected], got [$Actual])"; $script:fails++ }
}

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('rogue-envff-' + [guid]::NewGuid().ToString('N'))
$machine = Join-Path $sandbox 'machine-env'
$sbHome = Join-Path $sandbox 'home'
$root = Join-Path $sandbox 'root'
New-Item -ItemType Directory -Path $sbHome -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $root 'scripts') -Force | Out-Null
Copy-Item (Join-Path $repo 'scripts/shared/env-file.ps1') (Join-Path $root 'scripts/env-file.ps1')
$bundled = Join-Path $root 'env'
$user = Join-Path $sbHome '.rogue-env'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Set-EnvFile { param([string]$Path, [string[]]$Lines)
    [System.IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), $utf8)
}
function Clear-EnvFiles { foreach ($f in @($machine, $bundled, $user)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }

$saved = @{}
foreach ($k in 'USERPROFILE', 'HOME', 'ROGUE_API_KEY', 'ROGUE_BASE_URL', 'ROGUE_ACTOR_EMAIL',
               'ROGUE_ACTOR_NAME', 'ROGUE_PS_LIB_ONLY', 'CLAUDE_PLUGIN_ROOT') {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k)
}
function Set-ProcessEnv { param([hashtable]$Values)
    foreach ($k in 'ROGUE_API_KEY', 'ROGUE_BASE_URL', 'ROGUE_ACTOR_EMAIL', 'ROGUE_ACTOR_NAME') {
        [Environment]::SetEnvironmentVariable($k, $null)
    }
    foreach ($k in $Values.Keys) { [Environment]::SetEnvironmentVariable($k, $Values[$k]) }
}

# Dot-sources one reader with its machine path redirected, then runs its loader and
# returns the resolved map. Re-sourced per case: each file defines the same function
# names, and the file-scope statements must run in the shipped order every time.
function Resolve-With { param([string]$Rel, [string]$Loader)
    $text = Get-Content -Raw -LiteralPath (Join-Path $repo $Rel)
    $literal = "'C:\ProgramData\rogue\env'"
    if (-not $text.Contains($literal)) { throw "$Rel does not name the machine env file" }
    $text = $text.Replace($literal, "'" + $machine + "'")
    $script:creds = @{}
    . ([scriptblock]::Create($text))
    $ErrorActionPreference = 'Stop'
    # Plain assignment, not $script: - the dot-sourced param block declared an empty
    # $PluginRoot in THIS scope, and that is the one the loader would see.
    $PluginRoot = $root
    $script:pluginRoot = $root
    & $Loader
    return $script:creds
}

$readers = @(
    @{ rel = 'scripts/shared/ship-logs.ps1';           loader = 'Import-ShipEnv' },
    @{ rel = 'plugins/antigravity/scripts/hook.ps1';    loader = 'Import-Credentials' },
    @{ rel = 'plugins/antigravity/scripts/heartbeat.ps1'; loader = 'Import-Credentials' },
    @{ rel = 'plugins/kiro/scripts/heartbeat.ps1';      loader = 'Import-Credentials' })

try {
    $env:USERPROFILE = $sbHome
    $env:HOME = $sbHome
    $env:ROGUE_PS_LIB_ONLY = '1'
    $env:CLAUDE_PLUGIN_ROOT = $root

    foreach ($r in $readers) {
        Write-Host "== $($r.rel)"

        # All three files carry a key: the machine file alone configures the reader,
        # and the user file's base URL has no effect.
        Clear-EnvFiles
        Set-EnvFile $machine @('export ROGUE_API_KEY=machine-key', 'export ROGUE_BASE_URL=http://machine.invalid')
        Set-EnvFile $bundled @('export ROGUE_API_KEY=bundled-key', 'export ROGUE_BASE_URL=http://bundled.invalid')
        Set-EnvFile $user    @('export ROGUE_API_KEY=user-key',    'export ROGUE_BASE_URL=http://user.invalid')
        Set-ProcessEnv @{ ROGUE_API_KEY = 'process-key' }
        $m = Resolve-With $r.rel $r.loader
        Check "$($r.loader): machine file wins with all three present" 'machine-key' $m['ROGUE_API_KEY']
        Check "$($r.loader): nothing merged from the user file" 'http://machine.invalid' $m['ROGUE_BASE_URL']

        # A machine file without ROGUE_API_KEY is skipped whole; the bundled file is next.
        Set-EnvFile $machine @('export ROGUE_BASE_URL=http://machine.invalid')
        Set-ProcessEnv @{}
        $m = Resolve-With $r.rel $r.loader
        Check "$($r.loader): keyless machine file is skipped" 'bundled-key' $m['ROGUE_API_KEY']
        Check "$($r.loader): ...and contributes nothing" 'http://bundled.invalid' $m['ROGUE_BASE_URL']

        # The chosen file overrides the process env; keys it does not set are kept.
        Clear-EnvFiles
        Set-EnvFile $user @('export ROGUE_API_KEY=user-key')
        Set-ProcessEnv @{ ROGUE_API_KEY = 'process-key'; ROGUE_BASE_URL = 'http://process.invalid' }
        $m = Resolve-With $r.rel $r.loader
        Check "$($r.loader): the chosen file overrides the process env" 'user-key' $m['ROGUE_API_KEY']
        Check "$($r.loader): process env kept for keys the file lacks" 'http://process.invalid' $m['ROGUE_BASE_URL']

        # No file holds a key: the process env is what remains.
        Clear-EnvFiles
        $m = Resolve-With $r.rel $r.loader
        Check "$($r.loader): process env alone still configures" 'process-key' $m['ROGUE_API_KEY']
    }

    # The file-scope readers cannot be driven off-Windows, so hold their SOURCE to
    # the rule: process env read first, machine path first in the candidate list,
    # and a candidate skipped when it lacks the key.
    Write-Host '== structural: file-scope readers'
    foreach ($rel in 'plugins/rogue/scripts/hook.ps1', 'plugins/codex/scripts/hook.ps1',
                     'plugins/copilot/scripts/hook.ps1', 'plugins/cursor/scripts/hook.ps1',
                     'plugins/kiro/scripts/hook.ps1', 'plugins/rogue/scripts/heartbeat.ps1',
                     'plugins/codex/scripts/heartbeat.ps1', 'plugins/copilot/scripts/heartbeat.ps1',
                     'plugins/rogue/scripts/auto-update.ps1') {
        $src = Get-Content -Raw -LiteralPath (Join-Path $repo $rel)
        $machineAt = $src.IndexOf("'C:\ProgramData\rogue\env'")
        $bundledAt = [regex]::Match($src, "Join-Path \`$(?:env:CLAUDE_PLUGIN_ROOT|pluginRoot|PluginRoot) 'env'").Index
        $userAt = $src.IndexOf("'.rogue-env'")
        Check "${rel}: machine, then bundled, then user" $true ($machineAt -ge 0 -and $machineAt -lt $bundledAt -and $bundledAt -lt $userAt)
        Check "${rel}: a candidate without ROGUE_API_KEY is skipped" $true `
            ($src -match "if \(-not \`$(?:fileVals|vals)\['ROGUE_API_KEY'\]\) \{ (?:Dbg [^;]+; )?continue \}")
        if ($rel -notlike '*auto-update.ps1') {
            $procAt = $src.IndexOf("foreach (`$k in 'ROGUE_API_KEY'")
            Check "${rel}: process env is read before the files" $true ($procAt -ge 0 -and $procAt -lt $machineAt)
        }
    }
    $warn = Get-Content -Raw -LiteralPath (Join-Path $repo 'plugins/codex/scripts/warn.ps1')
    Check 'codex warn.ps1: machine path first' $true ($warn.IndexOf("'C:\ProgramData\rogue\env'") -lt $warn.IndexOf("Join-Path `$pluginRoot 'env'"))
    Check 'codex warn.ps1: stops at the first file with a key' $true ($warn -match 'if \(\$key\) \{ break \}')
    Check 'codex warn.ps1: process env only when no file has a key' $true ($warn -match "if \(-not \`$key\) \{ \`$key = \[Environment\]::GetEnvironmentVariable\('ROGUE_API_KEY'\) \}")
} finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:fails -gt 0) { Write-Host "$script:fails of $script:count checks FAILED"; exit 1 }
Write-Host "all $script:count env-file first-found checks passed"
exit 0
