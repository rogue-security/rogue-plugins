
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$script:fails = 0

function Check {
    param([string]$Label, $Expected, $Actual)
    if ($Expected -eq $Actual) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL: $Label (expected [$Expected], got [$Actual])"; $script:fails++ }
}

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-envps-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

$seed = @(
    '# Managed by the rogue Claude plugin. Read by hook subprocesses at runtime.',
    '# Delete this file to revoke credentials.',
    "export ROGUE_API_KEY='stale-key'",
    "export ROGUE_ACTOR_EMAIL='stale@example.com'",
    "export ROGUE_ACTOR_NAME='Stale'",
    '# our self-hosted API',
    "export ROGUE_BASE_URL='http://localhost:8007'",
    "export ROGUE_LOG_DIR='/var/log/rogue'",
    'export ROGUE_HEARTBEAT_MIN_INTERVAL=60'
) -join "`n"

function New-SeededFile {
    param([string]$Name)
    $path = Join-Path $sandbox $Name
    [System.IO.File]::WriteAllText($path, $seed + "`n",
        (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Get-EnvValue {
    param([string]$Path, [string]$Key)
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($line -match ('^\s*export\s+' + [regex]::Escape($Key) + "\s*=\s*'?(.*?)'?\s*$")) {
            return $Matches[1]
        }
    }
    return $null
}

function Count-Matching {
    param([string]$Path, [string]$Pattern)
    return @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_ -match $Pattern }).Count
}

. ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $repo 'scripts/shared/env-file.ps1'))))

$libFile = New-SeededFile 'lib.env'
Write-RogueEnvFile -Path $libFile -Values ([ordered]@{
    ROGUE_API_KEY     = 'new-key'
    ROGUE_ACTOR_EMAIL = 'new@example.com'
    ROGUE_ACTOR_NAME  = 'New Name'
}) | Out-Null

Check 'lib: api key replaced'      'new-key'               (Get-EnvValue $libFile 'ROGUE_API_KEY')
Check 'lib: actor name replaced'   'New Name'              (Get-EnvValue $libFile 'ROGUE_ACTOR_NAME')
Check 'lib: base url kept'         'http://localhost:8007' (Get-EnvValue $libFile 'ROGUE_BASE_URL')
Check 'lib: log dir kept'          '/var/log/rogue'        (Get-EnvValue $libFile 'ROGUE_LOG_DIR')
Check 'lib: beacon interval kept'  '60'                    (Get-EnvValue $libFile 'ROGUE_HEARTBEAT_MIN_INTERVAL')
Check 'lib: user comment kept'     1  (Count-Matching $libFile '^# our self-hosted API$')
Check 'lib: one api key line'      1  (Count-Matching $libFile '^export ROGUE_API_KEY=')
Check 'lib: one header line'       1  (Count-Matching $libFile 'Read by hook subprocesses')

$quoteFile = New-SeededFile 'quote.env'
Write-RogueEnvFile -Path $quoteFile -Values ([ordered]@{
    ROGUE_API_KEY     = "key'with'quotes"
    ROGUE_ACTOR_EMAIL = 'e@x.io'
    ROGUE_ACTOR_NAME  = "O'Brien"
}) | Out-Null
Check 'lib: quoted value escaped' "export ROGUE_API_KEY='key'\''with'\''quotes'" `
    (@(Get-Content -LiteralPath $quoteFile -Encoding UTF8 | Where-Object { $_ -match '^export ROGUE_API_KEY=' })[0])

$eacute = [string][char]0x00E9
$uuml   = [string][char]0x00FC
$actorName = 'Jos' + $eacute + ' M' + $uuml + 'ller'
$keptDir   = '/var/log/caf' + $eacute

$u8File = Join-Path $sandbox 'nonascii.env'
[System.IO.File]::WriteAllText($u8File, (@(
    "export ROGUE_API_KEY='stale-key'",
    "export ROGUE_LOG_DIR='$keptDir'"
) -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))

foreach ($pass in 1, 2) {
    Write-RogueEnvFile -Path $u8File -Values ([ordered]@{
        ROGUE_API_KEY     = 'new-key'
        ROGUE_ACTOR_EMAIL = 'e@x.io'
        ROGUE_ACTOR_NAME  = $actorName
    }) | Out-Null
    Check "lib: non-ASCII actor name round-trips (pass $pass)" $actorName (Get-EnvValue $u8File 'ROGUE_ACTOR_NAME')
    Check "lib: non-ASCII preserved line intact (pass $pass)"  $keptDir   (Get-EnvValue $u8File 'ROGUE_LOG_DIR')
}
$u8Bytes = [System.IO.File]::ReadAllBytes($u8File)
$u8Text  = [System.Text.Encoding]::UTF8.GetString($u8Bytes)
Check 'lib: non-ASCII stored as UTF-8 on disk' $true ($u8Text -match ([regex]::Escape($actorName)))
Check 'lib: non-ASCII file has no BOM' $false `
    (($u8Bytes[0] -eq 0xEF) -and ($u8Bytes[1] -eq 0xBB) -and ($u8Bytes[2] -eq 0xBF))

$bytes = [System.IO.File]::ReadAllBytes($libFile)
Check 'lib: no UTF-8 BOM' $false (($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF))
Check 'lib: no CR bytes'  $false ($bytes -contains 13)

$reqFile = New-SeededFile 'require-protection.env'
$reqBefore = [System.IO.File]::ReadAllText($reqFile)
$reqOk = Write-RogueEnvFile -Path $reqFile -RequireProtection -Values ([ordered]@{
    ROGUE_API_KEY     = 'guarded-key'
    ROGUE_ACTOR_EMAIL = 'e@x.io'
    ROGUE_ACTOR_NAME  = 'N'
})
if ($reqOk) {
    Check 'require-protection: wrote once the ACL applied' 'guarded-key' (Get-EnvValue $reqFile 'ROGUE_API_KEY')
} else {
    Check 'require-protection: existing file left untouched' $reqBefore ([System.IO.File]::ReadAllText($reqFile))
}
Check 'require-protection: no temp left behind' 0 `
    (@(Get-ChildItem -LiteralPath $sandbox -Filter '*.rogue-tmp.*' -Force).Count)

$chmod = Get-Command chmod -ErrorAction SilentlyContinue
if ($chmod) {
    $roDir = Join-Path $sandbox 'readonly'
    New-Item -ItemType Directory -Path $roDir -Force | Out-Null
    $roFile = Join-Path $roDir 'rogue.env'
    [System.IO.File]::WriteAllText($roFile, $seed + "`n", (New-Object System.Text.UTF8Encoding($false)))
    $roBefore = [System.IO.File]::ReadAllText($roFile)
    & $chmod.Source 500 $roDir
    try {
        $probe = Join-Path $roDir '.probe'
        $writable = $true
        try { [System.IO.File]::WriteAllText($probe, 'x'); Remove-Item -LiteralPath $probe -Force } catch { $writable = $false }
        if ($writable) {
            Write-Host '  skip: directory is writable anyway (running as root?)'
        } else {
            $threw = $false
            try {
                Write-RogueEnvFile -Path $roFile -Values ([ordered]@{
                    ROGUE_API_KEY = 'should-not-land'; ROGUE_ACTOR_EMAIL = 'e@x.io'; ROGUE_ACTOR_NAME = 'N'
                }) | Out-Null
            } catch { $threw = $true }
            Check 'failed write: reported, not swallowed' $true $threw
            Check 'failed write: old file intact' $roBefore ([System.IO.File]::ReadAllText($roFile))
        }
    } finally {
        & $chmod.Source 700 $roDir
    }
} else {
    Write-Host '  skip: chmod not available (failed-write case)'
}

# The writers take the file from %USERPROFILE%, the only place the readers look.
$saveSetupProfile = $env:USERPROFILE
foreach ($plugin in @('rogue', 'cursor')) {
    New-Item -ItemType Directory -Path (Join-Path $sandbox "$plugin-home") -Force | Out-Null
    $path = New-SeededFile "$plugin-home/.rogue-env"
    $env:USERPROFILE = Join-Path $sandbox "$plugin-home"
    & (Join-Path $repo "plugins/$plugin/scripts/setup.ps1") 'new-key' 'new@example.com' 'New Name' `
        -WarningAction SilentlyContinue | Out-Null
    Check "${plugin}: api key replaced" 'new-key'               (Get-EnvValue $path 'ROGUE_API_KEY')
    Check "${plugin}: base url kept"    'http://localhost:8007' (Get-EnvValue $path 'ROGUE_BASE_URL')
    Check "${plugin}: log dir kept"     '/var/log/rogue'        (Get-EnvValue $path 'ROGUE_LOG_DIR')
    Check "${plugin}: one header line"  1 (Count-Matching $path 'Read by hook subprocesses')
}
$env:USERPROFILE = $saveSetupProfile

foreach ($plugin in @('rogue', 'codex', 'cursor', 'copilot', 'antigravity')) {
    $text = Get-Content -Raw -LiteralPath (Join-Path $repo "plugins/$plugin/scripts/setup.ps1")
    Check "${plugin}: uses the shared writer" $true ($text -match 'Write-RogueEnvFile')
    Check "${plugin}: does not rewrite the file itself" $false ($text -match 'Set-Content\s+-Path\s+\$EnvFile')
    Check "${plugin}: never deletes the env file" $false ($text -match 'Remove-Item -LiteralPath \$EnvFile')
}
foreach ($plugin in @('codex', 'copilot', 'antigravity')) {
    $text = Get-Content -Raw -LiteralPath (Join-Path $repo "plugins/$plugin/scripts/setup.ps1")
    Check "${plugin}: requires protection before replacing" $true ($text -match '-RequireProtection')
}

$libText = Get-Content -Raw -LiteralPath (Join-Path $repo 'scripts/shared/env-file.ps1')
Check 'writer: no in-place write of the destination' $false `
    ($libText -match '\[System\.IO\.File\]::WriteAllText\(\$Path')
Check 'writer: renames a temp into place' $true `
    ($libText -match 'Move-Item -LiteralPath \$tmp -Destination \$Path')

Check 'writer: reads the env file as UTF-8' $true `
    ($libText -match 'Get-Content -LiteralPath \$Path -Encoding UTF8')

$installer = Get-Content -Raw -LiteralPath (Join-Path $repo 'install.ps1')
Check 'install.ps1: merges existing lines' $true ($installer -match 'foreach \(\$line in \(Get-Content -LiteralPath \$EnvFile')
Check 'install.ps1: reads the merge source as UTF-8' $true `
    ($installer -match 'Get-Content -LiteralPath \$EnvFile -Encoding UTF8')
$readValuesFn = [regex]::Match($installer, '(?ms)^function Read-EnvFileValues \{.*?^\}').Value
Check 'install.ps1: Read-EnvFileValues located' $true ($readValuesFn.Length -gt 0)
Check 'install.ps1: reads existing creds as UTF-8' $true `
    ($readValuesFn -match 'Get-Content -LiteralPath \$Path -Encoding UTF8')

$dispatcher = Get-Content -Raw -LiteralPath (Join-Path $repo 'plugins/rogue/scripts/hook.ps1')
function Get-NormalizedFunction {
    param([string]$Text, [string]$Name)
    $body = [regex]::Match($Text, "(?ms)^function $Name \{.*?^\}").Value
    $body = [regex]::Replace($body, '(?m)^\s*#.*$', '')      # comments differ on purpose
    return ([regex]::Replace($body, '\s+', ' ')).Trim()
}
Check 'install.ps1: decodes shell quoting, not just the outer quotes' $true `
    ($installer -match 'ConvertFrom-ShellQuoted \$Matches')
Check 'install.ps1: shell-word decoder matches the dispatcher' `
    (Get-NormalizedFunction $dispatcher 'ConvertFrom-ShellQuoted') `
    (Get-NormalizedFunction $installer  'ConvertFrom-ShellQuoted')
Check 'install.ps1: no truncating write'   $false ($installer -match 'Set-Content\s+-Path\s+\$EnvFile')
Check 'install.ps1: renames a temp into place' $true `
    ($installer -match 'Move-Item -LiteralPath \$envTmp -Destination \$EnvFile')

$loadFn = [regex]::Match($installer, '(?ms)^function Load-ExistingCreds \{.*?^\}').Value
Check 'install.ps1: Load-ExistingCreds located' $true ($loadFn.Length -gt 0)
$unquoteFn = [regex]::Match($installer, '(?ms)^function ConvertFrom-ShellQuoted \{.*?^\}').Value
Check 'install.ps1: ConvertFrom-ShellQuoted located' $true ($unquoteFn.Length -gt 0)
$hasKeyFn = [regex]::Match($installer, '(?ms)^function Test-EnvFileHasKey \{.*?^\}').Value
Check 'install.ps1: Test-EnvFileHasKey located' $true ($hasKeyFn.Length -gt 0)
. ([scriptblock]::Create($unquoteFn))
. ([scriptblock]::Create($hasKeyFn))
. ([scriptblock]::Create($readValuesFn))
. ([scriptblock]::Create($loadFn))

$ROGUE_BASE_URL_DEFAULT = 'https://api.rogue.security'
$saveProfile = $env:USERPROFILE
$env:USERPROFILE = $sandbox
$EnvFile = Join-Path $env:USERPROFILE '.rogue-env'
[System.IO.File]::WriteAllText((Join-Path $sandbox '.rogue-env'), $seed + "`n",
    (New-Object System.Text.UTF8Encoding($false)))

function Resolve-BaseUrl {
    param([string]$Given, [bool]$Explicit)
    $script:ApiKey = 'k'; $script:Email = 'e@x.io'; $script:Name = 'N'
    $script:BaseUrl = $Given
    $script:BaseUrlExplicit = $Explicit
    Load-ExistingCreds
    return $script:BaseUrl
}
Check 'install.ps1: silent run takes the on-disk url' 'http://localhost:8007' `
    (Resolve-BaseUrl $ROGUE_BASE_URL_DEFAULT $false)
Check 'install.ps1: explicit custom url wins' 'https://staging.example.com' `
    (Resolve-BaseUrl 'https://staging.example.com' $true)
Check 'install.ps1: explicit default clears the stale custom url' $ROGUE_BASE_URL_DEFAULT `
    (Resolve-BaseUrl $ROGUE_BASE_URL_DEFAULT $true)

$apos = "O'Brien"
$aposFile = Join-Path $sandbox '.rogue-env'
[System.IO.File]::WriteAllText($aposFile, (@(
    "export ROGUE_API_KEY='k'",
    "export ROGUE_ACTOR_EMAIL='o@example.com'",
    "export ROGUE_ACTOR_NAME='O'\''Brien'"
) -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))

$script:ApiKey = ''; $script:Email = ''; $script:Name = ''
$script:BaseUrl = $ROGUE_BASE_URL_DEFAULT; $script:BaseUrlExplicit = $false
Load-ExistingCreds
Check 'install.ps1: apostrophe decoded on load' $apos $script:Name

Write-RogueEnvFile -Path $aposFile -Values ([ordered]@{
    ROGUE_API_KEY     = $script:ApiKey
    ROGUE_ACTOR_EMAIL = $script:Email
    ROGUE_ACTOR_NAME  = $script:Name
}) | Out-Null
$script:Name = ''
Load-ExistingCreds
Check 'install.ps1: apostrophe survives a rewrite' $apos $script:Name
Check 'install.ps1: apostrophe not re-escaped on disk' "export ROGUE_ACTOR_NAME='O'\''Brien'" `
    (@(Get-Content -LiteralPath $aposFile -Encoding UTF8 |
       Where-Object { $_ -match '^export ROGUE_ACTOR_NAME=' })[0])
$bashForApos = Get-Command bash -ErrorAction SilentlyContinue
if ($bashForApos -and -not $env:OS) {
    $env:ROGUE_APOS_FILE = $aposFile
    $viaSh = & $bashForApos.Source -c '. "$ROGUE_APOS_FILE"; printf %s "$ROGUE_ACTOR_NAME"'
    Remove-Item Env:ROGUE_APOS_FILE -ErrorAction SilentlyContinue
    Check 'install.ps1: apostrophe reads the same under sh' $apos $viaSh
}
$env:USERPROFILE = $saveProfile

$bash = Get-Command bash -ErrorAction SilentlyContinue
if ($bash) {
    New-Item -ItemType Directory -Path (Join-Path $sandbox 'cmp-sh') -Force | Out-Null
    $shFile = New-SeededFile 'cmp-sh/.rogue-env'
    $psFile = New-SeededFile 'cmp-ps.env'
    $saveShHome = $env:HOME
    $env:HOME = Join-Path $sandbox 'cmp-sh'
    & $bash.Source (Join-Path $repo 'plugins/rogue/scripts/setup.sh') 'new-key' 'new@example.com' 'New Name' | Out-Null
    $env:HOME = $saveShHome
    Write-RogueEnvFile -Path $psFile -Values ([ordered]@{
        ROGUE_API_KEY     = 'new-key'
        ROGUE_ACTOR_EMAIL = 'new@example.com'
        ROGUE_ACTOR_NAME  = 'New Name'
    }) | Out-Null
    $shText = [System.IO.File]::ReadAllText($shFile)
    $psText = [System.IO.File]::ReadAllText($psFile)
    if ($shText -ceq $psText) { Write-Host '  ok: sh and PowerShell writers agree byte for byte' }
    else {
        Write-Host 'FAIL: sh and PowerShell writers disagree'
        Write-Host "--- sh ---`n$shText--- ps ---`n$psText"
        $script:fails++
    }
} else {
    Write-Host '  skip: bash not available (sh/PowerShell comparison)'
}

$nlFile = New-SeededFile 'linebreak.env'
$nlBefore = [System.IO.File]::ReadAllText($nlFile)
$nlThrew = $false
try {
    Write-RogueEnvFile -Path $nlFile -Values ([ordered]@{
        ROGUE_API_KEY     = 'k'
        ROGUE_ACTOR_EMAIL = 'e@x.io'
        ROGUE_ACTOR_NAME  = "a`nb"
    }) | Out-Null
} catch { $nlThrew = $true }
Check 'line break in a value is refused'  $true      $nlThrew
Check 'line break leaves the file alone'  $nlBefore  ([System.IO.File]::ReadAllText($nlFile))

$crFile = New-SeededFile 'carriage.env'
$crThrew = $false
try {
    Write-RogueEnvFile -Path $crFile -Values ([ordered]@{ ROGUE_API_KEY = "k`rx" }) | Out-Null
} catch { $crThrew = $true }
Check 'carriage return in a value is refused' $true $crThrew

Check 'line break leaves no temp behind' 0 `
    (@(Get-ChildItem -LiteralPath $sandbox -Filter '*linebreak*.rogue-tmp.*' -Force).Count)

if ($chmod) {
    $unreadFile = New-SeededFile 'unreadable.env'
    $unreadBefore = [System.IO.File]::ReadAllText($unreadFile)
    & $chmod.Source 000 $unreadFile
    $stillReadable = $true
    try { [void][System.IO.File]::ReadAllText($unreadFile) } catch { $stillReadable = $false }
    if ($stillReadable) {
        Write-Host '  skip: mode 000 is readable anyway (running as root?)'
    } else {
        $unreadThrew = $false
        try {
            Write-RogueEnvFile -Path $unreadFile -Values ([ordered]@{ ROGUE_API_KEY = 'should-not-land' }) | Out-Null
        } catch { $unreadThrew = $true }
        & $chmod.Source 600 $unreadFile
        Check 'unreadable file fails the write'  $true          $unreadThrew
        Check 'unreadable file left intact'      $unreadBefore  ([System.IO.File]::ReadAllText($unreadFile))
        Check 'unreadable file leaves no temp'   0 `
            (@(Get-ChildItem -LiteralPath $sandbox -Filter '*unreadable*.rogue-tmp.*' -Force).Count)
    }
    & $chmod.Source 600 $unreadFile
} else {
    Write-Host '  skip: chmod not available (unreadable-file case)'
}

$installerText = Get-Content -Raw -LiteralPath (Join-Path $repo 'install.ps1')
Check 'install.ps1: base url managed only when explicit' $true `
    ($installerText -match "if \(\`$BaseUrlExplicit\) \{ \`$managed \+= 'ROGUE_BASE_URL' \}")
Check 'install.ps1: base url written only when explicit' $true `
    ($installerText -match 'if \(\$BaseUrlExplicit -and \$BaseUrl -ne \$ROGUE_BASE_URL_DEFAULT\)')
Check 'install.ps1: merge read fails loudly' $true `
    ($installerText -match 'Get-Content -LiteralPath \$EnvFile -Encoding UTF8 -ErrorAction Stop')
Check 'library: merge read fails loudly' $true `
    ((Get-Content -Raw -LiteralPath (Join-Path $repo 'scripts/shared/env-file.ps1')) -match `
        'Get-Content -LiteralPath \$Path -Encoding UTF8 -ErrorAction Stop')

Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
if ($script:fails -gt 0) { Write-Host "$($script:fails) check(s) failed"; exit 1 }
Write-Host 'all env-file writer checks passed'
