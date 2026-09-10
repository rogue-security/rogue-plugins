#!/usr/bin/env pwsh
# tests/test_env_first_found.ps1 - the env file rule on the PowerShell readers: the
# first of machine (C:\ProgramData\rogue\env) -> bundled (<root>\env) -> user
# (%USERPROFILE%\.rogue-env) that holds ROGUE_API_KEY is used ALONE, and its values
# override the process env.
#
# Every reader runs its REAL credential code, with the machine path literal
# redirected into the sandbox by editing the script text before it is dot-sourced -
# the only way to stage that candidate without admin rights. Loaders reachable
# through the ROGUE_PS_LIB_ONLY seam (the shared shipper's Import-ShipEnv, the
# antigravity/kiro Import-Credentials, auto-update's ReadEnvVar) are called as
# functions; the dispatchers whose credential block runs at file scope, past the
# seam, have that block lifted from the source (from `$creds = @{}` through the
# `break }` that ends the file loop) and executed in place.
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
               'ROGUE_ACTOR_NAME', 'ROGUE_PS_LIB_ONLY', 'CLAUDE_PLUGIN_ROOT', 'CURSOR_PLUGIN_ROOT',
               'PLUGIN_ROOT', 'COPILOT_PLUGIN_ROOT', 'KIRO_PLUGIN_ROOT') {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k)
}
function Set-ProcessEnv { param([hashtable]$Values)
    foreach ($k in 'ROGUE_API_KEY', 'ROGUE_BASE_URL', 'ROGUE_ACTOR_EMAIL', 'ROGUE_ACTOR_NAME') {
        [Environment]::SetEnvironmentVariable($k, $null)
    }
    foreach ($k in $Values.Keys) { [Environment]::SetEnvironmentVariable($k, $Values[$k]) }
}

# The reader's source with the machine path pointed into the sandbox.
function Get-RedirectedSource { param([string]$Rel)
    $text = Get-Content -Raw -LiteralPath (Join-Path $repo $Rel)
    $literal = "'C:\ProgramData\rogue\env'"
    if (-not $text.Contains($literal)) { throw "${Rel} does not name the machine env file" }
    return $text.Replace($literal, "'" + $machine + "'")
}

# Dot-sources one reader, then runs its loader function and returns the resolved
# map. Re-sourced per case: each file defines the same function names, and the
# file-scope statements must run in the shipped order every time.
function Resolve-With { param([string]$Rel, [string]$Loader)
    $text = Get-RedirectedSource $Rel
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

# One named function's source: the single-line form first, else through the first
# column-0 close brace. Never the whole file - the heartbeats have no seam and would
# `exit 0` the test process off-Windows.
function Get-FunctionSource { param([string]$Text, [string]$Name, [string]$Rel)
    $m = [regex]::Match($Text, "\nfunction $Name \{[^\n]*\}(?=\r?\n)")
    if (-not $m.Success) { $m = [regex]::Match($Text, "(?s)\nfunction $Name \{.*?\n\}(?=\r?\n)") }
    if (-not $m.Success) { throw "${Rel}: function $Name not found" }
    return $m.Value
}

# Lifts a dispatcher's file-scope credential block (and the two helpers it calls)
# out of the source and runs it here.
function Resolve-FileScope { param([string]$Rel)
    $text = Get-RedirectedSource $Rel
    $block = [regex]::Match($text, '(?s)\n[ \t]*\$(?:script:)?creds = @\{\}\r?\n.*?\n[ \t]*break\r?\n[ \t]*\}\r?\n')
    if (-not $block.Success) { throw "${Rel}: no file-scope credential block found" }
    foreach ($name in 'Dbg', 'ConvertFrom-ShellQuoted') {
        . ([scriptblock]::Create((Get-FunctionSource $text $name $Rel)))
    }
    $script:creds = @{}
    $PluginRoot = $root
    $script:PluginRoot = $root
    . ([scriptblock]::Create($block.Value))
    return $creds
}

# auto-update.ps1 exposes one getter rather than a map; read the two keys through it.
function Resolve-AutoUpdate {
    $text = Get-RedirectedSource 'plugins/rogue/scripts/auto-update.ps1'
    $fn = [regex]::Match($text, '(?s)\nfunction ReadEnvVar \{.*?\n\}\r?\n')
    if (-not $fn.Success) { throw 'auto-update.ps1: ReadEnvVar not found' }
    . ([scriptblock]::Create($fn.Value))
    if (-not (Get-Command ReadEnvVar -ErrorAction SilentlyContinue)) { throw 'auto-update.ps1: ReadEnvVar did not load' }
    return @{ ROGUE_API_KEY = (ReadEnvVar 'ROGUE_API_KEY'); ROGUE_BASE_URL = (ReadEnvVar 'ROGUE_BASE_URL') }
}

$readers = @(
    @{ label = 'ship-logs.ps1 Import-ShipEnv';        resolve = { Resolve-With 'scripts/shared/ship-logs.ps1' 'Import-ShipEnv' } },
    @{ label = 'antigravity hook.ps1';                resolve = { Resolve-With 'plugins/antigravity/scripts/hook.ps1' 'Import-Credentials' } },
    @{ label = 'antigravity heartbeat.ps1';           resolve = { Resolve-With 'plugins/antigravity/scripts/heartbeat.ps1' 'Import-Credentials' } },
    @{ label = 'kiro heartbeat.ps1';                  resolve = { Resolve-With 'plugins/kiro/scripts/heartbeat.ps1' 'Import-Credentials' } },
    @{ label = 'rogue hook.ps1';                      resolve = { Resolve-FileScope 'plugins/rogue/scripts/hook.ps1' } },
    @{ label = 'codex hook.ps1';                      resolve = { Resolve-FileScope 'plugins/codex/scripts/hook.ps1' } },
    @{ label = 'copilot hook.ps1';                    resolve = { Resolve-FileScope 'plugins/copilot/scripts/hook.ps1' } },
    @{ label = 'cursor hook.ps1';                     resolve = { Resolve-FileScope 'plugins/cursor/scripts/hook.ps1' } },
    @{ label = 'kiro hook.ps1';                       resolve = { Resolve-FileScope 'plugins/kiro/scripts/hook.ps1' } },
    @{ label = 'rogue heartbeat.ps1';                 resolve = { Resolve-FileScope 'plugins/rogue/scripts/heartbeat.ps1' } },
    @{ label = 'codex heartbeat.ps1';                 resolve = { Resolve-FileScope 'plugins/codex/scripts/heartbeat.ps1' } },
    @{ label = 'copilot heartbeat.ps1';               resolve = { Resolve-FileScope 'plugins/copilot/scripts/heartbeat.ps1' } },
    @{ label = 'rogue auto-update.ps1 ReadEnvVar';    resolve = { Resolve-AutoUpdate } })

try {
    $env:USERPROFILE = $sbHome
    $env:HOME = $sbHome
    $env:ROGUE_PS_LIB_ONLY = '1'
    # Each dispatcher names its own plugin-root variable; the sandbox root is all of them.
    foreach ($k in 'CLAUDE_PLUGIN_ROOT', 'CURSOR_PLUGIN_ROOT', 'PLUGIN_ROOT', 'COPILOT_PLUGIN_ROOT', 'KIRO_PLUGIN_ROOT') {
        [Environment]::SetEnvironmentVariable($k, $root)
    }

    foreach ($r in $readers) {
        $L = $r.label
        Write-Host "== $L"

        # All three files carry a key: the machine file alone configures the reader,
        # and the user file's base URL has no effect.
        Clear-EnvFiles
        Set-EnvFile $machine @('export ROGUE_API_KEY=machine-key', 'export ROGUE_BASE_URL=http://machine.invalid')
        Set-EnvFile $bundled @('export ROGUE_API_KEY=bundled-key', 'export ROGUE_BASE_URL=http://bundled.invalid')
        Set-EnvFile $user    @('export ROGUE_API_KEY=user-key',    'export ROGUE_BASE_URL=http://user.invalid')
        Set-ProcessEnv @{ ROGUE_API_KEY = 'process-key' }
        $m = & $r.resolve
        Check "${L}: machine file wins with all three present" 'machine-key' $m['ROGUE_API_KEY']
        Check "${L}: nothing merged from the user file" 'http://machine.invalid' $m['ROGUE_BASE_URL']

        # A machine file without ROGUE_API_KEY is skipped whole; the bundled file is next.
        Set-EnvFile $machine @('export ROGUE_BASE_URL=http://machine.invalid')
        Set-ProcessEnv @{}
        $m = & $r.resolve
        Check "${L}: keyless machine file is skipped" 'bundled-key' $m['ROGUE_API_KEY']
        Check "${L}: ...and contributes nothing" 'http://bundled.invalid' $m['ROGUE_BASE_URL']

        # An empty ROGUE_API_KEY, quoted or bare, does not select the file - the same
        # answer the sh gate and the mjs readers give.
        Set-EnvFile $machine @("export ROGUE_API_KEY=''", 'export ROGUE_BASE_URL=http://machine.invalid')
        Set-EnvFile $bundled @('ROGUE_API_KEY=', 'export ROGUE_BASE_URL=http://bundled.invalid')
        $m = & $r.resolve
        Check "${L}: an empty key line does not select the file" 'user-key' $m['ROGUE_API_KEY']
        Check "${L}: ...and contributes nothing either" 'http://user.invalid' $m['ROGUE_BASE_URL']

        # The chosen file overrides the process env; keys it does not set are kept.
        Clear-EnvFiles
        Set-EnvFile $user @('export ROGUE_API_KEY=user-key')
        Set-ProcessEnv @{ ROGUE_API_KEY = 'process-key'; ROGUE_BASE_URL = 'http://process.invalid' }
        $m = & $r.resolve
        Check "${L}: the chosen file overrides the process env" 'user-key' $m['ROGUE_API_KEY']
        Check "${L}: process env kept for keys the file lacks" 'http://process.invalid' $m['ROGUE_BASE_URL']

        # No file holds a key: the process env is what remains.
        Clear-EnvFiles
        $m = & $r.resolve
        Check "${L}: process env alone still configures" 'process-key' $m['ROGUE_API_KEY']
    }

    # codex warn.ps1 exits before its loop off-Windows and has no seam; hold its
    # source to the rule instead.
    Write-Host '== structural: codex warn.ps1'
    $warn = Get-Content -Raw -LiteralPath (Join-Path $repo 'plugins/codex/scripts/warn.ps1')
    Check 'codex warn.ps1: machine path first' $true ($warn.IndexOf("'C:\ProgramData\rogue\env'") -lt $warn.IndexOf("Join-Path `$pluginRoot 'env'"))
    Check 'codex warn.ps1: stops at the first file with a key' $true ($warn -match 'if \(\$key\) \{ break \}')
    Check 'codex warn.ps1: process env only when no file has a key' $true ($warn -match "if \(-not \`$key\) \{ \`$key = \[Environment\]::GetEnvironmentVariable\('ROGUE_API_KEY'\) \}")
} finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
# A dispatcher that reached an `exit` while being loaded would end this process
# early with a clean status; the count proves every reader ran every scenario.
if ($script:count -lt ($readers.Count * 9)) { Write-Host "only $script:count checks ran"; exit 1 }
if ($script:fails -gt 0) { Write-Host "$script:fails of $script:count checks FAILED"; exit 1 }
Write-Host "all $script:count env-file first-found checks passed"
exit 0
