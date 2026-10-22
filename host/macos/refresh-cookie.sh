#!/usr/bin/env bash
# Push a freshly minted DSH browser-session cookie to the relay and reload nginx.
# EXPERIMENTAL: not tested by the maintainer on a Mac (Windows equivalent was).
#
# The relay login page hands this cookie to browsers after a successful login.
# The cookie expires (DSH caps it at 30 days), so schedule this daily/weekly:
#   launchd LaunchAgent (see README) or cron:
#     17 4 * * * /path/to/refresh-cookie.sh --authority dsh.example.com --relay-host relay.example.com >> ~/Library/Logs/dsh-remote-refresh.log 2>&1
#
# Example:
#   ./refresh-cookie.sh --authority dsh.example.com --relay-host relay.example.com \
#       --relay-user root --identity-file ~/.ssh/id_ed25519_dsh_admin
#
# OpenResty in Docker: add --container <name> and point --remote-inc at the
# host bind-mounted conf.d path.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AUTHORITY=""
RELAY_HOST=""
RELAY_USER="root"
RELAY_SSH_PORT="22"
IDENTITY_FILE=""
KNOWN_HOSTS="${HOME}/.local/state/dsh-remote/known_hosts"
STATE_DIR="${HOME}/.local/state/dsh-remote"
DAYS="30"
REMOTE_INC="/etc/nginx/conf.d/dsh-cookie.inc"
REMOTE_STAGING="/tmp/dsh-cookie.inc.new"
CONTAINER=""
NO_RELOAD="0"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --authority) AUTHORITY="${2:-}"; shift 2 ;;
    --relay-host) RELAY_HOST="${2:-}"; shift 2 ;;
    --relay-user) RELAY_USER="${2:-}"; shift 2 ;;
    --relay-ssh-port) RELAY_SSH_PORT="${2:-}"; shift 2 ;;
    --identity-file) IDENTITY_FILE="${2:-}"; shift 2 ;;
    --known-hosts) KNOWN_HOSTS="${2:-}"; shift 2 ;;
    --state-dir) STATE_DIR="${2:-}"; shift 2 ;;
    --days) DAYS="${2:-}"; shift 2 ;;
    --remote-inc) REMOTE_INC="${2:-}"; shift 2 ;;
    --remote-staging) REMOTE_STAGING="${2:-}"; shift 2 ;;
    --container) CONTAINER="${2:-}"; shift 2 ;;
    --no-reload) NO_RELOAD="1"; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ -n "$AUTHORITY" ] || die "--authority is required"
[ -n "$RELAY_HOST" ] || die "--relay-host is required"
command -v ssh >/dev/null 2>&1 || die "ssh not found"
command -v scp >/dev/null 2>&1 || die "scp not found"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
INC="${STATE_DIR}/dsh-cookie.inc"

python3 "${SCRIPT_DIR}/mint-cookie.py" --authority "$AUTHORITY" --days "$DAYS" \
  --write-inc "$INC"
chmod 600 "$INC"
echo "minted $INC"

SshOptions=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$KNOWN_HOSTS" -o ConnectTimeout=10)
if [ -n "$IDENTITY_FILE" ]; then
  [ -f "$IDENTITY_FILE" ] || die "identity file not found: $IDENTITY_FILE"
  SshOptions+=(-i "$IDENTITY_FILE" -o IdentitiesOnly=yes)
fi

scp "${SshOptions[@]}" -P "$RELAY_SSH_PORT" "$INC" "${RELAY_USER}@${RELAY_HOST}:${REMOTE_STAGING}"

if [ -n "$CONTAINER" ]; then
  TEST_CMD="docker exec $CONTAINER nginx -t"
  RELOAD_CMD="docker exec $CONTAINER nginx -s reload"
else
  TEST_CMD="nginx -t"
  RELOAD_CMD="nginx -s reload"
fi
if [ "$NO_RELOAD" = "1" ]; then RELOAD_CMD="true"; fi

ssh "${SshOptions[@]}" -p "$RELAY_SSH_PORT" "${RELAY_USER}@${RELAY_HOST}" bash -s -- \
  "$REMOTE_INC" "$REMOTE_STAGING" "$TEST_CMD" "$RELOAD_CMD" <<'REMOTE'
set -e
INC="$1"
STAGING="$2"
TEST_CMD="$3"
RELOAD_CMD="$4"
BACKUP="$INC.bak-$(date +%Y%m%d-%H%M%S)"
if [ -f "$INC" ]; then cp -a "$INC" "$BACKUP"; fi
install -m 600 "$STAGING" "$INC"
chmod 600 "$INC"
if ! eval "$TEST_CMD"; then
  echo "nginx -t failed; restoring $BACKUP" >&2
  if [ -f "$BACKUP" ]; then cp -a "$BACKUP" "$INC"; fi
  exit 1
fi
eval "$RELOAD_CMD"
echo "cookie include installed: $INC"
REMOTE

echo "relay updated: ${RELAY_USER}@${RELAY_HOST}:${REMOTE_INC}"
