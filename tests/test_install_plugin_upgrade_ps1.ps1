#!/usr/bin/env pwsh
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$installer = [System.IO.Path]::Combine($here, '..', 'install.ps1')

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-plugin-upgrade-" + [System.IO.Path]::GetRandomFileName())
$bin = Join-Path $work 'bin'
New-Item -ItemType Directory -Path $bin -Force | Out-Null
$prevPath = $env:PATH
$prevProfile = $env:USERPROFILE
$env:USERPROFILE = $work
$env:FAKE_CLI_STATE = $work

$fakeCli = Join-Path $bin 'fake-plugin-cli-fixture.ps1'
@'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Argv)
$snapshot = Join-Path $env:FAKE_CLI_STATE 'marketplace-snapshot'
$installed = Join-Path $env:FAKE_CLI_STATE 'installed-version'
Add-Content -LiteralPath (Join-Path $env:FAKE_CLI_STATE 'cli.log') -Value ($Argv -join ' ')
$command = ($Argv | Select-Object -First 3) -join ' '
if ($command -eq 'plugin marketplace add') {
    if (-not (Test-Path -LiteralPath $snapshot)) { [System.IO.File]::WriteAllText($snapshot, $env:PUBLISHED_VERSION) }
    exit 0
}
if ($command -eq 'plugin marketplace update') {
    [System.IO.File]::WriteAllText($snapshot, $env:PUBLISHED_VERSION)
    exit 0
}
$sub = "$($Argv[0]) $($Argv[1])"
if ($sub -eq 'plugin install') {
    if (Test-Path -LiteralPath $installed) { exit 0 }
    Copy-Item -LiteralPath $snapshot -Destination $installed
}
if ($sub -eq 'plugin update') {
    if (-not (Test-Path -LiteralPath $installed)) { exit 1 }
    Copy-Item -LiteralPath $snapshot -Destination $installed -Force
}
exit 0
'@ | Set-Content -LiteralPath $fakeCli -Encoding UTF8
if ($env:OS -eq 'Windows_NT') {
    [System.IO.File]::WriteAllText((Join-Path $bin 'fake-plugin-cli.cmd'),
        "@echo off`r`npowershell.exe -NoProfile -File `"$fakeCli`" %*`r`nexit /b %errorlevel%`r`n")
} else {
    $shim = Join-Path $bin 'fake-plugin-cli'
    [System.IO.File]::WriteAllText($shim, "#!/bin/sh`nexec pwsh -NoProfile -File `"$fakeCli`" `"`$@`"`n")
    & chmod +x $shim
}
$env:PATH = $bin + [System.IO.Path]::PathSeparator + $env:PATH

$env:ROGUE_PLUGIN_REPO = 'rogue-test/rogue-plugins'
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
$installedFile = Join-Path $work 'installed-version'
$logFile = Join-Path $work 'cli.log'
function Get-InstalledVersion { [System.IO.File]::ReadAllText($installedFile) }
function Get-CliCalls { @(Get-Content -LiteralPath $logFile) -join ' | ' }

function Install-FromMarketplace {
    Remove-Item -LiteralPath $logFile -ErrorAction SilentlyContinue
    Add-AndRefreshMarketplace -Cli 'fake-plugin-cli' -RefreshCommand 'update' -Marketplace 'rogue-marketplace'
    Update-OrInstallPlugin -Cli 'fake-plugin-cli' -PluginSlug 'rogue@rogue-marketplace'
}

$env:PUBLISHED_VERSION = '1.0.0'
Install-FromMarketplace
Assert-Eq (Get-InstalledVersion) '1.0.0' 'fresh: the published version is installed'
Assert-Eq (Get-CliCalls) 'plugin marketplace add rogue-test/rogue-plugins | plugin marketplace update rogue-marketplace | plugin update rogue@rogue-marketplace | plugin install rogue@rogue-marketplace' 'fresh: marketplace added and refreshed, update tried, then install'

$env:PUBLISHED_VERSION = '1.0.1'
Install-FromMarketplace
Assert-Eq (Get-InstalledVersion) '1.0.1' 'upgrade: the installed version moves to the newly published version'
Assert-Eq (Get-CliCalls) 'plugin marketplace add rogue-test/rogue-plugins | plugin marketplace update rogue-marketplace | plugin update rogue@rogue-marketplace' 'upgrade: marketplace refreshed, update alone runs'

$env:PATH = $prevPath
$env:USERPROFILE = $prevProfile
$env:FAKE_CLI_STATE = $null
$env:PUBLISHED_VERSION = $null
$env:ROGUE_PLUGIN_REPO = $null
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue

Write-Host ""
if ($fails -eq 0) { Write-Host "test_install_plugin_upgrade_ps1: all $count passed"; exit 0 }
Write-Host "test_install_plugin_upgrade_ps1: $fails of $count failed"
exit 1
