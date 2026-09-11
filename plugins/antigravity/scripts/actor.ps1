# Outputs @{ Email; Name } for the bridges whose host supplies no identity
# (codex, cursor, copilot, antigravity, kiro). Twin of actor.sh, one cascade per
# field: env file -> git config files (scripts/git-identity.ps1, never git.exe)
# -> <login>@<host> / login -> marker "unknown", never blank. plugins/rogue keeps
# its own cascade in hook.ps1 (it screens the Cowork sandbox identity).
#
# Load as a scriptblock (running a .ps1 by path is subject to ExecutionPolicy):
#   . ([scriptblock]::Create((Get-Content -Raw -LiteralPath $lib)))
#   $actor = Resolve-RogueSharedActor $creds $pluginRoot
# Windows PowerShell 5.1 compatible.

function Read-RogueGitIdentityFile {
    param([string]$PluginRoot)
    try {
        $lib = Join-Path $PluginRoot 'scripts\git-identity.ps1'
        if (Test-Path -LiteralPath $lib) {
            $id = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $lib)))
            if ($id) { return $id }
        }
    } catch {}
    return @{ Email = ''; Name = '' }
}

function Resolve-RogueSharedActor {
    param([hashtable]$Creds, [string]$PluginRoot)
    if ($null -eq $Creds) { $Creds = @{} }
    $name  = [string]$Creds['ROGUE_ACTOR_NAME']
    $email = [string]$Creds['ROGUE_ACTOR_EMAIL']
    if (-not $name -or -not $email) {
        $git = Read-RogueGitIdentityFile $PluginRoot
        if (-not $name)  { $name  = [string]$git.Name }
        if (-not $email) { $email = [string]$git.Email }
    }
    # [Environment]::UserName reads the process token, so it still answers in the
    # service contexts where USERNAME is unset; same for the DNS host name.
    $login = [string]$env:USERNAME
    if (-not $login) { $login = [string][Environment]::UserName }
    if (-not $name) { $name = $login }
    if (-not $email) {
        $hostName = [string]$env:COMPUTERNAME
        if (-not $hostName) { try { $hostName = [string][System.Net.Dns]::GetHostName() } catch {} }
        if ($login -and $hostName) { $email = "$login@$hostName" }
        elseif ($login) { $email = $login } else { $email = $hostName }
    }
    if (-not $name)  { $name  = 'unknown' }
    if (-not $email) { $email = 'unknown' }
    return @{ Email = $email; Name = $name }
}
