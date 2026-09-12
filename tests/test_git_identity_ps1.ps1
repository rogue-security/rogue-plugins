#!/usr/bin/env pwsh
# tests/test_git_identity_ps1.ps1 — the PowerShell actor fallback.
#
#   1. scripts/shared/git-identity.ps1: user.email / user.name from the git config
#      FILES (XDG then ~/.gitconfig, later wins, one level of [include] path).
#   2. plugins/rogue/scripts/hook.ps1 Resolve-RogueActor: env file → git config
#      files → <login>@<host>, loaded through the ROGUE_PS_LIB_ONLY seam.
#   2b. scripts/shared/actor.ps1 Resolve-RogueSharedActor, the same three levels
#      for codex/cursor/copilot/antigravity/kiro.
#   3. No dispatcher or heartbeat shells out to git: a stub git ahead of PATH is a
#      tripwire, and the sources are grepped for the old `& git config` call.
#
# Runs under pwsh 7 on any platform and under Windows PowerShell 5.1.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($here, '..'))
$lib  = [System.IO.Path]::Combine($repo, 'scripts', 'shared', 'git-identity.ps1')
$hook = [System.IO.Path]::Combine($repo, 'plugins', 'rogue', 'scripts', 'hook.ps1')
$sharedActor = [System.IO.Path]::Combine($repo, 'scripts', 'shared', 'actor.ps1')

$fails = 0
$count = 0
function Assert-Eq {
    param($Got, $Expected, [string]$Label)
    $script:count++
    if ([string]$Got -ceq [string]$Expected) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL [$Label]: got <$Got>, expected <$Expected>"; $script:fails++ }
}

# ── harness: a throwaway home the readers see through HOME, USERPROFILE and XDG ──
$saved = @{}
foreach ($k in 'HOME','USERPROFILE','XDG_CONFIG_HOME','PATH','CLAUDE_CODE_USER_EMAIL') {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k)
}
$homes = @()
function New-TestHome {
    $d = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'rogue-gitid-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $script:homes += $d
    $env:HOME = $d
    $env:USERPROFILE = $d
    $env:XDG_CONFIG_HOME = [System.IO.Path]::Combine($d, '.config')
    return $d
}
function Write-Cfg {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text)
}
function Read-GitId { return (& ([scriptblock]::Create((Get-Content -Raw -LiteralPath $lib)))) }

# Tripwire: `git` on PATH records every invocation. Both a POSIX script and a
# .cmd, so it fires on the Linux runner and under Windows PowerShell 5.1 alike.
$trip = New-TestHome
$tripMarker = [System.IO.Path]::Combine($trip, 'git-invoked')
Write-Cfg ([System.IO.Path]::Combine($trip, 'bin', 'git')) "#!/bin/sh`necho `"git `$*`" >> '$tripMarker'`nexit 1`n"
Write-Cfg ([System.IO.Path]::Combine($trip, 'bin', 'git.cmd')) "@echo git %* >> `"$tripMarker`"`r`n@exit /b 1`r`n"
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { & chmod +x ([System.IO.Path]::Combine($trip, 'bin', 'git')) }
$env:PATH = [System.IO.Path]::Combine($trip, 'bin') + [System.IO.Path]::PathSeparator + $env:PATH

try {
    Write-Host '-- git-identity.ps1: the config files --'

    $h = New-TestHome
    Write-Cfg ([System.IO.Path]::Combine($h, '.gitconfig')) "# comment`n[User]`n`tName = `"Jane; Dev`"   `n`temail = jane@corp.com ; trailing`n"
    $id = Read-GitId
    Assert-Eq $id.Email 'jane@corp.com' 'email read from ~/.gitconfig, comment stripped'
    Assert-Eq $id.Name  'Jane; Dev'     'quoted name unwrapped, section/key case-insensitive'

    $h = New-TestHome
    Write-Cfg ([System.IO.Path]::Combine($h, '.gitconfig')) "[user]`n`temail = home@corp.com`n[include]`n`tpath = ~/.gitconfig-work`n"
    Write-Cfg ([System.IO.Path]::Combine($h, '.gitconfig-work')) "[user]`n`temail = work@corp.com`n`tname = Work Me`n"
    $id = Read-GitId
    Assert-Eq $id.Email 'work@corp.com' '[include] path is followed and overrides the includer'
    Assert-Eq $id.Name  'Work Me'       'a field only the included file carries is used'

    $h = New-TestHome
    Write-Cfg ([System.IO.Path]::Combine($h, '.gitconfig')) "[include]`n`tpath = sub/extra`n"
    Write-Cfg ([System.IO.Path]::Combine($h, 'sub', 'extra')) "[user]`n`tname = Rel Inc`n"
    Assert-Eq (Read-GitId).Name 'Rel Inc' 'a relative include path resolves against the including file'

    $h = New-TestHome
    Write-Cfg ([System.IO.Path]::Combine($h, '.gitconfig')) "[includeIf `"gitdir:~/work/`"]`n`tpath = ~/.gitconfig-never`n"
    Write-Cfg ([System.IO.Path]::Combine($h, '.gitconfig-never')) "[user]`n`temail = never@corp.com`n"
    Assert-Eq (Read-GitId).Email '' 'a conditional include is not evaluated'

    $h = New-TestHome
    Write-Cfg ([System.IO.Path]::Combine($h, '.config', 'git', 'config')) "[user]`n`temail = xdg@corp.com`n`tname = Xdg Me`n"
    $id = Read-GitId
    Assert-Eq $id.Email 'xdg@corp.com' 'XDG config is read when ~/.gitconfig is absent'
    Write-Cfg ([System.IO.Path]::Combine($h, '.gitconfig')) "[user]`n`temail = home@corp.com`n"
    $id = Read-GitId
    Assert-Eq $id.Email 'home@corp.com' '~/.gitconfig overrides the XDG value'
    Assert-Eq $id.Name  'Xdg Me'        'a field only XDG carries survives'

    $h = New-TestHome
    Write-Cfg ([System.IO.Path]::Combine($h, '.gitconfig')) "[user]`r`n`temail = jane@corp.com`r`n`tname = Jane Dev`r`n"
    $id = Read-GitId
    Assert-Eq $id.Email 'jane@corp.com' 'CRLF file: no trailing CR on the email (same bytes as git-identity.sh)'
    Assert-Eq $id.Name  'Jane Dev'      'CRLF file: no trailing CR on the name'

    $h = New-TestHome
    Write-Cfg ([System.IO.Path]::Combine($h, '.gitconfig')) ([string][char]0xFEFF + "[user]`n`temail = bom@corp.com`n`tname = Bom Me`n")
    $id = Read-GitId
    Assert-Eq $id.Email 'bom@corp.com' 'a UTF-8 BOM before [user] does not hide the section (same as git-identity.sh)'
    Assert-Eq $id.Name  'Bom Me'       'BOM file: name read'

    $h = New-TestHome
    Write-Cfg ([System.IO.Path]::Combine($h, '.gitconfig')) "[user]`n`temail = jane@corp.com # work`n`tname = `"Jane \`"JJ\`" Dev`" ; nick`n"
    $id = Read-GitId
    Assert-Eq $id.Email 'jane@corp.com'  'an unquoted trailing comment is dropped'
    Assert-Eq $id.Name  'Jane "JJ" Dev'  'backslash-escaped quotes survive, as git reads them'

    $h = New-TestHome
    $id = Read-GitId
    Assert-Eq $id.Email '' 'no config file: empty email, no error'
    Assert-Eq $id.Name  '' 'no config file: empty name, no error'
    Assert-Eq $id.GetType().Name 'Hashtable' 'always outputs a hashtable'

    Write-Host '-- hook.ps1 Resolve-RogueActor: the three fallback levels --'
    $env:ROGUE_PS_LIB_ONLY = '1'
    . $hook
    $env:ROGUE_PS_LIB_ONLY = $null
    $ErrorActionPreference = 'Stop'
    $env:CLAUDE_CODE_USER_EMAIL = $null
    $pluginRoot = [System.IO.Path]::Combine($repo, 'plugins', 'rogue')

    $login = Select-ActorValue @($env:USERNAME, [Environment]::UserName)
    $dns = ''; try { $dns = [System.Net.Dns]::GetHostName() } catch {}
    $hostName = Select-ActorValue @($env:COMPUTERNAME, $dns)
    $loginAtHost = if ($hostName) { "$login@$hostName" } else { $login }

    $h = New-TestHome
    Write-Cfg ([System.IO.Path]::Combine($h, '.gitconfig')) "[user]`n`temail = jane@corp.com`n`tname = Jane Dev`n"
    $a = Resolve-RogueActor @{ ROGUE_ACTOR_EMAIL = 'mdm@corp.com'; ROGUE_ACTOR_NAME = 'MDM Provisioned' } $pluginRoot
    Assert-Eq $a.Email 'mdm@corp.com'    'level 1: env file email wins over the git identity'
    Assert-Eq $a.Name  'MDM Provisioned' 'level 1: env file name wins over the git identity'

    $a = Resolve-RogueActor @{} $pluginRoot
    Assert-Eq $a.Email 'jane@corp.com' 'level 2: git config file email when the env file has none'
    Assert-Eq $a.Name  'Jane Dev'      'level 2: git config file name when the env file has none'

    $a = Resolve-RogueActor @{ ROGUE_ACTOR_EMAIL = 'mdm@corp.com' } $pluginRoot
    Assert-Eq $a.Email 'mdm@corp.com' 'fields resolve independently (email from env)'
    Assert-Eq $a.Name  'Jane Dev'     'fields resolve independently (name from git)'

    $h = New-TestHome
    $a = Resolve-RogueActor @{} $pluginRoot
    Assert-Eq $a.Email $loginAtHost 'level 3: <login>@<host> when there is no git identity'
    Assert-Eq $a.Name  $login       'level 3: login as the name'
    Assert-Eq ([bool]$a.Email) $true 'level 3: the email is never blank'

    $h = New-TestHome
    Write-Cfg ([System.IO.Path]::Combine($h, '.gitconfig')) "[user]`n`temail = noreply@anthropic.com`n`tname = Claude`n"
    $a = Resolve-RogueActor @{} $pluginRoot
    Assert-Eq $a.Email $loginAtHost 'the sandbox git identity is screened, login@host used'
    Assert-Eq $a.Name  $login       'the sandbox git name is screened, login used'

    $env:CLAUDE_CODE_USER_EMAIL = 'real.user@corp.com'
    $h = New-TestHome
    Write-Cfg ([System.IO.Path]::Combine($h, '.gitconfig')) "[user]`n`temail = jane@corp.com`n`tname = Jane Dev`n"
    $a = Resolve-RogueActor @{} $pluginRoot
    Assert-Eq $a.Email 'real.user@corp.com' 'CLAUDE_CODE_USER_EMAIL outranks the git identity'
    Assert-Eq $a.Name  'real.user'          'its local-part is the name'
    $env:CLAUDE_CODE_USER_EMAIL = $null

    $a = Resolve-RogueActor @{} ([System.IO.Path]::Combine($h, 'no-such-plugin'))
    Assert-Eq $a.Email $loginAtHost 'a damaged install (no git-identity.ps1) degrades to login@host'

    # heartbeat.ps1 takes the same cascade through this seam inside a child scope:
    # the actor comes out, none of hook.ps1's helpers land in the caller.
    $h = New-TestHome
    Write-Cfg ([System.IO.Path]::Combine($h, '.gitconfig')) "[user]`n`temail = hb@corp.com`n`tname = HB Dev`n"
    $creds = @{}
    $viaSeam = & {
        $env:ROGUE_PS_LIB_ONLY = '1'
        try {
            & {
                . ([scriptblock]::Create((Get-Content -Raw -LiteralPath $hook)))
                Resolve-RogueActor $creds $pluginRoot
            }
        } finally { $env:ROGUE_PS_LIB_ONLY = $null }
    }
    Assert-Eq $viaSeam.Email 'hb@corp.com' 'heartbeat.ps1 construct: the seam-loaded cascade answers the git identity'
    Assert-Eq $viaSeam.Name  'HB Dev'      'heartbeat.ps1 construct: name too'
    Assert-Eq ([bool][string]$env:ROGUE_PS_LIB_ONLY) $false 'heartbeat.ps1 construct: the seam variable is cleared for the shipper it spawns'
    $hbSrc = Get-Content -Raw -LiteralPath ([System.IO.Path]::Combine($repo, 'plugins', 'rogue', 'scripts', 'heartbeat.ps1'))
    Assert-Eq ($hbSrc -match 'Resolve-RogueActor \$creds \$pluginRoot') $true 'heartbeat.ps1 calls hook.ps1 Resolve-RogueActor'
    Assert-Eq ($hbSrc -match 'function (Select-ActorValue|Test-SyntheticActor)') $false 'heartbeat.ps1 carries no copy of the cascade'

    Write-Host '-- scripts/shared/actor.ps1 Resolve-RogueSharedActor: the three fallback levels --'
    . ([scriptblock]::Create((Get-Content -Raw -LiteralPath $sharedActor)))
    $codexRoot = [System.IO.Path]::Combine($repo, 'plugins', 'codex')
    $sharedLogin = $env:USERNAME
    if (-not $sharedLogin) { $sharedLogin = [Environment]::UserName }
    $sharedHost = $env:COMPUTERNAME
    if (-not $sharedHost) { $sharedHost = $dns }
    $sharedLoginAtHost = if ($sharedHost) { "$sharedLogin@$sharedHost" } else { $sharedLogin }

    $h = New-TestHome
    Write-Cfg ([System.IO.Path]::Combine($h, '.gitconfig')) "[user]`n`temail = jane@corp.com`n`tname = Jane Dev`n"
    $a = Resolve-RogueSharedActor @{ ROGUE_ACTOR_EMAIL = 'mdm@corp.com'; ROGUE_ACTOR_NAME = 'MDM Provisioned' } $codexRoot
    Assert-Eq $a.Email 'mdm@corp.com'    'shared level 1: env file email wins over the git identity'
    Assert-Eq $a.Name  'MDM Provisioned' 'shared level 1: env file name wins over the git identity'

    $a = Resolve-RogueSharedActor @{} $codexRoot
    Assert-Eq $a.Email 'jane@corp.com' 'shared level 2: git config file email'
    Assert-Eq $a.Name  'Jane Dev'      'shared level 2: git config file name'

    $a = Resolve-RogueSharedActor @{ ROGUE_ACTOR_EMAIL = 'mdm@corp.com' } $codexRoot
    Assert-Eq $a.Email 'mdm@corp.com' 'shared: fields resolve independently (email from env)'
    Assert-Eq $a.Name  'Jane Dev'     'shared: fields resolve independently (name from git)'

    $h = New-TestHome
    $a = Resolve-RogueSharedActor @{} $codexRoot
    Assert-Eq $a.Email $sharedLoginAtHost 'shared level 3: <login>@<host> when there is no git identity'
    Assert-Eq $a.Name  $sharedLogin       'shared level 3: login as the name'
    Assert-Eq ([bool]$a.Email) $true 'shared level 3: the email is never blank'

    $a = Resolve-RogueSharedActor @{} ([System.IO.Path]::Combine($h, 'no-such-plugin'))
    Assert-Eq $a.Email $sharedLoginAtHost 'shared: a damaged install (no git-identity.ps1) degrades to login@host'

    Write-Host '-- every non-Claude bridge loads the shared cascade --'
    foreach ($p in 'codex','copilot','antigravity','kiro','cursor') {
        foreach ($f in 'hook.ps1','heartbeat.ps1') {
            $src = [System.IO.Path]::Combine($repo, 'plugins', $p, 'scripts', $f)
            if (-not (Test-Path -LiteralPath $src)) { continue }
            Assert-Eq ((Get-Content -Raw -LiteralPath $src) -match 'Resolve-RogueSharedActor') $true "$p/$f resolves the actor through actor.ps1"
        }
    }

    Write-Host '-- no bridge shells out to git --'
    Assert-Eq (Test-Path -LiteralPath $tripMarker) $false 'git binary never invoked'
    foreach ($p in 'rogue','codex','copilot','antigravity','kiro','cursor') {
        foreach ($f in 'hook.ps1','heartbeat.ps1') {
            $src = [System.IO.Path]::Combine($repo, 'plugins', $p, 'scripts', $f)
            if (-not (Test-Path -LiteralPath $src)) { continue }
            Assert-Eq ((Get-Content -Raw -LiteralPath $src) -match '&\s*git\s') $false "$p/$f does not call git"
        }
    }
} finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    foreach ($d in $homes) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($fails -gt 0) { Write-Host "$fails of $count git identity test(s) FAILED."; exit 1 }
Write-Host "All $count git identity tests passed."
exit 0
