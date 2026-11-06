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
    $m = [regex]::Match((Get-Content -Raw -LiteralPath $pin), '"version"\s*:\s*"([0-9][0-9A-Za-z.+-]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Get-RogueNativeDir {
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
        [string]$Root,
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
    $bin = Join-Path (Join-Path (Get-RogueNativeDir) $version) (Get-RogueNativeExe)
    if (-not (Test-Path -LiteralPath $bin -PathType Leaf)) {
        $installer = Join-Path $Root 'scripts/native-bridge-install.ps1'
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
    $copyOut = $proc.StandardOutput.BaseStream.CopyToAsync($stdout)
    $copyErr = $proc.StandardError.BaseStream.CopyToAsync($stderr)
    $feed = [Console]::OpenStandardInput().CopyToAsync($proc.StandardInput.BaseStream)
    $fed = $feed.Wait($BudgetMs)
    if ($fed) { $proc.StandardInput.Close() }
    $left = [int][Math]::Max(0, $BudgetMs - $clock.ElapsedMilliseconds)
    if (-not $fed -or -not $proc.WaitForExit($left)) {
        try { $proc.Kill() } catch {}
        if ($FailOpen) { [Console]::Out.Write($FailOpen) }
        exit 0
    }
    [void]$copyOut.Wait(2000)
    [void]$copyErr.Wait(2000)
    $stdout.Flush()
    $stderr.Flush()
    exit $proc.ExitCode
}
