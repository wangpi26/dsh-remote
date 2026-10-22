# Push a freshly minted DSH browser-session cookie to the relay and reload nginx.
#
# The relay's login page hands this cookie to browsers after a successful
# username/password check. The cookie expires (DSH caps it at 30 days), so run
# this on a schedule (Task Scheduler / cron). The relay-side step is:
#   backup existing include  ->  install new include  ->  nginx -t  ->  reload
# and it rolls the old include back when `nginx -t` fails.
#
# Examples:
#   # plain nginx on the relay
#   .\refresh-cookie.ps1 -Authority dsh.example.com -RelayHost relay.example.com `
#       -RelayUser dsh-admin -IdentityFile "$env:LOCALAPPDATA\dsh-remote\id_ed25519_dsh_admin"
#
#   # OpenResty in Docker (1Panel etc.): run nginx -t / reload inside the container
#   .\refresh-cookie.ps1 -Authority dsh.example.com -RelayHost relay.example.com `
#       -RelayUser root -NginxContainer 1Panel-openresty-xxxx `
#       -RemoteIncPath /opt/1panel/apps/openresty/openresty/conf/conf.d/dsh-cookie.inc

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Authority,
  [Parameter(Mandatory = $true)][string]$RelayHost,
  [string]$RelayUser = 'root',
  [int]$RelaySshPort = 22,
  [string]$IdentityFile,
  [string]$KnownHostsFile = (Join-Path $env:LOCALAPPDATA 'dsh-remote\known_hosts'),
  [string]$StateDir = (Join-Path $env:LOCALAPPDATA 'dsh-remote'),
  [ValidateRange(1, 30)][int]$Days = 30,
  [string]$Credentials = (Join-Path $HOME '.dsh\.credentials.yaml'),
  [string]$RemoteIncPath = '/etc/nginx/conf.d/dsh-cookie.inc',
  [string]$RemoteStagingPath = '/tmp/dsh-cookie.inc.new',
  [string]$NginxContainer,
  [switch]$NoReload
)

$ErrorActionPreference = 'Stop'
$null = New-Item -ItemType Directory -Force -Path $StateDir
$incPath = Join-Path $StateDir 'dsh-cookie.inc'
$logPath = Join-Path $StateDir 'refresh-cookie.log'

function Write-Log {
  param([string]$Message)
  $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $Message
  Add-Content -Path $logPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
  Write-Host $line
}

function Quote-Arg {
  param([string]$Value)
  if ($Value -match '[\s"]') { return '"' + $Value.Replace('"', '\"') + '"' }
  return $Value
}

$sshExe = (Get-Command ssh.exe -ErrorAction SilentlyContinue)
$scpExe = (Get-Command scp.exe -ErrorAction SilentlyContinue)
if ($null -eq $sshExe -or $null -eq $scpExe) { throw 'ssh.exe/scp.exe not found; install the Windows OpenSSH client first.' }

$mintScript = Join-Path $PSScriptRoot 'mint-cookie.ps1'
& $mintScript -Authority $Authority -Credentials $Credentials -Days $Days -WriteInc $incPath
if (-not (Test-Path -LiteralPath $incPath)) { throw "cookie include was not written: $incPath" }
Write-Log ("minted cookie include for {0} (valid {1} days); size={2} bytes" -f $Authority, $Days, (Get-Item $incPath).Length)

$sshOptions = @(
  '-o', 'BatchMode=yes',
  '-o', 'StrictHostKeyChecking=accept-new',
  '-o', ('UserKnownHostsFile=' + $KnownHostsFile),
  '-o', 'ConnectTimeout=10'
)
if ($IdentityFile) {
  if (-not (Test-Path -LiteralPath $IdentityFile)) { throw "identity file not found: $IdentityFile" }
  $sshOptions += @('-i', $IdentityFile, '-o', 'IdentitiesOnly=yes')
}

# 1) upload to a staging path on the relay (scp uses -P, ssh uses -p)
$scpArgs = @($sshOptions) + @('-P', [string]$RelaySshPort, $incPath, ("{0}@{1}:{2}" -f $RelayUser, $RelayHost, $RemoteStagingPath))
& $scpExe.Source @scpArgs
if ($LASTEXITCODE -ne 0) { throw "scp failed with exit code $LASTEXITCODE" }

# 2) install + test + reload (roll back on nginx -t failure)
$testCommand = 'nginx -t'
$reloadCommand = 'nginx -s reload'
if ($NginxContainer) {
  $testCommand = "docker exec $NginxContainer nginx -t"
  $reloadCommand = "docker exec $NginxContainer nginx -s reload"
}
$remoteScript = @'
set -e
INC="__INC__"
STAGING="__STAGING__"
BACKUP="$INC.bak-$(date +%Y%m%d-%H%M%S)"
if [ -f "$INC" ]; then cp -a "$INC" "$BACKUP"; fi
install -m 600 "$STAGING" "$INC"
chmod 600 "$INC"
if ! __TEST__; then
  echo "nginx -t failed; restoring $BACKUP" >&2
  if [ -f "$BACKUP" ]; then cp -a "$BACKUP" "$INC"; fi
  exit 1
fi
__RELOAD__
echo "cookie include installed: $INC"
'@
$remoteScript = $remoteScript.Replace('__INC__', $RemoteIncPath).Replace('__STAGING__', $RemoteStagingPath)
$remoteScript = $remoteScript.Replace('__TEST__', $testCommand).Replace('__RELOAD__', $(if ($NoReload) { 'true' } else { $reloadCommand }))

$sshArgs = @($sshOptions) + @('-p', [string]$RelaySshPort, ("{0}@{1}" -f $RelayUser, $RelayHost), 'bash -s')
$remoteScript | & $sshExe.Source @sshArgs
if ($LASTEXITCODE -ne 0) { throw "remote install failed with exit code $LASTEXITCODE" }
Write-Log ("relay updated: {0}@{1}:{2} (nginx tested before reload)" -f $RelayUser, $RelayHost, $RemoteIncPath)
