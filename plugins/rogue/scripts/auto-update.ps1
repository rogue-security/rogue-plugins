# Silent plugin auto-updater (Windows / PowerShell).
#
# Native-Windows analogue of auto-update.sh. Launched DETACHED from the
# SessionStart hook so it never blocks Claude Code startup. Compares the installed
# plugin version against the "claude" key of the latest release's versions.json;
# if newer, re-runs the PowerShell one-line installer to upgrade in place. New
# version takes effect on the next session.
#
# Opt-outs:
#   ROGUE_AUTO_UPDATE=0       - disable entirely
#   ROGUE_PLUGIN_VERSION=<release> - pinned, never updates
#
# Runs at most once per 24h (cached in %USERPROFILE%\.rogue\.auto-update-check).
# Silent on every failure path. All activity logs to
# %USERPROFILE%\.rogue\auto-update.log for diagnostics.

# ── Pure helpers, above the seam ─────────────────────────────────────────────
# These sit above BOTH the stand-down and the ROGUE_PS_LIB_ONLY seam so
# tests/test_auto_update_ps1.ps1 can dot-source them on Linux. Below the
# stand-down they would never be defined there.

# GitHub serves every release asset as application/octet-stream with an
# attachment disposition (verified against a real asset). On Windows PowerShell
# 5.1 that makes Invoke-WebRequest return a WebResponseObject whose .Content is a
# BYTE ARRAY, not a string - pwsh 7 always gives a string. Coercing that byte[]
# into a [string] parameter yields "123 34 115 ..." and every regex below misses,
# so without this decode the updater would log "could not resolve" and silently
# never update on Windows, forever, while macOS worked fine. Body, not param
# type, because a [string] param would have already done the bad coercion.
function ConvertTo-RogueText {
    param($Body)
    if ($null -eq $Body) { return '' }
    if ($Body -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($Body) }
    return [string]$Body
}

# Read one slug's version out of the manifest by regex rather than
# ConvertFrom-Json, so the compact and pretty-printed forms behave identically and
# a malformed body is a null instead of a throw. Mirrors the sh half's grep.
function Get-RogueManifestVersion {
    param($Json, [string]$Slug)
    $text = ConvertTo-RogueText $Json
    if (-not $text) { return $null }
    $m = [regex]::Match($text, '"' + [regex]::Escape($Slug) + '"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# True when $Latest is strictly newer than $Installed. The old code compared the
# release tag to "v$installed" with string equality, which cannot tell newer from
# older: once a release name stops carrying a version, a manifest BEHIND the
# install would re-run the installer every 24h forever.
function Test-RogueNewer {
    param([string]$Installed, [string]$Latest)
    try { return ([version]$Latest -gt [version]$Installed) } catch { return $false }
}

if ($env:ROGUE_PS_LIB_ONLY) { return }

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

# Stand down on non-Windows (auto-update.sh runs on macOS/Linux).
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { exit 0 }
if (-not $env:CLAUDE_CODE_ENTRYPOINT) { exit 0 }

$rogueDir = Join-Path $env:USERPROFILE '.rogue'
try { if (-not (Test-Path -LiteralPath $rogueDir)) { New-Item -ItemType Directory -Path $rogueDir -Force | Out-Null } } catch { exit 0 }
$log = Join-Path $rogueDir 'auto-update.log'
function LogLine { param([string]$M) try { Add-Content -LiteralPath $log -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + " $M") -Encoding UTF8 } catch {} }
LogLine '--- auto-update tick (windows) ---'

try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# Pull creds/flags from the same files the hooks read (values may carry shell
# quoting, but the only flags we read here are simple tokens).
function ReadEnvVar {
    param([string]$Key)
    # Same rule as the dispatcher: the first env file holding ROGUE_API_KEY is used
    # alone (machine, bundled, user) and overrides the process env. The bundled
    # ${CLAUDE_PLUGIN_ROOT}\env is where compiled/managed plugins pin flags like
    # ROGUE_AUTO_UPDATE=0 / ROGUE_PLUGIN_VERSION.
    $files = @('C:\ProgramData\rogue\env')
    if ($env:CLAUDE_PLUGIN_ROOT) { $files += (Join-Path $env:CLAUDE_PLUGIN_ROOT 'env') }
    $files += (Join-Path $env:USERPROFILE '.rogue-env')
    foreach ($f in $files) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $vals = @{}
        foreach ($line in (Get-Content -LiteralPath $f)) {
            if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
                $vals[$Matches[1]] = $Matches[2].Trim().Trim("'").Trim('"')
            }
        }
        if (-not $vals['ROGUE_API_KEY']) { continue }
        if ($vals.ContainsKey($Key)) { return $vals[$Key] }
        break
    }
    return [Environment]::GetEnvironmentVariable($Key)
}

if ((ReadEnvVar 'ROGUE_AUTO_UPDATE') -eq '0') { LogLine 'ROGUE_AUTO_UPDATE=0, skipping'; exit 0 }
$pin = ReadEnvVar 'ROGUE_PLUGIN_VERSION'
if ($pin) { LogLine "ROGUE_PLUGIN_VERSION=$pin pinned, skipping"; exit 0 }

# Rate-limit to once per day.
$cache = Join-Path $rogueDir '.auto-update-check'
if (Test-Path -LiteralPath $cache) {
    $age = (Get-Date) - (Get-Item -LiteralPath $cache).LastWriteTime
    if ($age.TotalSeconds -lt 86400) { LogLine 'checked within TTL, skipping'; exit 0 }
}
try { Set-Content -LiteralPath $cache -Value '' -Encoding ASCII } catch {}

# ROGUE_PLUGIN_REPO is load-bearing beyond its default: rogue-ui's
# hooks-matcher.ts whitelists Rogue's own updater by matching a repo slug AND one
# of ROGUE_NON_INTERACTIVE / ROGUE_AUTO_UPDATE / ROGUE_INSTALLER_URL /
# ROGUE_PLUGIN_REPO.
$repo = ReadEnvVar 'ROGUE_PLUGIN_REPO'; if (-not $repo) { $repo = 'rogue-security/rogue-plugins' }

$pluginRoot = $env:CLAUDE_PLUGIN_ROOT
$pj = Join-Path $pluginRoot '.claude-plugin\plugin.json'
if (-not (Test-Path -LiteralPath $pj)) { LogLine "no plugin.json at $pj"; exit 0 }
$m = [regex]::Match((Get-Content -Raw -LiteralPath $pj), '"version"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)')
if (-not $m.Success) { LogLine 'no installed version found'; exit 0 }
$installed = $m.Groups[1].Value

# The release NAME is not a version - the monorepo ships six independently
# versioned plugins. versions.json is the contract; this plugin's key is "claude".
$manifestUrl = "https://github.com/$repo/releases/latest/download/versions.json"
try {
    $body = (Invoke-WebRequest -Uri $manifestUrl -UseBasicParsing `
        -Headers @{ 'User-Agent' = 'rogue-auto-update' } -TimeoutSec 5 -ErrorAction Stop).Content
} catch { LogLine "could not fetch $manifestUrl"; exit 0 }
$latest = Get-RogueManifestVersion -Json $body -Slug 'claude'
if (-not $latest) { LogLine 'could not resolve latest claude version from the manifest'; exit 0 }

if (-not (Test-RogueNewer -Installed $installed -Latest $latest)) {
    LogLine "up to date at $installed (manifest says $latest)"; exit 0
}
LogLine "upgrade available: $installed -> $latest, running installer"
$installerUrl = ReadEnvVar 'ROGUE_INSTALLER_URL'
if (-not $installerUrl) { $installerUrl = 'https://raw.githubusercontent.com/rogue-security/rogue-plugins/main/install.ps1' }
try {
    $script = (Invoke-WebRequest -Uri $installerUrl -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop).Content
    $env:ROGUE_NON_INTERACTIVE = '1'
    & ([scriptblock]::Create($script))
    LogLine "installer finished"
} catch { LogLine "installer failed: $($_.Exception.Message)" }
