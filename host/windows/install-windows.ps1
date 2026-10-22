# One-time Windows host setup for dsh-remote.
#
# What it does (idempotent):
#   1. appends `trustedHosts: [<domain>]` to the DSH desktop profile patch
#      (%USERPROFILE%\.dsh\profiles\desktop\cordis.patch.yml); the patch layer
#      hot-reloads, no DSH restart needed.
#   2. creates a dedicated ed25519 key for the reverse tunnel.
#   3. mints the initial browser-session cookie include (dsh-cookie.inc).
#   4. registers Task Scheduler tasks:
#        dsh-remote-tunnel   - runs the watchdog at logon
#        dsh-remote-refresh  - re-mints and pushes the cookie daily
#
# Run this in an elevated PowerShell (task registration needs it), or pass
# -SkipTasks and register the tasks manually (see README).
#
# Example:
#   .\install-windows.ps1 -Domain dsh.example.com -RelayHost relay.example.com `
#       -RelayUser dsh-tunnel -CookieRelayUser root

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Domain,
  [string]$RelayHost,
  [string]$RelayUser = 'dsh-tunnel',
  [int]$RelaySshPort = 22,
  [int]$RemotePort = 9100,
  [string]$StateDir = (Join-Path $env:LOCALAPPDATA 'dsh-remote'),
  [string]$KeyPath,
  [string]$Credentials = (Join-Path $HOME '.dsh\.credentials.yaml'),
  [string]$CookieRelayUser = 'root',
  [string]$CookieIdentityFile,
  [string]$NginxContainer,
  [string]$RemoteIncPath = '/etc/nginx/conf.d/dsh-cookie.inc',
  [string]$RefreshTime = '04:00',
  [switch]$SkipCookiePush,
  [switch]$SkipTasks
)

$ErrorActionPreference = 'Stop'
if ($Domain -notmatch '^[A-Za-z0-9.-]+$') { throw '-Domain must be a bare host name, e.g. dsh.example.com' }

$null = New-Item -ItemType Directory -Force -Path $StateDir
if (-not $KeyPath) { $KeyPath = Join-Path $StateDir 'id_ed25519_dsh_remote' }

$sshKeygen = (Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue)
if ($null -eq $sshKeygen) { throw 'ssh-keygen.exe not found; install the Windows OpenSSH client first.' }

# ---------------------------------------------------------------- 1. trustedHosts
$profileDir = Join-Path $HOME '.dsh\profiles\desktop'
$patchPath = Join-Path $profileDir 'cordis.patch.yml'
if (-not (Test-Path -LiteralPath $profileDir)) {
  throw "DSH desktop profile not found at $profileDir - start the DSH desktop app once first."
}
$patchText = ''
if (Test-Path -LiteralPath $patchPath) { $patchText = [System.IO.File]::ReadAllText($patchPath) }

if ($patchText -match '(?m)^\s*trustedHosts\s*:') {
  if ($patchText -match ('(?m)^\s*-\s*' + [regex]::Escape($Domain) + '\s*$')) {
    Write-Host "[trustedHosts] $Domain already present, leaving patch untouched"
  } else {
    throw "cordis.patch.yml already has a trustedHosts block that does not contain $Domain. Add it manually:`n$patchPath"
  }
} else {
  $backup = Join-Path $StateDir ('cordis.patch.yml.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  if ($patchText) { [System.IO.File]::WriteAllText($backup, $patchText, (New-Object System.Text.UTF8Encoding($false))) }
  if ($patchText -and -not $patchText.EndsWith("`n")) { $patchText += "`n" }
  $block = @(
    '- id: connection',
    '  config:',
    '    trustedHosts:',
    ('      - ' + $Domain)
  ) -join "`n"
  $patchText += $block + "`n"
  [System.IO.File]::WriteAllText($patchPath, $patchText, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "[trustedHosts] appended $Domain to $patchPath (backup: $backup)"
}

# ---------------------------------------------------------------- 2. tunnel key
if (Test-Path -LiteralPath $KeyPath) {
  Write-Host "[ssh key] reusing $KeyPath"
} else {
  & $sshKeygen.Source -t ed25519 -f $KeyPath -N '""' -C 'dsh-remote' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed with exit code $LASTEXITCODE" }
  Write-Host "[ssh key] generated $KeyPath"
}
$pubKeyPath = "$KeyPath.pub"
if (-not (Test-Path -LiteralPath $pubKeyPath)) { throw "public key missing: $pubKeyPath" }
$pubKey = (Get-Content -LiteralPath $pubKeyPath -Raw).Trim()

# ---------------------------------------------------------------- 3. cookie
$mintScript = Join-Path $PSScriptRoot 'mint-cookie.ps1'
$incPath = Join-Path $StateDir 'dsh-cookie.inc'
& $mintScript -Authority $Domain -Credentials $Credentials -WriteInc $incPath
Write-Host "[cookie] minted $incPath (30-day bearer credential, keep it private)"

if ($RelayHost -and -not $SkipCookiePush) {
  $refreshScript = Join-Path $PSScriptRoot 'refresh-cookie.ps1'
  $refreshArgs = @{
    Authority      = $Domain
    RelayHost      = $RelayHost
    RelayUser      = $CookieRelayUser
    RelaySshPort   = $RelaySshPort
    RemoteIncPath  = $RemoteIncPath
    StateDir       = $StateDir
    Credentials    = $Credentials
  }
  if ($CookieIdentityFile) { $refreshArgs['IdentityFile'] = $CookieIdentityFile }
  if ($NginxContainer) { $refreshArgs['NginxContainer'] = $NginxContainer }
  & $refreshScript @refreshArgs
}

# ---------------------------------------------------------------- 4. tasks
if (-not $SkipTasks) {
  if (-not $RelayHost) { throw '-RelayHost is required to register the tunnel task' }

  $tunnelCmd = Join-Path $StateDir 'run-tunnel.cmd'
  $tunnelArgs = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', ('"' + (Join-Path $PSScriptRoot 'tunnel.ps1') + '"'),
    '-RelayHost', $RelayHost,
    '-RelayUser', $RelayUser,
    '-RelaySshPort', $RelaySshPort,
    '-RemotePort', $RemotePort,
    '-IdentityFile', ('"' + $KeyPath + '"')
  ) -join ' '
  $tunnelCmdText = "@echo off`r`nstart `"`" /min powershell.exe $tunnelArgs`r`n"
  [System.IO.File]::WriteAllText($tunnelCmd, $tunnelCmdText, (New-Object System.Text.UTF8Encoding($false)))

  $principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType Interactive -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

  $tunnelAction = New-ScheduledTaskAction -Execute $tunnelCmd -WorkingDirectory $StateDir
  $tunnelTrigger = New-ScheduledTaskTrigger -AtLogOn -User ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
  Register-ScheduledTask -TaskName 'dsh-remote-tunnel' -Action $tunnelAction -Trigger $tunnelTrigger `
    -Principal $principal -Settings $settings -Description 'DSH remote reverse SSH tunnel watchdog' -Force | Out-Null
  Write-Host "[task] dsh-remote-tunnel registered (runs at logon)"

  if ($RelayHost) {
    $refreshCmd = Join-Path $StateDir 'run-refresh.cmd'
    $refreshCmdArgs = @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass',
      '-File', ('"' + (Join-Path $PSScriptRoot 'refresh-cookie.ps1') + '"'),
      '-Authority', $Domain,
      '-RelayHost', $RelayHost,
      '-RelayUser', $CookieRelayUser,
      '-RelaySshPort', $RelaySshPort,
      '-RemoteIncPath', $RemoteIncPath
    ) -join ' '
    $refreshCmdText = "@echo off`r`npowershell.exe $refreshCmdArgs`r`n"
    [System.IO.File]::WriteAllText($refreshCmd, $refreshCmdText, (New-Object System.Text.UTF8Encoding($false)))

    $refreshTrigger = New-ScheduledTaskTrigger -Daily -At $RefreshTime
    $refreshAction = New-ScheduledTaskAction -Execute $refreshCmd -WorkingDirectory $StateDir
    Register-ScheduledTask -TaskName 'dsh-remote-refresh' -Action $refreshAction -Trigger $refreshTrigger `
      -Principal $principal -Settings $settings -Description 'Re-mint and push the DSH remote browser cookie' -Force | Out-Null
    Write-Host "[task] dsh-remote-refresh registered (daily at $RefreshTime)"
  }
}

# ---------------------------------------------------------------- next steps
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Authorize this public key on the relay:'
Write-Host ('     ' + $pubKey)
Write-Host '  2. Run relay/install-relay.sh on the relay (see README) and point it at your domain/certs.'
Write-Host ('  3. If you skipped the cookie push, run host/windows/refresh-cookie.ps1 -Authority ' + $Domain + ' -RelayHost <relay>.')
Write-Host '  4. Open https://<domain>/ from a phone; the login page asks for the relay account/password.'
