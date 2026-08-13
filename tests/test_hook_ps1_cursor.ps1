#!/usr/bin/env pwsh
# tests/test_hook_ps1_cursor.ps1 — unit tests for the Cursor PowerShell
# dispatcher's subagent -> parent session attribution
# (plugins/cursor/scripts/hook.ps1).
#
# Lockstep partner of tests/test_hook_sh_cursor.sh: every case there has a case
# here, because the repo's rule is that hook.sh and hook.ps1 move together. What
# it cannot mirror is the POST itself — hook.ps1's main body stands down on
# non-Windows, so this file loads only its FUNCTIONS through the
# ROGUE_PS_LIB_ONLY seam. The header-emit call site is covered by the sh suite
# plus the parse gate in .github/workflows/validate.yml; the resolution logic,
# which is where a wrong answer would come from, is covered here.
#
# These are the ONLY automated checks that ever execute this code: hooks.json
# loads hook.ps1 via `[scriptblock]::Create(...)` inside a catch that swallows
# failures into `{}`, so a logic error here is a silent no-op for every Windows
# Cursor user rather than an error anyone sees.
#
# Run on any platform with PowerShell:  pwsh tests/test_hook_ps1_cursor.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# [IO.Path]::Combine takes many segments on Windows PowerShell 5.1; multi-segment
# Join-Path is PowerShell 7+ only.
$hook = [System.IO.Path]::Combine($here, '..', 'plugins', 'cursor', 'scripts', 'hook.ps1')

# Load hook.ps1's functions without executing the dispatcher body.
$env:ROGUE_PS_LIB_ONLY = '1'
. $hook
$env:ROGUE_PS_LIB_ONLY = $null
# hook.ps1 sets SilentlyContinue for its own fail-open behaviour; the test itself
# wants failures to be loud. Every function under test guards with try/catch, so
# this does not change what they do.
$ErrorActionPreference = 'Stop'

$fails = 0
$count = 0
function Assert-Eq {
    param($Got, $Expected, [string]$Label)
    $script:count++
    if ([string]$Got -ceq [string]$Expected) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL [$Label]: got <$Got>, expected <$Expected>"; $script:fails++ }
}
function Assert-True {
    param($Cond, [string]$Label)
    $script:count++
    if ($Cond) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL [$Label]: expected true, got <$Cond>"; $script:fails++ }
}
function Assert-Null {
    param($Got, [string]$Label)
    $script:count++
    if ($null -eq $Got) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL [$Label]: expected null, got <$Got>"; $script:fails++ }
}

# ── harness ────────────────────────────────────────────────────────────────
# The functions read %USERPROFILE% (falling back to $HOME), so pointing it at a
# throwaway directory is what isolates a case.
$homes = @()
function New-TestHome {
    $d = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(),
        'rogue-cursor-ps-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $script:homes += $d
    $env:USERPROFILE = $d
    return $d
}
function New-ChildFile {
    param([string]$Root, [string]$Slug, [string]$Parent, [string]$Child)
    $dir = [System.IO.Path]::Combine($Root, '.cursor', 'projects', $Slug, 'agent-transcripts', $Parent, 'subagents')
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($dir, ($Child + '.jsonl')), '')
}
function New-Marker {
    param([string]$Root, [string]$Slug, [string]$Id, [int]$AgeSeconds = 0)
    $dir = [System.IO.Path]::Combine($Root, '.rogue', 'cursor-spawn', $Slug)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $f = [System.IO.Path]::Combine($dir, $Id)
    [System.IO.File]::WriteAllText($f, '')
    if ($AgeSeconds -gt 0) {
        (Get-Item -LiteralPath $f).LastWriteTime = (Get-Date).AddSeconds(-$AgeSeconds)
    }
}
function Set-CachedParent {
    param([string]$Root, [string]$Child, [string]$Parent)
    $dir = [System.IO.Path]::Combine($Root, '.rogue', 'cursor-parent')
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($dir, $Child), $Parent)
}

$WS = '/Users/test/work/proj'
$SLUG = 'Users-test-work-proj'
function New-Payload {
    param([string]$Id)
    # transcript_path is null here exactly as it is on real events, INCLUDING
    # ordinary parent ones; nothing in the dispatcher may branch on it.
    return ('{"conversation_id":"' + $Id + '","session_id":"' + $Id +
            '","workspace_roots":["' + $WS + '"],"transcript_path":null}')
}

# ── Slug derivation ────────────────────────────────────────────────────────
Assert-Eq (Get-RogueWorkspaceSlug (New-Payload 'x')) $SLUG 'slug strips the leading / and maps / and . to -'
Assert-Eq (Get-RogueWorkspaceSlug '{"workspace_roots":["/a/b.c"]}') 'a-b-c' 'slug maps a dotted path segment'
Assert-Eq (Get-RogueWorkspaceSlug '{"conversation_id":"x"}') '' 'no workspace_roots yields an empty slug'
Assert-Eq (Get-RogueWorkspaceSlug 'not json') '' 'unparseable payload yields an empty slug'

# ── Conversation id validation ─────────────────────────────────────────────
# The id becomes a path component, so anything outside the uuid charset is
# rejected rather than looked up.
Assert-True (Test-RogueConversationId 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa') 'a uuid is a conversation id'
Assert-True (-not (Test-RogueConversationId '../../etc/passwd')) 'a traversal-shaped id is rejected'
Assert-True (-not (Test-RogueConversationId '')) 'an empty id is rejected'
Assert-True (-not (Test-RogueConversationId 'a b')) 'an id with a space is rejected'

# ── Lookup: the filename IS the key ────────────────────────────────────────
$h = New-TestHome
$childA = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'
$parentA = '99999999-9999-4999-8999-999999999999'
New-ChildFile $h $SLUG $parentA $childA
Assert-Eq (Get-RogueCursorParent $childA $SLUG) $parentA 'parent is the agent-transcripts directory name'
Assert-Null (Get-RogueCursorParent 'ffffffff-0000-4000-8000-ffffffffffff' $SLUG) 'a child with no file resolves to nothing'

# Slug-scoping is an OPTIMIZATION: slug derivation has real exceptions on disk
# (numeric slugs, empty-window, .code-workspace-derived names), so a wrong slug
# still resolves through the global scan, which returns the SAME answer.
$h = New-TestHome
$childS = 'dddddddd-1111-4111-8111-dddddddddddd'
$parentS = '77777777-7777-4777-8777-777777777777'
New-ChildFile $h '1784115802260' $parentS $childS
Assert-Eq (Get-RogueCursorParent $childS $SLUG) $parentS 'resolved under a non-derivable slug via the global scan'
Assert-Eq (Get-RogueCursorParent $childS '') $parentS 'resolved with no slug at all'

# Two concurrent subagents under ONE parent: each carries its own id, so each
# finds its own file. Any "newest file wins" rule would hand one of them the
# other's id, which is the single outcome that would make this feature wrong.
$h = New-TestHome
$childX = 'bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb'
$childY = 'cccccccc-1111-4111-8111-cccccccccccc'
$parentXY = '88888888-8888-4888-8888-888888888888'
New-ChildFile $h $SLUG $parentXY $childX
New-ChildFile $h $SLUG $parentXY $childY
(Get-Item -LiteralPath ([System.IO.Path]::Combine($h, '.cursor', 'projects', $SLUG, 'agent-transcripts', $parentXY, 'subagents', ($childX + '.jsonl')))).LastWriteTime = (Get-Date).AddSeconds(-60)
Assert-Eq (Get-RogueCursorParent $childX $SLUG) $parentXY 'concurrent subagent X resolves the shared parent (older file)'
Assert-Eq (Get-RogueCursorParent $childY $SLUG) $parentXY 'concurrent subagent Y resolves the shared parent'

# ── Marker gate: decides WHETHER to wait, never the answer ─────────────────
$h = New-TestHome
Assert-True (-not (Test-RogueSpawnMarkerLive $SLUG)) 'no marker directory means no live marker'
New-Marker $h $SLUG '33333333-3333-4333-8333-333333333333'
Assert-True (Test-RogueSpawnMarkerLive $SLUG) 'a fresh marker is live'
Assert-True (Test-RogueSpawnMarkerLive '') 'a fresh marker is found with no slug (unscoped scan)'
Assert-True (-not (Test-RogueSpawnMarkerLive 'some-other-workspace')) 'markers are scoped per workspace'

$h = New-TestHome
New-Marker $h $SLUG '44444444-4444-4444-8444-444444444444' -AgeSeconds 600
Assert-True (-not (Test-RogueSpawnMarkerLive $SLUG)) 'a marker past the TTL is treated as absent'

# ── subagentStart writes the marker, subagentStop clears it ────────────────
# subagentStart fires ON THE PARENT, so its conversation_id IS the parent's id.
$h = New-TestHome
$parentM = '33333333-3333-4333-8333-333333333333'
Write-RogueSpawnMarker (New-Payload $parentM)
$markerPath = [System.IO.Path]::Combine($h, '.rogue', 'cursor-spawn', $SLUG, $parentM)
Assert-True (Test-Path -LiteralPath $markerPath) 'subagentStart writes ~/.rogue/cursor-spawn/<slug>/<parent id>'
Remove-RogueSpawnMarker (New-Payload $parentM)
Assert-True (-not (Test-Path -LiteralPath $markerPath)) 'subagentStop clears the marker'

# A non-uuid conversation id never becomes a path component.
$h = New-TestHome
Write-RogueSpawnMarker '{"conversation_id":"../../evil","workspace_roots":["/a"]}'
Assert-True (-not (Test-Path -LiteralPath ([System.IO.Path]::Combine($h, '.rogue', 'cursor-spawn')))) 'a traversal-shaped id writes no marker'

# ── Resolution: cache-cold hit, and the cache is written ───────────────────
$h = New-TestHome
New-ChildFile $h $SLUG $parentA $childA
$r = Resolve-RogueParentSession (New-Payload $childA)
Assert-Eq $r.Parent $parentA 'cache-cold resolution returns the parent'
Assert-Eq $r.Child $childA 'cache-cold resolution returns the child id'
$cacheFile = [System.IO.Path]::Combine($h, '.rogue', 'cursor-parent', $childA)
Assert-Eq ([System.IO.File]::ReadAllText($cacheFile)) $parentA 'resolution is cached at ~/.rogue/cursor-parent/<child>'

# A second event reuses the cache. Proven by DELETING the transcript tree first:
# only a cache read can still answer. A subagent fires 18-223 hooks per spawn and
# Cursor reuses a child id across re-spawns, so this is the common path.
Remove-Item -LiteralPath ([System.IO.Path]::Combine($h, '.cursor')) -Recurse -Force
$r = Resolve-RogueParentSession (New-Payload $childA)
Assert-Eq $r.Parent $parentA 'second event resolves from the cache, not the filesystem'

# The cache is read BEFORE any scan: seed a parent that exists nowhere on disk.
$h = New-TestHome
$childC = '2c2c2c2c-1111-4111-8111-2c2c2c2c2c2c'
Set-CachedParent $h $childC 'cached-parent-id'
$r = Resolve-RogueParentSession (New-Payload $childC)
Assert-Eq $r.Parent 'cached-parent-id' 'cache is consulted before the filesystem'

# ── Resolution: fail-open paths ────────────────────────────────────────────
# No marker means NO WAIT AT ALL. A brand-new top-level conversation has no
# directory of its own for ~9s and so looks exactly like an unresolved child;
# without this gate every session start would pay the full budget.
$h = New-TestHome
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Resolve-RogueParentSession (New-Payload '22222222-2222-2222-2222-222222222222')
$sw.Stop()
Assert-Null $r 'a main-agent conversation resolves to nothing'
Assert-True ($sw.Elapsed.TotalSeconds -lt 1) "no marker means no wait (took $([math]::Round($sw.Elapsed.TotalSeconds,2))s, budget is ~3s)"

# A stale marker is treated as absent, so it does not arm the wait either.
$h = New-TestHome
New-Marker $h $SLUG '44444444-4444-4444-8444-444444444444' -AgeSeconds 600
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Resolve-RogueParentSession (New-Payload '0a0a0a0a-1111-4111-8111-0a0a0a0a0a0a')
$sw.Stop()
Assert-Null $r 'a stale marker resolves to nothing'
Assert-True ($sw.Elapsed.TotalSeconds -lt 1) 'a stale marker does not arm the wait'

# Live marker, file never created: the budget expires and we fail open.
$h = New-TestHome
New-Marker $h $SLUG '55555555-5555-4555-8555-555555555555'
$env:ROGUE_CURSOR_PARENT_ITERS = '3'
$r = Resolve-RogueParentSession (New-Payload 'ffffffff-1111-4111-8111-ffffffffffff')
$env:ROGUE_CURSOR_PARENT_ITERS = $null
Assert-Null $r 'budget expiry resolves to nothing (fail open)'

# Live marker, file appears mid-wait: the wait pays off. File creation is
# INDEPENDENT of hook returns (one spawn's file appeared 2.40s before any
# blocking hook fired), so this wait cannot self-deadlock.
$h = New-TestHome
$childW = 'eeeeeeee-1111-4111-8111-eeeeeeeeeeee'
$parentW = '66666666-6666-4666-8666-666666666666'
New-Marker $h $SLUG $parentW
$job = Start-Job -ScriptBlock {
    param($root, $slug, $parent, $child)
    Start-Sleep -Milliseconds 700
    $dir = [System.IO.Path]::Combine($root, '.cursor', 'projects', $slug, 'agent-transcripts', $parent, 'subagents')
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($dir, ($child + '.jsonl')), '')
} -ArgumentList $h, $SLUG, $parentW, $childW
$r = Resolve-RogueParentSession (New-Payload $childW)
Receive-Job $job -Wait -AutoRemoveJob | Out-Null
Assert-Eq $r.Parent $parentW 'live marker: waited and resolved once the file appeared'
Assert-Eq $r.Child $childW 'mid-wait resolution carries the child id'

# Malformed input never throws and never resolves.
$h = New-TestHome
Assert-Null (Resolve-RogueParentSession '{"conversation_id":"../../etc/passwd"}') 'a traversal-shaped id resolves to nothing'
Assert-Null (Resolve-RogueParentSession 'not json at all') 'an unparseable payload resolves to nothing'
Assert-Null (Resolve-RogueParentSession '{}') 'a payload with no conversation_id resolves to nothing'

# ── teardown ───────────────────────────────────────────────────────────────
foreach ($d in $homes) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
$env:USERPROFILE = $null

Write-Host ''
if ($fails -gt 0) {
    Write-Host "$fails of $count Cursor hook.ps1 assertions FAILED"
    exit 1
}
Write-Host "All $count Cursor hook.ps1 assertions passed."
exit 0
