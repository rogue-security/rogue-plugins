# Installs the native hook dispatcher pinned in rogue-hook.json as
# %CLAUDE_PLUGIN_DATA%\rogue-hook.exe (Windows twin of hook-binary.sh). hook.ps1 hands
# every event to that binary when it exists. Fired detached from SessionStart.
# Fail-safe: whenever no binary matching the pin is installed, hook.ps1 keeps handling
# events itself.
#
# The binary is downloaded through GET /api/v1/hooks/binary with the API key and must
# match the pinned sha256 and report the pinned version before it replaces anything.
# The last run's outcome is written to ~/.rogue/hook-binary.log.

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { exit 0 }
if (-not $env:CLAUDE_CODE_ENTRYPOINT -or -not $env:CLAUDE_PLUGIN_DATA -or -not $env:CLAUDE_PLUGIN_ROOT) { exit 0 }

$bin = Join-Path $env:CLAUDE_PLUGIN_DATA 'rogue-hook.exe'
$rogueDir = Join-Path $env:USERPROFILE '.rogue'
New-Item -ItemType Directory -Force -Path $rogueDir | Out-Null
$logPath = Join-Path $rogueDir 'hook-binary.log'
Set-Content -LiteralPath $logPath -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Encoding UTF8
function Log { param([string]$Msg) Add-Content -LiteralPath $logPath -Value $Msg -Encoding UTF8 }
function Use-Scripts {
    param([string]$Why)
    Remove-Item -LiteralPath $bin -Force -ErrorAction SilentlyContinue
    Log "$Why; hook.ps1 handles events"
    exit 0
}

try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

$pinPath = Join-Path $env:CLAUDE_PLUGIN_ROOT 'rogue-hook.json'
$pin = if (Test-Path -LiteralPath $pinPath) { Get-Content -Raw -LiteralPath $pinPath | ConvertFrom-Json }
$version = if ($pin) { [string]$pin.version } else { '' }
if (-not $version) { Use-Scripts 'no pinned version' }

# An x64 PowerShell on an ARM64 machine reports AMD64 and keeps the real arch in PROCESSOR_ARCHITEW6432.
$cpu = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$arch = switch ($cpu) { 'AMD64' { 'amd64' } 'ARM64' { 'arm64' } default { '' } }
if (-not $arch) { Use-Scripts "unsupported architecture $cpu" }
$want = [string]$pin.sha256."windows-$arch"
if (-not $want) { Use-Scripts "no pinned sha256 for windows-$arch" }

function Get-Sha256 { param([string]$Path) (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }

if ((Test-Path -LiteralPath $bin) -and (Get-Sha256 $bin) -eq $want) {
    Log "rogue-hook $version already installed"
    exit 0
}
# Never leave a binary that does not match the pin in charge while the download runs.
# A running exe cannot be deleted but can be renamed out of the way.
$stale = "$bin.old"
Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $bin) {
    Move-Item -LiteralPath $bin -Destination $stale -Force
    if (Test-Path -LiteralPath $bin) { Use-Scripts "cannot replace $bin" }
}

# Same env file rule as hook.ps1: the first trusted file holding ROGUE_API_KEY is used alone.
function Read-RogueEnvFile { param([string]$Path) }
try { . ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $env:CLAUDE_PLUGIN_ROOT 'scripts/env-file.ps1') -ErrorAction Stop))) } catch {}
$creds = @{ ROGUE_API_KEY = $env:ROGUE_API_KEY; ROGUE_BASE_URL = $env:ROGUE_BASE_URL }
foreach ($f in @('C:\ProgramData\rogue\env', (Join-Path $env:CLAUDE_PLUGIN_ROOT 'env'), (Join-Path $env:USERPROFILE '.rogue-env'))) {
    if (-not (Test-Path -LiteralPath $f)) { continue }
    $vals = @{}
    foreach ($line in (Read-RogueEnvFile $f)) {
        if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.*)$') { $vals[$Matches[1]] = $Matches[2].Trim().Trim("'").Trim('"') }
    }
    if (-not ([string]$vals['ROGUE_API_KEY']).Trim()) { continue }
    foreach ($k in @($creds.Keys)) { if ($vals.ContainsKey($k)) { $creds[$k] = $vals[$k] } }
    break
}
if (-not $creds.ROGUE_API_KEY) { Use-Scripts 'no ROGUE_API_KEY' }

$base = if ($creds.ROGUE_BASE_URL) { $creds.ROGUE_BASE_URL.TrimEnd('/') } else { 'https://api.rogue.security' }
try {
    $resp = Invoke-RestMethod -Method Get -TimeoutSec 15 -Headers @{ 'x-rogue-api-key' = $creds.ROGUE_API_KEY } `
        -Uri "$base/api/v1/hooks/binary?version=$version&os=windows&arch=$arch"
} catch { Use-Scripts "no download URL for rogue-hook $version windows-${arch}: $($_.Exception.Message)" }
if (-not $resp.url) { Use-Scripts "no download URL for rogue-hook $version windows-$arch" }

New-Item -ItemType Directory -Force -Path $env:CLAUDE_PLUGIN_DATA | Out-Null
$tmp = "$bin.download.$PID.exe"
try {
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri $resp.url -OutFile $tmp
    $got = Get-Sha256 $tmp
    if ($got -ne $want) { Use-Scripts "sha256 mismatch: got $got, pinned $want" }
    # Catches a binary this machine cannot run before hook.ps1 would hand events to it.
    if ((& $tmp --version) -ne "rogue-hook $version") { Use-Scripts 'downloaded binary does not run here' }
    Move-Item -LiteralPath $tmp -Destination $bin -Force
    if (-not (Test-Path -LiteralPath $bin)) { Use-Scripts "cannot install $bin" }
    Log "installed rogue-hook $version (windows-$arch)"
} catch {
    Use-Scripts "download failed: $($_.Exception.Message)"
} finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
exit 0
