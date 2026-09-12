#!/usr/bin/env pwsh
# tests/test_install_env_ps1.ps1 - install.ps1 and the machine env file, in
# lockstep with tests/test_install_env_sh.sh.
#
# A keyed C:\ProgramData\rogue\env owned by SYSTEM/Administrators is read alone
# by every dispatcher, so on such a machine the installer prompts for nothing and
# writes no %USERPROFILE%\.rogue-env; it names the file in use, validates its key
# and installs the plugins as before. With the machine file absent, present
# without ROGUE_API_KEY, or keyed but writable by others (Kiro and the log
# shipper skip it), the prompt and the user env file write are as they were.
# install.ps1 runs from a COPY whose machine path literal points into a sandbox:
# once end to end (-Cursor, Invoke-WebRequest and the key validation stubbed),
# otherwise Configure-Credentials through the ROGUE_INSTALL_LIB_ONLY seam with
# Read-Host counting its calls. Off Windows a `stat` shim on PATH reports the
# sandbox file as root-owned; on Windows its owner is set to Administrators.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($here, '..'))

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-env-install-" + [System.IO.Path]::GetRandomFileName())
$bin  = Join-Path $work 'bin'
New-Item -ItemType Directory -Path $bin -Force | Out-Null

$MachineEnvFile = Join-Path $work 'machine-env'
$EnvFile        = Join-Path $work '.rogue-env'
$installer = Join-Path $work 'install.ps1'
$src = [System.IO.File]::ReadAllText((Join-Path $repo 'install.ps1'))
$redirected = $src.Replace("`$MachineEnvFile = 'C:\ProgramData\rogue\env'", "`$MachineEnvFile = '$MachineEnvFile'")
if ($redirected -eq $src) { Write-Host 'the machine path was not redirected'; exit 1 }
[System.IO.File]::WriteAllText($installer, $redirected)

$unix = $PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows
$prevKey = $env:ROGUE_API_KEY
$prevProfile = $env:USERPROFILE
$prevPath = $env:PATH
$env:ROGUE_API_KEY = $null
$env:USERPROFILE = $work
if ($unix) {
    $realStat = (Get-Command stat -CommandType Application | Select-Object -First 1).Source
    [System.IO.File]::WriteAllText((Join-Path $bin 'stat'), @"
#!/usr/bin/env bash
for a in "`$@"; do
  if [ "`$a" = "$MachineEnvFile" ]; then
    if "$realStat" --version >/dev/null 2>&1; then mode="`$("$realStat" -c %a "`$a")"; else mode="`$("$realStat" -f %Lp "`$a")"; fi
    printf '%s %s\n' "`${ROGUE_TEST_MACHINE_OWNER:-0}" "`$mode"; exit 0
  fi
done
exec "$realStat" "`$@"
"@)
    & chmod +x (Join-Path $bin 'stat')
    $env:PATH = "$bin$([System.IO.Path]::PathSeparator)$env:PATH"
}

$env:ROGUE_INSTALL_LIB_ONLY = '1'
. $installer
$env:ROGUE_INSTALL_LIB_ONLY = $null
$ErrorActionPreference = 'Stop'
$Email = 'tester@example.com'; $Name = 'Tester'

# Machine file fixtures: trusted = owned by root/Administrators, writable by no
# one else; untrusted = the same file with a write grant for everyone.
function Set-MachineFile {
    param([string]$Content, [switch]$Untrusted)
    [System.IO.File]::WriteAllText($MachineEnvFile, $Content)
    if ($unix) {
        & chmod ($(if ($Untrusted) { '666' } else { '644' })) $MachineEnvFile
        return
    }
    $acl = Get-Acl -LiteralPath $MachineEnvFile
    $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    if ($Untrusted) {
        $everyone = New-Object System.Security.Principal.SecurityIdentifier('S-1-1-0')
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($everyone, 'Write', 'Allow')))
    }
    Set-Acl -LiteralPath $MachineEnvFile -AclObject $acl
}

class FakeHttpError : System.Exception {
    [object]$Response
    FakeHttpError([int]$code) : base("HTTP $code") { $this.Response = [pscustomobject]@{ StatusCode = $code } }
}
# Env vars, not script variables: the stubs also run from the end-to-end child
# script, whose $script: scope is its own.
$env:ROGUE_TEST_HTTP_CODE = '200'
$script:prompts = 0
function Read-Host {
    param([Parameter(Position = 0)][string]$Prompt, [switch]$AsSecureString)
    $script:prompts++
    return (ConvertTo-SecureString 'typed-key' -AsPlainText -Force)
}
# `-OutFile` is the Cursor tarball download; anything else is the validation POST.
function Invoke-WebRequest {
    $i = [array]::IndexOf($args, '-OutFile')
    if ($i -ge 0) { Copy-Item -LiteralPath $env:ROGUE_TEST_TARBALL -Destination $args[$i + 1]; return }
    if ($env:ROGUE_TEST_HTTP_CODE -ne '200') { throw [FakeHttpError]::new([int]$env:ROGUE_TEST_HTTP_CODE) }
    return [pscustomobject]@{ StatusCode = 200 }
}

$fails = 0
function Assert-Eq {
    param($Got, $Expected, [string]$Label)
    if ([string]$Got -ceq [string]$Expected) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL [$Label]: got <$Got>, expected <$Expected>"; $script:fails++ }
}
function Count-Matches { param([string]$Text, [string]$Needle) return ([regex]::Matches($Text, [regex]::Escape($Needle))).Count }

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

# -- 1. Trusted machine env file with a key: no prompt, no user env file, key validated
Set-MachineFile "export ROGUE_API_KEY='machine-key'`nexport ROGUE_ACTOR_EMAIL='mdm@example.com'`n"
$NonInteractive = $true
$out = Run-Configure ''
Assert-Eq $script:prompts 0 'keyed machine file: no credential prompt'
Assert-Eq (Test-Path -LiteralPath $EnvFile) $false 'keyed machine file: no user env file'
Assert-Eq (Count-Matches $out "machine env file $MachineEnvFile") 1 'keyed machine file: output names the machine file once'
Assert-Eq (Count-Matches $out 'Key validated') 1 'keyed machine file: the machine key is validated'
Assert-Eq (Count-Matches $out 'is ignored') 0 'keyed machine file: no ignored-key warning'
Assert-Eq $CredentialSource $MachineEnvFile 'keyed machine file: summary points at the machine file'

$NonInteractive = $false
$out = Run-Configure ''
Assert-Eq $script:prompts 0 'keyed machine file, interactive: no prompt'
Assert-Eq (Test-Path -LiteralPath $EnvFile) $false 'keyed machine file, interactive: no user env file'

$out = Run-Configure 'passed-key'
Assert-Eq (Test-Path -LiteralPath $EnvFile) $false 'keyed machine file + passed key: no user env file'
Assert-Eq (Count-Matches $out "API key / base URL is ignored: $MachineEnvFile") 1 'keyed machine file + passed key: warns that the key is ignored'

$NonInteractive = $true
$env:ROGUE_TEST_HTTP_CODE = '401'
$out = Run-Configure ''
$env:ROGUE_TEST_HTTP_CODE = '200'
Assert-Eq (Count-Matches $out "key in $MachineEnvFile is invalid (HTTP 401)") 1 'keyed machine file, key rejected: warning names the file'
Assert-Eq (Test-Path -LiteralPath $EnvFile) $false 'keyed machine file, key rejected: no user env file'

# End to end: the credential skip does not end the installer; the Cursor section
# runs and the summary prints. The plugin files themselves land only on Windows,
# whose backslash paths the Cursor block is written for.
$stage = [System.IO.Path]::Combine($work, 'stage', 'rogue-plugin-cursor', 'plugins')
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Copy-Item -Recurse ([System.IO.Path]::Combine($repo, 'plugins', 'cursor')) ([System.IO.Path]::Combine($stage, 'cursor'))
$env:ROGUE_TEST_TARBALL = Join-Path $work 'rogue-plugin-cursor.tar.gz'
& tar -czf $env:ROGUE_TEST_TARBALL -C (Join-Path $work 'stage') rogue-plugin-cursor
if ($LASTEXITCODE -ne 0) { Write-Host 'could not build the Cursor tarball'; exit 1 }
$out = & $installer -Cursor -NonInteractive 6>&1 | Out-String
Assert-Eq (Count-Matches $out "machine env file $MachineEnvFile") 1 'end to end: output names the machine file once'
Assert-Eq (Count-Matches $out 'Key validated') 1 'end to end: the machine key is validated'
Assert-Eq (Test-Path -LiteralPath $EnvFile) $false 'end to end: no user env file'
Assert-Eq ($out -match 'Rogue Security - Cursor') $true 'end to end: the Cursor install runs after the credential skip'
Assert-Eq ($out -match 'Credentials:\s+' + [regex]::Escape($MachineEnvFile)) $true 'end to end: summary lists the machine file'
if (-not $unix) {
    Assert-Eq (Test-Path -LiteralPath (Join-Path $work '.cursor\plugins\local\rogue\.cursor-plugin\plugin.json')) $true 'end to end: Cursor plugin installed'
}

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
Set-MachineFile "export ROGUE_ACTOR_EMAIL='mdm@example.com'`n# ROGUE_API_KEY='commented-out'`nexport ROGUE_API_KEY=`n"
$NonInteractive = $true
$out = Run-Configure 'passed-key'
Assert-Eq $script:prompts 0 'keyless machine file, non-interactive: no prompt'
Assert-Eq (Get-WrittenKey) 'passed-key' 'keyless machine file, non-interactive: passed key written'
Assert-Eq ($out -match 'machine env file') $false 'keyless machine file: output does not name a machine file'

$NonInteractive = $false
$out = Run-Configure ''
Assert-Eq $script:prompts 1 'keyless machine file, interactive: prompts once'
Assert-Eq (Get-WrittenKey) 'typed-key' 'keyless machine file, interactive: typed key written'

# -- 4. Keyed machine env file writable by others: a warning names it, then as in 2 --
Set-MachineFile "export ROGUE_API_KEY='machine-key'`n" -Untrusted
$NonInteractive = $true
$out = Run-Configure 'passed-key'
Assert-Eq (Count-Matches $out "$MachineEnvFile holds ROGUE_API_KEY but is not owned by SYSTEM/Administrators or is writable by others") 1 'writable machine file: warning names the file'
Assert-Eq (Get-WrittenKey) 'passed-key' 'writable machine file, non-interactive: passed key written'
Assert-Eq ($out -match 'Credentials come from the machine env file') $false 'writable machine file: not named as the credential source'

$NonInteractive = $false
$out = Run-Configure ''
Assert-Eq $script:prompts 1 'writable machine file, interactive: prompts once'
Assert-Eq (Get-WrittenKey) 'typed-key' 'writable machine file, interactive: typed key written'

if ($unix) {
    Set-MachineFile "export ROGUE_API_KEY='machine-key'`n"
    $env:ROGUE_TEST_MACHINE_OWNER = (& id -u)
    $NonInteractive = $true
    $out = Run-Configure 'passed-key'
    $env:ROGUE_TEST_MACHINE_OWNER = $null
    Assert-Eq (Count-Matches $out "$MachineEnvFile holds ROGUE_API_KEY") 1 'user-owned machine file: warning names the file'
    Assert-Eq (Get-WrittenKey) 'passed-key' 'user-owned machine file: passed key written'
}

$env:ROGUE_API_KEY = $prevKey
$env:USERPROFILE = $prevProfile
$env:PATH = $prevPath
$env:ROGUE_TEST_HTTP_CODE = $null
$env:ROGUE_TEST_TARBALL = $null
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host ''
if ($fails -eq 0) { Write-Host 'all install env-file tests passed'; exit 0 }
Write-Host "$fails FAILED"; exit 1
