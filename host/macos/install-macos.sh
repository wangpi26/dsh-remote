#!/usr/bin/env bash
# One-time macOS host setup for dsh-remote (validated on macOS / Apple silicon).
#
# Does:
#   1. merge trustedHosts for the domain into ~/.dsh/profiles/desktop/cordis.patch.yml
#      (the DSH desktop profile patch hot-reloads, no DSH restart)
#   2. create a dedicated ed25519 key for the reverse tunnel
#   3. mint the initial browser-session cookie include
#   4. install + start a launchd LaunchAgent for the tunnel watchdog
#
# Usage:
#   ./install-macos.sh --domain dsh.example.com --relay-host relay.example.com
#
# Re-running is safe: an already trusted domain is reported and left alone, an
# existing trustedHosts list is appended to instead of being duplicated, and the
# tunnel key is reused.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DOMAIN=""
RELAY_HOST=""
RELAY_USER="dsh-tunnel"
REMOTE_PORT="9100"
STATE_DIR="${HOME}/.local/state/dsh-remote"
KEY="${STATE_DIR}/id_ed25519_dsh_remote"
CREDENTIALS="${HOME}/.dsh/.credentials.yaml"
INSTALL_LAUNCHD=1

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
macOS host setup for dsh-remote.

  --domain HOST        public hostname the relay serves (required)
  --relay-host HOST    relay server to dial (required)
  --relay-user USER    ssh user on the relay (default: dsh-tunnel)
  --remote-port PORT   port opened on the relay loopback (default: 9100)
  --state-dir DIR      where the key, cookie and logs live
  --key PATH           tunnel key path (default: <state-dir>/id_ed25519_dsh_remote)
  --no-launchd         prepare key/cookie/patch but do not load a LaunchAgent
  -h, --help           show this help
EOF
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --relay-host) RELAY_HOST="${2:-}"; shift 2 ;;
    --relay-user) RELAY_USER="${2:-}"; shift 2 ;;
    --remote-port) REMOTE_PORT="${2:-}"; shift 2 ;;
    --state-dir) STATE_DIR="${2:-}"; shift 2 ;;
    --key) KEY="${2:-}"; shift 2 ;;
    --no-launchd) INSTALL_LAUNCHD=0; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ -n "$DOMAIN" ] || die "--domain is required"
[ -n "$RELAY_HOST" ] || die "--relay-host is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required (macOS: 'xcode-select --install' provides it)"
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' \
  || die "python3 3.8+ is required (found $(python3 -V 2>&1))"
command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# ---------------------------------------------------------------- trustedHosts
PROFILE_DIR="${HOME}/.dsh/profiles/desktop"
[ -d "$PROFILE_DIR" ] || die "DSH desktop profile not found at $PROFILE_DIR - start the DSH desktop app once first"
python3 - "$DOMAIN" "$PROFILE_DIR/cordis.patch.yml" "$STATE_DIR" <<'PY'
import datetime, os, re, sys

domain, path, state_dir = sys.argv[1], sys.argv[2], sys.argv[3]

text = ""
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()


def backup(current):
    # Microseconds keep two runs in the same second from overwriting each other.
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    target = os.path.join(state_dir, "cordis.patch.yml.bak-" + stamp)
    with open(target, "w", encoding="utf-8") as handle:
        handle.write(current)
    print("[trustedHosts] backup: %s" % target)


def write(current):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(current)
    # The profile patch is operator config; keep it owner-only like DSH does.
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def normalize(item):
    item = item.strip()
    if item.startswith("-"):
        item = item[1:].strip()
    if len(item) >= 2 and item[0] in "\"'" and item[-1] == item[0]:
        item = item[1:-1]
    return item.strip()


lines = text.splitlines(keepends=True)

# A patch entry replaces the targeted row's whole `config`, so appending a second
# `- id: connection` item would drop every other key of that row. Merge into the
# existing trustedHosts list when there is one.
key_index = None
for index, line in enumerate(lines):
    if re.match(r"^[ \t]*trustedHosts[ \t]*:[ \t]*$", line):
        key_index = index
        break

if key_index is None:
    empty_flow = None
    for index, line in enumerate(lines):
        if re.match(r"^[ \t]*trustedHosts[ \t]*:[ \t]*\[[ \t]*\][ \t]*$", line):
            empty_flow = index
            break
    if empty_flow is not None:
        indent = re.match(r"^([ \t]*)", lines[empty_flow]).group(1)
        lines[empty_flow] = "%strustedHosts:\n%s  - %s\n" % (indent, indent, domain)
        backup(text)
        write("".join(lines))
        print("[trustedHosts] replaced empty trustedHosts with %s" % domain)
        raise SystemExit(0)

    flow = re.search(r"^[ \t]*trustedHosts[ \t]*:[ \t]*\S", text, re.MULTILINE)
    if flow:
        raise SystemExit(
            "cordis.patch.yml declares trustedHosts in flow style; add %s by hand: %s"
            % (domain, path)
        )

    if text:
        backup(text)
    if text and not text.endswith("\n"):
        text += "\n"
    text += "- id: connection\n  config:\n    trustedHosts:\n      - %s\n" % domain
    write(text)
    print("[trustedHosts] appended a connection entry with %s to %s" % (domain, path))
    raise SystemExit(0)

key_line = lines[key_index]
key_indent = len(key_line) - len(key_line.lstrip(" \t"))

item_indices = []
cursor = key_index + 1
while cursor < len(lines):
    raw = lines[cursor]
    if not raw.strip():
        cursor += 1
        continue
    indent = len(raw) - len(raw.lstrip(" \t"))
    if indent <= key_indent:
        break
    if re.match(r"^[ \t]*-[ \t]", raw):
        item_indices.append(cursor)
    cursor += 1

existing = [normalize(lines[index]) for index in item_indices]
if domain in existing:
    print("[trustedHosts] %s already present in %s" % (domain, path))
    raise SystemExit(0)

backup(text)
if item_indices:
    last = item_indices[-1]
    item_indent = len(lines[last]) - len(lines[last].lstrip(" \t"))
    lines.insert(last + 1, "%s- %s\n" % (" " * item_indent, domain))
else:
    lines.insert(key_index + 1, "%s  - %s\n" % (" " * key_indent, domain))
write("".join(lines))
print("[trustedHosts] added %s to the existing trustedHosts list in %s" % (domain, path))
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
if [ "$INSTALL_LAUNCHD" = "0" ]; then
  echo "[launchd] skipped (--no-launchd)"
else
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
fi

cat <<EOF

Next steps:
  1. Authorize the public key above on the relay (relay/setup-tunnel-user.sh --pubkey-file ...).
  2. Install the relay side (relay/install-relay.sh) with this domain and TLS certs.
  3. Push the cookie to the relay from this Mac:
       host/macos/refresh-cookie.sh --authority $DOMAIN --relay-host $RELAY_HOST
  4. Open https://$DOMAIN/ from your phone.

Logs: $STATE_DIR/tunnel.log, $STATE_DIR/launchd.err.log
EOF
