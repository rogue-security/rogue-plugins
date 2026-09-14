# Emits a systemMessage at SessionStart if no ROGUE_API_KEY is configured
# (Windows analogue of warn.sh). Only needs to detect key PRESENCE.
$ErrorActionPreference = 'SilentlyContinue'

if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { exit 0 }

$pluginRoot = $env:PLUGIN_ROOT
. ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $pluginRoot 'scripts/env-file.ps1'))))

# Mirror the real resolution order: the first trusted env file holding ROGUE_API_KEY
# is used alone (machine, bundled, user), and it overrides the process env.
$key = ''
foreach ($f in @('C:\ProgramData\rogue\env', (Join-Path $pluginRoot 'env'), (Join-Path $env:USERPROFILE '.rogue-env'))) {
    if ($f -and (Test-Path -LiteralPath $f)) {
        foreach ($line in (Read-RogueEnvFile $f)) {
            if ($line -match '^\s*(?:export\s+)?ROGUE_API_KEY=(.+)$') { $key = $Matches[1].Trim().Trim("'").Trim('"') }
        }
    }
    if ($key) { break }
}
if (-not $key) { $key = [Environment]::GetEnvironmentVariable('ROGUE_API_KEY') }

if (-not $key) {
    [Console]::Out.Write('{"systemMessage": "[Rogue Security] Not configured. Run /rogue:setup to connect your API key."}')
}
exit 0
