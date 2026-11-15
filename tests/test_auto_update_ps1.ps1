# Unit tests for the pure helpers in plugins/rogue/scripts/auto-update.ps1.
#
# Runs on LINUX in CI (pwsh 7), so the helpers must be defined ABOVE both the
# non-Windows stand-down and the ROGUE_PS_LIB_ONLY seam. If they sit below the
# stand-down, this file dot-sources a script that exits before defining anything
# and every check fails with "command not found".
$ErrorActionPreference = 'Stop'
$fails = 0
function Ok($m) { Write-Host "  ok: $m" }
function Bad($m, $d) { Write-Host "FAIL [$m]: $d"; $script:fails++ }

$script = Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins/rogue/scripts/auto-update.ps1'

# ORDER CHECK, AND IT MUST RUN BEFORE THE DOT-SOURCE.
# auto-update.ps1 stands down on non-Windows with a bare `exit 0`. Dot-sourcing
# runs at THIS script's scope, so that exit terminates the whole test process -
# with a 0 status and no output, i.e. a silent green that reports nothing. Every
# assertion below it would be unreachable and no one would know. So the invariant
# (seam above stand-down) is asserted statically, here, where a violation can
# still be reported.
$lines = Get-Content -LiteralPath $script
$seamIdx = ($lines | Select-String -SimpleMatch 'ROGUE_PS_LIB_ONLY' | Select-Object -First 1).LineNumber
$standIdx = ($lines | Select-String -SimpleMatch 'IsWindows' | Select-Object -First 1).LineNumber
if (-not $seamIdx) {
    Bad 'has a ROGUE_PS_LIB_ONLY seam' 'no seam found - the helpers cannot be loaded on Linux'
    Write-Host ''
    Write-Host "auto-update.ps1: $fails failure(s)"
    exit 1
}
if ($standIdx -and $seamIdx -gt $standIdx) {
    Bad 'seam sits above the non-Windows stand-down' "seam at line $seamIdx, stand-down at line $standIdx - dot-sourcing would kill this process"
    Write-Host ''
    Write-Host "auto-update.ps1: $fails failure(s)"
    exit 1
}
Ok 'seam sits above the non-Windows stand-down'

$env:ROGUE_PS_LIB_ONLY = '1'
. ([scriptblock]::Create((Get-Content -Raw -LiteralPath $script)))
Remove-Item Env:ROGUE_PS_LIB_ONLY

# Reaching here proves the dot-source returned at the seam instead of exiting.
foreach ($fn in 'Get-RogueManifestVersion', 'Test-RogueNewer') {
    if (Get-Command $fn -ErrorAction SilentlyContinue) { Ok "$fn is defined above the seam" }
    else { Bad "$fn is defined above the seam" 'not found after dot-sourcing' }
}

$manifest = '{"schema":1,"plugins":{"claude":"1.0.29","codex":"1.0.2"}}'
$pretty = "{`n  `"schema`": 1,`n  `"plugins`": {`n    `"claude`": `"1.0.29`"`n  }`n}"

if ((Get-RogueManifestVersion -Json $manifest -Slug 'claude') -eq '1.0.29') {
    Ok 'reads the claude version from a compact manifest'
} else { Bad 'reads the claude version from a compact manifest' 'wrong or null' }

if ((Get-RogueManifestVersion -Json $pretty -Slug 'claude') -eq '1.0.29') {
    Ok 'reads it from a pretty-printed manifest too'
} else { Bad 'reads it from a pretty-printed manifest' 'wrong or null' }

if ($null -eq (Get-RogueManifestVersion -Json $manifest -Slug 'gemini')) {
    Ok 'a missing slug is null, not a guess'
} else { Bad 'a missing slug is null' 'returned a value' }

if ($null -eq (Get-RogueManifestVersion -Json 'not json' -Slug 'claude')) {
    Ok 'garbage is null'
} else { Bad 'garbage is null' 'returned a value' }

if ($null -eq (Get-RogueManifestVersion -Json $null -Slug 'claude')) {
    Ok 'a null body is null'
} else { Bad 'a null body is null' 'returned a value' }

# GitHub serves release assets as application/octet-stream, and Windows
# PowerShell 5.1 hands back a BYTE ARRAY for that content type where pwsh 7 hands
# back a string. A byte[] coerced into a [string] becomes "123 34 115 ..." and
# every regex misses - which would make the updater log "could not resolve" and
# silently never update on Windows while macOS worked fine. Only a Windows run
# hits the real code path, so the decode itself is asserted here.
$bytes = [System.Text.Encoding]::UTF8.GetBytes($manifest)
if ((Get-RogueManifestVersion -Json $bytes -Slug 'claude') -eq '1.0.29') {
    Ok 'decodes a byte[] body (Windows PowerShell 5.1 octet-stream shape)'
} else { Bad 'decodes a byte[] body' 'byte array was not decoded before matching' }

if (Test-RogueNewer -Installed '1.0.28' -Latest '1.0.29') { Ok '1.0.28 -> 1.0.29 is newer' }
else { Bad '1.0.28 -> 1.0.29 is newer' 'returned false' }

if (-not (Test-RogueNewer -Installed '1.0.28' -Latest '1.0.28')) { Ok 'equal is not newer' }
else { Bad 'equal is not newer' 'returned true' }

# The anti-loop property: an older manifest must never trigger a reinstall.
if (-not (Test-RogueNewer -Installed '1.0.28' -Latest '1.0.27')) { Ok 'older is not newer' }
else { Bad 'older is not newer' 'returned true' }

# Numeric, not lexical.
if (Test-RogueNewer -Installed '1.0.9' -Latest '1.0.10') { Ok '1.0.9 -> 1.0.10 is newer' }
else { Bad '1.0.9 -> 1.0.10 is newer' 'returned false' }
if (Test-RogueNewer -Installed '1.9.0' -Latest '1.10.0') { Ok '1.9.0 -> 1.10.0 is newer' }
else { Bad '1.9.0 -> 1.10.0 is newer' 'returned false' }

if (-not (Test-RogueNewer -Installed '1.0.28' -Latest 'unknown')) { Ok 'unparseable latest is not newer' }
else { Bad 'unparseable latest is not newer' 'returned true' }

# Wiring: the tag is gone, the markers the rogue-ui hooks-matcher whitelist keys
# off are still present.
$raw = Get-Content -Raw -LiteralPath $script
if ($raw -notmatch 'tag_name') { Ok 'no longer reads tag_name' }
else { Bad 'no longer reads tag_name' 'tag_name still referenced' }
if ($raw -match 'ROGUE_PLUGIN_REPO') { Ok 'keeps the ROGUE_PLUGIN_REPO marker' }
else { Bad 'keeps the ROGUE_PLUGIN_REPO marker' 'env var is gone' }
if ($raw -match 'versions\.json') { Ok 'fetches versions.json' }
else { Bad 'fetches versions.json' 'no reference found' }

$installerOutput = Join-Path ([IO.Path]::GetTempPath()) ("rogue-installer-test-" + [guid]::NewGuid().ToString('N') + '.txt')
$env:ROGUE_TEST_INSTALLER_OUTPUT = $installerOutput
$fakeInstaller = @'
$EnvFile = 'top-level-env-file'
function Read-EnvFilePath { $script:EnvFile }
Set-Content -LiteralPath $env:ROGUE_TEST_INSTALLER_OUTPUT -Value (Read-EnvFilePath)
exit 7
'@
$rc = Invoke-RogueInstaller -Script $fakeInstaller
$seen = if (Test-Path -LiteralPath $installerOutput) { (Get-Content -Raw -LiteralPath $installerOutput).Trim() } else { '' }
Remove-Item -LiteralPath $installerOutput -Force -ErrorAction SilentlyContinue
Remove-Item Env:ROGUE_TEST_INSTALLER_OUTPUT
if ($seen -eq 'top-level-env-file') { Ok 'installer functions see its top-level variables through $script:' }
else { Bad 'installer functions see its top-level variables through $script:' "got '$seen'" }
if ($rc -eq 7) { Ok 'installer exit code is returned, not inherited by the updater' }
else { Bad 'installer exit code is returned, not inherited by the updater' "got '$rc'" }
if (-not $env:ROGUE_INSTALLER_SCRIPT) { Ok 'installer path variable is cleared' }
else { Bad 'installer path variable is cleared' 'still set' }

Write-Host ''
if ($fails -eq 0) { Write-Host 'auto-update.ps1: all checks passed'; exit 0 }
Write-Host "auto-update.ps1: $fails failure(s)"; exit 1
