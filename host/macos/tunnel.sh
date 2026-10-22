#!/usr/bin/env bash
# DSH remote reverse-tunnel watchdog (macOS / Linux desktop host).
#
# EXPERIMENTAL: this script is provided for macOS hosts but was not validated on
# a Mac by the maintainer (the Windows path was). Please open an issue/PR with
# fixes. The nginx relay, login page and cookie format are host-OS independent.
#
# Keeps this tunnel alive:
#   relay 127.0.0.1:<remote-port>  ->  local 127.0.0.1:<dsh-port>
# It auto-detects the DSH desktop host's loopback port (the port changes on
# every launch), restarts ssh when it exits, and reconnects when the port moves.
#
# Usage:
#   ./tunnel.sh --relay-host relay.example.com --relay-user dsh-tunnel \
#       --identity-file ~/.ssh/id_ed25519_dsh_remote
#
# Environment overrides: RELAY_HOST, RELAY_USER, REMOTE_PORT, LOCAL_PORT,
# IDENTITY_FILE, KNOWN_HOSTS, STATE_DIR, CHECK_INTERVAL, RETRY_DELAY.
set -uo pipefail

RELAY_HOST="${RELAY_HOST:-}"
RELAY_USER="${RELAY_USER:-root}"
RELAY_SSH_PORT="${RELAY_SSH_PORT:-22}"
REMOTE_PORT="${REMOTE_PORT:-9100}"
LOCAL_PORT="${LOCAL_PORT:-0}"
IDENTITY_FILE="${IDENTITY_FILE:-}"
KNOWN_HOSTS="${KNOWN_HOSTS:-${HOME}/.local/state/dsh-remote/known_hosts}"
STATE_DIR="${STATE_DIR:-${HOME}/.local/state/dsh-remote}"
CHECK_INTERVAL="${CHECK_INTERVAL:-15}"
RETRY_DELAY="${RETRY_DELAY:-5}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --relay-host) RELAY_HOST="${2:-}"; shift 2 ;;
    --relay-user) RELAY_USER="${2:-}"; shift 2 ;;
    --relay-ssh-port) RELAY_SSH_PORT="${2:-}"; shift 2 ;;
    --remote-port) REMOTE_PORT="${2:-}"; shift 2 ;;
    --local-port) LOCAL_PORT="${2:-}"; shift 2 ;;
    --identity-file) IDENTITY_FILE="${2:-}"; shift 2 ;;
    --known-hosts) KNOWN_HOSTS="${2:-}"; shift 2 ;;
    --state-dir) STATE_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ -n "$RELAY_HOST" ] || die "--relay-host is required (or set RELAY_HOST)"
command -v ssh >/dev/null 2>&1 || die "ssh not found"
mkdir -p "$STATE_DIR" "$(dirname "$KNOWN_HOSTS")"

LOG="${STATE_DIR}/tunnel.log"
ERR="${STATE_DIR}/tunnel-ssh.err.log"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"
}

discover_port() {
  # 1) explicit overrides
  if [ "${LOCAL_PORT}" -gt 0 ] 2>/dev/null; then printf '%s' "$LOCAL_PORT"; return 0; fi
  if [ -n "${DSH_LOCAL_PORT:-}" ]; then printf '%s' "$DSH_LOCAL_PORT"; return 0; fi

  # 2) the desktop host process, then its loopback listener
  local pid port
  for pid in $(pgrep -f 'dsh-desktop-host' 2>/dev/null || true); do
    port=$(lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN 2>/dev/null \
      | awk 'NR>1 {print $9}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -n | head -1)
    if [ -n "${port:-}" ]; then printf '%s' "$port"; return 0; fi
  done

  # 3) fallback: any loopback listener owned by a DeepSeek process
  port=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
    | awk 'tolower($1) ~ /deepseek/ {print $9}' \
    | sed -E 's/.*:([0-9]+)$/\1/' | sort -n | head -1)
  [ -n "${port:-}" ] && printf '%s' "$port"
  return 0
}

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

SSH_PID=""
cleanup() {
  log "stopping watchdog"
  if [ -n "$SSH_PID" ] && kill -0 "$SSH_PID" 2>/dev/null; then
    kill "$SSH_PID" 2>/dev/null
    wait "$SSH_PID" 2>/dev/null
  fi
  exit 0
}
trap cleanup TERM INT HUP

log "watchdog starting; relay=${RELAY_USER}@${RELAY_HOST}:${RELAY_SSH_PORT} remote=${REMOTE_PORT} local=$( [ "${LOCAL_PORT}" -gt 0 ] 2>/dev/null && printf '%s' "$LOCAL_PORT" || printf 'auto')"

while true; do
  port=$(discover_port)
  if [ -z "${port:-}" ]; then
    log "DSH desktop host port not found; waiting ${CHECK_INTERVAL}s"
    sleep "$CHECK_INTERVAL"
    continue
  fi

  "${SSH_ARGS[@]}" -R "127.0.0.1:${REMOTE_PORT}:127.0.0.1:${port}" "${RELAY_USER}@${RELAY_HOST}" 2>"$ERR" &
  SSH_PID=$!
  log "tunnel up: relay 127.0.0.1:${REMOTE_PORT} -> local 127.0.0.1:${port} pid=${SSH_PID}"
  current_port="$port"

  while kill -0 "$SSH_PID" 2>/dev/null; do
    sleep "$CHECK_INTERVAL"
    new_port=$(discover_port)
    if [ -n "${new_port:-}" ] && [ "$new_port" != "$current_port" ]; then
      log "DSH port changed ${current_port} -> ${new_port}; restarting tunnel"
      kill "$SSH_PID" 2>/dev/null
      wait "$SSH_PID" 2>/dev/null
      break
    fi
  done

  wait "$SSH_PID" 2>/dev/null
  log "ssh exited; reconnecting in ${RETRY_DELAY}s"
  sleep "$RETRY_DELAY"
done
