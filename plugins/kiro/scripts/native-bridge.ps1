# Hand-off from a script bridge to the native bridge (rogue-hook) - SHARED, dot-sourced by every
# PowerShell hook, heartbeat, log shipper and updater. Twin of native-bridge.sh; read that file for
# the contract.
#
#   . ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $root 'scripts/native-bridge.ps1'))))
#   Invoke-RogueNativeHandoff -Root $root -Family claude -Arguments @('claude', $EventName) `
#       -Settings $vals -BudgetMs 18000 -FailOpen '{}'
#
# ONE COPY IS EDITABLE: scripts/shared/native-bridge.ps1 (see sync-shared-scripts.sh).
# Defines functions only; nothing runs at source time.

function Get-RogueNativeVersion {
    param([string]$Root)
    $pin = Join-Path $Root 'rogue-hook.json'
    if (-not (Test-Path -LiteralPath $pin -PathType Leaf)) { return '' }
    $m = [regex]::Match((Get-Content -Raw -LiteralPath $pin), '"version"\s*:\s*"([0-9][0-9A-Za-z.-]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# $Settings is the merged env (process env plus the env file in use), as in Invoke-RogueNativeHandoff.
function Get-RogueNativeDir {
    param([hashtable]$Settings)
    if ($Settings -and $Settings['ROGUE_NATIVE_BRIDGE_DIR']) { return [string]$Settings['ROGUE_NATIVE_BRIDGE_DIR'] }
    if ($env:ROGUE_NATIVE_BRIDGE_DIR) { return $env:ROGUE_NATIVE_BRIDGE_DIR }
    $home_ = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    return (Join-Path (Join-Path (Join-Path $home_ '.rogue') 'bin') 'rogue-hook')
}

function Get-RogueNativeExe {
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { return 'rogue-hook' }
    return 'rogue-hook.exe'
}

# Returns only when the script bridge should keep the job; otherwise relays the binary's stdout,
# stderr and exit code and exits.
function Invoke-RogueNativeHandoff {
    param(
        [string]$Root = '',
        [string]$Family,
        [string[]]$Arguments,
        [hashtable]$Settings,
        [int]$BudgetMs = 18000,
        [string]$FailOpen = '{}'
    )
    $setting = {
        param([string]$Name)
        if ($Settings -and $Settings.ContainsKey($Name)) { return [string]$Settings[$Name] }
        return [string][Environment]::GetEnvironmentVariable($Name)
    }
    if ($env:ROGUE_HOOK_SOURCE -eq 'managed') { return }
    if ((& $setting 'ROGUE_NATIVE_BRIDGE') -eq '0') { return }
    if ((& $setting ('ROGUE_NATIVE_BRIDGE_' + $Family.ToUpperInvariant())) -eq '0') { return }
    if (-not $Root -or -not [System.IO.Path]::IsPathRooted($Root)) { return }
    $version = Get-RogueNativeVersion $Root
    if (-not $version) { return }
    $dir = Get-RogueNativeDir $Settings
    $bin = Join-Path (Join-Path $dir $version) (Get-RogueNativeExe)
    if (-not (Test-Path -LiteralPath $bin -PathType Leaf)) {
        $installer = Join-Path $Root 'scripts/native-bridge-install.ps1'
        # Inside the retry interval the installer would stand down at once: do not start a PowerShell for it.
        $retry = if ($env:ROGUE_NATIVE_BRIDGE_RETRY -match '^[0-9]{1,9}$') { [int]$env:ROGUE_NATIVE_BRIDGE_RETRY } else { 900 }
        $stamp = Get-Item -Force -LiteralPath (Join-Path $dir ".attempt-$version") -ErrorAction SilentlyContinue
        $now = (Get-Date).ToUniversalTime()
        if ($retry -gt 0 -and $stamp -and $stamp.LastWriteTimeUtc -le $now -and $stamp.LastWriteTimeUtc -gt $now.AddSeconds(-$retry)) { return }
        if (Test-Path -LiteralPath $installer -PathType Leaf) {
            try {
                $boot = "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath '$($installer.Replace("'", "''"))'))) '$($Root.Replace("'", "''"))'"
                $shell = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh' } else { 'powershell' }
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($boot))
                $p = @{ FilePath = $shell; ArgumentList = @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) }
                if ($IsWindows -or $PSVersionTable.PSVersion.Major -lt 6) { $p.WindowStyle = 'Hidden' }
                Start-Process @p | Out-Null
            } catch {}
        }
        return
    }
    # The binary gets the payload and the API key: it runs only if no other user can replace it
    # (on Windows the ACL rule of env-file.ps1 applies to the exe; elsewhere its directory is held to it too).
    if (-not (Get-Command Test-RogueProtectedPath -ErrorAction SilentlyContinue)) {
        try { . ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $Root 'scripts/env-file.ps1') -ErrorAction Stop))) } catch { return }
    }
    $onWindows = -not ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows)
    if (-not (Test-RogueProtectedPath $bin) -or (-not $onWindows -and -not (Test-RogueProtectedPath (Split-Path -Parent $bin)))) { return }

    $quoted = ($Arguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo $bin, $quoted
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['ROGUE_PLUGIN_ROOT'] = $Root
    try { $proc = [System.Diagnostics.Process]::Start($psi) } catch { return }
    # Bytes are copied both ways untouched, so no console codepage re-encodes the payload or the
    # answer. One budget covers feeding stdin and waiting: a stuck child is killed here and the
    # event fails open instead of outliving the agent's hook timeout.
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $stdout = [Console]::OpenStandardOutput()
    $stderr = [Console]::OpenStandardError()
    # The answer is held back until the child finishes in budget: a killed child's partial answer
    # followed by the fail-open one would not parse.
    $answer = New-Object System.IO.MemoryStream
    $copyOut = $proc.StandardOutput.BaseStream.CopyToAsync($answer)
    $copyErr = $proc.StandardError.BaseStream.CopyToAsync($stderr)
    # Heartbeats, log shipping and updates read no input, and run from a hidden window whose console
    # stdin never ends: the child gets an empty stdin and as long as it needs (they are detached).
    $fed = $true
    if ($Arguments[0] -in 'heartbeat', 'ship-logs', 'update') {
        $proc.StandardInput.Close()
        $BudgetMs = [Math]::Max($BudgetMs, 600000)
    } else {
        $feed = [Console]::OpenStandardInput().CopyToAsync($proc.StandardInput.BaseStream)
        # A child that exits without reading its input (e.g. unconfigured) breaks the pipe: that counts as fed.
        try { $fed = $feed.Wait($BudgetMs) } catch {}
    }
    if ($fed) { try { $proc.StandardInput.Close() } catch {} }
    $left = [int][Math]::Max(0, $BudgetMs - $clock.ElapsedMilliseconds)
    if (-not $fed -or -not $proc.WaitForExit($left)) {
        try { $proc.Kill() } catch {}
        if ($FailOpen) { [Console]::Out.Write($FailOpen) }
        exit 0
    }
    [void]$copyOut.Wait(2000)
    [void]$copyErr.Wait(2000)
    $bytes = $answer.ToArray()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
    $stderr.Flush()
    exit $proc.ExitCode
}
