# Rogue Security — credential storage helper (Windows / PowerShell).
# Mirrors setup.sh: writes %USERPROFILE%\.rogue-env, restricted to the current
# user, in the same `export KEY=value` shell-quoted format both dispatchers read.
#
# Usage: powershell -NoProfile -File setup.ps1 <api-key> <email> <name>
param(
    [string]$ApiKey = '',
    [string]$Email = '',
    [string]$Name  = ''
)

$ErrorActionPreference = 'Stop'

$EnvFile = Join-Path $env:USERPROFILE '.rogue-env'
$MachineEnvFile = 'C:\ProgramData\rogue\env'

. ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'env-file.ps1'))))

# A trusted machine env file holding a key is read ALONE by every dispatcher,
# so $EnvFile written here would never be consulted. Nothing to do.
if ((Test-RogueEnvFileHasKey $MachineEnvFile) -and (Test-RogueEnvFile $MachineEnvFile -System)) {
    Write-Output "OK"
    Write-Output "ENV_FILE=$MachineEnvFile"
    Write-Output "Credentials come from the machine env file $MachineEnvFile - $EnvFile not written"
    exit 0
}

if (-not $ApiKey) {
    Write-Error 'Usage: setup.ps1 <api-key> <email> <name>'
    exit 1
}

$restricted = Write-RogueEnvFile -Path $EnvFile -Values ([ordered]@{
    ROGUE_API_KEY     = $ApiKey
    ROGUE_ACTOR_EMAIL = $Email
    ROGUE_ACTOR_NAME  = $Name
})

if (-not $restricted) {
    Write-Warning "Could not restrict permissions on $EnvFile"
}

Write-Output "OK"
Write-Output "ENV_FILE=$EnvFile"
