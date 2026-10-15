# Muse Windows installer and bridge under pwsh: settings.json keeps every byte
# except Rogue's managed_hooks_path member, foreign pointers are refused, and
# hook.ps1 relays the API's native response or fails open.
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Scripts = [IO.Path]::Combine($Repo, 'plugins', 'muse', 'scripts')
$script:fails = 0
# The engine running this file: pwsh 7 on Linux CI, Windows PowerShell 5.1 on the Windows job.
$PsExe = (Get-Process -Id $PID).Path
function Check { param([string]$Name, [scriptblock]$Test)
    $ok = $false; try { $ok = [bool](& $Test) } catch {}
    if ($ok) { Write-Host "ok   $Name" } else { Write-Host "FAIL $Name"; $script:fails++ }
}
# Continue: under Stop, Windows PowerShell 5.1 turns a child's stderr into a terminating error.
function Run { param([string[]]$Arguments) $ErrorActionPreference = 'Continue'; & $PsExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Scripts 'install.ps1') @Arguments *> $null; $LASTEXITCODE -eq 0 }
function Read-Text { param([string]$Path) [IO.File]::ReadAllText($Path) }

$H = Join-Path ([IO.Path]::GetTempPath()) ("muse-ps1 ' home-" + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $H | Out-Null
$env:USERPROFILE = $H; $env:XDG_CONFIG_HOME = Join-Path $H '.config'
$S = [IO.Path]::Combine($H, '.config', 'muse', 'settings.json')
$Hooks = [IO.Path]::Combine($H, '.rogue', 'plugins', 'muse', 'hooks.json')
try {
    Check 'fresh install' { Run @() }
    Check 'fresh settings point at hooks' { (Read-Text $S | ConvertFrom-Json).managed_hooks_path -eq $Hooks }
    Check 'hooks file has ten events' { @((Read-Text $Hooks | ConvertFrom-Json).hooks.PSObject.Properties).Count -eq 10 }
    $before = Read-Text $S
    Check 'repeat install is a no-op' { (Run @()) -and (Read-Text $S) -ceq $before }
    Check 'status passes' { Run @('-Status') }

    $original = "{`n  `"schema_version`": 1,`n  `"provider`": `"meta`",`n  `"hooks`": {`"PreToolUse`": []}`n}"
    [IO.File]::WriteAllText($S, $original)
    Check 'install into existing settings' { Run @() }
    Check 'only the pointer line is added' { (Read-Text $S).Replace("`n  `"managed_hooks_path`": " + ($Hooks | ConvertTo-Json) + ',', '') -ceq $original }
    Check 'uninstall restores exact text' { (Run @('-Uninstall')) -and (Read-Text $S) -ceq $original -and -not (Test-Path $Hooks) }
    Check 'status fails after uninstall' { -not (Run @('-Status')) }

    [IO.File]::WriteAllText($S, "{`n  `"provider`": `"meta`",`n  `"managed_hooks_path`": " + ($Hooks | ConvertTo-Json) + "`n}")
    Check 'uninstall of a last-member pointer leaves valid JSON' { (Run @('-Uninstall')) -and -not ((Read-Text $S | ConvertFrom-Json).PSObject.Properties['managed_hooks_path']) }

    [IO.File]::WriteAllText($S, '{}')
    Check 'empty object gains only the pointer' { (Run @()) -and ((Read-Text $S | ConvertFrom-Json).PSObject.Properties.Name -join ',') -eq 'managed_hooks_path' }

    foreach ($doc in '[]', '{"managed_hooks_path": "C:\\corp\\hooks.json"}', '{"managed_hooks_path": null}', '{invalid') {
        [IO.File]::WriteAllText($S, $doc)
        Check "refuses $doc" { -not (Run @()) -and (Read-Text $S) -ceq $doc }
    }
    Check 'a refusal releases the lock' { -not (Test-Path "$S.rogue-lock") }
    [IO.File]::WriteAllText($S, '{}'); New-Item -ItemType Directory -Path "$S.rogue-lock" | Out-Null
    Check 'refuses while locked' { -not (Run @()) -and (Read-Text $S) -ceq '{}' }
    Remove-Item "$S.rogue-lock"

    # hook.ps1 against an in-process mock of the Rogue API.
    Run @() | Out-Null
    $hook = [IO.Path]::Combine($H, '.rogue', 'plugins', 'muse', 'scripts', 'hook.ps1')
    function Invoke-Hook { param([string]$EventName) $ErrorActionPreference = 'Continue'; ('{"tool_name":"write_file"}' | & $PsExe -NoProfile -ExecutionPolicy Bypass -File $hook $EventName | Out-String).Trim() }
    Check 'unconfigured hook allows' { (Invoke-Hook 'PreToolUse') -eq '{}' }
    function Start-Mock { param([string]$Body, [int]$Status = 200)
        $port = Get-Random -Minimum 30000 -Maximum 40000
        $job = Start-Job -ArgumentList $port, $Body, $Status {
            param($port, $body, $status)
            $l = New-Object Net.HttpListener; $l.Prefixes.Add("http://localhost:$port/"); $l.Start()
            while ($true) {
                $c = $l.GetContext(); $c.Request.InputStream.CopyTo([IO.Stream]::Null)
                $c.Response.StatusCode = $status
                $b = [Text.Encoding]::UTF8.GetBytes($body); $c.Response.OutputStream.Write($b, 0, $b.Length); $c.Response.Close()
            }
        }
        for ($i = 0; $i -lt 100; $i++) {
            try { Invoke-WebRequest -Uri "http://localhost:$port/" -Method Post -UseBasicParsing -TimeoutSec 1 | Out-Null; break }
            catch { if ($_.Exception.Response) { break }; Start-Sleep -Milliseconds 200 }
        }
        $envFile = Join-Path $H '.rogue-env'
        [IO.File]::WriteAllText($envFile, "ROGUE_API_KEY='rg_test'`nROGUE_BASE_URL='http://localhost:$port'`n")
        if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { & chmod 600 $envFile }
        return $job
    }
    $deny = '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"no"}}'
    $job = Start-Mock $deny
    Check 'relays a native deny' { (Invoke-Hook 'PreToolUse') -eq $deny }
    Stop-Job $job; $job = Start-Mock '{}'
    Check 'relays an allow' { (Invoke-Hook 'UserPromptSubmit') -eq '{}' }
    Stop-Job $job; $job = Start-Mock $deny 500
    Check 'fails open on a server error' { (Invoke-Hook 'PreToolUse') -eq '{}' }
    Stop-Job $job
    Check 'fails open when unreachable' { (Invoke-Hook 'PreToolUse') -eq '{}' }
    Check 'logs every outcome' { (Get-Content ([IO.Path]::Combine($H, '.rogue', 'logs', 'muse.log')) | Select-String 'surface=muse_code').Count -ge 5 }
} finally {
    Get-Job -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $H
}
if ($script:fails) { Write-Host "$($script:fails) failed"; exit 1 }
Write-Host 'all Muse PowerShell tests passed'
