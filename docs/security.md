# 网络暴露面与访问控制

> 目标：**默认只信任局域网，对外暴露必须显式决定**。本项目只有局域网模式
> （ADR-027），本文件定义在此之上的三层收敛策略（ADR-028）与自检流程。

## 1. 三层模型

| 层 | 机制 | 默认值 | 谁能访问 |
|---|---|---|---|
| **L1 容器网络** | daemon 只挂 `orzmc_default`，不发布端口（ADR-026） | 已生效 | 仅同网络容器 |
| **L2 宿主绑定地址** | `.env` 的 `LAN_BIND_ADDR` | `0.0.0.0`（所有网卡） | 取决于绑定地址 |
| **L3 宿主防火墙** | `.env` 的 `LAN_CIDR` + `ALLOW_EXTRA_CIDRS` | 只放行 `192.168.0.0/24` | 只有该网段（+ 显式追加的 VPN 网段） |

**为什么三层都要有**：

- 只有 L2（绑 `127.0.0.1`）= 最严格，但局域网设备也进不来，需要前置反代/VPN；
- 只有 L3（防火墙限源）= 端口仍绑在所有网卡上，防火墙误改/被绕过就暴露；
- 两层叠加后，"误把规则改成 Any" 或 "误把绑定改成 0.0.0.0" 都还需要**另一个**误操作才会真正暴露。

## 2. 配置项

| 变量 | 缺省 | 说明 |
|---|---|---|
| `LAN_BIND_ADDR` | `0.0.0.0` | 端口绑定的宿主地址：`0.0.0.0` 全部网卡 / `127.0.0.1` 仅本机 / 具体 IP 只绑该网卡 |
| `LAN_CIDR` | `192.168.0.0/24` | 防火墙默认放行的来源网段 |
| `ALLOW_EXTRA_CIDRS` | 空 | 额外放行来源，逗号分隔（如 Tailscale `100.64.0.0/10`、另一台机器 IP） |
| `MC_TCP_PORTS` / `MC_UDP_PORTS` / `RCON_PORTS` | `25565,25566` / `19132` / `25575,25576` | 实例进服端口的放行清单（仅 `firewall` 使用） |

## 3. 三档推荐配置

### A. 最严格：只有本机能直连（推荐给"只在自己电脑管理"）

```bash
# .env
LAN_BIND_ADDR=127.0.0.1
```

此时端口只监听 `127.0.0.1`，局域网/外网都进不来。访问方式：

- 本机浏览器：`http://127.0.0.1:18090`
- 手机/别的设备：走 **Tailscale serve** 或本机反代（见 §5）

### B. 局域网可用（默认）

```bash
LAN_BIND_ADDR=0.0.0.0
LAN_CIDR=192.168.0.0/24        # 你的局域网网段
ALLOW_EXTRA_CIDRS=             # 有 VPN 就填 100.64.0.0/10（Tailscale）
```

然后应用防火墙（幂等，会先删掉旧的 `OrzMC-*` 规则再重建）：

```bash
./orzmc.sh firewall show       # 先看现状
./orzmc.sh firewall apply      # Windows 会弹 UAC（需管理员）；Linux 走 ufw
./orzmc.sh firewall apply --dry-run   # 只看将执行的命令
```

### C. 需要公网访问（三选一，按推荐顺序）

| 方式 | 做法 | 暴露面 |
|---|---|---|
| **VPN（推荐）** | Tailscale / WireGuard 组网；`LAN_BIND_ADDR` 可保持 `127.0.0.1`（配合 `tailscale serve`）或 `0.0.0.0` + `ALLOW_EXTRA_CIDRS=100.64.0.0/10` | **不开放任何公网端口** |
| **TLS 反代** | 本机或旁路设备跑 Caddy/Nginx（证书），只暴露反代端口；后端 `LAN_BIND_ADDR=127.0.0.1` | 只暴露 443/8443 |
| **路由器端口映射** | 映射到 `<宿主 LAN IP>:<端口>` | ❗ 面板是 HTTP + 口令登录；必须换强口令，且尽量限制来源 IP |

> 注意 WebSocket：面板与终端都走 WS，反代必须放行 `Upgrade`（Caddy 默认支持）。

## 3.1 TLS 反代实操配方（DNS-01，适合家宽）

站点若要给面板配 `https://<域名>`，推荐 **Caddy + Let's Encrypt DNS-01**：证书靠 Cloudflare
API 写 `_acme-challenge` TXT 记录验证，**不依赖入站 80/443**，因此家宽/端口被封也能签发。

```yaml
# $DATA_ROOT/compose.site.yaml（站点增量，升级不丢）
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

**反代不要顺带暴露开发文档**：EasyBot 的 `/docs`、`/swagger` 是开发调试页面，
公网无必要。注意 **容器内 `remote_ip` 已被 Docker 改写成网桥网关**，靠 IP 匹配区分
内外网并不可靠——直接在反代里无条件挡掉、局域网改走宿主端口即可：

```text
@devdocs path /docs* /swagger*
respond @devdocs "404 page not found" 404
```

同理：EasyBot 的插件 API（`/api/v1/*`）与管理后台同端口，一旦把该域名反代出去，
插件 API 也随之外露（有 API key 鉴权）。若不需要公网管理 EasyBot，最省事的是
**不给它配公网域名**，只保留面板一个公网入口。

验证：`openssl s_client -connect <域名>:443 -servername <域名>` 看 issuer 是否为 Let's Encrypt；
`curl -I https://<域名>/` 200；证书到期前 Caddy 会按 ARI 自动续期，无需人工干预。

## 4. 自检

```bash
./orzmc.sh status                 # 打印"暴露面"摘要（绑定地址 / 建议限源命令）
./orzmc.sh firewall show          # 列出当前 OrzMC-* 规则的端口与来源
docker ps --format '{{.Names}}\t{{.Ports}}' | grep orzmc   # 谁发布了什么端口
```

预期（安全基线）：

- 只有 `mcsmanager-web` 与 `easybot` 发布宿主端口；`daemon` 无发布端口；
- `firewall show` 里所有 `OrzMC-*` 规则的 `remote` 是 `LAN_CIDR`（不是 `Any`）；
- `status` 的暴露面提示与你的预期一致（`127.0.0.1` / `0.0.0.0` / 具体 IP）。

## 5. 常见暴露错误（不要这么干）

| 错误 | 后果 |
|---|---|
| 把 `23333` 规则改成 `RemoteAddress Any` | 任意来源可访问登录页，可被暴力破解 |
| `LAN_BIND_ADDR=0.0.0.0` 且没有任何防火墙规则 | 同网段任何设备（含访客 Wi-Fi/被入侵的设备）都能访问面板 |
| 直接把面板端口做公网映射 | 口令走明文 HTTP，等于公开凭据 |
| 用 `docker run -p 24444` 之类把 daemon 暴露出去 | daemon key = 宿主机 Docker 控制权，等于交出整机 |
| 给 `ALLOW_EXTRA_CIDRS` 填 `0.0.0.0/0` | 等于关闭防火墙 |

## 6. 平台差异

- **Windows**：`firewall apply` 通过 PowerShell 的 `New-NetFirewallRule` 建规则（需要管理员，
  脚本会弹 UAC）。Docker 发布端口在 WSL 网络栈里，Windows 侧 `netstat` 看不到监听属正常；
  **验证要用手机/另一台机器**。
- **Linux**：优先用 `ufw`（未安装时脚本打印等价 `iptables` 命令）。
- **macOS**：脚本只打印建议（`pf` 规则易误伤，不自动改），实际用 `LAN_BIND_ADDR` 控制即可。

## 7. 凭据加固（配合做）

- `.env` 权限收紧、永不入库；
- `EASYBOT_ADMIN_PASSWORD` / 面板管理员口令用强口令（12 位以上、非字典词）；
- 面板默认开启 `loginCheckIp`，保留；
- 定期 `./orzmc.sh firewall show` 复核，别让规则悄悄变回 `Any`。
