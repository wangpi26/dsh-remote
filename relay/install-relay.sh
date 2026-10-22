#!/usr/bin/env bash
# Install the dsh-remote relay: nginx vhost, custom login page, cookie include.
#
# Run on the relay (Linux, nginx or OpenResty, optionally in Docker):
#
#   sudo bash install-relay.sh \
#     --domain dsh.example.com \
#     --cert /etc/letsencrypt/live/dsh.example.com/fullchain.pem \
#     --key  /etc/letsencrypt/live/dsh.example.com/privkey.pem
#
# OpenResty in Docker (1Panel, etc.):
#
#   sudo bash install-relay.sh \
#     --domain dsh.example.com \
#     --cert /www/sites/dsh.example.com/ssl/fullchain.pem \
#     --key  /www/sites/dsh.example.com/ssl/privkey.pem \
#     --conf-dir /opt/1panel/apps/openresty/openresty/conf/conf.d \
#     --container 1Panel-openresty-xxxx \
#     --container-conf-dir /usr/local/openresty/nginx/conf/conf.d
#
# The script renders the templates, backs up an existing vhost, runs
# `nginx -t` and only then reloads; on failure it restores the previous vhost.
# It never touches other vhosts and never overwrites an existing dsh-cookie.inc.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

DOMAIN=""
SSL_CERT=""
SSL_KEY=""
UPSTREAM="127.0.0.1:9100"
CONF_DIR="/etc/nginx/conf.d"
CONTAINER=""
CONTAINER_CONF_DIR="/usr/local/openresty/nginx/conf/conf.d"
ACME_ROOT="/var/www/html"
LOGIN_USER="dsh"
LOGIN_PASSWORD=""
DRY_RUN=0

usage() {
  sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --cert) SSL_CERT="${2:-}"; shift 2 ;;
    --key) SSL_KEY="${2:-}"; shift 2 ;;
    --upstream) UPSTREAM="${2:-}"; shift 2 ;;
    --conf-dir) CONF_DIR="${2:-}"; shift 2 ;;
    --container) CONTAINER="${2:-}"; shift 2 ;;
    --container-conf-dir) CONTAINER_CONF_DIR="${2:-}"; shift 2 ;;
    --acme-root) ACME_ROOT="${2:-}"; shift 2 ;;
    --user) LOGIN_USER="${2:-}"; shift 2 ;;
    --password) LOGIN_PASSWORD="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root (or with sudo)"
[ -n "$DOMAIN" ] || die "--domain is required"
[ -n "$SSL_CERT" ] || die "--cert is required (path visible to nginx)"
[ -n "$SSL_KEY" ] || die "--key is required (path visible to nginx)"
case "$DOMAIN" in */*|*:*|*' '*) die "--domain must be a bare host name (no scheme/path)" ;; esac
[ -n "$LOGIN_USER" ] || die "--user must not be empty"

for template in "$SCRIPT_DIR/nginx/dsh-site.conf.template" "$SCRIPT_DIR/nginx/dsh-login.lua.template" "$SCRIPT_DIR/dsh-cookie.inc.template"; do
  [ -f "$template" ] || die "template missing: $template"
done
[ -d "$CONF_DIR" ] || die "nginx conf dir not found: $CONF_DIR"

if [ -n "$CONTAINER" ]; then
  command -v docker >/dev/null 2>&1 || die "--container given but docker is not installed"
  docker inspect -f '{{.State.Running}}' "$CONTAINER" >/dev/null 2>&1 || die "container not running: $CONTAINER"
  NGINX_CONF_DIR="$CONTAINER_CONF_DIR"
else
  NGINX_CONF_DIR="$CONF_DIR"
fi

[ -f "$SSL_CERT" ] || echo "warning: $SSL_CERT is not visible from the host; make sure nginx can read it" >&2
[ -f "$SSL_KEY" ] || echo "warning: $SSL_KEY is not visible from the host; make sure nginx can read it" >&2

# ---------------------------------------------------------------- credentials
rand_string() {
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$1" || true
}
SALT=$(rand_string 16)
[ "${#SALT}" -eq 16 ] || die "could not generate salt from /dev/urandom"
if [ -z "$LOGIN_PASSWORD" ]; then
  LOGIN_PASSWORD=$(rand_string 18)
  [ "${#LOGIN_PASSWORD}" -eq 18 ] || die "could not generate password from /dev/urandom"
fi
if command -v md5sum >/dev/null 2>&1; then
  LOGIN_HASH=$(printf '%s' "$SALT$LOGIN_PASSWORD" | md5sum | awk '{print $1}')
else
  LOGIN_HASH=$(printf '%s' "$SALT$LOGIN_PASSWORD" | openssl dgst -md5 | awk '{print $NF}')
fi
[ "${#LOGIN_HASH}" -eq 32 ] || die "could not compute the login password hash"

# sed replacement escaping (& | \ are special)
esc() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }

render() {
  local template=$1 out=$2
  sed -e "s|__DOMAIN__|$(esc "$DOMAIN")|g" \
      -e "s|__SSL_CERT__|$(esc "$SSL_CERT")|g" \
      -e "s|__SSL_KEY__|$(esc "$SSL_KEY")|g" \
      -e "s|__ACME_ROOT__|$(esc "$ACME_ROOT")|g" \
      -e "s|__CONF_DIR__|$(esc "$NGINX_CONF_DIR")|g" \
      -e "s|__UPSTREAM__|$(esc "$UPSTREAM")|g" \
      "$template" >"$out"
}

render_lua() {
  local template=$1 out=$2
  sed -e "s|__LOGIN_USER__|$(esc "$LOGIN_USER")|g" \
      -e "s|__LOGIN_SALT__|$(esc "$SALT")|g" \
      -e "s|__LOGIN_HASH__|$(esc "$LOGIN_HASH")|g" \
      "$template" >"$out"
}

# ---------------------------------------------------------------- write files
SITE_CONF="$CONF_DIR/$DOMAIN.conf"
LUA_FILE="$CONF_DIR/dsh-login.lua"
COOKIE_FILE="$CONF_DIR/dsh-cookie.inc"
BACKUP=""

if [ -f "$SITE_CONF" ]; then
  BACKUP="$SITE_CONF.bak-$(date +%Y%m%d-%H%M%S)"
  cp -a "$SITE_CONF" "$BACKUP"
  echo "backup: $BACKUP"
fi

render "$SCRIPT_DIR/nginx/dsh-site.conf.template" "$SITE_CONF"
render_lua "$SCRIPT_DIR/nginx/dsh-login.lua.template" "$LUA_FILE"
chmod 644 "$LUA_FILE"
if [ ! -f "$COOKIE_FILE" ]; then
  install -m 600 "$SCRIPT_DIR/dsh-cookie.inc.template" "$COOKIE_FILE"
  echo "cookie include placeholder: $COOKIE_FILE (push a real cookie from the DSH host)"
fi
chmod 644 "$SITE_CONF"

echo "rendered: $SITE_CONF"
echo "lua:      $LUA_FILE"
echo "cookie:   $COOKIE_FILE"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry run: skipping nginx -t and reload"
  exit 0
fi

# ---------------------------------------------------------------- test + reload
if [ -n "$CONTAINER" ]; then
  if ! docker exec "$CONTAINER" nginx -t; then
    echo "nginx -t failed; rolling back $SITE_CONF" >&2
    if [ -n "$BACKUP" ]; then cp -a "$BACKUP" "$SITE_CONF"; else rm -f "$SITE_CONF"; fi
    exit 1
  fi
  docker exec "$CONTAINER" nginx -s reload
else
  if ! nginx -t; then
    echo "nginx -t failed; rolling back $SITE_CONF" >&2
    if [ -n "$BACKUP" ]; then cp -a "$BACKUP" "$SITE_CONF"; else rm -f "$SITE_CONF"; fi
    exit 1
  fi
  nginx -s reload
fi

cat <<EOF

Relay installed.

  URL:      https://$DOMAIN/
  account:  $LOGIN_USER
  password: $LOGIN_PASSWORD

Next steps:
  1. Push the signed DSH cookie from the desktop host:
       host/windows/refresh-cookie.ps1 -Authority $DOMAIN -RelayHost <relay> ...
     Until then the login page returns 500.
  2. Make sure the SSH reverse tunnel is running: the relay should listen on
     $UPSTREAM (ss -ltnp | grep 9100).
  3. Open https://$DOMAIN/ and sign in.

Save the password in your password manager now; it is not stored on the relay.
EOF
