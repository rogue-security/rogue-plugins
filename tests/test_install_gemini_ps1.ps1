#!/usr/bin/env pwsh
# tests/test_install_gemini_ps1.ps1 - unit tests for Install-GeminiExtension in install.ps1.
#
# The real `gemini extensions install --consent` prints "You have consented to the
# following:" on stderr and succeeds. Under $ErrorActionPreference = 'Stop', Windows
# PowerShell 5.1 turned that line into a terminating error, so every Windows install
# reported Gemini as failed (FIRE-3357). The fake CLI writes to stderr on every call;
# validate.yml runs this file under Windows PowerShell 5.1, where the bug reproduces.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$installer = [System.IO.Path]::Combine($here, '..', 'install.ps1')

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-gemini-install-" + [System.IO.Path]::GetRandomFileName())
$home1 = Join-Path $work 'home'
$bin = Join-Path $work 'bin'
$source = Join-Path $work 'extension'
foreach ($d in @($home1, $bin, $source)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }

$prevProfile = $env:USERPROFILE
$prevPath = $env:PATH
$env:USERPROFILE = $home1
$env:GEMINI_CLI_LOG = Join-Path $work 'gemini.log'

$fakeCli = Join-Path $bin 'gemini-fixture.ps1'
@'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Argv)
Add-Content -LiteralPath $env:GEMINI_CLI_LOG -Value ($Argv -join ' ')
[Console]::Error.WriteLine('You have consented to the following:')
$dir = [System.IO.Path]::Combine($env:USERPROFILE, '.gemini', 'extensions', 'rogue')
$sub = "$($Argv[0]) $($Argv[1])"
if ($sub -eq 'extensions uninstall') {
    if (-not (Test-Path -LiteralPath $dir)) { [Console]::Error.WriteLine('Extension "rogue" not found.'); exit 1 }
    Remove-Item -Recurse -Force -LiteralPath $dir
    exit 0
}
if ($sub -eq 'extensions install') {
    if ($env:GEMINI_FAKE_INSTALL_FAILS) { [Console]::Error.WriteLine('Invalid extension manifest.'); exit 1 }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dir 'gemini-extension.json'), '{"name":"rogue"}')
    Write-Output 'Extension "rogue" installed successfully and enabled.'
    exit 0
}
exit 2
'@ | Set-Content -LiteralPath $fakeCli -Encoding UTF8
# A child process, so its stderr reaches the installer the way node's does.
if ($env:OS -eq 'Windows_NT') {
    [System.IO.File]::WriteAllText((Join-Path $bin 'gemini.cmd'),
        "@echo off`r`npowershell.exe -NoProfile -File `"$fakeCli`" %*`r`nexit /b %errorlevel%`r`n")
} else {
    $shim = Join-Path $bin 'gemini'
    [System.IO.File]::WriteAllText($shim, "#!/bin/sh`nexec pwsh -NoProfile -File `"$fakeCli`" `"`$@`"`n")
    & chmod +x $shim
}
$env:PATH = $bin + [System.IO.Path]::PathSeparator + $env:PATH

$env:ROGUE_INSTALL_LIB_ONLY = '1'
. $installer
$env:ROGUE_INSTALL_LIB_ONLY = $null

$fails = 0
$count = 0
function Assert-Eq {
    param($Got, $Expected, [string]$Label)
    $script:count++
    if ([string]$Got -ceq [string]$Expected) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL [$Label]: got <$Got>, expected <$Expected>"; $script:fails++ }
}
$manifest = [System.IO.Path]::Combine($home1, '.gemini', 'extensions', 'rogue', 'gemini-extension.json')

Assert-Eq $ErrorActionPreference 'Stop' 'the installer runs under Stop'

$thrown = $null
try { Install-GeminiExtension $source } catch { $thrown = $_.Exception.Message }
Assert-Eq $thrown $null 'first install: stderr output does not fail it'
Assert-Eq (Test-Path -LiteralPath $manifest) $true 'first install: the extension is installed'
Assert-Eq ((Get-Content -LiteralPath $env:GEMINI_CLI_LOG) -join ' | ') "extensions uninstall rogue | extensions install $source --consent" 'first install: uninstalls, then installs with consent'

Remove-Item -LiteralPath $env:GEMINI_CLI_LOG
$thrown = $null
try { Install-GeminiExtension $source } catch { $thrown = $_.Exception.Message }
Assert-Eq $thrown $null 're-run: upgrades without an error'
Assert-Eq (Test-Path -LiteralPath $manifest) $true 're-run: the extension is installed'

$env:GEMINI_FAKE_INSTALL_FAILS = '1'
$thrown = $null
try { Install-GeminiExtension $source } catch { $thrown = $_.Exception.Message }
$env:GEMINI_FAKE_INSTALL_FAILS = $null
Assert-Eq ([bool]$thrown) $true 'failed install: throws'
Assert-Eq (([string]$thrown).Contains('gemini extensions install failed')) $true 'failed install: names the command'
Assert-Eq (([string]$thrown).Contains('Invalid extension manifest.')) $true 'failed install: carries the CLI output'

$env:PATH = $prevPath
$env:USERPROFILE = $prevProfile
$env:GEMINI_CLI_LOG = $null
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue

Write-Host ""
if ($fails -eq 0) { Write-Host "test_install_gemini_ps1: all $count passed"; exit 0 }
Write-Host "test_install_gemini_ps1: $fails of $count failed"
exit 1
