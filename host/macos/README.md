# macOS host

Validated on macOS (Apple silicon) against a real DSH desktop app and a Linux
relay (OpenResty in Docker). The Windows path (`host/windows`) remains the one
with the longest track record; the mac scripts follow the same design.

## What is portable

* The relay (`relay/`) is Linux nginx/OpenResty and OS independent.
* The cookie format and `mint-cookie.py` are OS independent: the script reads
  `~/.dsh/.credentials.yaml` and produces `dsh-cookie.inc`.
* `~/.dsh/profiles/desktop/cordis.patch.yml` works the same way on macOS: the
  DSH desktop host hot-reloads the profile patch, no restart required.

## Verified on macOS

| Check | Result |
| --- | --- |
| `mint-cookie.py` against the local DSH listener | HTTP 200 |
| cookie with a tampered signature | HTTP 401 |
| cookie for authority A presented as authority B | HTTP 401 |
| cookie minted for that authority, same Host | HTTP 200 |
| `tunnel.sh` port auto-discovery | finds the random DSH port |
| `ssh -R` tunnel established | relay shows `127.0.0.1:<port> LISTEN` |
| relay → tunnel → DSH end to end | 401 unauthenticated, 200 with a valid cookie |
| plist `plutil -lint` | OK |
| `launchctl bootstrap` / `launchctl print` | loaded, `state = running` |
| KeepAlive after `kill` / `kill -9` | restarted, no orphan `ssh`, port released |
| SIGTERM shutdown latency | ~1 s (was up to `CHECK_INTERVAL`) |
| trustedHosts patch idempotency | re-run reports "already present", no duplicate |
| trustedHosts hot reload | new host passes the fence ~2.5 s after the write, DSH never restarted |

Not exercised on macOS: an IPv6-only (`[::1]`) DSH listener (the code follows
whichever family DSH binds, but the test machine bound `127.0.0.1`), and a live
port change while the tunnel is up (that needs a DSH restart).

## Steps

```bash
# 1. On the relay: install nginx vhost + login page, then create a restricted
#    tunnel user (see ../relay and the top-level README).

# 2. On the Mac: trust the public domain, create the key, install launchd
#    (hot reload, no DSH restart). Use a remote port that is free on the relay.
./install-macos.sh --domain dsh.example.com --relay-host relay.example.com \
    --relay-user dsh-tunnel --remote-port 9100

# 3. Authorize ~/.local/state/dsh-remote/id_ed25519_dsh_remote.pub on the relay.

# 4. Push the cookie (needs an identity that can write the nginx config).
#    nginx in Docker (1Panel/OpenResty): add --container <name>.
./refresh-cookie.sh --authority dsh.example.com --relay-host relay.example.com \
    --relay-user root --identity-file ~/.ssh/id_ed25519_dsh_admin \
    --container <your-openresty-container>

# 5. Schedule the cookie refresh daily (launchd) so the 30-day cookie never
#    expires; see the example in refresh-cookie.sh's header.
```

## Port discovery

`tunnel.sh` locates the DSH desktop host and forwards its loopback port. The
port is chosen at every launch, so it must be discovered rather than configured.

Order: `--local-port` → `DSH_LOCAL_PORT` → `ps -axo pid=,args=` looking for
`dsh-desktop-host` → `pgrep -f` → any loopback listener owned by a DSH-looking
process.

**macOS pitfall:** `pgrep -f dsh-desktop-host` returns nothing on macOS even
though `ps -p <pid> -o args=` shows that exact string. The host is a child of
the Electron app and pgrep only matches the Chromium Helper processes, so the
`ps` scan comes first. If discovery still fails, pass the port explicitly:

```bash
lsof -nP -iTCP -sTCP:LISTEN | grep -i deepseek
./tunnel.sh ... --local-port <port>
```

Discovery only considers loopback listeners (`127.0.0.0/8` and `[::1]`), and the
forward target follows the family DSH actually bound, so an IPv6-only listener
is forwarded to `[::1]` instead of a dead `127.0.0.1`.

## launchd

`install-macos.sh` writes `~/Library/LaunchAgents/com.dsh-remote.tunnel.plist`
(mode 644) with `RunAtLoad`, `KeepAlive`, `ThrottleInterval` 10 and logs in
`~/.local/state/dsh-remote/`.

* launchd's default PATH is `/usr/bin:/bin:/usr/sbin:/sbin`. That already
  contains `bash`, `ssh`, `lsof`, `ps`, `sed` and `awk`, so no
  `EnvironmentVariables` block is needed.
* When the job is killed, launchd terminates the whole process group, so the
  `ssh` child dies with it and the relay port is released — verified with
  `kill -9`, where the port was gone within ~2 s.
* `tunnel.sh` keeps its sleeps interruptible (one-second slices), so SIGTERM
  tears the tunnel down immediately instead of waiting out `CHECK_INTERVAL`.
* When DSH is not running, the script logs "port not found" and waits; it does
  not exit, which keeps `KeepAlive` from turning into a restart loop.

Useful commands:

```bash
plutil -lint ~/Library/LaunchAgents/com.dsh-remote.tunnel.plist
launchctl print gui/$(id -u)/com.dsh-remote.tunnel
launchctl kickstart -k gui/$(id -u)/com.dsh-remote.tunnel
tail -f ~/.local/state/dsh-remote/tunnel.log
```

Uninstall:

```bash
launchctl bootout gui/$(id -u)/com.dsh-remote.tunnel
rm ~/Library/LaunchAgents/com.dsh-remote.tunnel.plist
```

## trustedHosts

`install-macos.sh` merges the domain into an existing `trustedHosts:` list
instead of appending a second `- id: connection` entry: a patch entry replaces
the targeted row's whole `config`, so a duplicate entry would drop the row's
other keys. Re-running is a no-op, and any change is backed up first to
`~/.local/state/dsh-remote/cordis.patch.yml.bak-<timestamp>`.

Flow-style lists (`trustedHosts: ['a.example.com']`) are refused with an
instruction to edit by hand rather than guessed at.

The desktop profile patch hot-reloads. On the test machine a host added to the
list started passing the `/api` Host fence within ~2.5 s, with the DSH process
PID and start time unchanged. Do not restart DSH.

## Docker / 1Panel relays

When nginx runs in a container the host has no `nginx` binary. Pass
`--container <name>` to `refresh-cookie.sh`; it runs `nginx -t` and
`nginx -s reload` inside the container. `--remote-inc` is a **host** path and
must be the bind-mounted conf.d directory (for 1Panel:
`/opt/1panel/apps/openresty/openresty/conf/conf.d`).

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `tunnel.log` repeats "port not found" | DSH not running, or discovery missed it; pass `--local-port` |
| relay port never appears | key not authorized, or `permitlisten` does not allow that port |
| 403 on `/api` | domain missing from `trustedHosts` |
| 401 then a login loop | cookie expired, or minted for another authority |
| `refresh-cookie.sh` prints docker/nginx usage | `--container` missing (or the old `eval` arg-passing bug) |
