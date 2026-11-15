$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$task='C:\ProgramData\Rogue-Cortex-QA-FIRE-3075'
$q='C:\Users\test\cortex-qa-FIRE-3075'
$result=[ordered]@{Task='FIRE-3075';Host=$env:COMPUTERNAME;Errors=@()}
try {
    $before=Get-Content "$task\ssh-before.json" -Raw | ConvertFrom-Json
    $keys=Get-Content "$task\key-state.json" -Raw | ConvertFrom-Json
    $authorized='C:\ProgramData\ssh\administrators_authorized_keys'
    if ($keys.Existed) {
        Copy-Item "$task\administrators_authorized_keys.before" $authorized -Force
        $acl=Get-Acl $authorized
        $acl.SetSecurityDescriptorSddlForm((Get-Content "$task\key-acl.before" -Raw).Trim())
        Set-Acl $authorized $acl
    } elseif (Test-Path $authorized) { Remove-Item $authorized -Force }
    $result.AuthorizedKeysRestored=((Test-Path $authorized) -eq [bool]$keys.Existed)
    if ($before.FirewallExisted) {
        Set-NetFirewallRule -Name OpenSSH-Server-In-TCP -Enabled $before.FirewallEnabled
    } else { Get-NetFirewallRule -Name OpenSSH-Server-In-TCP -ErrorAction SilentlyContinue | Remove-NetFirewallRule }
    $result.FirewallRestored=((@(Get-NetFirewallRule -Name OpenSSH-Server-In-TCP -ErrorAction SilentlyContinue).Count -gt 0) -eq [bool]$before.FirewallExisted)
    powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\Program Files\OpenSSH\uninstall-sshd.ps1' > "$task\ssh-uninstall.log" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "uninstall-sshd.ps1 exit=$LASTEXITCODE" }
    Start-Sleep -Seconds 3
    $result.SshdAbsent=(-not (Get-Service sshd -ErrorAction SilentlyContinue))
    for ($i=0;$i -lt 5 -and (Test-Path 'C:\Program Files\OpenSSH');$i++) {
        Remove-Item 'C:\Program Files\OpenSSH' -Recurse -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
    $result.OpenSshFolderAbsent=(-not (Test-Path 'C:\Program Files\OpenSSH'))
    $machinePath=[Environment]::GetEnvironmentVariable('Path','Machine')
    $newPath=($machinePath.Split(';') | Where-Object { $_.TrimEnd('\') -ine 'C:\Program Files\OpenSSH' }) -join ';'
    [Environment]::SetEnvironmentVariable('Path',$newPath,'Machine')
    $result.TaskMachinePathEntryAbsent=(-not ([Environment]::GetEnvironmentVariable('Path','Machine').Split(';') | Where-Object { $_.TrimEnd('\') -ieq 'C:\Program Files\OpenSSH' }))
    foreach ($file in @('C:\Users\test\.rogue\logs\cortex.log','C:\Users\test\.rogue\logs\cortex.log.1','C:\Users\test\Desktop\cortex-ssh-status-FIRE-3075.txt','C:\Users\test\Desktop\cortex-setup-ssh-FIRE-3075.ps1','C:\Users\test\Downloads\cortex-setup-ssh-FIRE-3075.ps1')) {
        if(Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
    Remove-Item -LiteralPath $q -Recurse -Force
    $result.GuestQaFolderAbsent=(-not (Test-Path $q))
    $result.CortexConfigAbsent=(-not (Test-Path 'C:\Users\test\.snowflake'))
    $result.CortexCliAbsent=(-not (Test-Path 'C:\Users\test\AppData\Local\cortex'))
    $result.CortexDesktopAbsent=(-not (Test-Path 'C:\Users\test\AppData\Local\Programs\Cortex Code'))
    Remove-Item -LiteralPath $task -Recurse -Force
    $result.GuestSshSetupFolderAbsent=(-not (Test-Path $task))
} catch { $result.Errors+= $_.Exception.Message }
try { Unregister-ScheduledTask -TaskName RogueCortexFIRE3075Cleanup -Confirm:$false; $result.CleanupScheduledTaskAbsent=(-not (Get-ScheduledTask -TaskName RogueCortexFIRE3075Cleanup -ErrorAction SilentlyContinue)) } catch { $result.Errors+=$_.Exception.Message }
$result.AllChecksPassed=($result.Errors.Count -eq 0 -and -not ($result.Values | Where-Object {$_ -is [bool] -and -not $_}))
$body=$result|ConvertTo-Json -Depth 5
$body | Set-Content 'C:\Windows\Temp\cortex-FIRE-3075-cleanup-result.json'
try { Invoke-WebRequest -UseBasicParsing -Uri 'http://192.168.64.1:43662/status' -Method Post -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 10 | Out-Null } catch {}
Remove-Item -LiteralPath 'C:\Windows\Temp\cortex-FIRE-3075-cleanup-result.json' -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
