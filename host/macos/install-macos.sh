#!/usr/bin/env bash
# One-time macOS host setup for dsh-remote (EXPERIMENTAL, not tested by the
# maintainer on a Mac; the Windows path was validated).
#
# Does:
#   1. append trustedHosts for the domain to ~/.dsh/profiles/desktop/cordis.patch.yml
#      (the DSH desktop profile patch hot-reloads, no DSH restart)
#   2. create a dedicated ed25519 key for the reverse tunnel
#   3. mint the initial browser-session cookie include
#   4. install + start a launchd LaunchAgent for the tunnel watchdog
#
# Usage:
#   ./install-macos.sh --domain dsh.example.com --relay-host relay.example.com
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DOMAIN=""
RELAY_HOST=""
RELAY_USER="dsh-tunnel"
REMOTE_PORT="9100"
STATE_DIR="${HOME}/.local/state/dsh-remote"
KEY="${STATE_DIR}/id_ed25519_dsh_remote"
CREDENTIALS="${HOME}/.dsh/.credentials.yaml"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --relay-host) RELAY_HOST="${2:-}"; shift 2 ;;
    --relay-user) RELAY_USER="${2:-}"; shift 2 ;;
    --remote-port) REMOTE_PORT="${2:-}"; shift 2 ;;
    --state-dir) STATE_DIR="${2:-}"; shift 2 ;;
    --key) KEY="${2:-}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ -n "$DOMAIN" ] || die "--domain is required"
[ -n "$RELAY_HOST" ] || die "--relay-host is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# ---------------------------------------------------------------- trustedHosts
PROFILE_DIR="${HOME}/.dsh/profiles/desktop"
[ -d "$PROFILE_DIR" ] || die "DSH desktop profile not found at $PROFILE_DIR - start the DSH desktop app once first"
python3 - "$DOMAIN" "$PROFILE_DIR/cordis.patch.yml" "$STATE_DIR" <<'PY'
import os, sys, time
domain, path, state_dir = sys.argv[1], sys.argv[2], sys.argv[3]
text = ""
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
if "trustedHosts" in text:
    if domain not in text:
        raise SystemExit(
            "cordis.patch.yml already has a trustedHosts block without %s; add it manually: %s"
            % (domain, path)
        )
    print("[trustedHosts] %s already present" % domain)
else:
    if text:
        stamp = time.strftime("%Y%m%d-%H%M%S")
        backup = os.path.join(state_dir, "cordis.patch.yml.bak-" + stamp)
        with open(backup, "w", encoding="utf-8") as handle:
            handle.write(text)
        print("[trustedHosts] backup: %s" % backup)
    if text and not text.endswith("\n"):
        text += "\n"
    text += "- id: connection\n  config:\n    trustedHosts:\n      - %s\n" % domain
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    print("[trustedHosts] appended %s to %s" % (domain, path))
PY

# ---------------------------------------------------------------- tunnel key
if [ -f "$KEY" ]; then
  echo "[ssh key] reusing $KEY"
else
  ssh-keygen -t ed25519 -f "$KEY" -N "" -C dsh-remote >/dev/null
  chmod 600 "$KEY"
  echo "[ssh key] generated $KEY"
fi
echo "[ssh key] authorize this public key on the relay:"
cat "${KEY}.pub"

# ---------------------------------------------------------------- cookie
python3 "${SCRIPT_DIR}/mint-cookie.py" --authority "$DOMAIN" --credentials "$CREDENTIALS" \
  --write-inc "${STATE_DIR}/dsh-cookie.inc"

# ---------------------------------------------------------------- launchd
PLIST_DST="${HOME}/Library/LaunchAgents/com.dsh-remote.tunnel.plist"
mkdir -p "${HOME}/Library/LaunchAgents"
sed -e "s|__TUNNEL_SCRIPT__|${SCRIPT_DIR}/tunnel.sh|g" \
    -e "s|__RELAY_HOST__|${RELAY_HOST}|g" \
    -e "s|__RELAY_USER__|${RELAY_USER}|g" \
    -e "s|__IDENTITY_FILE__|${KEY}|g" \
    -e "s|__REMOTE_PORT__|${REMOTE_PORT}|g" \
    -e "s|__STATE_DIR__|${STATE_DIR}|g" \
    "${SCRIPT_DIR}/com.dsh-remote.tunnel.plist.template" >"$PLIST_DST"
chmod 644 "$PLIST_DST"
chmod +x "${SCRIPT_DIR}/tunnel.sh"

launchctl bootout "gui/${UID}/com.dsh-remote.tunnel" 2>/dev/null || true
launchctl bootstrap "gui/${UID}" "$PLIST_DST"
launchctl enable "gui/${UID}/com.dsh-remote.tunnel" 2>/dev/null || true
echo "[launchd] com.dsh-remote.tunnel loaded"

cat <<EOF

Next steps:
  1. Authorize the public key above on the relay (relay/setup-tunnel-user.sh --pubkey-file ...).
  2. Install the relay side (relay/install-relay.sh) with this domain and TLS certs.
  3. Push the cookie to the relay from this Mac:
       host/macos/refresh-cookie.sh --authority $DOMAIN --relay-host $RELAY_HOST
  4. Open https://$DOMAIN/ from your phone.

Logs: $STATE_DIR/tunnel.log, $STATE_DIR/launchd.err.log
EOF
