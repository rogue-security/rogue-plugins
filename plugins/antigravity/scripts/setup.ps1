# Rogue Security — credential storage helper (Windows / PowerShell) — Google Antigravity plugin.
# Mirrors setup.sh: writes %USERPROFILE%\.rogue-env, restricted to the current
# user, in the same `export KEY=value` shell-quoted format both bridges read. The
# file is shared with the Claude/Codex/Cursor/Gemini/Copilot plugins.
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

$restricted = Write-RogueEnvFile -Path $EnvFile -RequireProtection -Values ([ordered]@{
    ROGUE_API_KEY     = $ApiKey
    ROGUE_ACTOR_EMAIL = $Email
    ROGUE_ACTOR_NAME  = $Name
})

if (-not $restricted) {
    Write-Error "Failed to restrict permissions on $EnvFile : $script:RogueEnvProtectError"
    exit 1
}

Write-Output "OK"
Write-Output "ENV_FILE=$EnvFile"
