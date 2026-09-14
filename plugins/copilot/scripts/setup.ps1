# Rogue Security — credential storage helper (Windows / PowerShell) — Copilot plugin.
# Mirrors setup.sh: writes %USERPROFILE%\.rogue-env, restricted to the current
# user, in the same `export KEY=value` shell-quoted format both bridges read. The
# file is shared with the Claude/Codex/Cursor/Gemini plugins.
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
