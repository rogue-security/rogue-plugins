param([string]$Poll, [string]$Base, [string]$ScriptDirectory=$PSScriptRoot)
$script:RPHelperDirectory=$ScriptDirectory
$script:RPDirectory=$null
$script:RPRevision=$null
$script:RPKey=$null

function Write-RogueProtectionFile([string]$Path, [string]$Value) {
    $temp = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($temp, $Value, (New-Object Text.UTF8Encoding($false)))
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temp, $Path) }
}
function Test-RogueProtectionDecision($Decision) {
    if ($null -eq $Decision -or $Decision.protocolVersion -ne 1 -or $Decision.revision -isnot [long] -and $Decision.revision -isnot [int] -or $Decision.revision -lt 0) { return $false }
    foreach ($cap in 'aidr','aispm') {
        $value=$Decision.$cap
        if ($null -eq $value -or $value.paused -isnot [bool] -or ($value.revision -isnot [long] -and $value.revision -isnot [int]) -or $value.revision -lt 0) { return $false }
    }
    return $true
}
function Get-RogueProtectionState {
    try {
        $value = Get-Content -LiteralPath "$script:RPDirectory/state.json" -Raw | ConvertFrom-Json
        if (-not (Test-RogueProtectionDecision $value.decision)) { return $null }
        $serverNow = ([DateTimeOffset]$value.decision.serverTime).AddSeconds(([DateTimeOffset]::UtcNow - ([DateTimeOffset]$value.receivedAt)).TotalSeconds)
        foreach ($cap in 'aidr','aispm') {
            if ($value.decision.$cap.expiresAt -and ([DateTimeOffset]$value.decision.$cap.expiresAt) -le $serverNow) { $value.decision.$cap.paused = $false }
        }
        return $value.decision
    } catch { return $null }
}
function Test-RogueProtectionCurrent {
    if (-not $script:RPDirectory) { return $true }
    if ($script:RPPersistenceFailed -or (Test-Path -LiteralPath "$script:RPDirectory/persistence-failed")) { return $false }
    $state = Get-RogueProtectionState
    return ($null -ne $state) -and ((-not $state.aidr.paused) -and ($null -eq $script:RPRevision -or $state.aidr.revision -eq $script:RPRevision))
}
function Send-RogueProtectionAck {
    if ($script:RPPersistenceFailed -or (Test-Path -LiteralPath "$script:RPDirectory/persistence-failed")) { return }
    $state = Get-RogueProtectionState
    if (-not $state) { return }
    foreach ($lease in @(Get-ChildItem -LiteralPath $script:RPDirectory -Filter 'active.*' -ErrorAction SilentlyContinue)) {
        $owner = 0
        if ([int]::TryParse(($lease.Name -replace '^active\.',''), [ref]$owner) -and (Get-Process -Id $owner -ErrorAction SilentlyContinue)) { return }
        Remove-Item -LiteralPath $lease.FullName -ErrorAction SilentlyContinue
    }
    $identity = "$($state.revision):$($state.aidr.paused):$($state.aispm.paused)"
    if ((Get-Content -LiteralPath "$script:RPDirectory/ack" -Raw -ErrorAction SilentlyContinue) -eq $identity) { return }
    try {
        $body = @{ protocolVersion=1; revision=$state.revision; status='applied'; aidrPaused=[bool]$state.aidr.paused; aispmPaused=[bool]$state.aispm.paused } | ConvertTo-Json -Compress
        $null = Invoke-RestMethod -ErrorAction Stop -Uri "$script:RPBase/api/v1/hooks/protection/ack" -Method Post -Headers @{'x-rogue-api-key'=$script:RPKey} -ContentType 'application/json' -Body $body -TimeoutSec 5
        Write-RogueProtectionFile "$script:RPDirectory/ack" $identity
    } catch { }
}
function Update-RogueProtection {
    if (-not $script:RPDirectory) { return }
    try {
        $lock = [IO.File]::Open("$script:RPDirectory/refresh.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch { return }
    try {
        Write-RogueProtectionFile "$script:RPDirectory/attempt" ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString())
        $state = Invoke-RestMethod -ErrorAction Stop -Uri "$script:RPBase/api/v1/hooks/protection/state" -Headers @{'x-rogue-api-key'=$script:RPKey} -TimeoutSec 5
        $old = Get-RogueProtectionState
        if ((Test-RogueProtectionDecision $state) -and ($null -eq $old -or $state.revision -ge $old.revision)) {
            try {
                Write-RogueProtectionFile "$script:RPDirectory/state.json" (@{ decision=$state; receivedAt=[DateTimeOffset]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 8 -Compress)
                Remove-Item -LiteralPath "$script:RPDirectory/persistence-failed" -Force -ErrorAction SilentlyContinue
                $script:RPPersistenceFailed=$false
            } catch {
                $script:RPPersistenceFailed=$true
                try { Write-RogueProtectionFile "$script:RPDirectory/persistence-failed" '1' } catch {}
                $body=@{protocolVersion=1;revision=$state.revision;status='failed';aidrPaused=[bool]$state.aidr.paused;aispmPaused=[bool]$state.aispm.paused;error='state_persistence_failed'} | ConvertTo-Json -Compress
                try { $null=Invoke-RestMethod -ErrorAction Stop -Uri "$script:RPBase/api/v1/hooks/protection/ack" -Method Post -Headers @{'x-rogue-api-key'=$script:RPKey} -ContentType 'application/json' -Body $body -TimeoutSec 5 } catch {}
            }
        }
    } catch { } finally { $lock.Dispose() }
    Send-RogueProtectionAck
}
function Initialize-RogueProtection([string]$Key, [string]$BaseUrl, [string]$Slug, [string]$Family, [string]$Surface='default', [string]$Version='unknown') {
    if (-not $Key) { return $Key }
    if (-not $BaseUrl) { $BaseUrl='https://api.rogue.security' }
    $script:RPBase=$BaseUrl.TrimEnd('/')
    $root=$env:ROGUE_PROTECTION_DIR
    if (-not $root) {
        $profilePath=$env:USERPROFILE
        if (-not $profilePath) { $profilePath=[Environment]::GetFolderPath('UserProfile') }
        $root=Join-Path $profilePath '.rogue/protection'
    }
    $hash=[Security.Cryptography.SHA256]::Create()
    try { $id=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes("$script:RPBase`n$Key")))).Replace('-','').ToLowerInvariant() } finally { $hash.Dispose() }
    $script:RPDirectory=Join-Path $root "$Slug-default-$id"
    if ($env:ROGUE_PROTECTION_STATE -and (Split-Path $env:ROGUE_PROTECTION_STATE -Leaf).StartsWith("$Slug-default-") -and (Get-Content -LiteralPath (Join-Path $env:ROGUE_PROTECTION_STATE 'credential') -Raw -ErrorAction SilentlyContinue) -eq $Key) { $script:RPDirectory=$env:ROGUE_PROTECTION_STATE }
    try { $null=[IO.Directory]::CreateDirectory($script:RPDirectory) } catch { $script:RPDirectory=$null; return $Key }
    $linked=Get-Content -LiteralPath "$script:RPDirectory/installation-directory" -Raw -ErrorAction SilentlyContinue
    if ($linked -and (Split-Path $linked -Parent) -eq $root -and (Split-Path $linked -Leaf).StartsWith("$Slug-default-") -and (Get-Content -LiteralPath "$linked/base" -Raw -ErrorAction SilentlyContinue) -eq $script:RPBase) { $script:RPDirectory=$linked }
    try { Write-RogueProtectionFile "$script:RPDirectory/used" ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString()) } catch {}
    $credential="$script:RPDirectory/credential"
    try { Write-RogueProtectionFile "$script:RPDirectory/base" $script:RPBase } catch {}
    if (-not (Test-Path -LiteralPath $credential)) {
        foreach ($previous in @(Get-ChildItem -LiteralPath $root -Directory -Filter "$Slug-default-*" -ErrorAction SilentlyContinue)) {
            if ($previous.FullName -eq $script:RPDirectory -or (Get-Content -LiteralPath (Join-Path $previous.FullName 'base') -Raw -ErrorAction SilentlyContinue) -ne $script:RPBase) { continue }
            $previousKey=Get-Content -LiteralPath (Join-Path $previous.FullName 'credential') -Raw -ErrorAction SilentlyContinue
            if (-not $previousKey) { continue }
            try {
                $body=@{type='coding_agent';name=$Slug;family=$Family;host=[Environment]::MachineName;version=$Version} | ConvertTo-Json -Compress
                $restored=Invoke-RestMethod -ErrorAction Stop -Uri "$script:RPBase/api/v1/hooks/protection/enroll" -Method Post -Headers @{'x-rogue-api-key'=$Key;'x-rogue-installation-key'=$previousKey} -ContentType 'application/json' -Body $body -TimeoutSec 5
                if ($restored.apiKey -ne $previousKey) { continue }
                Write-RogueProtectionFile "$script:RPDirectory/installation-directory" $previous.FullName
                $script:RPDirectory=$previous.FullName
                $credential=Join-Path $script:RPDirectory 'credential'
                try { Write-RogueProtectionFile "$script:RPDirectory/used" ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString()) } catch {}
                break
            } catch { if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -notin 401,403) { return $Key } }
        }
    }
    if (-not (Test-Path -LiteralPath $credential)) {
        $enrollAttempt=0L
        $null=[long]::TryParse((Get-Content -LiteralPath "$script:RPDirectory/enroll-attempt" -Raw -ErrorAction SilentlyContinue), [ref]$enrollAttempt)
        if ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $enrollAttempt -lt 60) { if (Test-Path -LiteralPath "$script:RPDirectory/legacy-server") { $script:RPDirectory=$null }; return $Key }
        try { $lock=[IO.File]::Open("$script:RPDirectory/enroll.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) } catch { return $Key }
        try {
            if (-not (Test-Path -LiteralPath $credential)) {
                Write-RogueProtectionFile "$script:RPDirectory/enroll-attempt" ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString())
                $nonce=Get-Content -LiteralPath "$script:RPDirectory/enrollment-nonce" -Raw -ErrorAction SilentlyContinue
                if (-not $nonce) { $nonce=[Guid]::NewGuid().ToString('N'); Write-RogueProtectionFile "$script:RPDirectory/enrollment-nonce" $nonce }
                $body=@{ enrollmentNonce=$nonce; type='coding_agent'; name=$Slug; family=$Family; host=[Environment]::MachineName; version=$Version } | ConvertTo-Json -Compress
                Remove-Item -LiteralPath "$script:RPDirectory/legacy-server" -Force -ErrorAction SilentlyContinue
                $enrolled=Invoke-RestMethod -ErrorAction Stop -Uri "$script:RPBase/api/v1/hooks/protection/enroll" -Method Post -Headers @{'x-rogue-api-key'=$Key} -ContentType 'application/json' -Body $body -TimeoutSec 5
                if ($enrolled.alreadyEnrolled) { $enrolled | Add-Member -NotePropertyName apiKey -NotePropertyValue $Key -Force }
                if ($enrolled.apiKey) { Write-RogueProtectionFile $credential $enrolled.apiKey }
            }
        } catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { try { Write-RogueProtectionFile "$script:RPDirectory/legacy-server" '1' } catch {} }
        } finally { $lock.Dispose() }
    }
    if (-not (Test-Path -LiteralPath $credential)) { if (Test-Path -LiteralPath "$script:RPDirectory/legacy-server") { $script:RPDirectory=$null }; return $Key }
    $script:RPKey=Get-Content -LiteralPath $credential -Raw
    $attempt=0L
    $null=[long]::TryParse((Get-Content -LiteralPath "$script:RPDirectory/attempt" -Raw -ErrorAction SilentlyContinue), [ref]$attempt)
    if ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $attempt -ge 15) { Update-RogueProtection }
    $pollLock=$null
    try { $pollLock=[IO.File]::Open("$script:RPDirectory/poll-start.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) } catch {}
    try {
    $pollPid=0
    $null=[int]::TryParse((Get-Content -LiteralPath "$script:RPDirectory/poll.pid" -Raw -ErrorAction SilentlyContinue), [ref]$pollPid)
    if ($pollLock -and -not ($pollPid -and (Get-Process -Id $pollPid -ErrorAction SilentlyContinue))) {
        $scriptFile=Join-Path $script:RPHelperDirectory 'protection.ps1'
        $escape={param($s) "'" + $s.Replace("'", "''") + "'"}
        $command="& ([scriptblock]::Create((Get-Content -Raw -LiteralPath $(& $escape $scriptFile)))) -Poll $(& $escape $script:RPDirectory) -Base $(& $escape $script:RPBase)"
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $params=@{ FilePath=(Get-Process -Id $PID).Path; ArgumentList=@('-NoProfile','-NonInteractive','-EncodedCommand',$encoded); PassThru=$true }
        if ($env:OS -eq 'Windows_NT') { $params.WindowStyle='Hidden' }
        try { $child=Start-Process @params; Write-RogueProtectionFile "$script:RPDirectory/poll.pid" $child.Id.ToString() } catch { }
    }
    } finally { if ($pollLock) { $pollLock.Dispose() } }
    $state=Get-RogueProtectionState
    $script:RPRevision=if ($state) { $state.aidr.revision } else { $null }
    $env:ROGUE_PROTECTION_STATE=$script:RPDirectory
    $env:ROGUE_LOG_FILE=Join-Path $script:RPDirectory "$Slug.log"
    $script:logFile=$env:ROGUE_LOG_FILE
    return $script:RPKey
}
function Read-RogueProtectionInput {
    $reader=[Console]::OpenStandardInput()
    $buffer=New-Object byte[] 4096
    $text=New-Object IO.MemoryStream
    while (Test-RogueProtectionCurrent) {
        $pending=$reader.ReadAsync($buffer,0,$buffer.Length)
        while (-not $pending.IsCompleted) {
            if (-not (Test-RogueProtectionCurrent)) { return '' }
            Start-Sleep -Milliseconds 100
        }
        $count=$pending.GetAwaiter().GetResult()
        if ($count -eq 0) { break }
        if (-not (Test-RogueProtectionCurrent)) { return '' }
        $text.Write($buffer,0,$count)
    }
    $bytes=$text.ToArray(); $text.Dispose()
    if (Test-RogueProtectionCurrent) { return [Console]::InputEncoding.GetString($bytes) }
    return ''
}
function Leave-RogueProtection {
    if (-not $script:RPDirectory) { return }
    Remove-Item -LiteralPath "$script:RPDirectory/active.$PID" -Force -ErrorAction SilentlyContinue
    Send-RogueProtectionAck
}
function Enter-RogueProtection {
    if (-not (Test-RogueProtectionCurrent)) { return $false }
    if ($script:RPDirectory) {
        try { Write-RogueProtectionFile "$script:RPDirectory/active.$PID" ([string]$script:RPRevision) }
        catch {
            $script:RPPersistenceFailed=$true
            $state=Get-RogueProtectionState
            if ($state) {
                $body=@{protocolVersion=1;revision=$state.revision;status='failed';aidrPaused=$state.aidr.paused;aispmPaused=$state.aispm.paused;error='state_persistence_failed'} | ConvertTo-Json -Compress
                try { $null=Invoke-RestMethod -ErrorAction Stop -Uri "$script:RPBase/api/v1/hooks/protection/ack" -Method Post -Headers @{'x-rogue-api-key'=$script:RPKey} -ContentType 'application/json' -Body $body -TimeoutSec 5 } catch {}
            }
            return $false
        }
    }
    return Test-RogueProtectionCurrent
}
if ($Poll) {
    $script:RPDirectory=$Poll; $script:RPBase=$Base
    $script:RPKey=Get-Content -LiteralPath "$Poll/credential" -Raw
    while ($true) {
        $used=0L
        $null=[long]::TryParse((Get-Content -LiteralPath "$Poll/used" -Raw -ErrorAction SilentlyContinue), [ref]$used)
        $busy=@(Get-ChildItem -LiteralPath $Poll -Filter 'active.*' -ErrorAction SilentlyContinue | Where-Object { $owner=0; [int]::TryParse(($_.Name -replace '^active\.',''),[ref]$owner) -and (Get-Process -Id $owner -ErrorAction SilentlyContinue) }).Count -gt 0
        if ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $used -ge 90 -and -not $busy) { break }
        Update-RogueProtection
        Start-Sleep -Seconds 15
    }
}
