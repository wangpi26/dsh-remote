#!/usr/bin/env bash
# Create a restricted SSH user for the DSH reverse tunnel.
#
# The desktop host connects as this user with `ssh -N -R 127.0.0.1:9100:...`.
# The authorized_keys entry uses `restrict,port-forwarding,permitlisten=...`, so
# the key can only open the one loopback forward the relay needs: no shell, no
# command execution, no other forwards, no scp. Cookie refreshes must use a
# separate admin key/user.
#
# Example (run on the relay as root):
#   ssh-keygen -t ed25519 -f ~/dsh-tunnel-key -N ''        # on the desktop host
#   sudo bash setup-tunnel-user.sh --user dsh-tunnel --port 9100 \
#        --pubkey-file /tmp/dsh-tunnel-key.pub
set -euo pipefail

USER_NAME="dsh-tunnel"
PORT="9100"
PUBKEY=""
PUBKEY_FILE=""
SHELL_PATH="/bin/bash"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() {
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER_NAME="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --pubkey) PUBKEY="${2:-}"; shift 2 ;;
    --pubkey-file) PUBKEY_FILE="${2:-}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root (or with sudo)"
[ -n "$USER_NAME" ] || die "--user is required"
case "$PORT" in ''|*[!0-9]*) die "--port must be numeric" ;; esac

if [ -n "$PUBKEY_FILE" ]; then
  [ -f "$PUBKEY_FILE" ] || die "public key file not found: $PUBKEY_FILE"
  PUBKEY=$(tr -d '\r\n' <"$PUBKEY_FILE")
fi
[ -n "$PUBKEY" ] || die "pass --pubkey or --pubkey-file"
case "$PUBKEY" in
  ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *) : ;;
  *) die "unrecognized public key format" ;;
esac

if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  useradd -m -s "$SHELL_PATH" "$USER_NAME"
  echo "created user: $USER_NAME"
else
  echo "reusing user: $USER_NAME"
fi

HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
[ -n "$HOME_DIR" ] || die "cannot resolve home directory for $USER_NAME"
GROUP_NAME=$(id -gn "$USER_NAME")

install -d -m 700 -o "$USER_NAME" -g "$GROUP_NAME" "$HOME_DIR/.ssh"
AUTH_KEYS="$HOME_DIR/.ssh/authorized_keys"
touch "$AUTH_KEYS"
chown "$USER_NAME:$GROUP_NAME" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

OPTIONS="restrict,port-forwarding,permitlisten=\"127.0.0.1:$PORT\""
if grep -qF "$PUBKEY" "$AUTH_KEYS"; then
  echo "public key already authorized"
else
  printf '%s %s\n' "$OPTIONS" "$PUBKEY" >>"$AUTH_KEYS"
  echo "authorized restricted key (listen 127.0.0.1:$PORT only)"
fi

# sshd must allow TCP forwarding and must not expose forwarded ports publicly.
SSHD_CONFIG=$(sshd -T 2>/dev/null || true)
if [ -z "$SSHD_CONFIG" ]; then
  echo "warning: 'sshd -T' failed; verify AllowTcpForwarding yes and GatewayPorts no manually" >&2
else
  echo "$SSHD_CONFIG" | grep -qi '^allowtcpforwarding no' && \
    echo "warning: AllowTcpForwarding is disabled in sshd_config" >&2 || true
  if echo "$SSHD_CONFIG" | grep -qi '^gatewayports yes'; then
    echo "warning: GatewayPorts yes is set; forwarded ports may be reachable publicly" >&2
  fi
fi

cat <<EOF

Tunnel user ready.

  user:     $USER_NAME
  key:      restricted to 127.0.0.1:$PORT
  test:     ssh -N -R 127.0.0.1:$PORT:127.0.0.1:<local-dsh-port> $USER_NAME@<relay>

The desktop host should run its tunnel watchdog with this user, for example:
  tunnel.ps1 -RelayHost <relay> -RelayUser $USER_NAME -IdentityFile <key>
  tunnel.sh --relay-host <relay> --relay-user $USER_NAME --identity-file <key>

Cookie refreshes need a separate admin identity because this key has no shell.
EOF
