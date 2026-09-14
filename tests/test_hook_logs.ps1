#!/usr/bin/env pwsh
# PowerShell half of the hook-log contract test (see CLAUDE.md § "The hook log").
# The sh/mjs half is tests/test_hook_logs.sh — same assertions, other dispatchers.
#
# One file per agent under %USERPROFILE%\.rogue\logs\, one shared line format, one
# rotation policy — across all five PowerShell dispatchers. The contract is
# duplicated five times (the repo has no shared library), so a copy/paste drift in
# any one of them is invisible until a Windows customer's log is read.
#
# Runs on macOS/Linux too: each dispatcher exposes its logging helpers above a
# ROGUE_PS_LIB_ONLY seam, and each falls back from USERPROFILE to $HOME. That is
# what lets .github/workflows/validate.yml cover the Windows-only code paths on a
# Linux runner.
#
# Two layers, because a PowerShell dispatcher's MAIN BODY stands down on
# non-Windows and so cannot be exercised here:
#   * behavioural — call Initialize-Logging / Log directly through the seam.
#   * structural  — assert each dispatcher WIRES that up correctly (log vars in
#     the process-env override list; Initialize-Logging called after the
#     credential files are parsed and before the API-key check).
#
#   pwsh -NoProfile -File tests/test_hook_logs.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$probe = Join-Path $repo 'tests/log_probe.ps1'
$failures = 0

$cases = @(
    @{ slug = 'claude';      path = 'plugins/rogue/scripts/hook.ps1';       event = 'PreToolUse' }
    @{ slug = 'codex';       path = 'plugins/codex/scripts/hook.ps1';       event = 'PreToolUse' }
    @{ slug = 'cursor';      path = 'plugins/cursor/scripts/hook.ps1';      event = 'preToolUse' }
    @{ slug = 'copilot';     path = 'plugins/copilot/scripts/hook.ps1';     event = 'preToolUse' }
    @{ slug = 'antigravity'; path = 'plugins/antigravity/scripts/hook.ps1'; event = 'PreToolUse' }
    @{ slug = 'kiro';        path = 'plugins/kiro/scripts/hook.ps1';        event = 'PreToolUse' }
)

function Pass { param([string]$M) Write-Host "  ok: $M" }
function Fail { param([string]$M) Write-Host "FAIL: $M"; $script:failures++ }
function Check {
    param([string]$Label, [string]$Expected, [string]$Actual)
    if ($Expected -eq $Actual) { Pass $Label } else { Fail "$Label (expected [$Expected], got [$Actual])" }
}

# Run the probe for one case in a child pwsh and return its KEY=value output as a
# hashtable. USERPROFILE/HOME are set for the CHILD only; every ROGUE_LOG_* is
# blanked in the child's process env so a value exported in the developer's own
# shell can never leak in — overrides are injected through -Creds instead, which
# is exactly the map the dispatchers build from their env files.
function Invoke-Probe {
    param(
        [hashtable]$Case,
        [string]$CaseHome,
        [hashtable]$Creds = @{},
        [int]$SeedBytes = 0,
        [string]$SeedPrevious = '',
        [string]$Surface = '<default>',   # override the dispatcher's $script:surface
        [switch]$NoUserProfile      # prove the USERPROFILE -> $HOME fallback
    )

    $envOverrides = @{
        USERPROFILE         = if ($NoUserProfile) { '' } else { $CaseHome }
        HOME                = $CaseHome
        ROGUE_LOG_FILE      = ''
        ROGUE_LOG_DIR       = ''
        ROGUE_LOG_MAX_BYTES = ''
    }
    $saved = @{}
    foreach ($k in $envOverrides.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $envOverrides[$k])
    }
    try {
        # -SeedPrevious is appended ONLY when it has a value. Windows PowerShell 5.1
        # DROPS an empty string when it builds a native command's argument list, so
        # `-SeedPrevious ''` reached the probe as a bare `-SeedPrevious` and failed
        # with "Missing an argument for parameter 'SeedPrevious'". pwsh 7 passes it as
        # `""`, which is why this only surfaced once these suites ran under 5.1 too.
        # The probe's default for it is '' anyway, so omitting it is exact.
        $argv = @('-NoProfile', '-File', $probe,
                  '-Dispatcher', (Join-Path $repo $Case.path),
                  '-EventName', $Case.event,
                  '-CredsB64', [Convert]::ToBase64String(
                      [System.Text.Encoding]::UTF8.GetBytes(($Creds | ConvertTo-Json -Compress))),
                  '-SeedBytes', $SeedBytes)
        if ($SeedPrevious) { $argv += @('-SeedPrevious', $SeedPrevious) }
        # Appended only when set: Windows PowerShell 5.1 DROPS an empty native-command
        # argument, which would shift every later positional and is why the sibling
        # arguments above are conditional too.
        if ($Surface -ne '<default>') { $argv += @('-Surface', $Surface) }
        $out = & (Get-Process -Id $PID).Path @argv 2>$null
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }

    $facts = @{}
    foreach ($line in @($out)) {
        if ($line -match '^([A-Z]+)=(.*)$') { $facts[$Matches[1]] = $Matches[2] }
    }
    return $facts
}

function New-CaseHome {
    param([string]$Name)
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-logtest-" + $Name + "-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

$homes = @()
try {

Write-Host "== default path: one file per agent under <home>/.rogue/logs/"
foreach ($c in $cases) {
    $h = New-CaseHome "default-$($c.slug)"; $homes += $h
    $f = Invoke-Probe -Case $c -CaseHome $h
    $expected = Join-Path (Join-Path (Join-Path $h '.rogue') 'logs') "$($c.slug).log"
    Check "$($c.slug) resolves <home>/.rogue/logs/$($c.slug).log" $expected $f['LOGFILE']
}

Write-Host ""
Write-Host "== USERPROFILE unset falls back to `$HOME (non-Windows only)"
# SKIPPED ON WINDOWS, deliberately. The fallback under test is for pwsh on macOS and
# Linux, where USERPROFILE does not exist; on Windows USERPROFILE is always set, so the
# branch is unreachable in practice. It is also not expressible here: the `$HOME` the
# dispatchers fall back to is PowerShell's AUTOMATIC variable, which Windows builds at
# session start from HOMEDRIVE + HOMEPATH and never from $env:HOME — so the child cannot
# be steered into the sandbox by this fixture, and a run with USERPROFILE stripped
# produced no probe output at all rather than a wrong path. Asserting it there would be
# testing the fixture, not the product.
if ($PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows) {
    Write-Host '  skip: USERPROFILE is always set on Windows; the fallback is a POSIX path'
} else {
    foreach ($c in $cases) {
        $h = New-CaseHome "nouserprofile-$($c.slug)"; $homes += $h
        $f = Invoke-Probe -Case $c -CaseHome $h -NoUserProfile
        $expected = Join-Path (Join-Path (Join-Path $h '.rogue') 'logs') "$($c.slug).log"
        Check "$($c.slug) still resolves a log path" $expected $f['LOGFILE']
    }
}

Write-Host ""
Write-Host "== ROGUE_LOG_DIR from the credential map relocates, keeping the basename"
foreach ($c in $cases) {
    $h = New-CaseHome "dir-$($c.slug)"; $homes += $h
    $custom = Join-Path $h 'custom'
    $f = Invoke-Probe -Case $c -CaseHome $h -Creds @{ ROGUE_LOG_DIR = $custom }
    Check "$($c.slug) honors ROGUE_LOG_DIR" (Join-Path $custom "$($c.slug).log") $f['LOGFILE']
}

Write-Host ""
Write-Host "== ROGUE_LOG_FILE (exact path) beats ROGUE_LOG_DIR"
foreach ($c in $cases) {
    $h = New-CaseHome "file-$($c.slug)"; $homes += $h
    $exact = Join-Path $h 'exact.log'
    $f = Invoke-Probe -Case $c -CaseHome $h -Creds @{ ROGUE_LOG_FILE = $exact; ROGUE_LOG_DIR = (Join-Path $h 'custom') }
    Check "$($c.slug) honors ROGUE_LOG_FILE over ROGUE_LOG_DIR" $exact $f['LOGFILE']
}

Write-Host ""
Write-Host "== cap parsing: default / zero / zero-padded zero / non-numeric"
foreach ($c in $cases) {
    $h = New-CaseHome "cap-$($c.slug)"; $homes += $h
    Check "$($c.slug) default cap is 10 MiB" '10485760' (Invoke-Probe -Case $c -CaseHome $h)['CAP']
    Check "$($c.slug) cap 0 disables rotation" '0' (Invoke-Probe -Case $c -CaseHome $h -Creds @{ ROGUE_LOG_MAX_BYTES = '0' })['CAP']
    # "00" must read as zero, matching hook.sh's `-gt 0` and Node's Number("00").
    Check "$($c.slug) cap 00 also reads as zero" '0' (Invoke-Probe -Case $c -CaseHome $h -Creds @{ ROGUE_LOG_MAX_BYTES = '00' })['CAP']
    # A typo must NOT silently disable the disk cap.
    Check "$($c.slug) non-numeric cap falls back to the default" '10485760' (Invoke-Probe -Case $c -CaseHome $h -Creds @{ ROGUE_LOG_MAX_BYTES = 'abc' })['CAP']
    # All digits, but far too wide for a signed 64-bit int. This case PASSED
    # before the fix too, and that is the point of keeping it: the plain [int64]
    # cast raised an error, $ErrorActionPreference = 'SilentlyContinue' ate it,
    # the assignment was skipped and the cap kept its default by accident. It
    # pins the value so a future change (a different preference, a different
    # initial value) cannot turn the accident into rotation-off. The sh
    # dispatchers' 18-digit clamp and Node's isSafeInteger reach the same
    # number deliberately, where the same input WAS a live bug.
    $huge = '9' * 400
    Check "$($c.slug) unrepresentable cap falls back to the default" '10485760' (Invoke-Probe -Case $c -CaseHome $h -Creds @{ ROGUE_LOG_MAX_BYTES = $huge })['CAP']
}

Write-Host ""
Write-Host "== line format: '<ts> provider=<slug> event=<Event> …' with NO BOM"
foreach ($c in $cases) {
    $h = New-CaseHome "fmt-$($c.slug)"; $homes += $h
    $f = Invoke-Probe -Case $c -CaseHome $h
    # A UTC ISO-8601 second-precision stamp with no fractional part: the shipper's
    # line splitter and the backend's parser both key off it.
    # `surface=` is OPTIONAL, so the shape allows it and the dedicated section
    # below pins which plugin emits which slug. Through the seam a single-surface
    # plugin shows its constant while a per-session one is still empty, and both
    # are well-formed lines.
    $want = "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z provider=$($c.slug)( surface=[a-z_]+)? event=$($c.event) outcome=probe$"
    # The FIRST physical line, not $f['LAST']: a dispatcher that emitted a
    # leading blank line (or any preamble) would still put a well-formed record
    # last and pass. The probe fires one event, so line 0 IS that record.
    $firstLine = @([System.IO.File]::ReadAllLines($f['LOGFILE']))[0]
    if ($firstLine -match $want) { Pass "$($c.slug) line is '<ts> provider=$($c.slug) event=$($c.event) …'" }
    else { Fail "$($c.slug) line shape [$firstLine]" }
    # EF BB BF here would break any parser anchored on the timestamp.
    if ($f['HEAD'] -eq 'EF BB BF') { Fail "$($c.slug) log starts with a UTF-8 BOM" }
    else { Pass "$($c.slug) log has no UTF-8 BOM (head: $($f['HEAD']))" }
}

Write-Host ""
Write-Host "== the optional surface token"
# Each dispatcher's file-scope default is what a probe sees: a single-surface plugin
# hard-codes its slug, while one that detects per session leaves it empty until the
# MAIN BODY resolves it (below the seam, so never here). Both are asserted, then the
# emit shape is forced both ways with -Surface.
$surfaceDefaults = @{
    claude = ''; codex = ''; antigravity = ''   # resolved per session in the main body
    kiro = ''                                   # an install-time argument, read in the main body
    cursor = 'cursor'; copilot = 'github_copilot'
}
foreach ($c in $cases) {
    $h = New-CaseHome "surface-$($c.slug)"; $homes += $h
    $f = Invoke-Probe -Case $c -CaseHome $h
    Check "$($c.slug) file-scope surface default" $surfaceDefaults[$c.slug] $f['SURFACE']

    # A resolved surface lands directly after provider= and before event=, so a
    # reader scanning for the next `key=` gets the whole value.
    $f = Invoke-Probe -Case $c -CaseHome $h -Surface 'desktop'
    $want = "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z provider=$($c.slug) surface=desktop event=$($c.event) outcome=probe$"
    if (@([System.IO.File]::ReadAllLines($f['LOGFILE']))[-1] -match $want) {
        Pass "$($c.slug) stamps surface= between provider= and event="
    } else { Fail "$($c.slug) surface placement [$($f['LAST'])]" }

    # An UNDETERMINED surface omits the whole token. `surface=` with nothing after
    # it, or `surface=unknown`, would both be worse than saying nothing: a reader
    # cannot tell either from a real value, and every line written by a version
    # before this one has no token at all.
    $f = Invoke-Probe -Case $c -CaseHome $h -Surface '<none>'   # see log_probe.ps1: 5.1 drops an empty argument
    $wantBare = "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z provider=$($c.slug) event=$($c.event) outcome=probe$"
    if (@([System.IO.File]::ReadAllLines($f['LOGFILE']))[-1] -match $wantBare) {
        Pass "$($c.slug) omits the token when the surface is unknown"
    } else { Fail "$($c.slug) emitted a placeholder surface [$($f['LAST'])]" }
}

Write-Host ""
Write-Host "== claude's surface table is ONE table, shared with the heartbeat"
# The whole point of plugins/rogue/scripts/surface.ps1: hook.ps1 stamps the slug and
# heartbeat.ps1 sends the label, and a copy in each would eventually drift - leaving
# a log line and the roster row for one session naming different surfaces. Mirrors
# the sh half in tests/test_hook_logs.sh.
. (Join-Path $repo 'plugins/rogue/scripts/surface.ps1')
foreach ($row in @(
    @{ ep = 'cli';               slug = 'cli';     label = 'Claude Code - CLI' ; agent = 'claude_code' },
    @{ ep = 'desktop';           slug = 'desktop'; label = 'Claude Code - Desktop' ; agent = 'claude_code_desktop' },
    @{ ep = 'cowork';            slug = 'cowork';  label = 'Claude Cowork' ; agent = 'claude_cowork' },
    @{ ep = 'CLI';               slug = 'cli';     label = 'Claude Code - CLI' ; agent = 'claude_code' },
    @{ ep = 'vscode-extension';  slug = 'cli';     label = 'Claude Code - CLI' ; agent = 'claude_code' },
    @{ ep = '';                  slug = '';        label = 'Claude Code - CLI' ; agent = 'claude_code' }
)) {
    $env:CLAUDE_CODE_ENTRYPOINT = $row.ep
    Check "entrypoint '$($row.ep)' -> slug '$($row.slug)'" $row.slug ([string](Get-RogueSurfaceSlug))
    Check "entrypoint '$($row.ep)' -> label '$($row.label)'" $row.label ([string](Get-RogueSurfaceLabel))
    Check "entrypoint '$($row.ep)' -> agent id '$($row.agent)'" $row.agent ([string](Get-RogueSurfaceAgentId))
}
Remove-Item Env:CLAUDE_CODE_ENTRYPOINT -ErrorAction SilentlyContinue

# CLAUDE_CODE_IS_COWORK wins over the entrypoint, in all three projections - Cowork
# spawns Claude Code with CLAUDE_CODE_ENTRYPOINT=local-agent, not a *cowork* value,
# so the entrypoint alone files a LOCAL Cowork session under the CLI. Mirrors the sh
# half; any drift between the twins is a per-platform behaviour difference.
$env:CLAUDE_CODE_IS_COWORK = '1'
$env:CLAUDE_CODE_ENTRYPOINT = 'local-agent'
Check "IS_COWORK=1 + entrypoint=local-agent -> slug"     'cowork'        ([string](Get-RogueSurfaceSlug))
Check "IS_COWORK=1 + entrypoint=local-agent -> agent id" 'claude_cowork' ([string](Get-RogueSurfaceAgentId))
Check "IS_COWORK=1 + entrypoint=local-agent -> label"    'Claude Cowork' ([string](Get-RogueSurfaceLabel))
Remove-Item Env:CLAUDE_CODE_IS_COWORK -ErrorAction SilentlyContinue
Check "entrypoint=local-agent WITHOUT the marker is claude_code" 'claude_code' ([string](Get-RogueSurfaceAgentId))
Remove-Item Env:CLAUDE_CODE_ENTRYPOINT -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "== rotation at the cap, including over an EXISTING .1"
foreach ($c in $cases) {
    $h = New-CaseHome "rot-$($c.slug)"; $homes += $h
    # Seed 300B against a 100B cap. The comparison is `>=`, so keep the seed
    # clearly above the cap rather than on the boundary. SeedPrevious makes this
    # the SECOND rotation, which is where `Move-Item -Force` alone is unreliable
    # on Windows PowerShell 5.1 — if it fails, the live log never gets trimmed.
    $f = Invoke-Probe -Case $c -CaseHome $h -Creds @{ ROGUE_LOG_MAX_BYTES = '100' } `
                      -SeedBytes 300 -SeedPrevious 'STALE-PREVIOUS-GENERATION'
    Check "$($c.slug) rotated the old log to $($c.slug).log.1" 'True' $f['ROTATED']
    Check "$($c.slug) started a fresh log (1 line)" '1' $f['LINES']
    if ($f['PREVIOUS'] -eq 'STALE-PREVIOUS-GENERATION') {
        Fail "$($c.slug) left the stale .1 in place - rotation silently no-oped"
    } else { Pass "$($c.slug) replaced the previous .1 generation" }
}

Write-Host ""
Write-Host "== cap 0 disables rotation entirely"
foreach ($c in $cases) {
    $h = New-CaseHome "norot-$($c.slug)"; $homes += $h
    $f = Invoke-Probe -Case $c -CaseHome $h -Creds @{ ROGUE_LOG_MAX_BYTES = '0' } -SeedBytes 300
    Check "$($c.slug) created no .log.1" 'False' $f['ROTATED']
    # The 300B seed has no trailing newline, so the appended line lands on the
    # same physical line: still 1 line, but the seed text must survive.
    Check "$($c.slug) kept the over-cap content" 'True' ([string]($f['LAST'] -like 'sss*'))
}

Write-Host ""
Write-Host "== no dispatcher resolves the legacy shared hook.log"
foreach ($c in $cases) {
    $h = New-CaseHome "legacy-$($c.slug)"; $homes += $h
    $f = Invoke-Probe -Case $c -CaseHome $h
    if ($f['LOGFILE'] -like '*hook.log') { Fail "$($c.slug) still points at hook.log [$($f['LOGFILE'])]" }
    else { Pass "$($c.slug) no longer points at hook.log" }
}

# ── structural: the main body must WIRE UP what the behavioural cases prove ──
# Initialize-Logging reading $Creds is worthless if a dispatcher never passes it
# the merged map, or builds that map without the log keys. Neither is reachable
# through the seam (the main body stands down off-Windows), so assert the source.
Write-Host ""
Write-Host "== wiring: log vars in the process-env base list, init after creds"
foreach ($c in $cases) {
    $src = Get-Content -Raw -LiteralPath (Join-Path $repo $c.path)

    $missing = @('ROGUE_LOG_FILE', 'ROGUE_LOG_DIR', 'ROGUE_LOG_MAX_BYTES') |
        Where-Object { $src -notmatch [regex]::Escape("'$_'") }
    if ($missing) { Fail "$($c.slug) never reads $($missing -join ', ') from the process env" }
    else { Pass "$($c.slug) lists all three ROGUE_LOG_* in its process-env base list" }

    # The call must pass an argument — a bare `Initialize-Logging` would silently
    # fall back to an empty map and ignore every env file.
    if ($src -match '(?m)^\s*Initialize-Logging\s+\S') {
        Pass "$($c.slug) calls Initialize-Logging with the credential map"
    } else {
        Fail "$($c.slug) calls Initialize-Logging with no argument (env files ignored)"
    }

    # Ordering: credentials parsed, THEN logging initialised, THEN the API-key
    # check that logs `outcome=unconfigured`.
    $lines = $src -split "\r?\n"
    $credsIdx = ($lines | Select-String -Pattern 'GetEnvironmentVariable' | Select-Object -First 1).LineNumber
    $initIdx  = ($lines | Select-String -Pattern '^\s*Initialize-Logging\s+\S' | Select-Object -First 1).LineNumber
    if ($credsIdx -and $initIdx -and $initIdx -gt $credsIdx) {
        Pass "$($c.slug) initialises logging after the credential map is built"
    } else {
        Fail "$($c.slug) initialises logging at line $initIdx, creds at $credsIdx"
    }
}

} finally {
    foreach ($h in $homes) { Remove-Item -Recurse -Force $h -ErrorAction SilentlyContinue }
}

Write-Host ""
if ($failures -eq 0) {
    Write-Host "All hook-log contract tests passed (PowerShell)."
    exit 0
}
Write-Host "$failures failure(s)."
exit 1
