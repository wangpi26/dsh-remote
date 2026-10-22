#!/usr/bin/env python3
"""Mint a DSH browser-session cookie from the local DSH credential store.

The DSH desktop host authenticates browser requests with a signed cookie:

    name  = "dsh-auth-" + base64url(sha256(authority))
    value = "v1." + base64url(json(payload)) + "." + base64url(hmac_sha256(secret, body))

where ``payload = {version: 1, authority, issuedAt, expiresAt}``, ``authority`` is
the request ``Host`` header value (host[:port], no scheme) and ``secret`` is the
32-byte signing secret stored in ``~/.dsh/.credentials.yaml`` under the
``client-connection/browser-session`` credential record.

This script is dependency-free (Python 3.8+) and runs on macOS/Linux. Windows
users can run ``host/windows/mint-cookie.ps1`` instead.

SECURITY: the emitted cookie is a live bearer credential (up to 30 days). Never
commit it, paste it into issues, or store it outside the relay's
``dsh-cookie.inc`` (mode 600).

Usage:
    python3 mint-cookie.py --authority dsh.example.com --print-cookie
    python3 mint-cookie.py --authority dsh.example.com --write-inc ./dsh-cookie.inc
    python3 mint-cookie.py --authority dsh.example.com --verify-url http://127.0.0.1:<port>
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import http.client
import json
import os
import re
import sys
import time
from urllib.parse import urlsplit

DEFAULT_CREDENTIALS = os.path.join(os.path.expanduser("~"), ".dsh", ".credentials.yaml")
RECORD = "client-connection/browser-session"
SECRET_BYTES = 32
MAX_DAYS = 30  # DSH enforces `expiresAt - issuedAt <= cookieMaxAgeDays` (default 30)


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def from_b64url(text: str) -> bytes:
    padded = text + "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(padded.encode("ascii"))


def read_secret(credentials_path: str) -> bytes:
    """Extract the browser-session signing secret (kept out of logs/diagnostics)."""
    try:
        with open(credentials_path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError as error:
        raise SystemExit(
            "cannot read DSH credentials at %s: %s\n"
            "Start the DSH desktop app once so it creates the file, or pass --credentials."
            % (credentials_path, error)
        )

    match = re.search(r"^(\s*)\"?%s\"?\s*:\s*$" % re.escape(RECORD), text, re.MULTILINE)
    if not match:
        raise SystemExit(
            "credential record %r not found in %s; start the DSH desktop app once so "
            "the browser-session secret is created." % (RECORD, credentials_path)
        )

    base_indent = len(match.group(1))
    block: list[str] = []
    for line in text[match.end():].splitlines():
        if not line.strip():
            block.append(line)
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent <= base_indent:
            break
        block.append(line)
    body = "\n".join(block)

    if not re.search(r"^\s+kind:\s*[\"']?grant[\"']?\s*$", body, re.MULTILINE):
        raise SystemExit("credential record %r is not a grant record" % RECORD)

    secret_match = re.search(
        r"^\s+secret:\s*[\"']?([A-Za-z0-9_-]+)[\"']?\s*$", body, re.MULTILINE
    )
    if not secret_match:
        raise SystemExit("credential record %r has no payload.secret" % RECORD)

    secret = from_b64url(secret_match.group(1))
    if len(secret) != SECRET_BYTES:
        raise SystemExit("browser-session secret is not %d bytes" % SECRET_BYTES)
    return secret


def mint(authority: str, secret: bytes, days: int) -> tuple[str, str, int, int]:
    if not 1 <= days <= MAX_DAYS:
        raise SystemExit("--days must be between 1 and %d (DSH limit)" % MAX_DAYS)
    if not re.fullmatch(r"[A-Za-z0-9.-]+(?::[0-9]{1,5})?", authority):
        raise SystemExit(
            "--authority must be a bare Host value such as dsh.example.com "
            "(no scheme, no path)"
        )

    issued_at = int(time.time() * 1000)
    expires_at = issued_at + days * 86_400_000
    payload = {
        "version": 1,
        "authority": authority,
        "issuedAt": issued_at,
        "expiresAt": expires_at,
    }
    body = b64url(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    signature = b64url(hmac.new(secret, body.encode("ascii"), hashlib.sha256).digest())
    name = "dsh-auth-" + b64url(hashlib.sha256(authority.encode("utf-8")).digest())
    return name, "v1.%s.%s" % (body, signature), issued_at, expires_at


def inc_line(name: str, value: str, days: int, secure: bool = True) -> str:
    attributes = (
        "%s=%s; Max-Age=%d; Path=/; HttpOnly; SameSite=Strict"
        % (name, value, days * 86_400)
    )
    if secure:
        attributes += "; Secure"
    return 'set $dsh_cookie "%s";' % attributes


def verify(url: str, authority: str, name: str, value: str) -> int:
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https"):
        raise SystemExit("--verify-url must be an http(s) URL")
    if parts.scheme == "https":
        connection = http.client.HTTPSConnection(parts.hostname, parts.port or 443, timeout=10)
    else:
        connection = http.client.HTTPConnection(parts.hostname, parts.port or 80, timeout=10)
    try:
        connection.putrequest("GET", parts.path or "/", skip_host=True)
        connection.putheader("Host", authority)
        connection.putheader("Cookie", "%s=%s" % (name, value))
        connection.endheaders()
        response = connection.getresponse()
        response.read(1024)
        return response.status
    finally:
        connection.close()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Mint the DSH browser-session cookie used by the relay login page."
    )
    parser.add_argument("--authority", required=True, help="public host, e.g. dsh.example.com")
    parser.add_argument("--credentials", default=DEFAULT_CREDENTIALS, help="DSH credentials YAML")
    parser.add_argument("--days", type=int, default=MAX_DAYS, help="cookie lifetime (1-30)")
    parser.add_argument("--print-cookie", action="store_true", help="print name=value only")
    parser.add_argument("--write-inc", metavar="PATH", help="write nginx include with the cookie")
    parser.add_argument("--no-secure", action="store_true", help="omit the Secure attribute")
    parser.add_argument(
        "--verify-url",
        metavar="URL",
        help="check the cookie against a local DSH listener (HTTP 200 means valid)",
    )
    args = parser.parse_args()

    secret = read_secret(args.credentials)
    name, value, issued_at, expires_at = mint(args.authority, secret, args.days)

    if args.print_cookie:
        print("%s=%s" % (name, value))
        return 0

    if args.write_inc:
        line = inc_line(name, value, args.days, secure=not args.no_secure)
        directory = os.path.dirname(os.path.abspath(args.write_inc))
        os.makedirs(directory, exist_ok=True)
        # 0o600: the file carries a live bearer credential.
        fd = os.open(args.write_inc, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(
                "# DSH browser-session cookie, minted %s for %s (valid until %s).\n"
                "# Generated by dsh-remote; contains a live credential, keep mode 600.\n"
                "%s\n"
                % (
                    time.strftime("%Y-%m-%d %H:%M:%S %z"),
                    args.authority,
                    time.strftime("%Y-%m-%d %H:%M:%S %z", time.localtime(expires_at / 1000)),
                    line,
                )
            )
        print(
            "wrote %s (valid until %s)"
            % (args.write_inc, time.strftime("%Y-%m-%d %H:%M", time.localtime(expires_at / 1000))),
            file=sys.stderr,
        )

    if args.verify_url:
        status = verify(args.verify_url, args.authority, name, value)
        print("verify %s -> HTTP %d" % (args.verify_url, status), file=sys.stderr)
        if status != 200:
            print(
                "cookie was rejected; check --authority matches the Host header the "
                "listener receives and that the DSH profile uses this credentials file.",
                file=sys.stderr,
            )
            return 1

    if not args.print_cookie and not args.write_inc and not args.verify_url:
        print("%s=%s" % (name, value))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
