# Installs the native bridge pinned in <plugin>\rogue-hook.json - SHARED, started detached by
# native-bridge.ps1 whenever the pinned version is missing. Twin of native-bridge-install.sh; read
# that file for the contract.
#
# ONE COPY IS EDITABLE: scripts/shared/native-bridge-install.ps1 (see sync-shared-scripts.sh).
param([string]$Root)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

if (-not $Root -or -not [System.IO.Path]::IsPathRooted($Root)) { exit 0 }
try { . ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $Root 'scripts/native-bridge.ps1') -ErrorAction Stop))) } catch { exit 0 }
$version = Get-RogueNativeVersion $Root
if (-not $version) { exit 0 }
$dir = Get-RogueNativeDir
$dest = Join-Path (Join-Path $dir $version) (Get-RogueNativeExe)
if (Test-Path -LiteralPath $dest -PathType Leaf) { exit 0 }

$home_ = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$rogueDir = Join-Path $home_ '.rogue'
New-Item -ItemType Directory -Force -Path $rogueDir, $dir | Out-Null
$logPath = Join-Path $rogueDir 'hook-binary.log'
function Say { param([string]$Msg) Add-Content -LiteralPath $logPath -Encoding UTF8 -Value "$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) rogue-hook ${version}: $Msg" }

# One attempt at a time, and not again until the retry interval has passed.
$lock = Join-Path $dir ".lock-$version"
$lockItem = Get-Item -LiteralPath $lock -ErrorAction SilentlyContinue
if ($lockItem -and $lockItem.LastWriteTimeUtc -gt (Get-Date).ToUniversalTime().AddMinutes(-10)) { exit 0 }
Remove-Item -LiteralPath $lock -Force -Recurse -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
$tmp = ''
try {
    $stamp = Join-Path $dir ".attempt-$version"
    $retry = 900
    if ($env:ROGUE_NATIVE_BRIDGE_RETRY -match '^[0-9]{1,9}$') { $retry = [int]$env:ROGUE_NATIVE_BRIDGE_RETRY }
    $last = Get-Item -LiteralPath $stamp -ErrorAction SilentlyContinue
    if ($retry -gt 0 -and $last -and $last.LastWriteTimeUtc -le (Get-Date).ToUniversalTime() -and
        $last.LastWriteTimeUtc -gt (Get-Date).ToUniversalTime().AddSeconds(-$retry)) { exit 0 }
    Set-Content -LiteralPath $stamp -Value ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())

    function Give-Up { param([string]$Why) Say "$Why; the script bridge handles events"; exit 0 }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {}

    $onWindows = -not ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows)
    if ($onWindows) {
        # An x64 PowerShell on an ARM64 machine reports AMD64 and keeps the real arch in PROCESSOR_ARCHITEW6432.
        $cpu = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
        $os = 'windows'
        $arch = switch ($cpu) { 'AMD64' { 'amd64' } 'ARM64' { 'arm64' } default { '' } }
        $platform = "windows-$arch"
    } elseif ($IsMacOS) {
        $os = 'darwin'; $arch = 'arm64'; $platform = 'darwin-universal'
    } else {
        $os = 'linux'
        $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) { 'X64' { 'amd64' } 'Arm64' { 'arm64' } default { '' } }
        $platform = "linux-$arch"
    }
    if (-not $arch) { Give-Up "unsupported architecture" }
    $m = [regex]::Match((Get-Content -Raw -LiteralPath (Join-Path $Root 'rogue-hook.json')), '"' + [regex]::Escape($platform) + '"\s*:\s*"([0-9a-f]+)"')
    if (-not $m.Success) { Give-Up "no pinned sha256 for $platform" }
    $want = $m.Groups[1].Value

    # Same env file rule as the hooks: the first trusted file holding ROGUE_API_KEY is used alone.
    try { . ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $Root 'scripts/env-file.ps1') -ErrorAction Stop))) } catch {}
    $creds = @{ ROGUE_API_KEY = $env:ROGUE_API_KEY; ROGUE_BASE_URL = $env:ROGUE_BASE_URL }
    $machine = if ($onWindows) { Join-Path $env:ProgramData 'rogue\env' } else { '/etc/rogue/env' }
    foreach ($f in @($machine, (Join-Path $Root 'env'), (Join-Path $home_ '.rogue-env'))) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        if ((Get-Command Test-RogueEnvFile -ErrorAction SilentlyContinue) -and -not (Test-RogueEnvFile $f)) { continue }
        $vals = @{}
        foreach ($line in (Get-Content -LiteralPath $f)) {
            if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $vals[$Matches[1]] = $Matches[2].Trim().Trim("'").Trim('"') }
        }
        if (-not ([string]$vals['ROGUE_API_KEY']).Trim()) { continue }
        foreach ($k in @($creds.Keys)) { if ($vals.ContainsKey($k)) { $creds[$k] = $vals[$k] } }
        break
    }
    if (-not $creds.ROGUE_API_KEY) { Give-Up 'no ROGUE_API_KEY' }
    $base = if ($creds.ROGUE_BASE_URL) { $creds.ROGUE_BASE_URL.TrimEnd('/') } else { 'https://api.rogue.security' }
    try {
        $resp = Invoke-RestMethod -Method Get -TimeoutSec 15 -Headers @{ 'x-rogue-api-key' = $creds.ROGUE_API_KEY } `
            -Uri "$base/api/v1/hooks/download?version=$version&os=$os&arch=$arch"
    } catch { Give-Up "no download URL for $platform" }
    if (-not $resp.url) { Give-Up "no download URL for $platform" }

    New-Item -ItemType Directory -Force -Path (Join-Path $dir $version) | Out-Null
    $tmp = Join-Path (Join-Path $dir $version) ".rogue-hook.download.$PID$(if ($onWindows) { '.exe' })"
    try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -Uri $resp.url -OutFile $tmp } catch { Give-Up 'download failed' }
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $tmp).Hash.ToLowerInvariant()
    if ($got -ne $want) { Give-Up "sha256 mismatch: got $got, pinned $want" }
    if (-not $onWindows) { & chmod 755 $tmp }
    # Catches a binary this machine cannot run before a hook would hand events to it.
    if ((& $tmp --version) -ne "rogue-hook $version") { Give-Up 'downloaded binary does not run here' }
    Move-Item -LiteralPath $tmp -Destination $dest -Force
    if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { Give-Up "cannot install $dest" }
    $tmp = ''
    Remove-Item -LiteralPath $stamp -Force -ErrorAction SilentlyContinue
    Say "installed ($platform)"
} finally {
    if ($tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $lock -Force -Recurse -ErrorAction SilentlyContinue
}
exit 0
