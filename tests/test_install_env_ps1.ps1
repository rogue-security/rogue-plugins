#!/usr/bin/env pwsh
# tests/test_install_env_ps1.ps1 - install.ps1 and the machine env file, in
# lockstep with tests/test_install_env_sh.sh.
#
# A keyed C:\ProgramData\rogue\env is read alone by every dispatcher, so on such
# a machine the installer prompts for nothing and writes no %USERPROFILE%\.rogue-env;
# it names the file in use. With the machine file absent, or present without
# ROGUE_API_KEY, the prompt and the user env file write are as they were.
# Configure-Credentials is loaded through the ROGUE_INSTALL_LIB_ONLY seam with
# both file paths pointed into a sandbox, Read-Host counting its calls, and
# Invoke-WebRequest answering 200. Runs on any platform with PowerShell.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$installer = [System.IO.Path]::Combine($here, '..', 'install.ps1')

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-env-install-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work -Force | Out-Null

$prevKey = $env:ROGUE_API_KEY
$prevProfile = $env:USERPROFILE
$env:ROGUE_API_KEY = $null
$env:USERPROFILE = $work
$env:ROGUE_INSTALL_LIB_ONLY = '1'
. $installer
$env:ROGUE_INSTALL_LIB_ONLY = $null
$ErrorActionPreference = 'Stop'

$MachineEnvFile = Join-Path $work 'machine-env'
$EnvFile        = Join-Path $work '.rogue-env'
$Email = 'tester@example.com'; $Name = 'Tester'

$script:prompts = 0
function Read-Host {
    param([Parameter(Position = 0)][string]$Prompt, [switch]$AsSecureString)
    $script:prompts++
    return (ConvertTo-SecureString 'typed-key' -AsPlainText -Force)
}
function Invoke-WebRequest { return [pscustomobject]@{ StatusCode = 200 } }

$fails = 0
function Assert-Eq {
    param($Got, $Expected, [string]$Label)
    if ([string]$Got -ceq [string]$Expected) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL [$Label]: got <$Got>, expected <$Expected>"; $script:fails++ }
}

# Run-Configure <api-key> -> the installer's console output as one string.
function Run-Configure {
    param([string]$Key)
    $script:ApiKey = $Key
    $script:CredentialSource = $null
    $script:prompts = 0
    Remove-Item -LiteralPath $EnvFile -Force -ErrorAction SilentlyContinue
    return (Configure-Credentials 6>&1 | Out-String)
}
function Get-WrittenKey {
    if (-not (Test-Path -LiteralPath $EnvFile)) { return '<no file>' }
    foreach ($line in (Get-Content -LiteralPath $EnvFile)) {
        if ($line -match "^export ROGUE_API_KEY='(.*)'$") { return $Matches[1] }
    }
    return '<no key line>'
}

# -- 1. Machine env file with a key: no prompt, no user env file -------------------
[System.IO.File]::WriteAllText($MachineEnvFile, "export ROGUE_API_KEY='machine-key'`nexport ROGUE_ACTOR_EMAIL='mdm@example.com'`n")
$NonInteractive = $true
$out = Run-Configure ''
Assert-Eq $script:prompts 0 'keyed machine file: no credential prompt'
Assert-Eq (Test-Path -LiteralPath $EnvFile) $false 'keyed machine file: no user env file'
Assert-Eq ($out -match [regex]::Escape("machine env file $MachineEnvFile")) $true 'keyed machine file: output names the machine file'
Assert-Eq $CredentialSource $MachineEnvFile 'keyed machine file: summary points at the machine file'

$NonInteractive = $false
$out = Run-Configure ''
Assert-Eq $script:prompts 0 'keyed machine file, interactive: no prompt'
Assert-Eq (Test-Path -LiteralPath $EnvFile) $false 'keyed machine file, interactive: no user env file'

$out = Run-Configure 'passed-key'
Assert-Eq (Test-Path -LiteralPath $EnvFile) $false 'keyed machine file + passed key: no user env file'

# -- 2. No machine env file: unchanged ---------------------------------------------
Remove-Item -LiteralPath $MachineEnvFile -Force
$NonInteractive = $true
$out = Run-Configure 'passed-key'
Assert-Eq $script:prompts 0 'no machine file, non-interactive: no prompt'
Assert-Eq (Get-WrittenKey) 'passed-key' 'no machine file, non-interactive: passed key written'
Assert-Eq ($out -match 'machine env file') $false 'no machine file: output does not name a machine file'
Assert-Eq $CredentialSource $EnvFile 'no machine file: summary points at the user file'

$NonInteractive = $false
$out = Run-Configure ''
Assert-Eq $script:prompts 1 'no machine file, interactive: prompts once'
Assert-Eq (Get-WrittenKey) 'typed-key' 'no machine file, interactive: typed key written'

# -- 3. Machine env file without a key: unchanged, as in 2 --------------------------
[System.IO.File]::WriteAllText($MachineEnvFile, "export ROGUE_ACTOR_EMAIL='mdm@example.com'`n# ROGUE_API_KEY='commented-out'`nexport ROGUE_API_KEY=`n")
$NonInteractive = $true
$out = Run-Configure 'passed-key'
Assert-Eq $script:prompts 0 'keyless machine file, non-interactive: no prompt'
Assert-Eq (Get-WrittenKey) 'passed-key' 'keyless machine file, non-interactive: passed key written'
Assert-Eq ($out -match 'machine env file') $false 'keyless machine file: output does not name a machine file'

$NonInteractive = $false
$out = Run-Configure ''
Assert-Eq $script:prompts 1 'keyless machine file, interactive: prompts once'
Assert-Eq (Get-WrittenKey) 'typed-key' 'keyless machine file, interactive: typed key written'

$env:ROGUE_API_KEY = $prevKey
$env:USERPROFILE = $prevProfile
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host ''
if ($fails -eq 0) { Write-Host 'all install env-file tests passed'; exit 0 }
Write-Host "$fails FAILED"; exit 1
