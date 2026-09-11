# Outputs @{ Email; Name } from the global git config FILES. git.exe is never
# run (mirrors git-identity.sh: on a Mac without the Command Line Tools `git`
# opens the installer dialog, and one rule must hold on every platform).
#
# Invoke as a scriptblock and take its output:
#   $gitId = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $lib)))
#
# $XDG_CONFIG_HOME/git/config, then ~/.gitconfig, a later value overriding an
# earlier one as git does, each file followed by its [include] path entries
# (one level; includeIf is not evaluated). Windows PowerShell 5.1 compatible.

function Resolve-RogueGitInclude {
    param([string]$Inc, [string]$From, [string]$UserHome)
    if ($Inc.StartsWith('~/') -or $Inc.StartsWith('~\')) { return (Join-Path $UserHome $Inc.Substring(2)) }
    if ([System.IO.Path]::IsPathRooted($Inc)) { return $Inc }
    return (Join-Path (Split-Path -Parent $From) $Inc)
}

function Read-RogueGitConfig {
    param([string]$Path, [string]$UserHome, [hashtable]$Id, [int]$Depth)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $section = ''
    foreach ($raw in [System.IO.File]::ReadAllLines($Path)) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line[0] -eq '#' -or $line[0] -eq ';') { continue }
        if ($line[0] -eq '[') {
            $section = ($line.Substring(1) -replace '[\]\s"].*$', '').ToLowerInvariant()
            continue
        }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $line.Substring(0, $eq).Trim().ToLowerInvariant()
        $val = $line.Substring($eq + 1).Trim()
        if ($val.StartsWith('"')) { $val = $val.Substring(1) -replace '".*$', '' }
        else { $val = ($val -replace '\s*[#;].*$', '').Trim() }
        if ($section -eq 'include' -and $key -eq 'path' -and $Depth -eq 0) {
            Read-RogueGitConfig (Resolve-RogueGitInclude $val $Path $UserHome) $UserHome $Id 1
        } elseif ($section -eq 'user' -and $val) {
            if ($key -eq 'email') { $Id.Email = $val } elseif ($key -eq 'name') { $Id.Name = $val }
        }
    }
}

function Get-RogueGitIdentity {
    $id = @{ Email = ''; Name = '' }
    try {
        $userHome = $env:HOME
        if (-not $userHome) { $userHome = $env:USERPROFILE }
        if (-not $userHome) { return $id }
        $xdg = $env:XDG_CONFIG_HOME
        if (-not $xdg) { $xdg = Join-Path $userHome '.config' }
        foreach ($f in @([System.IO.Path]::Combine($xdg, 'git', 'config'), (Join-Path $userHome '.gitconfig'))) {
            Read-RogueGitConfig $f $userHome $id 0
        }
    } catch {}
    return $id
}

Get-RogueGitIdentity
