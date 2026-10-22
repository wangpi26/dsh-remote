# dsh-remote 装机 runbook（给 AI agent 执行）

> **你是执行者。** 这份文件写给 AI agent，不是写给人。人类只会把入口那一行丢给你，
> 然后把密码、域名、SSH 访问这类**只有他知道的东西**告诉你。剩下的读文件、查状态、
> 改配置、验证、排错都由你完成，并且每一步都要真的跑验证命令，不要"看起来应该没问题"。

把 DSH 桌面端通过一台 Linux relay（nginx + 自定义登录页 + SSH 反向隧道）安全开放给手机浏览器，
**本机不开任何入站端口**。项目仓库：`https://github.com/wangpi26/dsh-remote`

---

## 0. 硬性规则（违反即停）

1. **永不**把下面这些内容打印到终端回显、写进对话、写进日志或提交到 git：
   cookie 原文（`dsh-auth-*`）、`~/.dsh/.credentials.yaml` 内容、SSH 私钥、登录密码、
   隧道 secret、真实 relay 公网 IP 与域名（写进 ticket/截图也不行）。
   需要确认时只打印长度、路径、sha256。
2. **不重启 DSH**。`trustedHosts` 是热加载的，改完 `cordis.patch.yml` 等几秒即可生效。
   重启会打断用户正在用的会话。
3. **不动别人的东西**。relay 上可能还跑着别的站点：不要改与本任务无关的 vhost、
   不要改别的 `*.conf`、不要动别人的 `authorized_keys` 行。只做**追加**，并先备份。
4. **改任何 nginx 配置前先备份、改完先 `nginx -t`**，测试不过就回滚，绝不 `reload` 一份坏配置。
5. **每个 Phase 的验收命令必须真的执行并贴出结果**。没跑过的检查一律标记为"未验证"，
   不要写成"已通过"。
6. 需要**只有人能做**的事（云厂商安全组、DNS 解析、证书签发、提供 SSH 凭据）时，
   明确告诉人"我需要你做 X"，然后等他做完再继续。不要自己猜一个域名继续往下走。

---

## 1. 先问清楚（一次性问完，别来回挤牙膏）

开始动手前，向人要齐下面几项；缺任何一项就停下来等，不要假设：

| 需要 | 说明 |
| --- | --- |
| 公开域名 | 例如 `dsh.example.com`，**只需一个**。要有指向 relay 的 A 记录 |
| relay 地址 | relay 的域名或公网 IP（后面命令里的 `RELAY_HOST`）。它就是那台 VPS |
| relay SSH 权限 | 能 `sudo` 的用户 + 已配好的 key。**不要向人要私钥内容**，让他自己配好 `~/.ssh/config` 别名 |
| nginx 形态 | 裸机 nginx，还是 Docker（1Panel/OpenResty）？后者要容器名 |
| 是否已有 dsh-remote | 这台 relay 上是否已经有一台电脑在用（默认占 `127.0.0.1:9100`）？有就换端口 |

同时自己先探一遍环境，把结果记下来（下面命令按平台选）：

```bash
# macOS
sw_vers; uname -m; python3 -V
ls -la ~/.dsh/.credentials.yaml ~/.dsh/profiles/desktop/ 2>/dev/null
lsof -nP -iTCP -sTCP:LISTEN | grep -i -E 'deepseek|dsh'   # 找 DSH 桌面端端口

# Windows（PowerShell）
$PSVersionTable.PSVersion; python --version
Test-Path "$env:USERPROFILE\.dsh\.credentials.yaml"
Get-NetTCPConnection -State Listen | Where-Object { $_.LocalAddress -eq '127.0.0.1' }
```

判据：`~/.dsh/.credentials.yaml` 和 `~/.dsh/profiles/desktop/` 都存在 = DSH 至少启动过一次。
不存在就让用户**先启动一次 DSH 桌面端**再继续。

---

## 2. Preflight：先排除 3 个最常见的死路

1. **DNS**：`dig +short <域名>` 应返回 relay 的 IP。没有记录 → 让人去加 A 记录，等生效。
2. **端口**：relay 的 80 和 443 必须能从公网访问。云厂商默认安全组常常只开 22，
   这是第一次装机最常见的卡点。让用户在控制台放行 80/443，然后你从外部验证：
   ```bash
   # 在 relay 之外的机器上（比如当前这台）
   nc -z -w 5 <域名> 443 && echo "443 open"; nc -z -w 5 <域名> 80 && echo "80 open"
   ```
3. **端口占用**：relay 上 9100 是否已被别的电脑占用。
   ```bash
   ssh <relay> 'ss -ltn | grep -E "9100|9101" || echo free'
   ```
   被占用就换一个（如 9101），并记住：**vhost 的 upstream 和隧道端口必须一致**。

把 Phase 1 收集到的信息和这三项检查结果，用一段话汇报给用户再进入 Phase 3。

---

## 3. Relay 侧安装

在 relay 上执行（`RELAY_HOST` 用你 ssh 的别名）：

```bash
ssh <relay> 'git clone https://github.com/wangpi26/dsh-remote.git ~/dsh-remote 2>/dev/null || (cd ~/dsh-remote && git pull)'
```

**裸机 nginx**：

```bash
ssh <relay> 'cd ~/dsh-remote/relay && sudo bash install-relay.sh \
  --domain <域名> \
  --cert /etc/letsencrypt/live/<域名>/fullchain.pem \
  --key  /etc/letsencrypt/live/<域名>/privkey.pem'
```

**Docker / 1Panel**（容器名用 `docker ps` 查；两个目录参数别写反）：

```bash
ssh <relay> 'cd ~/dsh-remote/relay && sudo bash install-relay.sh \
  --domain <域名> \
  --cert /www/sites/<域名>/ssl/fullchain.pem \
  --key  /www/sites/<域名>/ssl/privkey.pem \
  --conf-dir /opt/1panel/apps/openresty/openresty/conf/conf.d \
  --container <容器名> \
  --container-conf-dir /usr/local/openresty/nginx/conf/conf.d'
```

- `--conf-dir` = **宿主机上写文件的位置**；`--container-conf-dir` = **容器里 nginx 看到的路径**。
  写反不报参数错，但渲染出的 `include` 指向容器里不存在的文件，`nginx -t` 会报
  `open() ... failed (No such file or directory)`。
- 容器形态下脚本可能警告证书"is not visible from the host"：**这是正常的**，
  证书是给容器里的 nginx 读的，不是给宿主机读的。不要为了消掉这条警告去改路径。
- 脚本会打印**登录账号和随机密码**：把它交给用户存进密码管理器，**不要贴回对话**。

验收（此时隧道还没建，`127.0.0.1:9100` 连不通是正常的，下一步才建）：

```bash
ssh <relay> 'sudo docker exec <容器名> nginx -t'        # 裸机则 nginx -t；必须 successful
ssh <relay> 'curl -s -o /dev/null -w "%{http_code}\n" https://<域名>/login'
```

`/login` 返回 **500 是正常的**（cookie include 还是占位内容），Phase 5 推完 cookie 才好。
返回 **404** 说明 vhost 没生效，重跑 install-relay.sh；返回 **502** 说明 nginx 找不到上游，
但 `/login` 不走代理，出现 502 反而说明打到别的站点去了，检查 server_name。

---

## 4. Host 侧安装（按平台二选一）

### macOS

```bash
git clone https://github.com/wangpi26/dsh-remote.git
cd dsh-remote
bash host/macos/install-macos.sh \
  --domain <域名> --relay-host <RELAY_HOST> \
  --relay-user dsh-tunnel --remote-port 9100
```

它会：合并 `trustedHosts`（热加载、幂等、自动备份）、生成隧道 key、mint 初始 cookie、
装 launchd 隧道守护。**它会打印公钥**，记下来给 Phase 5。

### Windows（管理员 PowerShell）

```powershell
git clone https://github.com/wangpi26/dsh-remote.git
cd dsh-remote\host\windows
.\install-windows.ps1 -Domain <域名> -RelayHost <RELAY_HOST> `
  -RelayUser dsh-tunnel -CookieRelayUser root -SkipCookiePush
```

`-SkipCookiePush` 先不推 cookie（此时 relay 还没授权公钥），Phase 5 再推。

`--no-launchd`（macOS）只在你想自己接管守护时使用。

验收：`~/.dsh/profiles/desktop/cordis.patch.yml`（Windows 为 `%USERPROFILE%\.dsh\profiles\desktop\cordis.patch.yml`）
里出现你的域名，且 YAML 缩进正确。**不要重启 DSH**，等 3~5 秒让它热加载。

---

## 5. 授权公钥 + 推 cookie

**5.1 在 relay 上建受限隧道用户**（只允许转发这一个回环端口，不能登录 shell、不能 scp）：

```bash
ssh <relay> 'cd ~/dsh-remote/relay && sudo bash setup-tunnel-user.sh \
  --user dsh-tunnel --port 9100 --pubkey "<Phase 4 打印的公钥>"'
```

**5.2 确认隧道起来了**：

```bash
ssh <relay> 'ss -ltn | grep 9100'      # 应看到 127.0.0.1:9100
```

没起来就看电脑侧日志：macOS `~/.local/state/dsh-remote/tunnel.log` +
`tunnel-ssh.err.log`；Windows `%LOCALAPPDATA%\dsh-remote\tunnel.log`。
常见原因：公钥没授权、`permitlisten` 端口不匹配、DSH 没运行、电脑在睡眠。

**5.3 推 cookie**（需要一个能写 nginx 配置的身份，通常是 root）：

```bash
# macOS
bash host/macos/refresh-cookie.sh --authority <域名> \
  --relay-host <RELAY_HOST> --relay-user root \
  --identity-file ~/.ssh/<admin_key>
# Docker 里再加：--container <容器名> --remote-inc /宿主机/conf.d/dsh-cookie.inc

# Windows
.\refresh-cookie.ps1 -Authority <域名> -RelayHost <RELAY_HOST> `
  -RelayUser root -IdentityFile "$env:USERPROFILE\.ssh\<admin_key>"
```

脚本会：生成 cookie → 上传到 `/tmp` → `install -m 600` → `nginx -t` → reload；失败自动回滚。

> **绝对不要把一台电脑的 cookie 推到另一个 DSH 实例对应的 relay 上**：secret 不匹配会让对方登录失效。

---

## 6. 端到端验收（必须全部通过才算完成）

```bash
# ① 隧道在
ssh <relay> 'ss -ltnp | grep 9100'
# ② 隧道后面是活的 DSH（带 Host 头；401 = DSH 在、只是没 cookie，属正常）
ssh <relay> 'curl -s -o /dev/null -w "%{http_code}\n" -H "Host: <域名>" http://127.0.0.1:9100/'
# ③ 登录页可用（现在是 200，不再是 500）
curl -s -o /dev/null -w "%{http_code}\n" https://<域名>/login
# ④ 浏览器实际登录：输入账号密码 → 302 回 / → 带 Set-Cookie(HttpOnly/Secure/SameSite=Strict)
# ⑤ 手机连 4G（不走内网）打开 https://<域名>/，能进 DSH 且对话、WebSocket 正常
```

再做一个**反向确认**：删除 cookie 或换一个错误域名访问 `/api` 应得到 **403**，
说明 `trustedHosts` 与 Host 栅栏真的在生效（不是被谁放通了）。

---

## 7. 定时续期（30 天不做就会"登录成功却反复跳登录页"）

- Windows：`install-windows.ps1` 已注册 `dsh-remote-refresh` 计划任务，确认即可：
  `schtasks /Query /TN dsh-remote-refresh /V /FO LIST`
- macOS：没有自动的，装一个 LaunchAgent（完整 plist 见 `host/macos/README.md`
  的 "Scheduling the refresh" 段），然后
  `plutil -lint` + `launchctl bootstrap gui/$(id -u) …` 验证。

---

## 8. 出事怎么退

| 现象 | 先查 | 常见原因 |
| --- | --- | --- |
| 502 | relay `ss -ltn \| grep 9100` | 隧道没建、电脑睡眠、DSH 没跑 |
| 403 | `cordis.patch.yml` 里的域名 | `trustedHosts` 没生效/缩进错 |
| 登录成功又跳回 /login | 手动 mint + `--verify-url` 是否 200 | cookie 过期或 authority 不匹配 |
| `/login` 500 | `dsh-cookie.inc` 内容 | 还是占位 `set $dsh_cookie "";` |
| `/login` 404 | vhost 是否被覆盖 | 1Panel 改站点会重写 vhost，重跑 install-relay.sh |
| `nginx -t` 失败 | 脚本自动回滚 | 手工 `cp -a <conf>.bak-<时间> <conf>` 再 `nginx -t` |

回滚整台机器：`launchctl bootout gui/$(id -u)/com.dsh-remote.tunnel` + 删 plist（macOS），
或 `schtasks /Delete /TN dsh-remote-tunnel /F`（Windows），再删 relay 上那条 vhost 即可。
`~/.dsh/profiles/desktop/cordis.patch.yml` 从 `.bak` 还原。

---

## 9. 收尾要给人的汇报（按这个格式，不要贴机密）

1. **环境**：OS/版本、DSH 是否在跑、本机端口、relay 形态（裸机 or 容器）
2. **结果表**：DNS / 端口放行 / 隧道 / 登录页 / 浏览器登录 / 手机访问 —— 各写"通过 / 未验证 / 失败"
3. **未验证项**：没做的检查写清楚原因（例如"没有手机，未测 4G 访问"）
4. **日常维护**：cookie 续期怎么跑、日志在哪、换域名/改密码怎么重跑
5. **风险**：单账号无登出、依赖 DSH 未公开的 cookie 实现（升级可能失效，
   自检法：mint 后 `--verify-url` 返回 200 即仍兼容）

**不要**在汇报里出现：cookie 原文、凭据文件内容、私钥、登录密码、真实 IP。
