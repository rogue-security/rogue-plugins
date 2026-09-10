# Rogue Security — credential storage helper (Windows / PowerShell).
# Mirrors setup.sh: writes %USERPROFILE%\.rogue-env, restricted to the current
# user, in the same `export KEY=value` shell-quoted format both dispatchers read.
#
# Usage: powershell -NoProfile -File setup.ps1 <api-key> <email> <name>
param(
    [Parameter(Mandatory = $true)][string]$ApiKey,
    [string]$Email = '',
    [string]$Name  = ''
)

$ErrorActionPreference = 'Stop'

$EnvFile = Join-Path $env:USERPROFILE '.rogue-env'

. ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'env-file.ps1'))))

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
