#!/usr/bin/env pwsh
# tests/test_hook_ps1.ps1 — unit tests for hook.ps1's shell-quoting decoder
# (ConvertFrom-ShellQuoted).
#
# Why this matters: on Windows ONLY hook.ps1 reads the credential files, but one
# of those files — the compiled plugin `env` — is a cross-platform artifact that
# hook.sh `source`s on macOS/Linux. So the value MUST come out identical whether
# the shell parses it or hook.ps1 decodes it. These files are shell-quoted two
# different ways in the wild:
#   • POSIX single-quoting with `'\''` escapes ............ install.ps1 / setup.ps1
#   • bash `printf %q` (backslash + double-quote escapes) .. install.sh / setup.sh
# A naive outer-quote strip mangles both. This decoder must match what a POSIX
# shell would do when evaluating a single word.
#
# Run on any platform with PowerShell:  pwsh tests/test_hook_ps1.ps1
# (hook.ps1 stands down on non-Windows for its MAIN body, but the test only loads
#  its functions via the ROGUE_PS_LIB_ONLY seam, so this runs anywhere.)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# [IO.Path]::Combine takes many segments on Windows PowerShell 5.1; multi-segment
# Join-Path is PowerShell 7+ only.
$hook = [System.IO.Path]::Combine($here, '..', 'plugins', 'rogue', 'scripts', 'hook.ps1')

# Load hook.ps1's functions without executing the dispatcher body.
$env:ROGUE_PS_LIB_ONLY = '1'
. $hook
$env:ROGUE_PS_LIB_ONLY = $null

# Single-char building blocks, so the test literals themselves can't be
# mis-escaped (PowerShell's own quoting rules differ from the shell's).
$SQ  = [char]39   # '
$DQ  = [char]34   # "
$BS  = [char]92   # \
$DOL = [char]36   # $
$BT  = [char]96   # `

$fails = 0
$count = 0
function Assert-Decode {
    param([string]$Raw, [string]$Expected, [string]$Label)
    $script:count++
    $got = ConvertFrom-ShellQuoted $Raw
    if ($got -ceq $Expected) {
        Write-Host "  ok: $Label"
    } else {
        Write-Host "FAIL [$Label]: ConvertFrom-ShellQuoted <$Raw> = <$got>, expected <$Expected>"
        $script:fails++
    }
}

# ── barewords: nothing for the shell to interpret, returned as-is ──────────
Assert-Decode 'rsk_abc123'        'rsk_abc123'        'plain API-key-style value'
Assert-Decode 'user@example.com'  'user@example.com'  'plain email'
Assert-Decode 'café'              'café'              'non-ASCII passes through'
Assert-Decode ''                  ''                  'empty string'

# ── POSIX single-quoting (install.ps1 / setup.ps1 Format-EnvVal) ───────────
Assert-Decode "'Test User'"           'Test User'            'single-quoted value with space'
Assert-Decode "''"                    ''                     'empty single-quoted value'
Assert-Decode "' '"                   ' '                    'single-quoted lone space'
Assert-Decode ("'O'" + $BS + $SQ + $SQ + "Brien'")  ("O" + $SQ + "Brien")  "POSIX escaped single quote"
Assert-Decode ("'Mary O'" + $BS + $SQ + $SQ + "Brien-Smith'") ("Mary O" + $SQ + "Brien-Smith") "POSIX escaped quote mid-name"
Assert-Decode "'a'b'c'"               'abc'                  'adjacent single-quoted segments concatenate'
Assert-Decode "''''"                  ''                     'four single quotes cancel to empty'
Assert-Decode ("'it'" + $BS + $SQ + $SQ + "s'") ("it" + $SQ + "s") "mixed bareword + escaped quote (it's)"
Assert-Decode "'a;b|c&d'"             'a;b|c&d'              'shell metacharacters literal inside single quotes'
Assert-Decode ($SQ + 'a' + $DOL + 'HOME' + $SQ) ('a' + $DOL + 'HOME') 'dollar literal inside single quotes'

# ── bash printf %q output (install.sh / setup.sh) ──────────────────────────
Assert-Decode 'Your\ Name'            'Your Name'            'printf %q escaped space'
Assert-Decode ("O" + $BS + $SQ + "Brien")  ("O" + $SQ + "Brien")  'printf %q escaped single quote'
Assert-Decode ("Mary" + $BS + " O" + $BS + $SQ + "Brien") ("Mary O" + $SQ + "Brien") 'printf %q escaped space + quote'
Assert-Decode 'C:\\path\\to'          'C:\path\to'           'printf %q escaped backslashes'
Assert-Decode 'a\\b'                  'a\b'                  'printf %q single escaped backslash'
Assert-Decode ('a' + $BS + $DQ + 'b') ('a' + $DQ + 'b')      'printf %q escaped double quote (bareword)'
Assert-Decode ($BS + $DOL + 'HOME')   ($DOL + 'HOME')        'printf %q escaped dollar (bareword)'

# ── double-quoted forms (a writer or hand-edit may use them) ───────────────
Assert-Decode '"a b"'                 'a b'                  'double-quoted value with space'
Assert-Decode '"a;b|c"'               'a;b|c'                'metacharacters literal inside double quotes'
Assert-Decode ('"a' + $BS + $DQ + 'b"') ('a' + $DQ + 'b')   'double-quoted escaped double quote'
Assert-Decode '"a\\b"'                'a\b'                  'double-quoted escaped backslash'
Assert-Decode ($DQ + 'a' + $BS + $DOL + 'b' + $DQ) ('a' + $DOL + 'b') 'double-quoted escaped dollar stays literal'
Assert-Decode ($DQ + 'a' + $BS + $BT + 'b' + $DQ) ('a' + $BT + 'b')   'double-quoted escaped backtick stays literal'
Assert-Decode ($DQ + 'O' + $SQ + 'Brien' + $DQ) ('O' + $SQ + 'Brien') 'single quote literal inside double quotes'

# ── trailing backslash: no following char to escape, kept literal ──────────
Assert-Decode ('a' + $BS)             ('a' + $BS)            'trailing lone backslash kept literal'

# ── actor identity screening (Test-SyntheticActor / Select-ActorValue) ─────
# In Claude Cowork the hook runs in a sandbox as unix user `claude` whose git
# identity is Anthropic's synthetic "Claude <noreply@anthropic.com>", so those
# values must never be reported as the acting human — from ANY source, including
# an explicit ROGUE_ACTOR_* baked into a compiled bundle's env file. The sh twin
# of this screen is actor.sh's _rogue_is_synthetic (see tests/test_actor_sh.sh).
function Assert-Synthetic {
    param([string]$Value, [bool]$Expected, [string]$Label)
    $script:count++
    $got = [bool](Test-SyntheticActor $Value)
    if ($got -eq $Expected) {
        Write-Host "  ok: $Label"
    } else {
        Write-Host "FAIL [$Label]: Test-SyntheticActor <$Value> = $got, expected $Expected"
        $script:fails++
    }
}
function Assert-Selected {
    param([string[]]$Candidates, [string]$Expected, [string]$Label)
    $script:count++
    $got = Select-ActorValue $Candidates
    if ($got -ceq $Expected) {
        Write-Host "  ok: $Label"
    } else {
        Write-Host "FAIL [$Label]: Select-ActorValue = <$got>, expected <$Expected>"
        $script:fails++
    }
}

Assert-Synthetic ''                      $true  'empty value is synthetic'
Assert-Synthetic '   '                   $true  'whitespace-only value is synthetic'
Assert-Synthetic 'Claude'                $true  'Claude is synthetic'
Assert-Synthetic 'claude'                $true  'claude (lowercase) is synthetic'
Assert-Synthetic 'Claude Code'           $true  'Claude Code is synthetic'
Assert-Synthetic '  CLAUDE   code  '     $true  'case + repeated whitespace still matches'
Assert-Synthetic 'noreply@anthropic.com' $true  'sandbox git email is synthetic'
Assert-Synthetic 'NoReply@Anthropic.COM' $true  'sandbox git email match is case-insensitive'
Assert-Synthetic 'Jane Dev'              $false 'a real name is not synthetic'
Assert-Synthetic 'Claudia Claude-Smith'  $false 'a name merely containing claude is not synthetic'
Assert-Synthetic 'claude.dubois@corp.com' $false 'a real email at a real domain is not synthetic'

Assert-Selected @('noreply@anthropic.com', 'real.user@corp.com') 'real.user@corp.com' 'poisoned first candidate skipped'
Assert-Selected @('Claude', '', 'Jane Dev')                      'Jane Dev'           'synthetic + empty candidates skipped'
Assert-Selected @('mdm@corp.com', 'real.user@corp.com')          'mdm@corp.com'       'first legitimate candidate wins'
Assert-Selected @('Claude', 'claude code', '  ')                 ''                   'all-synthetic yields empty (caller emits the unknown marker)'

# ── last-resort fallbacks: parity with the POSIX cascade ───────────────────
# actor.sh ends at `<login>@<hostname>`; the PowerShell twin must still resolve
# a real identity when USERNAME or COMPUTERNAME is unset (service contexts),
# rather than skipping straight to the unknown marker. It does NOT shell out to
# whoami.exe: that prints DOMAIN\user, which is a different identity string and
# would re-fingerprint every existing roster row.
Assert-Selected @('', '', [Environment]::UserName) ([Environment]::UserName) 'token user answers when git name and USERNAME are both empty'
Assert-Selected @('Jane Dev', [Environment]::UserName) 'Jane Dev'             'a real git name still outranks the token user'

# ── the synthetic host email must not leak in through its local-part ───────
# noreply@anthropic.com is screened as an email, but "noreply" is not itself on
# the screen list, so splitting before screening would report it as the actor
# name. Screen the whole address first, then split.
$labMail = Select-ActorValue @('noreply@anthropic.com')
Assert-Selected @('', (($labMail -split '@')[0])) ''          'synthetic host email contributes no name'
$labMail = Select-ActorValue @('jane.doe@corp.com')
Assert-Selected @('', (($labMail -split '@')[0])) 'jane.doe'  'real host email still yields its local-part'

# hook.ps1's cascade (Resolve-RogueActor) is driven end to end in
# tests/test_git_identity_ps1.ps1, which also drives the seam construct heartbeat.ps1
# reaches it through. The fallbacks are pinned structurally here too: a silent drop
# of either is exactly the regression this covers.
foreach ($f in @('hook.ps1')) {
    $src = Get-Content -Raw -LiteralPath ([System.IO.Path]::Combine($here, '..', 'plugins', 'rogue', 'scripts', $f))
    $script:count++
    if ($src -match [regex]::Escape('Select-ActorValue @($env:USERNAME, [Environment]::UserName)')) {
        Write-Host "  ok: $f login falls back to the process token user"
    } else {
        Write-Host "FAIL [$f]: login does not fall back to [Environment]::UserName"
        $script:fails++
    }
    $script:count++
    if ($src -match [regex]::Escape("scripts\git-identity.ps1") -and $src -notmatch '&\s*git\s') {
        Write-Host "  ok: $f reads the git identity from the config files, never git.exe"
    } else {
        Write-Host "FAIL [$f]: git identity is not read through git-identity.ps1"
        $script:fails++
    }
    $script:count++
    if ($src -match [regex]::Escape('$hostMail = Select-ActorValue @($env:CLAUDE_CODE_USER_EMAIL)') -and
        $src -notmatch [regex]::Escape("(($env:CLAUDE_CODE_USER_EMAIL -split '@')[0])")) {
        Write-Host "  ok: $f screens the host email before taking its local-part"
    } else {
        Write-Host "FAIL [$f]: host email is split before it is screened"
        $script:fails++
    }
    $script:count++
    if ($src -match [regex]::Escape('Select-ActorValue @($env:COMPUTERNAME, $dnsHost)')) {
        Write-Host "  ok: $f actor-email host falls back to the DNS host name"
    } else {
        Write-Host "FAIL [$f]: actor-email host marker does not fall back to GetHostName()"
        $script:fails++
    }
}

# ── the status skill's Windows block must use the same screen ──────────────
# /rogue:status upserts a roster row, so posting $creds['ROGUE_ACTOR_*'] raw
# would register the sandbox identity as a second, wrongly-attributed install.
# It cannot run here (it reads $env:USERPROFILE and posts), so assert its shape.
$skill = Get-Content -Raw -LiteralPath ([System.IO.Path]::Combine($here, '..', 'plugins', 'rogue', 'skills', 'status', 'SKILL.md'))
$script:count++
if ($skill -match [regex]::Escape('$env:ROGUE_PS_LIB_ONLY') -and $skill -match 'Resolve-RogueActor' -and $skill -notmatch '&\s*git\s') {
    Write-Host "  ok: status skill resolves the actor through hook.ps1's screen"
} else {
    Write-Host "FAIL: status skill does not load hook.ps1's actor screen"
    $script:fails++
}
$script:count++
if ($skill -match [regex]::Escape('$hostName = $env:COMPUTERNAME') -and
    $skill -match [regex]::Escape('[System.Net.Dns]::GetHostName()') -and
    $skill -notmatch [regex]::Escape('host=$env:COMPUTERNAME')) {
    Write-Host "  ok: status skill resolves the roster host with the COMPUTERNAME -> DNS -> unknown cascade"
} else {
    Write-Host "FAIL: status skill posts a bare COMPUTERNAME as the roster host"
    $script:fails++
}

$script:count++
if ($skill -notmatch [regex]::Escape("actor_email=[string]`$creds['ROGUE_ACTOR_EMAIL']")) {
    Write-Host "  ok: status skill does not post raw env-file actor values"
} else {
    Write-Host "FAIL: status skill posts \$creds['ROGUE_ACTOR_EMAIL'] straight into the body"
    $script:fails++
}

# ── Test-WantAlert: the Cowork-only block-modal gate ───────────────────────
# Twin of hook.sh's _rogue_want_alert (covered end-to-end in tests/test_hook_sh.sh).
# The modal exists because Claude Cowork's client discards hook-authored text on
# every documented channel, so the OS dialog is the only thing the user sees. The
# CLI and the Desktop app render blocks natively and must never get one — a modal
# there double-reports. These cases pin that split so a refactor cannot quietly
# widen the blast radius to every surface, which is what c31ee5a removed.
function Assert-Gate {
    param([string]$InstallAgent, [string]$HookEvent, [bool]$Expected, [string]$Label)
    $script:count++
    $got = [bool](Test-WantAlert $InstallAgent $HookEvent)
    if ($got -eq $Expected) {
        Write-Host "  ok: $Label"
    } else {
        Write-Host "FAIL [$Label]: Test-WantAlert '$InstallAgent' '$HookEvent' = $got, expected $Expected"
        $script:fails++
    }
}

# Leave the environment as we found it — later assertions in this file read env.
$savedRemote = $env:CLAUDE_CODE_REMOTE
$savedAlert  = $env:ROGUE_ALERT
$savedEvents = $env:ROGUE_ALERT_EVENTS
$env:CLAUDE_CODE_REMOTE = $null; $env:ROGUE_ALERT = $null; $env:ROGUE_ALERT_EVENTS = $null

# Cowork only. The surface id comes from the SAME cascade the roster uses
# (CLAUDE_CODE_IS_COWORK first, then a *cowork* entrypoint), so the gate cannot
# drift from install-id.sh / heartbeat.ps1.
Assert-Gate 'claude_cowork'        'UserPromptSubmit' $true  'local Cowork fires the modal'
Assert-Gate 'claude_cowork'        'PreToolUse'       $true  'local Cowork fires on a tool deny too'
Assert-Gate 'claude_code'          'UserPromptSubmit' $false 'the CLI never gets a modal (renders blocks natively)'
Assert-Gate 'claude_code_desktop'  'UserPromptSubmit' $false 'the Desktop app never gets a modal either'
Assert-Gate ''                     'UserPromptSubmit' $false 'an unresolved surface gets no modal'

# Cloud Cowork runs the hook in a headless Linux container: no GUI to reach, so it
# is excluded explicitly rather than left to fail silently.
$env:CLAUDE_CODE_REMOTE = 'true'
Assert-Gate 'claude_cowork' 'UserPromptSubmit' $false 'cloud Cowork (CLAUDE_CODE_REMOTE=true) is excluded'
$env:CLAUDE_CODE_REMOTE = $null

# Kill switch.
$env:ROGUE_ALERT = '0'
Assert-Gate 'claude_cowork' 'UserPromptSubmit' $false 'ROGUE_ALERT=0 disables the modal'
$env:ROGUE_ALERT = $null

# Event allowlist: the escape hatch for narrowing to UserPromptSubmit (the one
# event with no visible channel) without shipping a release.
$env:ROGUE_ALERT_EVENTS = 'UserPromptSubmit'
Assert-Gate 'claude_cowork' 'UserPromptSubmit' $true  'ROGUE_ALERT_EVENTS keeps a listed event'
Assert-Gate 'claude_cowork' 'PreToolUse'       $false 'ROGUE_ALERT_EVENTS excludes an unlisted event'
$env:ROGUE_ALERT_EVENTS = 'UserPromptSubmit PreToolUse'
Assert-Gate 'claude_cowork' 'PreToolUse'       $true  'ROGUE_ALERT_EVENTS is space-separated'

$env:CLAUDE_CODE_REMOTE = $savedRemote
$env:ROGUE_ALERT        = $savedAlert
$env:ROGUE_ALERT_EVENTS = $savedEvents

# The dispatcher must relay the decision BEFORE launching the modal, and launch it
# detached. Inline, a modal that waits for a click holds Claude's stdout pipe open
# until dismissed; Claude times the hook out at 20s and FAILS OPEN, letting the
# blocked prompt through. Its sh twin has an end-to-end regression test for this
# (a hanging osascript stub); on this side the ordering is structural, so assert it
# statically rather than not at all.
$hookSrc = Get-Content -Raw -LiteralPath $hook
$script:count++
$emitIdx  = $hookSrc.IndexOf('Emit-Json $resp')
$startIdx = $hookSrc.IndexOf('Start-Process -FilePath ' + [char]39 + 'powershell' + [char]39)
if ($emitIdx -gt 0 -and $startIdx -gt $emitIdx) {
    Write-Host "  ok: the response is relayed before the modal is launched"
} else {
    Write-Host "FAIL: modal launch is not strictly after Emit-Json (emit=$emitIdx start=$startIdx)"
    $script:fails++
}
$script:count++
if ($hookSrc -match [regex]::Escape('-WindowStyle Hidden')) {
    Write-Host "  ok: the modal is launched detached and hidden, never inline"
} else {
    Write-Host "FAIL: modal is not launched via a detached hidden process"
    $script:fails++
}
# -EncodedCommand, not -Command: Start-Process joins -ArgumentList with spaces and
# does not quote elements, so a -Command scriptblock bootstrap reaches the child
# mangled and silently never runs. A Base64 blob has no spaces.
$script:count++
if ($hookSrc -match [regex]::Escape("'-EncodedCommand'")) {
    Write-Host "  ok: the modal bootstrap is passed as -EncodedCommand"
} else {
    Write-Host "FAIL: modal bootstrap must be -EncodedCommand, not -Command"
    $script:fails++
}

if ($fails -gt 0) {
    Write-Host ""
    Write-Host "$fails of $count PowerShell unit test(s) FAILED."
    exit 1
}
Write-Host ""
Write-Host "All $count hook.ps1 unit tests passed."
