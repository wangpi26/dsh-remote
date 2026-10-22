# DSH remote reverse-tunnel watchdog (Windows PowerShell 5.1+).
#
# Discovers the DSH desktop host's loopback port and keeps an SSH reverse tunnel
#   relay 127.0.0.1:<RemotePort>  ->  local 127.0.0.1:<dsh-port>
# alive. Reconnects when ssh exits, when the DSH port changes (the desktop host
# picks a random port on every launch), and cleans up only its own orphaned
# ssh processes.
#
# Typical use (run it from Task Scheduler at logon; see install-windows.ps1):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tunnel.ps1 `
#       -RelayHost relay.example.com -RelayUser dsh-tunnel `
#       -IdentityFile "$env:LOCALAPPDATA\dsh-remote\id_ed25519_dsh_remote"
#
# Notes
#  * The relay must authorize the public key. A restricted key entry looks like:
#      restrict,port-forwarding,permitlisten="127.0.0.1:9100" ssh-ed25519 AAAA... dsh-remote
#  * Do not run two watchdogs for the same relay/remote port: a named mutex makes
#    the second instance exit.

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$RelayHost,
  [string]$RelayUser = 'root',
  [int]$RelaySshPort = 22,
  [int]$RemotePort = 9100,
  [int]$LocalPort = 0,
  [string]$IdentityFile,
  [string]$KnownHostsFile = (Join-Path $env:LOCALAPPDATA 'dsh-remote\known_hosts'),
  [string]$StateDir = (Join-Path $env:LOCALAPPDATA 'dsh-remote'),
  [int]$CheckIntervalSeconds = 15,
  [int]$RetryDelaySeconds = 5
)

$ErrorActionPreference = 'Continue'
$null = New-Item -ItemType Directory -Force -Path $StateDir
$log = Join-Path $StateDir 'tunnel.log'
$errLog = Join-Path $StateDir 'tunnel-ssh.err.log'

$sshExe = (Get-Command ssh.exe -ErrorAction SilentlyContinue)
if ($null -eq $sshExe) { throw 'ssh.exe not found; install the Windows OpenSSH client first.' }

# One watchdog per relay target. Hash keeps the mutex name short and stable.
$mutexId = [System.BitConverter]::ToString(
  [System.Security.Cryptography.SHA1]::Create().ComputeHash(
    [System.Text.Encoding]::UTF8.GetBytes("$RelayHost`:$RelaySshPort`:$RemotePort")
  )
).Replace('-', '').Substring(0, 8)
$mutex = $null
foreach ($scope in @('Global', 'Local')) {
  try {
    $mutex = New-Object System.Threading.Mutex($false, "$scope\dsh-remote-tunnel-$mutexId")
    break
  } catch { }
}
if ($null -eq $mutex) { exit 0 }
try {
  if (-not $mutex.WaitOne(0)) { exit 0 }   # another watchdog already runs
} catch { exit 0 }

function Write-Log {
  param([string]$Message)
  $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $Message
  try {
    Add-Content -Path $log -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    $item = Get-Item $log -ErrorAction SilentlyContinue
    if ($null -ne $item -and $item.Length -gt 5242880) {
      Move-Item -Path $log -Destination ($log + '.1') -Force -ErrorAction SilentlyContinue
    }
  } catch { }
}

function Get-DshHostPort {
  # Explicit override wins; useful when auto-discovery is not possible.
  if ($LocalPort -gt 0) { return $LocalPort }
  $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'DeepSeek*' -and $_.CommandLine -ne $null -and $_.CommandLine.Contains('dsh-desktop-host') }
  foreach ($process in $processes) {
    $listener = Get-NetTCPConnection -State Listen -OwningProcess $process.ProcessId -ErrorAction SilentlyContinue |
      Where-Object { $_.LocalAddress -eq '127.0.0.1' -and $_.LocalPort -gt 0 } |
      Sort-Object LocalPort | Select-Object -First 1
    if ($null -ne $listener) { return [int]$listener.LocalPort }
  }
  return $null
}

function Quote-Arg {
  param([string]$Value)
  if ($Value -match '[\s"]') { return '"' + $Value.Replace('"', '\"') + '"' }
  return $Value
}

function Start-Tunnel {
  param([int]$Port)
  $arguments = @(
    '-N', '-T',
    '-p', [string]$RelaySshPort,
    '-o', 'BatchMode=yes',
    '-o', 'ExitOnForwardFailure=yes',
    '-o', 'ServerAliveInterval=20',
    '-o', 'ServerAliveCountMax=3',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', ('UserKnownHostsFile=' + $KnownHostsFile),
    '-o', 'ConnectTimeout=10',
    '-o', 'LogLevel=ERROR'
  )
  if ($IdentityFile) {
    if (-not (Test-Path -LiteralPath $IdentityFile)) { throw "identity file not found: $IdentityFile" }
    $arguments += @('-i', $IdentityFile, '-o', 'IdentitiesOnly=yes')
  }
  $arguments += @('-R', ("127.0.0.1:{0}:127.0.0.1:{1}" -f $RemotePort, $Port), ("{0}@{1}" -f $RelayUser, $RelayHost))
  $argumentString = ($arguments | ForEach-Object { Quote-Arg $_ }) -join ' '
  return Start-Process -FilePath $sshExe.Source -ArgumentList $argumentString -WindowStyle Hidden -PassThru `
    -RedirectStandardError $errLog
}

# Kill only orphaned tunnels for this exact relay/remote port (never other ssh sessions).
$forwardPattern = "127.0.0.1:$RemotePort:127.0.0.1:"
$atPattern = '@' + $RelayHost
Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue |
  Where-Object {
    $_.CommandLine -ne $null -and
    $_.CommandLine.Contains($forwardPattern) -and
    $_.CommandLine.Contains($atPattern)
  } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Write-Log ("watchdog starting; relay={0}@{1}:{2} remote={3} local={4}" -f $RelayUser, $RelayHost, $RelaySshPort, $RemotePort, $(if ($LocalPort -gt 0) { $LocalPort } else { 'auto' }))

while ($true) {
  $port = Get-DshHostPort
  if ($null -eq $port) {
    Write-Log 'DSH desktop host port not found; waiting'
    Start-Sleep -Seconds $CheckIntervalSeconds
    continue
  }

  try {
    $ssh = Start-Tunnel -Port $port
  } catch {
    Write-Log ('failed to start ssh: ' + $_.Exception.Message)
    Start-Sleep -Seconds $RetryDelaySeconds
    continue
  }

  Write-Log ("tunnel up: relay 127.0.0.1:{0} -> local 127.0.0.1:{1} pid={2}" -f $RemotePort, $port, $ssh.Id)
  $currentPort = $port

  while ($true) {
    Start-Sleep -Seconds $CheckIntervalSeconds
    if ($ssh.HasExited) {
      Write-Log ("ssh exited code={0}; reconnecting" -f $ssh.ExitCode)
      break
    }
    $newPort = Get-DshHostPort
    if ($null -ne $newPort -and $newPort -ne $currentPort) {
      Write-Log ("DSH port changed {0} -> {1}; restarting tunnel" -f $currentPort, $newPort)
      Stop-Process -Id $ssh.Id -Force -ErrorAction SilentlyContinue
      break
    }
    if ($null -eq $newPort) { Write-Log 'DSH port temporarily unavailable; keeping tunnel' }
  }
  Start-Sleep -Seconds $RetryDelaySeconds
}
