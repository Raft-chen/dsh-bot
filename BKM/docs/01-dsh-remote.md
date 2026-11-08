# 案例 1：手机远程控制家里的 DSH（国内网络）

> 目标：人在外面，用手机（iPhone / 华为）查看和控制家里工作站上跑的 DSH。
>
> 环境：Windows 11 工作站 + 阿里云轻量服务器（Linux）+ 国内网络。
>
> 结果：`https://<你的子域名>` 从任何网络都能打开，不需要 VPN，不需要公网 IP。

---

## 一、最终架构

```
手机 Safari/浏览器（任意网络）
        │  HTTPS（证书由服务器签发，自动续期）
        ▼
阿里云服务器 nginx  ── 反代 ──>  127.0.0.1:8787
        │                              ▲
        │  SSH 反向隧道（工作站主动连出） │
        ▼                              │
家里工作站 ─────────────────────────────┘
        └─ DSH Remote 网关 :8787 ──> DSH 本体
```

要点：

- **工作站主动向服务器建立 SSH 隧道**，所以家里不需要公网 IP、不需要端口映射
- 服务器上 nginx 只把请求转给 `127.0.0.1:8787`，这个端口只对隧道开放
- 手机只看到 HTTPS，证书合法，不触发浏览器的「仅 HTTPS」拦截

---

## 二、走过的三条路

### 路线 A：Tailscale（❌ 放弃）

思路没问题，但国内环境有三个硬伤：

| 问题 | 现象 |
|---|---|
| 控制面不稳 | 不开 VPN 时手机连不上 Tailscale 控制服务器；开了 VPN 又把 WireGuard 流量代理走，打洞失败 |
| iOS Safari 拦 http | 开着「仅 HTTPS」时，`http://<tailscale-ip>:8787` 直接报「导览失败，因为要求是针对已启用"仅限 HTTPS"的 HTTP URL」 |
| 华为装不了 | 没有 Google Play，官方只发 Play 商店；APK 侧载又要过「纯净模式」+ 未知来源 |

> 注意：Tailscale 本身没坏，只是这套**国内网络 + iOS/鸿蒙 + 局域网服务**的组合太难搞。
> 如果你能稳定访问控制面，Tailscale 依然是很好的方案。

### 路线 B：nginx 子路径 `/remote/`（❌ 失败）

以为加一个 `location /remote/ { proxy_pass http://127.0.0.1:8787/; }` 就行。

**不行**：DSH Remote 网关的 Web 客户端用的是**绝对路径**（`/api/...`、`/styles.css`），
挂在子路径下所有资源都会 404。它没有 base path 配置项。

### 路线 C：独立子域名 + SSH 反向隧道（✅ 采用）

```
dsh.<你的域名>  →  A 记录  →  阿里云 IP
nginx 443       →  proxy_pass http://127.0.0.1:8787
工作站          →  ssh -R 8787:127.0.0.1:8787 <user>@<服务器>
```

---

## 三、实施步骤（可复制）

### 1. DNS

在域名服务商加一条 A 记录：

| 类型 | 主机记录 | 值 |
|---|---|---|
| A | `dsh` | `<服务器公网 IP>` |

### 2. 证书（acme.sh）

**坑**：`acme.sh --issue --nginx` 在 `sudo` 下会直接拒绝运行并打印一段关于 sudo 的说明。

**解决**：用 **webroot 模式**，以**普通用户**签发，把证书目录交给该用户写。

```bash
# 服务器上，普通用户执行，不要 sudo
~/.acme.sh/acme.sh --issue -d dsh.<你的域名> -w /var/www/<站点目录>

~/.acme.sh/acme.sh --install-cert -d dsh.<你的域名> \
  --key-file       /etc/nginx/ssl/dsh.key \
  --fullchain-file /etc/nginx/ssl/dsh.pem \
  --reloadcmd      "sudo systemctl reload nginx"
```

- `/var/www/<站点目录>` 必须是该用户可写、nginx 可读
- `/etc/nginx/ssl` 的 owner 要给该用户（`sudo chown -R <user>:<user> /etc/nginx/ssl`），
  否则 `--install-cert` 报 `touch: Permission denied`

### 3. nginx 配置

`/etc/nginx/conf.d/dsh.conf`：

```nginx
proxy_cache_path /var/cache/nginx/dsh levels=1:2 keys_zone=dshcache:20m
                 max_size=300m inactive=7d use_temp_path=off;

server {
    listen 80;
    server_name dsh.<你的域名>;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name dsh.<你的域名>;

    ssl_certificate     /etc/nginx/ssl/dsh.pem;
    ssl_certificate_key /etc/nginx/ssl/dsh.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    client_max_body_size 2g;
    access_log /var/log/nginx/dsh-access.log;

    gzip              on;
    gzip_comp_level   6;
    gzip_min_length   512;
    gzip_proxied      any;
    gzip_vary         on;
    gzip_types        text/plain text/css text/javascript application/javascript
                      application/json application/xml image/svg+xml application/wasm;

    # 静态资源：缓存，避免反复穿过隧道
    location ~* \.(js|css|svg|png|jpg|jpeg|gif|ico|woff2?|ttf|map|webmanifest|json)$ {
        proxy_pass http://127.0.0.1:8787;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_ignore_headers   Cache-Control Set-Cookie Expires Vary;
        proxy_cache            dshcache;
        proxy_cache_key        "$request_uri";
        proxy_cache_valid      200 7d;
        proxy_cache_lock       on;
        proxy_cache_use_stale  error timeout updating;
        add_header X-Cache-Status $upstream_cache_status;
    }

    # 动态（会话 / SSE / WebSocket）：不缓存
    location / {
        proxy_pass http://127.0.0.1:8787;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
        add_header Cache-Control "no-store";
    }
}
```

> **`proxy_ignore_headers Cache-Control ...`** 是让缓存真正生效的关键：
> 上游默认返回 `Cache-Control: no-cache` + `Vary`，nginx 会因此拒绝缓存。

### 4. 工作站：常驻反向隧道

手工 `ssh -R` 一关窗口就断。做成 **Windows 计划任务 + 守护循环**：

见 [`scripts/keep-tunnel.ps1`](../scripts/keep-tunnel.ps1)。核心：

```powershell
& $ssh -N -C `
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 `
    -o ExitOnForwardFailure=yes -o ConnectTimeout=15 `
    -R 8787:127.0.0.1:8787 <ssh-host-alias>
```

用 `schtasks` 注册成登录自启：

```powershell
schtasks /create /tn "DSH-Remote-Tunnel" /tr "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File <路径>\keep-tunnel.ps1" /sc onlogon /rl highest /f
```

> `-C` 是 SSH 压缩：文本资源（JS/CSS）在窄上行下能省 5~8 倍。

### 5. 工作站：常驻网关

DSH Remote 网关是**插件 spawn 出来的子进程**，有两个坑：

1. DSH 一重启，网关跟着死
2. 通过脚本/工具启动的进程可能被父进程树回收，起来了也会"凭空消失"

解决：同样用计划任务，并且**自动探测 DSH 上游端口**（DSH 每次启动端口会变）。

见 [`scripts/keep-gateway.ps1`](../scripts/keep-gateway.ps1)。探测思路：

```
扫描本机所有监听端口 → 请求 http://127.0.0.1:<port>/ → 返回 401 的就是 DSH Web
```

### 6. 防令牌爆破

网关的访问令牌只有 8 位，公网可达就需要限制尝试次数。

踩过 `fail2ban` 的两个坑：

| 坑 | 现象 | 原因 |
|---|---|---|
| 封禁不生效 | 日志里 `FirewallD is not running` | 默认 action 用 `firewallcmd`，但系统没跑 firewalld → 改用 `iptables-multiport` |
| 计数永远是 0 | `Found a match but no valid date/time found` | nginx 日志时间戳在 `[...]` 里，日期模板要写成 `^[^\[]*\[({DATE})` |

最后干脆**自己写**：40 行 bash + cron 每分钟 + iptables 自定义链。
见 [`scripts/dsh-remote-guard.sh`](../scripts/dsh-remote-guard.sh)。

规则：同 IP 10 分钟内累计 10 次 `401` → 封 80/443 一小时，自动解封，本机/内网豁免。

---

## 四、坑位清单（12 条）

| # | 坑 | 排查 / 解决 |
|---|---|---|
| 1 | Tailscale 国内直连不稳 | 放弃，改用阿里云中转 |
| 2 | iOS Safari 提示「仅 HTTPS」 | 要么关开关，要么给服务上合法 HTTPS（本方案选了后者）|
| 3 | 华为无 GMS，装不了 Play 应用 | 用浏览器访问即可；或侧载 APK（需关纯净模式）|
| 4 | 轻量服务器站点目录 owner 是 `nginx:root` | `sudo chown -R <user>:<user> /var/www/...`，之后就再也不用 sudo |
| 5 | 忘了 sudo 密码 | 控制台「重置密码」→ VNC 登录 root → `passwd <user>`；或干脆 `chown` 掉 |
| 6 | nginx 子路径反代 404 | 网关不支持 base path，必须用独立子域名 |
| 7 | `acme.sh` 拒绝 sudo 运行 | 用 webroot 模式 + 普通用户执行 |
| 8 | `--install-cert` 报 Permission denied | `/etc/nginx/ssl` 的 owner 改成该用户 |
| 9 | 静态资源 `proxy_cache` 一直 MISS | 加 `proxy_ignore_headers Cache-Control Set-Cookie Expires Vary` |
| 10 | fail2ban 封禁不生效 | 系统没有 firewalld → `action = iptables-multiport` |
| 11 | fail2ban 数不到 401 | nginx 日志日期模板要写成 `^[^\[]*\[({DATE})` |
| 12 | 网关「自己消失」 | DSH 子进程 + 父进程树回收 → 用计划任务 + 上游端口自动探测 |

---

## 五、几条方法论

1. **「网页没更新」先分端口径**：服务器返回的 SHA256 和本地一致 → 就是浏览器缓存，别去改服务器
2. **测速要测对方向**：本机访问自己的公网域名会绕一圈，数字没有意义；要在服务器侧测
3. **进程别用脚本起**：交互式命令启动的常驻进程很可能被回收，一律走计划任务 / 服务
4. **改配置前先备份**：`cp <file> <file>.bak.$(date +%s)`
5. **每个"慢"字都要量化**：`time_total`、`speed_download`、TTFT、tok/s —— 有数字才谈得上优化

---

## 六、运行后的自检清单

```bash
# 服务器：隧道端口在监听
ss -lnt | grep 8787

# 服务器：隧道 -> 网关
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://127.0.0.1:8787/

# 服务器：nginx -> 隧道
curl -sk -o /dev/null -w '%{http_code} %{time_total}s\n' https://127.0.0.1/ -H 'Host: dsh.<你的域名>'

# 本机：外网可访问
curl -s -o /dev/null -w '%{http_code}\n' https://dsh.<你的域名>/
```

四条全 200 就通了。
