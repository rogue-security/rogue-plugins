# A Windows PowerShell child can inherit PowerShell 7's PSModulePath. Load
# this engine's ACL cmdlets explicitly instead of resolving an incompatible module.
if ($PSVersionTable.PSVersion.Major -eq 5) {
    Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
}

# Reject files writable by identities other than the current user or Windows
# administrators/system. System-wide configuration cannot be user-owned.
function Test-RogueEnvFile {
    param([string]$Path, [switch]$System)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
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
            if ($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $write) -and
                $rule.IdentityReference.Value -notin $writers) { return $false }
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
