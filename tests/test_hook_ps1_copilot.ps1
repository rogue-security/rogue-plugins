#!/usr/bin/env pwsh
# tests/test_hook_ps1_copilot.ps1 — unit tests for the Copilot PowerShell
# dispatcher's pure helpers (plugins/copilot/scripts/hook.ps1).
#
# Why a separate file from tests/test_hook_ps1.ps1: that one is explicitly about
# the CLAUDE plugin's shell-quoting decoder (ConvertFrom-ShellQuoted) and the
# cross-bridge round-trip of ~/.rogue-env. This one covers the Copilot-only
# JetBrains silent-block alert — the single out-of-band exception to pure relay —
# and must stay in lockstep with tests/test_hook_sh_copilot.sh cases 4b-4e, plus
# the subagent agent-tag HEADERS, in lockstep with that file's cases 14-16.
#
# These are the ONLY automated checks that ever execute hook.ps1's alert code:
# a parse or logic error there is not a graceful degradation, because the
# hooks.json loader wraps the call in `try { … } catch { '{}' } ; exit 0` and
# would silently turn every Windows Copilot user's enforcement into a no-op.
#
# Run on any platform with PowerShell:  pwsh tests/test_hook_ps1_copilot.ps1
# hook.ps1 stands down on non-Windows for its MAIN body, but this test loads only
# its functions via the ROGUE_PS_LIB_ONLY seam, so it runs anywhere. Test-JetBrainsIde
# is exercised through its env fallback: the CIM walk throws (Get-CimInstance does
# not exist off Windows) / finds no copilot ancestor, and falls through.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# [IO.Path]::Combine takes many segments on Windows PowerShell 5.1; multi-segment
# Join-Path is PowerShell 7+ only.
$hook = [System.IO.Path]::Combine($here, '..', 'plugins', 'copilot', 'scripts', 'hook.ps1')

# Load hook.ps1's functions without executing the dispatcher body.
$env:ROGUE_PS_LIB_ONLY = '1'
. $hook
$env:ROGUE_PS_LIB_ONLY = $null
# hook.ps1 sets SilentlyContinue for its own fail-open behaviour; the test itself
# wants failures to be loud. Every helper under test guards with try/catch, so
# this does not change what they do.
$ErrorActionPreference = 'Stop'

# Single-char building blocks, so the test literals themselves can't be
# mis-escaped (PowerShell's own quoting rules differ from the shell's).
$SQ = [char]39   # '
$BS = [char]92   # \

$fails = 0
$count = 0
function Assert-Eq {
    param($Got, $Expected, [string]$Label)
    $script:count++
    if ([string]$Got -ceq [string]$Expected) {
        Write-Host "  ok: $Label"
    } else {
        Write-Host "FAIL [$Label]: got <$Got>, expected <$Expected>"
        $script:fails++
    }
}
function Assert-True {
    param($Cond, [string]$Label)
    $script:count++
    if ($Cond) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL [$Label]: expected true, got <$Cond>"; $script:fails++ }
}

# ── log capture ────────────────────────────────────────────────────────────
# hook.ps1 assigns $logFile at dot-source time into THIS script's scope, and Log
# resolves it up the scope chain at call time — so re-pointing it here is enough
# to isolate each case.
function Reset-Log {
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-copilot-ps-" + [guid]::NewGuid().ToString('N') + ".log")
    $script:logFile = $p
    return $p
}
function Get-LogText {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-Content -Raw -LiteralPath $Path) }
    return ''
}
# The alert's DRYRUN=2 seam logs "ide_alert=escaped msg=<composed literal>", with
# real newlines rendered as '|' so the record stays one line.
function Get-EscapedMsg {
    param([string]$Path)
    $txt = Get-LogText $Path
    $m = [regex]::Match($txt, 'ide_alert=escaped msg=(.*)')
    if ($m.Success) { return $m.Groups[1].Value.TrimEnd([char]13) }
    return $null
}
function Clear-AlertEnv {
    $env:ROGUE_IDE_ALERT = $null
    $env:ROGUE_IDE_ALERT_DRYRUN = $null
    $env:COPILOT_CLI_BINARY_VERSION = $null
    $env:PKG_EXECPATH = $null
    $env:GITHUB_COPILOT_RIPGREP_PATH_OVERRIDE = $null
}
Clear-AlertEnv

# ── Sanitize: strip control characters (log-forgery guard) ─────────────────
# The reason text is server-controlled and lands in the hook log; a raw newline
# or CR would let it forge a second log record.
Assert-Eq (Sanitize "a`tb`nc`r`0d") 'abcd'  'Sanitize strips tab/LF/CR/NUL'
Assert-Eq (Sanitize ("x" + [char]0x7f + "y")) 'xy' 'Sanitize strips DEL (0x7f)'
Assert-Eq (Sanitize 'plain text') 'plain text' 'Sanitize leaves printable text alone'
Assert-Eq (Sanitize $null) '' 'Sanitize tolerates null'

# ── Show-BlockNotification: ROGUE_IDE_ALERT=0 is a hard off switch ─────────
$log = Reset-Log
$env:ROGUE_IDE_ALERT = '0'
$env:ROGUE_IDE_ALERT_DRYRUN = '1'
Show-BlockNotification 'should not appear'
Assert-Eq (Get-LogText $log) '' 'ROGUE_IDE_ALERT=0 logs nothing and shows nothing'
Clear-AlertEnv

# ── Show-BlockNotification: DRYRUN=1 logs, never composes or spawns ────────
$log = Reset-Log
$env:ROGUE_IDE_ALERT_DRYRUN = '1'
Show-BlockNotification 'Coding Agent Security: PROMPT_INJECTION'
$txt = Get-LogText $log
Assert-True ($txt -like '*ide_alert=fired*') 'DRYRUN=1 logs ide_alert=fired'
Assert-True (-not ($txt -like '*ide_alert=escaped*')) 'DRYRUN=1 stops before composing the popup'
Clear-AlertEnv

# ── Show-BlockNotification: empty reason falls back to a default ───────────
$log = Reset-Log
$env:ROGUE_IDE_ALERT_DRYRUN = '2'
Show-BlockNotification ''
Assert-Eq (Get-EscapedMsg $log) 'Prompt blocked by Rogue Security.' 'empty reason uses the default text'
Clear-AlertEnv

# ── Show-BlockNotification: literal \n becomes a real newline ──────────────
# API reasons are two paragraphs (findings text + the `rgx!` hint) carrying
# literal "\n" straight out of the JSON string. The call site must NOT collapse
# them to a space or this conversion is dead code. Mirrors hook.sh case 4e.
$log = Reset-Log
$env:ROGUE_IDE_ALERT_DRYRUN = '2'
Show-BlockNotification ('Rogue blocked.' + $BS + 'nUse rgx! to override.')
Assert-Eq (Get-EscapedMsg $log) 'Rogue blocked.|Use rgx! to override.' 'literal \n becomes a real newline'
Clear-AlertEnv

# ── Show-BlockNotification: single quotes are doubled ──────────────────────
# $safe is interpolated into a single-quoted PowerShell literal inside the
# -EncodedCommand payload, where "'" is the only metacharacter.
$log = Reset-Log
$env:ROGUE_IDE_ALERT_DRYRUN = '2'
Show-BlockNotification ("don" + $SQ + "t run this")
Assert-Eq (Get-EscapedMsg $log) ("don" + $SQ + $SQ + "t run this") 'single quote is doubled for the PS literal'
Clear-AlertEnv

# ── Show-BlockNotification: a runaway reason is truncated to 400 ───────────
$log = Reset-Log
$env:ROGUE_IDE_ALERT_DRYRUN = '2'
Show-BlockNotification ('a' * 500)
Assert-Eq (Get-EscapedMsg $log).Length 400 '500-char reason truncated to 400'
Clear-AlertEnv

# ── Test-JetBrainsIde: env-fallback truth table ────────────────────────────
# Both harnesses set COPILOT_CLI=1, so the parent process is the real
# discriminator. When the process walk is unavailable (WMI off, container, or —
# as here — dot-sourced off Windows) the env shape decides: the IDE does NOT
# export COPILOT_CLI_BINARY_VERSION but DOES export PKG_EXECPATH /
# GITHUB_COPILOT_RIPGREP_PATH_OVERRIDE. Mirrors hook.sh in_jetbrains_ide.
Clear-AlertEnv
$env:PKG_EXECPATH = '/x'
Assert-True (Test-JetBrainsIde) 'fallback: version unset + PKG_EXECPATH set => IDE'
Clear-AlertEnv

$env:GITHUB_COPILOT_RIPGREP_PATH_OVERRIDE = '/x/rg'
Assert-True (Test-JetBrainsIde) 'fallback: version unset + ripgrep override set => IDE'
Clear-AlertEnv

Assert-True (-not (Test-JetBrainsIde)) 'fallback: version unset + no IDE markers => not IDE'

$env:COPILOT_CLI_BINARY_VERSION = '1.0.75'
$env:PKG_EXECPATH = '/x'
Assert-True (-not (Test-JetBrainsIde)) 'fallback: version SET (terminal CLI) wins over PKG_EXECPATH'
Clear-AlertEnv

$env:COPILOT_CLI_BINARY_VERSION = '1.0.75'
Assert-True (-not (Test-JetBrainsIde)) 'fallback: version SET + no markers => not IDE'
Clear-AlertEnv

# ── The subagent agent tag rides in HEADERS ────────────────────────────────
# A re-attributed subagent event is tagged with x-rogue-agent-id +
# x-rogue-agent-name-b64 (the same pair the Antigravity dispatcher sends) and the
# POSTed body carries only the sessionId rewrite. Mirrors hook.sh and
# tests/test_hook_sh_copilot.sh cases 14-16.
#
# The emit site lives in the dispatcher's MAIN body, which cannot run here (it
# stands down on non-Windows, and there is no stdin/server to drive it), so these
# are source-level assertions over hook.ps1 plus the value computations the two
# headers depend on. What they protect is the migration itself: any regrowth of
# the body tagger — the jq round-trip over arbitrary toolArgs — fails them.
$src = Get-Content -Raw -LiteralPath $hook

Assert-True ($src -notmatch 'Add-AgentTag') 'Add-AgentTag is gone (definition and call site)'
Assert-True ($src -notmatch 'agentNameB64') 'no agentNameB64 body field remains'
Assert-True ($src -notmatch '"agentId":"') 'no agentId body field remains'
Assert-True ($src -notmatch '&\s+jq\b') 'no jq round-trip of the vendor payload remains'
# The one surviving body mutation on a subagent event (plus transcriptTailB64 on
# the two stop events, which is synthesised content and not a rewrite).
Assert-True ($src -match '\$payload\s+-replace\s+\(''"sessionId"') 'the sessionId rewrite is still there'

$idKey = $src.IndexOf("'x-rogue-agent-id'")
$nameKey = $src.IndexOf("'x-rogue-agent-name-b64'")
$idGuard = $src.IndexOf('if ($subagentId -and')
$nameGuard = $src.IndexOf('if ($subagentName)')
Assert-True ($idKey -gt 0) 'x-rogue-agent-id is added to $headers'
Assert-True ($nameKey -gt 0) 'x-rogue-agent-name-b64 is added to $headers'
# Both keys are nested inside the id check, and the name inside its own check, so
# neither is ever sent empty on a main-agent event.
Assert-True ($idGuard -gt 0 -and $idGuard -lt $idKey) 'the id header is guarded by $subagentId'
Assert-True ($nameGuard -gt $idGuard -and $nameGuard -lt $nameKey) 'the name header is nested inside both checks'
Assert-True ($src -match "x-rogue-agent-name-b64'\]\s*=\s*(\r?\n\s*)?\[Convert\]::ToBase64String") `
    'the name header value is base64, never raw vendor text'

# The id charset gate moved from the deleted tagger to the emit site. Pull the
# pattern out of the source and hold it to the same truth table the body tagger
# had: a bare Copilot token passes, anything else skips BOTH headers.
$gate = [regex]::Match($src, "\`$subagentId -match '([^']+)'")
Assert-True ($gate.Success) 'the emit site still gates the id on a charset pattern'
$pat = $gate.Groups[1].Value
Assert-Eq $pat '^[A-Za-z0-9_-]+$' 'the gate is the bare Copilot token charset'
Assert-True ('toolu_bdrk_TESTSUB' -match $pat) 'a toolu_ id passes the gate'
Assert-True ('call_NASTYNAME' -match $pat) 'a call_ id passes the gate'
Assert-True (-not ('call_"evil' -match $pat)) 'a quote in the id fails the gate'
Assert-True (-not (('call' + $BS + 'x') -match $pat)) 'a backslash in the id fails the gate'
Assert-True (-not ('call A' -match $pat)) 'a space in the id fails the gate'
Assert-True (-not ('' -match $pat)) 'an empty id fails the gate'

# The two dispatchers must agree on the header VALUES, so these are the exact
# base64 strings tests/test_hook_sh_copilot.sh decodes on the sh side.
function Get-NameB64 { param([string]$N) [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($N)) }
Assert-Eq (Get-NameB64 'Task Agent') 'VGFzayBBZ2VudA==' 'display name base64 matches the sh dispatcher'
Assert-Eq (Get-NameB64 ('Task "Agent" ' + $BS + ' v2')) 'VGFzayAiQWdlbnQiIFwgdjI=' `
    'a name with " and \ round-trips through base64'
Assert-Eq (Get-NameB64 'Stop Agent') 'U3RvcCBBZ2VudA==' 'the stop-event display name matches the sh dispatcher'
# UTF-8 before base64, so a non-ASCII name cannot produce an invalid header value
# (HTTP header values are ISO-8859-1 by spec — the whole reason for the encoding).
# Built from codepoints, not a literal: Windows PowerShell 5.1 reads a BOM-less
# file as ANSI, so a non-ASCII literal here decodes to mojibake and can terminate
# the string early (it did - the 5.1 job failed to parse this file at all). The
# source stays pure ASCII; the VALUE under test is still non-ASCII.
$JP = -join @(0x30A8, 0x30FC, 0x30B8, 0x30A7, 0x30F3, 0x30C8 | ForEach-Object { [char]$_ })
Assert-Eq (Get-NameB64 $JP) '44Ko44O844K444Kn44Oz44OI' 'a non-ASCII name is UTF-8 base64'

if ($fails -gt 0) {
    Write-Host ""
    Write-Host "$fails of $count Copilot hook.ps1 test(s) FAILED."
    exit 1
}
Write-Host ""
Write-Host "All $count Copilot hook.ps1 tests passed."
