#!/usr/bin/env bash
# DSH remote reverse-tunnel watchdog (macOS / Linux desktop host).
#
# Validated on macOS (Apple silicon) and Linux. The Windows host path lives in
# host/windows.
#
# Keeps this tunnel alive:
#   relay 127.0.0.1:<remote-port>  ->  local <local-host>:<local-port>
# It auto-detects the DSH desktop host's loopback port (the port changes on
# every launch), restarts ssh when it exits, and reconnects when the port moves.
#
# macOS notes:
#   * `pgrep -f dsh-desktop-host` does NOT match the DSH desktop host on macOS:
#     the host process is a child of the Electron app and pgrep cannot read its
#     argv (only the Chromium Helper processes show up). `ps -axo pid=,args=`
#     does see it, so discovery goes through ps first and keeps pgrep for Linux.
#   * The listener may be IPv4 loopback (127.0.0.1) or IPv6-only ([::1]); the
#     forward target follows whichever family DSH actually bound.
#   * launchd runs this with a narrow PATH, so `sleep` loops stay interruptible:
#     a SIGTERM must tear the ssh child down promptly, otherwise launchd's
#     KeepAlive restart races the previous ssh holding the relay port.
#
# Usage:
#   ./tunnel.sh --relay-host relay.example.com --relay-user dsh-tunnel \
#       --identity-file ~/.ssh/id_ed25519_dsh_remote
#
# Environment overrides: RELAY_HOST, RELAY_USER, RELAY_SSH_PORT, REMOTE_PORT,
# LOCAL_PORT, LOCAL_HOST, IDENTITY_FILE, KNOWN_HOSTS, STATE_DIR,
# CHECK_INTERVAL, RETRY_DELAY.
set -uo pipefail

RELAY_HOST="${RELAY_HOST:-}"
RELAY_USER="${RELAY_USER:-root}"
RELAY_SSH_PORT="${RELAY_SSH_PORT:-22}"
REMOTE_PORT="${REMOTE_PORT:-9100}"
LOCAL_PORT="${LOCAL_PORT:-0}"
LOCAL_HOST="${LOCAL_HOST:-}"
IDENTITY_FILE="${IDENTITY_FILE:-}"
KNOWN_HOSTS="${KNOWN_HOSTS:-${HOME}/.local/state/dsh-remote/known_hosts}"
STATE_DIR="${STATE_DIR:-${HOME}/.local/state/dsh-remote}"
CHECK_INTERVAL="${CHECK_INTERVAL:-15}"
RETRY_DELAY="${RETRY_DELAY:-5}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
DSH reverse-tunnel watchdog.

  --relay-host HOST       relay server to dial (required)
  --relay-user USER       ssh user on the relay (default: root)
  --relay-ssh-port PORT   ssh port on the relay (default: 22)
  --remote-port PORT      port opened on the relay loopback (default: 9100)
  --local-port PORT       skip discovery and forward a fixed DSH port
  --local-host HOST       with --local-port: 127.0.0.1 (default) or [::1]
  --identity-file PATH    ssh identity for the tunnel
  --known-hosts PATH      known_hosts file (default: <state-dir>/known_hosts)
  --state-dir DIR         where logs and state live
  -h, --help              show this help

Environment overrides: RELAY_HOST, RELAY_USER, RELAY_SSH_PORT, REMOTE_PORT,
LOCAL_PORT, LOCAL_HOST, IDENTITY_FILE, KNOWN_HOSTS, STATE_DIR,
CHECK_INTERVAL, RETRY_DELAY.
EOF
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --relay-host) RELAY_HOST="${2:-}"; shift 2 ;;
    --relay-user) RELAY_USER="${2:-}"; shift 2 ;;
    --relay-ssh-port) RELAY_SSH_PORT="${2:-}"; shift 2 ;;
    --remote-port) REMOTE_PORT="${2:-}"; shift 2 ;;
    --local-port) LOCAL_PORT="${2:-}"; shift 2 ;;
    --local-host) LOCAL_HOST="${2:-}"; shift 2 ;;
    --identity-file) IDENTITY_FILE="${2:-}"; shift 2 ;;
    --known-hosts) KNOWN_HOSTS="${2:-}"; shift 2 ;;
    --state-dir) STATE_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ -n "$RELAY_HOST" ] || die "--relay-host is required (or set RELAY_HOST)"
command -v ssh >/dev/null 2>&1 || die "ssh not found"
command -v lsof >/dev/null 2>&1 || die "lsof not found (needed for port discovery)"
mkdir -p "$STATE_DIR" "$(dirname "$KNOWN_HOSTS")"

LOG="${STATE_DIR}/tunnel.log"
ERR="${STATE_DIR}/tunnel-ssh.err.log"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"
}

# --------------------------------------------------------------- port discovery

# Print "<host> <port>" for every loopback TCP listener owned by one pid.
loopback_targets_for_pid() {
  lsof -nP -a -p "$1" -iTCP -sTCP:LISTEN 2>/dev/null \
    | awk 'NR > 1 { print $9 }' \
    | sed -nE 's/^(127\.[0-9]+\.[0-9]+\.[0-9]+|\[::1\]):([0-9]+)$/\1 \2/p' \
    | sort -k2 -n -u
}

# Pids whose argv names the DSH desktop host. `ps` is the only source that works
# on macOS; pgrep is kept because it is exact on Linux and cheaper than ps.
desktop_host_pids() {
  {
    ps -axo pid=,args= 2>/dev/null | awk '/dsh-desktop-host/ && !/awk/ { print $1 }'
    pgrep -f 'dsh-desktop-host' 2>/dev/null || true
  } | sort -u
}

# Broad last resort: any loopback listener owned by a DSH-looking process.
dsh_like_pids() {
  ps -axo pid=,args= 2>/dev/null \
    | awk 'tolower($0) ~ /(deepseek|dsh-desktop|dsh-desktop-host)/ && !/awk/ { print $1 }' \
    | sort -u
}

# Print "<host> <port>"; empty when nothing was found.
discover_target() {
  local pid found

  if [ "${LOCAL_PORT}" -gt 0 ] 2>/dev/null; then
    printf '%s %s\n' "${LOCAL_HOST:-127.0.0.1}" "$LOCAL_PORT"
    return 0
  fi
  if [ -n "${DSH_LOCAL_PORT:-}" ]; then
    printf '%s %s\n' "${DSH_LOCAL_HOST:-127.0.0.1}" "${DSH_LOCAL_PORT}"
    return 0
  fi

  for pid in $(desktop_host_pids); do
    found=$(loopback_targets_for_pid "$pid" | tail -1)
    [ -n "$found" ] && { printf '%s\n' "$found"; return 0; }
  done

  for pid in $(dsh_like_pids); do
    found=$(loopback_targets_for_pid "$pid" | tail -1)
    [ -n "$found" ] && { printf '%s\n' "$found"; return 0; }
  done

  return 0
}

# ------------------------------------------------------------------- signals

SSH_PID=""
STOP=0

cleanup() {
  STOP=1
  log "stopping watchdog"
  if [ -n "$SSH_PID" ] && kill -0 "$SSH_PID" 2>/dev/null; then
    kill "$SSH_PID" 2>/dev/null
    wait "$SSH_PID" 2>/dev/null
  fi
  exit 0
}
trap cleanup TERM INT HUP

# Sleep that notices a signal within one second. A plain `sleep 15` defers the
# trap for its whole duration, which left the ssh child holding the relay port
# for up to CHECK_INTERVAL seconds after launchd asked the job to stop.
nap() {
  local remaining="${1:-0}"
  while [ "$remaining" -gt 0 ] && [ "$STOP" -eq 0 ]; do
    sleep 1
    remaining=$((remaining - 1))
  done
}

# ---------------------------------------------------------------------- ssh

SSH_ARGS=(ssh -N -T
  -p "$RELAY_SSH_PORT"
  -o BatchMode=yes
  -o ExitOnForwardFailure=yes
  -o ServerAliveInterval=20
  -o ServerAliveCountMax=3
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$KNOWN_HOSTS"
  -o ConnectTimeout=10
  -o LogLevel=ERROR)
if [ -n "$IDENTITY_FILE" ]; then
  [ -f "$IDENTITY_FILE" ] || die "identity file not found: $IDENTITY_FILE"
  SSH_ARGS+=(-i "$IDENTITY_FILE" -o IdentitiesOnly=yes)
fi

log "watchdog starting; relay=${RELAY_USER}@${RELAY_HOST}:${RELAY_SSH_PORT} remote=${REMOTE_PORT} local=$(if [ "${LOCAL_PORT}" -gt 0 ] 2>/dev/null; then printf '%s' "$LOCAL_PORT"; else printf 'auto'; fi)"

while [ "$STOP" -eq 0 ]; do
  target=$(discover_target)
  if [ -z "${target:-}" ]; then
    log "DSH desktop host port not found; waiting ${CHECK_INTERVAL}s (hint: lsof -nP -iTCP -sTCP:LISTEN | grep -i deepseek, or pass --local-port)"
    nap "$CHECK_INTERVAL"
    continue
  fi

  target_host="${target%% *}"
  target_port="${target##* }"

  "${SSH_ARGS[@]}" -R "127.0.0.1:${REMOTE_PORT}:${target_host}:${target_port}" "${RELAY_USER}@${RELAY_HOST}" 2>"$ERR" &
  SSH_PID=$!
  log "tunnel up: relay 127.0.0.1:${REMOTE_PORT} -> local ${target_host}:${target_port} pid=${SSH_PID}"

  while kill -0 "$SSH_PID" 2>/dev/null && [ "$STOP" -eq 0 ]; do
    nap "$CHECK_INTERVAL"
    [ "$STOP" -eq 0 ] || break
    new_target=$(discover_target)
    if [ -n "${new_target:-}" ] && [ "$new_target" != "${target_host} ${target_port}" ]; then
      log "DSH listener changed ${target_host}:${target_port} -> ${new_target}; restarting tunnel"
      kill "$SSH_PID" 2>/dev/null
      wait "$SSH_PID" 2>/dev/null
      break
    fi
  done

  [ "$STOP" -eq 0 ] || break

  wait "$SSH_PID" 2>/dev/null
  log "ssh exited; reconnecting in ${RETRY_DELAY}s"
  nap "$RETRY_DELAY"
done

cleanup
