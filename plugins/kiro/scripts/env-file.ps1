# A Windows PowerShell child can inherit PowerShell 7's PSModulePath. Load
# this engine's ACL cmdlets explicitly instead of resolving an incompatible module.
if ($PSVersionTable.PSVersion.Major -eq 5) {
    Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
}

# Reject files writable by identities other than the current user or Windows
# administrators/system. System-wide configuration cannot be user-owned.
function Test-RogueEnvFile {
    param([string]$Path, [switch]$System)
    try { if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false } } catch { return $false }
    return (Test-RogueProtectedPath $Path -System:$System)
}

# The ownership rule itself: for a file anywhere, and off Windows for a directory too.
function Test-RogueProtectedPath {
    param([string]$Path, [switch]$System)
    try {
        if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
            $info = & stat -Lc '%u %a' $Path 2>$null
            if ($LASTEXITCODE -ne 0) { $info = & stat -Lf '%u %Lp' $Path 2>$null }
            if ($LASTEXITCODE -ne 0 -or $info -notmatch '^(\d+) ([0-7]+)$') { return $false }
            $ownerId = $Matches[1]; $mode = [Convert]::ToInt32($Matches[2], 8)
            return (($ownerId -eq '0' -or (-not $System -and $ownerId -eq (& id -u))) -and ($mode -band 18) -eq 0)
        }
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $admins = @('S-1-5-18', 'S-1-5-32-544')
        $trusted = @($admins) + $user
        # The machine file accepts only SYSTEM and Administrators as writers; the user file also accepts its owner.
        $writers = if ($System) { $admins } else { $trusted }
        $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($owner -notin $trusted -or ($System -and $owner -notin $admins)) { return $false }
        $write = [System.Security.AccessControl.FileSystemRights]'Write, Delete, ChangePermissions, TakeOwnership, DeleteSubdirectoriesAndFiles'
        foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
            # An inherit-only entry (a directory's CREATOR OWNER, say) grants nothing on the item itself.
            if ($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
            if ($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $write) -and
                $rule.IdentityReference.Value -notin $writers) { return $false }
        }
        return $true
    } catch { return $false }
}

# Test-RogueProtectedPath for every existing directory above the native bridge, so no other user can
# swap a component. $Path is its version directory, $Root the install root it lies in.
#   Off Windows: every existing directory from $Path (or its nearest existing parent) up to /, both
#   as written and as its physical path. A root-owned sticky directory (/tmp) also passes: nobody can
#   rename or remove an entry there that they do not own. A component written as a symlink must be
#   root's own link (not even ours): only then can no other user's link sit behind it.
#   Windows: every existing directory from $Path up to and including $Root, none of them a junction
#   or symlink. It stops at $Root: the drive root and C:\Users let any signed-in user create entries.
function Test-RogueDirChain {
    param([string]$Path, [string]$Root)
    try {
        if (-not ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows)) {
            $top = [IO.Path]::GetFullPath($Root).TrimEnd('\')
            $d = [IO.Path]::GetFullPath($Path).TrimEnd('\')
            if (-not ($d.Equals($top, 'OrdinalIgnoreCase') -or $d.StartsWith("$top\", 'OrdinalIgnoreCase'))) { return $false }
            while ($true) {
                $item = Get-Item -Force -LiteralPath $d -ErrorAction SilentlyContinue
                if ($item) {
                    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
                    if (-not (Test-RogueProtectedPath $d)) { return $false }
                }
                if ($d.Equals($top, 'OrdinalIgnoreCase')) { break }
                $d = Split-Path -Parent $d
            }
            # Above the root, a parent lets whoever may delete its children rename or replace the root,
            # and its owner may always rewrite its ACL to grant that. Plain create rights (C:\ grants
            # them to every signed-in user) don't.
            $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464',
                [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
            $replace = [System.Security.AccessControl.FileSystemRights]'Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
            for ($d = Split-Path -Parent $top; $d; $d = Split-Path -Parent $d) {
                # Not created yet (the installer makes it, then checks again).
                $item = Get-Item -Force -LiteralPath $d -ErrorAction SilentlyContinue
                if (-not $item) { continue }
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
                $acl = Get-Acl -LiteralPath $d -ErrorAction Stop
                if ($acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -notin $trusted) { return $false }
                foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
                    if ($rule.AccessControlType -eq 'Allow' -and -not ($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -and
                        ($rule.FileSystemRights -band $replace) -and $rule.IdentityReference.Value -notin $trusted) { return $false }
                }
            }
            return $true
        }
        if (-not $Path.StartsWith('/')) { return $false }
        $up = $Path
        while (-not (Test-Path -LiteralPath $up -PathType Container)) {
            $i = $up.LastIndexOf('/'); $up = if ($i -le 0) { '/' } else { $up.Substring(0, $i) }
        }
        $phys = & /bin/sh -c 'cd -P -- "$1" && pwd -P' sh $up 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $phys) { return $false }
        $list = New-Object System.Collections.Generic.List[string]
        $links = New-Object System.Collections.Generic.List[string]
        foreach ($p in @($up, [string]$phys)) {
            while ($true) {
                $list.Add($p)
                $item = Get-Item -Force -LiteralPath $p -ErrorAction SilentlyContinue
                if ($item -and $item.LinkType) { $links.Add($p) }
                if ($p -eq '/') { break }
                $i = $p.LastIndexOf('/'); $p = if ($i -le 0) { '/' } else { $p.Substring(0, $i) }
            }
        }
        $info = @(& stat -Lc '%u %a' $list 2>$null)
        if ($LASTEXITCODE -ne 0) { $info = @(& stat -Lf '%u %p' $list 2>$null) }
        if ($LASTEXITCODE -ne 0 -or $info.Count -ne $list.Count) { return $false }
        $me = [string](& id -u)
        if ($links.Count) {
            $owners = @(& stat -c '%u' $links 2>$null)
            if ($LASTEXITCODE -ne 0) { $owners = @(& stat -f '%u' $links 2>$null) }
            if ($LASTEXITCODE -ne 0 -or $owners.Count -ne $links.Count) { return $false }
            foreach ($o in $owners) { if ($o -ne '0') { return $false } }
        }
        foreach ($line in $info) {
            if ($line -notmatch '^(\d+) ([0-7]+)$') { return $false }
            $owner = $Matches[1]; $mode = [Convert]::ToInt32($Matches[2], 8)
            if ($owner -eq '0' -and ($mode -band 512)) { continue }
            if (($owner -ne '0' -and $owner -ne $me) -or ($mode -band 18)) { return $false }
        }
        return $true
    } catch { return $false }
}

# A candidate file "holds a key" when ROGUE_API_KEY is assigned a non-empty
# value - the same test every reader makes before selecting it.
function Test-RogueEnvFileHasKey {
    param([string]$Path)
    # Guard the read: -Encoding is a FileSystem-provider dynamic parameter, and a
    # Windows machine path evaluated off Windows resolves to no provider at all.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*(?:export\s+)?ROGUE_API_KEY=["'']?[^"''\s]') { return $true }
    }
    return $false
}

function Read-RogueEnvFile {
    param([string]$Path)
    if (Test-RogueEnvFile $Path -System:($Path -eq 'C:\ProgramData\rogue\env')) {
        Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}

function Format-RogueEnvValue {
    param([string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Protect-RogueEnvFile {
    param([string]$Path)
    $script:RogueEnvProtectError = ''
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $acl.SetAccessRuleProtection($true, $false)
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.SetAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        return $true
    } catch {
        $script:RogueEnvProtectError = $_.Exception.Message
        Write-Warning "Could not restrict credential file permissions: $script:RogueEnvProtectError"
        return $false
    }
}

function Write-RogueEnvFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Values,
        [switch]$RequireProtection
    )

    $managed = @($Values.Keys)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Managed by the Rogue plugins. Read by hook subprocesses at runtime.')
    $lines.Add('# Delete this file to revoke credentials.')
    foreach ($key in $managed) {
        $value = [string]$Values[$key]
        if ($value -match "[`r`n]") {
            throw "Refusing to write ${Path}: the value for $key contains a line break"
        }
        $lines.Add("export $key=$(Format-RogueEnvValue $value)")
    }

    if (Test-Path -LiteralPath $Path) {
        $owned = '^\s*(?:export\s+)?(?:' +
            (($managed | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\s*='
        $header = '^\s*# (Managed by the [Rr]ogue|Delete this file to revoke credentials)'
        foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop)) {
            if ($line -match $owned)  { continue }
            if ($line -match $header) { continue }
            $lines.Add($line)
        }
    }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $tmp = "$Path.rogue-tmp.$PID"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::WriteAllText($tmp, (($lines -join "`n") + "`n"), $utf8)
        $protected = Protect-RogueEnvFile $tmp
        if ($RequireProtection -and -not $protected) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            return $false
        }
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }

    return $protected
}
