
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

# -- The machine env file (FIRE-2135) -----------------------------------------
# A trusted machine env file holding ROGUE_API_KEY is read ALONE by every
# dispatcher, so setup writes no user env file, names that file and exits 0.
# Each plugin's setup.ps1 runs from a COPY whose machine path literal points into
# the sandbox, beside the real env-file.ps1 it loads. Off Windows a `stat` shim on
# PATH reports the file as root-owned; on Windows its owner is set to
# Administrators - the only way to stage the machine candidate without root.
$machineRoot = Join-Path $sandbox 'machine'
New-Item -ItemType Directory -Path $machineRoot -Force | Out-Null
$MachineEnvFile = Join-Path $machineRoot 'machine-env'
$unix = $PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows
$prevPath = $env:PATH
if ($unix) {
    $mbin = Join-Path $machineRoot 'bin'
    New-Item -ItemType Directory -Path $mbin -Force | Out-Null
    $realStat = (Get-Command stat -CommandType Application | Select-Object -First 1).Source
    [System.IO.File]::WriteAllText((Join-Path $mbin 'stat'), @"
#!/usr/bin/env bash
for a in "`$@"; do
  if [ "`$a" = "$MachineEnvFile" ]; then
    if "$realStat" --version >/dev/null 2>&1; then mode="`$("$realStat" -c %a "`$a")"; else mode="`$("$realStat" -f %Lp "`$a")"; fi
    printf '%s %s\n' "`${ROGUE_TEST_MACHINE_OWNER:-0}" "`$mode"; exit 0
  fi
done
exec "$realStat" "`$@"
"@)
    & chmod +x (Join-Path $mbin 'stat')
    $env:PATH = "$mbin$([System.IO.Path]::PathSeparator)$env:PATH"
}

# Trusted = owned by root/Administrators and writable by no one else; untrusted =
# the same file a standard user could rewrite, which would let them replace the
# key the MDM pushed. Recreated rather than overwritten: the previous call leaves
# an ACL this process may not be able to write through.
function Set-SetupMachineFile {
    param([string]$Content, [switch]$Untrusted)
    Remove-Item -LiteralPath $MachineEnvFile -Force -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllText($MachineEnvFile, $Content)
    if ($unix) {
        if ($Untrusted) { & chmod 666 $MachineEnvFile } else { & chmod 644 $MachineEnvFile }
        return
    }
    $admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $rights = 'Read'
    if ($Untrusted) { $rights = 'Read, Write' }
    $acl = Get-Acl -LiteralPath $MachineEnvFile
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($admins)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($admins, 'FullControl', 'Allow')))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me, $rights, 'Allow')))
    Set-Acl -LiteralPath $MachineEnvFile -AclObject $acl
}

function New-RedirectedSetup {
    param([string]$Plugin)
    $dir = Join-Path $machineRoot (Join-Path $Plugin 'scripts')
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo "plugins/$Plugin/scripts/env-file.ps1") -Destination $dir
    $src = [System.IO.File]::ReadAllText((Join-Path $repo "plugins/$Plugin/scripts/setup.ps1"))
    $out = $src.Replace("`$MachineEnvFile = 'C:\ProgramData\rogue\env'", "`$MachineEnvFile = '$MachineEnvFile'")
    Check "${Plugin}: machine path redirected for the test" $true ($out -ne $src)
    $path = Join-Path $dir 'setup.ps1'
    [System.IO.File]::WriteAllText($path, $out)
    return $path
}

# Invoke-Setup <script> <home> [args] -> the script's output as one string, with
# the exit code in $script:setupRc and a freshly emptied %USERPROFILE%.
function Invoke-Setup {
    param([string]$Script, [string]$Home2, [string[]]$Arguments)
    Remove-Item -Recurse -Force -LiteralPath $Home2 -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $Home2 -Force | Out-Null
    $env:USERPROFILE = $Home2
    $global:LASTEXITCODE = 0
    $text = & $Script @Arguments -WarningAction SilentlyContinue 3>&1 | Out-String -Width 4096
    $script:setupRc = $LASTEXITCODE
    return $text
}

# codex/copilot/antigravity refuse to replace the user env file unless the ACL is
# applied, which needs Set-Acl - Windows only. Their unchanged-path cases run in
# the Windows job; the machine-file skip happens before any write, so it runs
# everywhere.
$canProtect = [bool](Get-Command Set-Acl -ErrorAction SilentlyContinue)
$saveMachineProfile = $env:USERPROFILE
foreach ($plugin in @('rogue', 'codex', 'cursor', 'copilot', 'antigravity')) {
    $setup = New-RedirectedSetup $plugin
    $home2 = Join-Path $machineRoot (Join-Path $plugin 'home')
    $userFile = Join-Path $home2 '.rogue-env'

    # 1. Trusted machine file with a key: no write, exit 0, the file is named.
    Set-SetupMachineFile "export ROGUE_API_KEY='machine-key'`n"
    $out = Invoke-Setup $setup $home2 @('new-key', 'e@x.io', 'N')
    Check "${plugin}: keyed machine file exits 0" 0 $script:setupRc
    Check "${plugin}: keyed machine file writes no user file" $false (Test-Path -LiteralPath $userFile)
    Check "${plugin}: keyed machine file is named once" 1 `
        ([regex]::Matches($out, [regex]::Escape("machine env file $MachineEnvFile")).Count)
    Check "${plugin}: keyed machine file reported as the env file" $true `
        ($out -match ([regex]::Escape("ENV_FILE=$MachineEnvFile")))

    # An MDM machine has no key to pass, and setup must still succeed.
    $out = Invoke-Setup $setup $home2 @()
    Check "${plugin}: keyed machine file needs no api key argument" 0 $script:setupRc
    Check "${plugin}: keyed machine file, no argument, no user file" $false (Test-Path -LiteralPath $userFile)

    if (-not $canProtect -and $plugin -in @('codex', 'copilot', 'antigravity')) {
        Write-Host "  skip: ${plugin}: Set-Acl unavailable (unchanged-path cases)"
    } else {
        # 2. No machine file: unchanged.
        Remove-Item -LiteralPath $MachineEnvFile -Force -ErrorAction SilentlyContinue
        $out = Invoke-Setup $setup $home2 @('new-key', 'e@x.io', 'N')
        Check "${plugin}: no machine file exits 0" 0 $script:setupRc
        Check "${plugin}: no machine file writes the user file" 'new-key' (Get-EnvValue $userFile 'ROGUE_API_KEY')
        Check "${plugin}: no machine file names none" $false ($out -match 'machine env file')

        # 3. Machine file without a key: unchanged.
        Set-SetupMachineFile "export ROGUE_ACTOR_EMAIL='mdm@example.com'`n# ROGUE_API_KEY='commented-out'`nexport ROGUE_API_KEY=`n"
        $out = Invoke-Setup $setup $home2 @('new-key', 'e@x.io', 'N')
        Check "${plugin}: keyless machine file writes the user file" 'new-key' (Get-EnvValue $userFile 'ROGUE_API_KEY')
        Check "${plugin}: keyless machine file names none" $false ($out -match 'machine env file')

        # 4. Keyed but writable by a standard user: untrusted, so unchanged.
        Set-SetupMachineFile "export ROGUE_API_KEY='machine-key'`n" -Untrusted
        $out = Invoke-Setup $setup $home2 @('new-key', 'e@x.io', 'N')
        Check "${plugin}: untrusted machine file writes the user file" 'new-key' (Get-EnvValue $userFile 'ROGUE_API_KEY')
        Check "${plugin}: untrusted machine file names none" $false ($out -match 'machine env file')

        # 5. Keyed and mode-clean, but not owned by root: untrusted too (POSIX only -
        # on Windows the owner is part of the ACL the case above already rebuilds).
        if ($unix) {
            Set-SetupMachineFile "export ROGUE_API_KEY='machine-key'`n"
            $env:ROGUE_TEST_MACHINE_OWNER = '1000'
            $out = Invoke-Setup $setup $home2 @('new-key', 'e@x.io', 'N')
            $env:ROGUE_TEST_MACHINE_OWNER = $null
            Check "${plugin}: non-root machine file writes the user file" 'new-key' (Get-EnvValue $userFile 'ROGUE_API_KEY')
        }
    }
    Remove-Item -LiteralPath $MachineEnvFile -Force -ErrorAction SilentlyContinue
}
$env:USERPROFILE = $saveMachineProfile
$env:PATH = $prevPath

Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
if ($script:fails -gt 0) { Write-Host "$($script:fails) check(s) failed"; exit 1 }
Write-Host 'all env-file writer checks passed'
