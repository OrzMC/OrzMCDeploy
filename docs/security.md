# 暴露面与访问控制

> **定位**：默认只信任局域网，对外暴露必须显式决定。本文定义三层限源模型（ADR-028）、
> 三档推荐配置、对外暴露方案与自检清单。
> **读者**：负责把面板 / EasyBot 暴露出去的运维。部署与运维操作见 [usage](usage.md)。

## 1. 三层模型

| 层 | 机制 | 默认值 | 谁能访问 |
|---|---|---|---|
| **L1 容器网络** | daemon 只挂 `orzmc_default`，不发布端口（ADR-026） | 已生效 | 仅同网络容器 |
| **L2 宿主绑定地址** | `.env` 的 `LAN_BIND_ADDR` | `0.0.0.0`（所有网卡） | 取决于绑定地址 |
| **L3 宿主防火墙** | `.env` 的 `LAN_CIDR` + `ALLOW_EXTRA_CIDRS` | 只放行 `LAN_CIDR` | 只有你的局域网网段（+ 显式追加的 VPN 网段） |

**为什么三层都要有**：

- 只有 L2（绑 `127.0.0.1`）= 最严格，但局域网设备也进不来，需要前置反代/VPN；
- 只有 L3（防火墙限源）= 端口仍绑在所有网卡上，防火墙误改/被绕过就暴露；
- 两层叠加后，"误把规则改成 Any" 或 "误把绑定改成 0.0.0.0" 都还需要**另一个**误操作才会真正暴露。

## 2. 配置项

| 变量 | 缺省 | 说明 |
|---|---|---|
| `LAN_BIND_ADDR` | `0.0.0.0` | 端口绑定的宿主地址：`0.0.0.0` 全部网卡 / `127.0.0.1` 仅本机 / 具体 IP 只绑该网卡 |
| `LAN_CIDR` | `192.168.0.0/24` | 防火墙放行的来源网段；**模板里是示例值，必须改成你的局域网网段** |
| `ALLOW_EXTRA_CIDRS` | 空 | 额外放行来源，逗号分隔（如 Tailscale `100.64.0.0/10`、另一台机器 IP） |
| `MC_TCP_PORTS` / `MC_UDP_PORTS` / `RCON_PORTS` | `25565,25566` / `19132` / `25575,25576` | 实例进服端口的放行清单（仅 `firewall` 使用；`templates/env` 里以注释形式给出） |

## 3. 三档推荐配置

### A. 最严格：只有本机能直连（推荐给"只在自己电脑管理"）

```bash
# .env
LAN_BIND_ADDR=127.0.0.1
```

此时端口只监听 `127.0.0.1`，局域网/外网都进不来。访问方式：

- 本机浏览器：`http://127.0.0.1:18090`
- 手机/别的设备：走 **Tailscale serve** 或本机反代（见 §4）

### B. 局域网可用（默认）

```bash
LAN_BIND_ADDR=0.0.0.0
LAN_CIDR=<你的局域网网段，如 192.168.1.0/24>
ALLOW_EXTRA_CIDRS=             # 有 VPN 就填 100.64.0.0/10（Tailscale）
```

然后应用防火墙（幂等，会先删掉旧的 `OrzMC-*` 规则再重建）：

```bash
./orzmc.sh -d <数据目录> firewall show       # 先看现状
./orzmc.sh -d <数据目录> firewall apply      # Windows 会弹 UAC（需管理员）；Linux 走 ufw
./orzmc.sh -d <数据目录> firewall apply --dry-run   # 只看将执行的命令
```

### C. 需要公网访问（三选一，按推荐顺序）

| 方式 | 做法 | 暴露面 |
|---|---|---|
| **VPN（推荐）** | Tailscale / WireGuard 组网；`LAN_BIND_ADDR` 可保持 `127.0.0.1`（配合 `tailscale serve`）或 `0.0.0.0` + `ALLOW_EXTRA_CIDRS=100.64.0.0/10` | **不开放任何公网端口** |
| **TLS 反代** | 本机或旁路设备跑 Caddy/Nginx（证书），只暴露反代端口；后端 `LAN_BIND_ADDR=127.0.0.1` | 只暴露 443/8443 |
| **路由器端口映射** | 映射到 `<宿主 LAN IP>:<端口>` | ❗ 面板是 HTTP + 口令登录；必须换强口令，且尽量限制来源 IP |

> 注意 WebSocket：面板与终端都走 WS，反代必须放行 `Upgrade`（Caddy 默认支持）。

## 4. TLS 反代配方（DNS-01，家宽适用）

站点若要给面板配 `https://<域名>`，推荐 **Caddy + Let's Encrypt DNS-01**：证书靠 Cloudflare
API 写 `_acme-challenge` TXT 记录验证，**不依赖入站 80/443**，因此家宽/端口被封也能签发。

```yaml
# $DATA_ROOT/compose.site.yaml（站点增量，升级不丢）
services:
  caddy:
    # 官方 caddy 镜像不含 DNS provider，必须用带 cloudflare 模块的构建
    image: ghcr.io/caddybuilds/caddy-cloudflare@sha256:...
    ports: ["80:80", "443:443"]        # 80 仅用于 HTTP→HTTPS 跳转（可选）
    environment:
      CF_DNS_API_TOKEN: "${CF_DNS_API_TOKEN}"
    volumes:
      - "${DATA_ROOT}/site/Caddyfile:/etc/caddy/Caddyfile:ro"
      - "${DATA_ROOT}/caddy/data:/data"      # 证书缓存在这里，务必随数据备份
```

```text
# $DATA_ROOT/site/Caddyfile
{
    email you@example.com
}
mcs.example.com {
    tls { dns cloudflare {$CF_DNS_API_TOKEN} }
    reverse_proxy mcsmanager-web:23333     # 与面板同网络，无需经过宿主端口
}
```

配套三件事：

| 项 | 说明 |
|---|---|
| Cloudflare API Token | 权限 **Zone → DNS → Edit**，只授该 zone；写进 `$DATA_ROOT/.env`，永不入库 |
| 防火墙 | 只额外放行 Caddy 的端口（80/443）；面板 23333、EasyBot 18091 仍限 `LAN_CIDR` |
| 路由器 | `外部 443 → 宿主 443`；若 ISP 封 443，可改映射高位端口（如 18443 → 宿主 443），证书与端口无关 |

**关掉 HTTP/3，或同时转发 UDP 443**：Caddy 默认启用 QUIC 并返回 `alt-svc: h3=":443"`，
而家用路由器通常只转发 TCP 443 → 浏览器试 QUIC 被丢包再回退，表现为「偶尔打不开/白屏/
chunk 加载失败」，但 curl 正常（不走 h3）。最简单是在 Caddyfile 全局块加
`servers { protocols h1 h2 }`（或让路由器也转发 UDP 443）。改完需完全退出浏览器（或
`chrome://net-internals/#sockets` flush）才会丢掉缓存的 alt-svc。

**反代端口**（80/443）本身要对公网开放，属站点有意暴露：单独命名（如 `OrzMC-Web-TLS`）
并保留 `RemoteAddress` 按需（甚至 `Any`）。

**游戏端口是第二类有意 `Any`**（玩家要直连，无法经反代）：在 `.env` 写
`MC_PUBLIC_TCP` / `MC_PUBLIC_UDP`（逗号分隔），`./orzmc.sh firewall apply` 会生成
`OrzMC-MC-Public-TCP` / `OrzMC-MC-Public-UDP`（`RemoteAddress Any`）；留空则完全不生成。
典型清单：

| 协议 | 端口 | 用途 |
|---|---|---|
| TCP | `25565,25566` | Java 版 |
| TCP | `19132,19133` | 基岩 NetherNet 信令（`signaling.mode: builtin` 跑在 Bedrock 端口上） |
| UDP | `19132,19133` | 基岩 RakNet |
| UDP | `19134,19135` | 基岩 NetherNet 媒体（WebRTC） |
| UDP | `24454` | Simple Voice Chat（需实例映射该端口） |

路由器需把**相同端口、相同协议**转发到宿主机。`RCON`（`25575/25576`）与 `Query`（`9898`）
**不得**进这两个清单。游戏端口没有鉴权：公网开放后白名单就是唯一门槛，
`online-mode=false` 时更要管控名单。

**`OrzMC-Panel` / `OrzMC-EasyBot` / `OrzMC-MC-TCP` / `OrzMC-MC-UDP` / `OrzMC-RCON` 永远限
`LAN_CIDR`**（`firewall apply` 每次重建，只删重建 `OrzMC-*` 同名项，不会碰 `OrzMC-Web-TLS`）。

**反代一律整站透传**：站点 Caddyfile 里只写 `reverse_proxy <服务>:<端口>`（面板加
`flush_interval -1` 保 WebSocket），不要加 `handle` / `respond` / `rewrite` / `@matcher`
之类路径级规则——同一服务经公网与经局域网访问必须功能一致（路径、静态资源、WS、API 全同）。
确需收窄暴露面时，做法是**整个服务不给公网域名**，而不是在反代里挑几条路径挡掉：容器内
`remote_ip` 已被 Docker 改写成网桥网关，按来源 IP 分流本来就不可靠，拦几条路径只会让
「后台页面里的下载/文档/回调链接」在公网 404，排查成本远大于收益。

EasyBot 属同一原则：反代 `easybot` 域名后，后台 `/admin`、开发者文档 `/docs`、`/swagger`、
插件 API `/api/v1/*` 与直连 `http://<LAN_HOST_IP>:<LAN_EASYBOT_PORT>` 逐项相同（均自带登录 /
API key 鉴权，文档只暴露接口清单）。若站点确要隐藏文档，只能整站不给公网域名；强行路径拦截
会让后台里的文档链接在公网 404，破坏一致性：

```text
@devdocs path /docs* /swagger*
respond @devdocs "404 page not found" 404
```

验证：`openssl s_client -connect <域名>:443 -servername <域名>` 看 issuer；证书由 Caddy 按
ARI 自动续期。

## 5. 自检

```bash
./orzmc.sh -d <数据目录> status        # 打印"暴露面"摘要（绑定地址 / 建议限源命令）
./orzmc.sh -d <数据目录> firewall show    # 列出当前 OrzMC-* 规则的端口与来源
docker ps --format '{{.Names}}\t{{.Ports}}' | grep orzmc   # 谁发布了什么端口
```

预期（安全基线）：

- 只有 `mcsmanager-web` 与 `easybot` 发布宿主端口；`daemon` 无发布端口；
- `firewall show` 里所有 `OrzMC-*` 规则的 `remote` 是 `LAN_CIDR`（不是 `Any`）；
- `status` 的暴露面提示与你的预期一致（`127.0.0.1` / `0.0.0.0` / 具体 IP）。

## 6. 常见暴露错误

| 错误 | 后果 |
|---|---|
| 把 `23333` 规则改成 `RemoteAddress Any` | 任意来源可访问登录页，可被暴力破解 |
| `LAN_BIND_ADDR=0.0.0.0` 且没有任何防火墙规则 | 同网段任何设备（含访客 Wi-Fi/被入侵的设备）都能访问面板 |
| 直接把面板端口做公网映射 | 口令走明文 HTTP，等于公开凭据 |
| 用 `docker run -p 24444` 之类把 daemon 暴露出去 | daemon key = 宿主机 Docker 控制权，等于交出整机 |
| 给 `ALLOW_EXTRA_CIDRS` 填 `0.0.0.0/0` | 等于关闭防火墙 |

## 7. 平台差异

- **Windows**：`firewall apply` 走 PowerShell `New-NetFirewallRule`（弹 UAC）；发布端口在 WSL
  网络栈里，`netstat` 看不到监听属正常，用另一台设备验证（其余见 usage 附录 F）。
- **Linux**：优先 `ufw`，未安装时脚本打印等价 `iptables` 命令。
- **macOS**：只打印等价 `pf` 规则（不自动改），实际用 `LAN_BIND_ADDR` 收紧更可靠。

## 8. 凭据加固

- `.env` 权限收紧、永不入库；
- `EASYBOT_ADMIN_PASSWORD` / 面板管理员口令用强口令（12 位以上、非字典词）；
- 面板默认开启 `loginCheckIp`，保留；
- 定期 `./orzmc.sh firewall show` 复核，别让规则悄悄变回 `Any`。
