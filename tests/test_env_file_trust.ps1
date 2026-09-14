$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts/shared/env-file.ps1')
$dir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory $dir | Out-Null
$file = Join-Path $dir 'env'
try {
    [System.IO.File]::WriteAllText($file, 'ROGUE_TEST_VALUE=trusted')
    $unix = $PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows
    if ($unix) { & chmod 600 $file }
    elseif (-not (Protect-RogueEnvFile $file)) { throw $script:RogueEnvProtectError }
    if (-not (Test-RogueEnvFile $file)) { throw 'owner-only env was rejected' }
    if ((Read-RogueEnvFile $file) -ne 'ROGUE_TEST_VALUE=trusted') { throw 'trusted env not read' }
    if ($unix) { & chmod 666 $file }
    else {
        $acl = Get-Acl -LiteralPath $file
        $everyone = New-Object System.Security.Principal.SecurityIdentifier('S-1-1-0')
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($everyone, 'Write', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $file -AclObject $acl
    }
    if (Test-RogueEnvFile $file) { throw 'world-writable env was trusted' }
    if (@(Read-RogueEnvFile $file).Count -ne 0) { throw 'unsafe env was read' }
    # A write grant to the current user is fine for the user file. The machine file
    # is rejected here on OWNERSHIP (a user-owned file is never a machine file); the
    # admins-only writer rule that ownership check sits in front of needs an
    # Administrators-owned fixture, which an unelevated test cannot create.
    # Recreate the file: the Everyone rule above is explicit, so protection alone would keep it.
    Remove-Item -LiteralPath $file -Force
    [System.IO.File]::WriteAllText($file, 'ROGUE_TEST_VALUE=trusted')
    if ($unix) { & chmod 600 $file }
    else {
        if (-not (Protect-RogueEnvFile $file)) { throw $script:RogueEnvProtectError }
        $acl = Get-Acl -LiteralPath $file
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'Write', 'Allow')))
        Set-Acl -LiteralPath $file -AclObject $acl
    }
    if (-not (Test-RogueEnvFile $file)) { throw 'user-writable user env was rejected' }
    if (Test-RogueEnvFile $file -System) { throw 'user-owned machine env was trusted' }
    if (Test-RogueEnvFile (Join-Path $dir 'missing')) { throw 'missing env was trusted' }
    Write-Host 'env-file trust: all checks passed'
} finally { Remove-Item -Recurse -Force $dir }
