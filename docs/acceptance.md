# OrzMC 三档验收实录（2026-08-15）

> 本文件记录 **prod / local / lan** 三档的**实际验收过程**：验收清单、实测步骤、
> 发现的问题与解决办法，作为后续验收与运维的参考基线。
> 与平台层相关文档联动：架构与 ADR 见 `docs/architecture.md`，用户操作见 `docs/usage.md`。

## 1. 前置条件与总览

- **同机互斥**：三档共用 compose 项目名 `orzmc` 与容器名，**同一时刻只能跑一档**。
  切档前必须 `stop`（`./local.sh stop` / `./lan.sh stop` / `deploy.sh -d <root> stop`），
  否则 profile 专属容器（caddy/cloudflared）残留、互相顶替。
- **节点地址铁律（三档通用）**：**面板服务端与浏览器必须走同一地址**——面板容器要能
  解析/路由到该地址，浏览器也要能访问；否则出现「节点在线但浏览器无法直连终端」。
- **验收方式**：平台层容器状态 + 入口可达性 + 面板登录 + 节点连通 + Gatus 状态页 +
  用户浏览器实际确认（本机或局域网设备）。

| 档 | DATA_ROOT | 入口形态 | 边缘层 | 节点地址 |
|---|---|---|---|---|
| prod | `/Users/Shared/orzmc` | `mcs.<domain>` 等（HTTPS） | cloudflared 隧道 | `wss://mcs-node.<domain>:443` |
| local | `.local-data/` | `mcs.localhost:18443` 等（HTTPS，本地 CA） | Caddy | `wss://mcs-node.localhost:18443` |
| lan | `.local-data-lan/` | `http://<LAN_HOST_IP>:18090` 等（HTTP） | 无 | `ws://<LAN_HOST_IP>:24444` |

三档浏览器**终端/控制台/文件管理器均可用**（ADR-013 + ADR-014）；daemon 全部业务路由
要求 daemon key 鉴权，无 key 无权限。

## 2. prod 档验收

### 2.1 清单与结果

| 检查项 | 结果 |
|---|---|
| 6 容器 Up（web / daemon / easybot / mariadb / status / cloudflared），mariadb+easybot healthy | PASS |
| cloudflared `Registered tunnel connection`（QUIC ×4） | PASS |
| 4 公网入口 `mcs/easybot/mcs-node/orzmcs.<domain>` HTTP 200 | PASS |
| 面板↔daemon 经隧道连接 + 密钥验证通过 | PASS |
| MariaDB 内网 `mariadb-admin ping` / EasyBot `/api/v1/live` 200 | PASS |
| Gatus 状态页平台层 + 实例全 UP | PASS |
| PaperMC 实例 `25565` TCP 可达 | PASS |

### 2.2 实测过程

1. `./update-image-digests.sh` 刷新镜像 digest → `deploy.sh -d /Users/Shared/orzmc up`。
2. `deploy.sh -d /Users/Shared/orzmc status` 确认 6 容器；`docker logs orzmc-cloudflared`
   看隧道注册。
3. 从 `.env` 读 `DOMAIN_*`（非密钥），逐个 `curl -sS -o /dev/null -w '%{http_code}' https://<domain>`。
4. `docker logs orzmc-mcsmanager-web` 确认「已连接 + 密钥验证通过」；
   `curl -sk https://orzmcs.<domain>/api/v1/endpoints/statuses` 看状态页。

### 2.3 发现的问题与解决

- **P1｜浏览器无法连接到地址 `ws://mcsmanager-daemon:24444`**：节点 `ip` 是 Docker 内网
  主机名（ADR-011 时代的遗留），浏览器解析不了。**解决**：节点地址改隧道 URL
  `wss://mcs-node.<domain>:443`（ADR-013）。实证：隧道 socket.io 的 polling/websocket +
  `{uuid,data}` 信封鉴权全通（`data:true`），daemon 日志确认来自 cloudflared 的会话鉴权。
- **事故｜面板 crash-loop `Cannot read properties of null (reading 'ip')`**：改节点配置前把
  备份 `.bak` 放进了 `RemoteServiceConfig/` 目录——storage `list()` 全量扫描该目录、把
  `.bak` 当第二个节点 uuid 加载 null。**教训**：`RemoteServiceConfig/` 禁止放任何非节点
  配置文件；配置备份一律放 `$DATA_ROOT/backups/`。

## 3. local 档验收

### 3.1 清单与结果

| 检查项 | 结果 |
|---|---|
| 6 容器 Up（含 caddy；无 cloudflared），mariadb+easybot healthy | PASS |
| 4 入口 `mcs/easybot/mcs-node/orzmcs.localhost:18443`（Caddy 本地 CA，`curl -k`）HTTP 200 | PASS |
| `./local.sh validate` | PASS |
| 面板登录 + 添加节点（`wss://mcs-node.localhost`）→ 节点 `connected` | PASS |
| Gatus 状态页全 UP / EasyBot live 200 | PASS |
| 浏览器直连终端可用（信任本地 CA 后「网页直连」正常） | PASS |

### 3.2 实测过程

1. `deploy.sh -d /Users/Shared/orzmc stop`（停 prod）→ `./local.sh start`。
2. `./local.sh status` / `./local.sh validate`；`curl -k` 4 个 `.localhost` 入口。
3. 面板登录 → 添加节点（地址 `wss://mcs-node.localhost`，端口 `18443`，key 取
   `.local-data/mcsmanager/daemon/data/Config/global.json`）。
4. 浏览器信任 Caddy 本地根证书（见 P2）并完全重启后，节点「网页直连」正常、终端可用。

### 3.3 发现的问题与解决

- **P1｜节点添加后显示离线**：两个根因叠加——
  ① 面板容器（`mcsmanager-web`）**没有 `extra_hosts`**，容器内把 `mcs-node.localhost`
  解析成自己的回环 `127.0.0.1`（RFC 6761 `.localhost`），连不到宿主 Caddy；② 节点 `ip`
  缺 `wss://` 前缀（Caddy 18443 是 TLS 端口）。**解决**：`compose.yaml` 的 web 服务加
  `extra_hosts: ["mcs-node.localhost:host-gateway"]`（与 status 服务既有做法一致），节点
  `ip` 改 `wss://mcs-node.localhost`（ADR-014）。改后 `docker restart orzmc-mcsmanager-web`
  即连上：日志「URL: wss://mcs-node.localhost:18443 已连接 + 密钥验证通过」。
- **P2｜「网页直连」异常**：浏览器直连 `wss://mcs-node.localhost:18443` 时**不信任 Caddy
  本地根证书**（`curl -k` 能过，`curl` 不带 `-k` 报 `unable to get local issuer certificate`）。
  **解决**（一次性）：把根证书导入钥匙串并**完全退出重开**浏览器：
  ```
  security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain \
    .local-data/caddy/data/caddy/pki/authorities/local/root.crt
  ```
  若 Chrome 仍未采纳登录钥匙串信任，改用系统钥匙串
  `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ...`。
  验证技巧：本机 Node 不读 macOS 钥匙串，需 `NODE_EXTRA_CA_CERTS=<root.crt>` 才能复刻
  浏览器严格 TLS；用 `curl` 不带 `-k` 验证系统信任即可。
- **P3｜状态页残留「PaperMC 测试服」端点**（模板已移除，运行文件没变）：`ensure_*` 函数
  绝不覆盖已有文件，模板变更后需**删除落盘文件再重新 init**：
  ```
  python3 -c "import os; os.remove('.local-data/status/config.yaml')" && ./local.sh start
  docker restart orzmc-status
  ```

## 4. lan 档验收

### 4.1 清单与结果

| 检查项 | 结果 |
|---|---|
| 5 容器 Up（**无 caddy/cloudflared**，无边缘层），mariadb healthy | PASS |
| 4 宿主端口 `18090/18091/18092/24444`（真实 LAN IP）HTTP 200 | PASS |
| `./lan.sh validate` | PASS |
| 面板登录 + 添加节点（`ws://<LAN_HOST_IP>`）→ 节点 `connected` | PASS |
| Gatus 状态页全 UP / EasyBot live 200 | PASS |
| 浏览器（含局域网其他设备）直连终端可用 | PASS |

### 4.2 实测过程

1. `./local.sh stop`（停 local）→ `./lan.sh start`。
2. 用 **真实局域网 IP** 逐个 `curl http://<LAN_HOST_IP>:<port>/`（详见 P1）。
3. 面板登录 → 添加节点（地址 `ws://<LAN_HOST_IP>`，端口 `LAN_MCS_DAEMON_PORT`，key 取
   `.local-data-lan/mcsmanager/daemon/data/Config/global.json`）。
4. 浏览器/局域网设备访问实例页验证终端（lan 为纯 HTTP，无 CA 信任问题）。

### 4.3 发现的问题与解决

- **P1｜`LAN_HOST_IP` 配置错误**：`.env` 里是 `192.168.1.100`（不同网段死地址，`ping` 不通），
  本机实际 IP 是 `192.168.0.26`（`ipconfig getifaddr en0`）。导致 lan.sh 打印的入口与状态页
  按钮全指向不可达地址。**解决**：改 `.env` `LAN_HOST_IP=192.168.0.26`，删 `status/config.yaml`
  重新 init 生成按钮。⚠️ LAN IP 多为 DHCP，换 IP 需同步改 `.env` 与节点地址。
- **P2｜实例页报「浏览器无法连接到地址：ws://mcsmanager-daemon:24444」+ 网页直连异常**：
  节点地址是 Docker 内网主机名，浏览器解析不了（ADR-011 lan 遗留）。lan 无边缘层但 daemon
  端口**本就发布到宿主**，故节点地址改 `ws://<LAN_HOST_IP>:<LAN_MCS_DAEMON_PORT>`——面板容器
  经宿主网络、浏览器/局域网设备经 LAN IP，同一地址双向可达（ADR-014）。改后实例页不再报错、
  「网页直连」正常、终端可用。
- **P3｜状态页残留测试服端点**：同 local P3，删文件重新 init。

## 5. 通用问题与运维教训（后续参考）

1. **切档必先 stop**：同机三档互斥，`./local.sh stop` / `./lan.sh stop` / `deploy.sh stop`
   后再 `start` 另一档；网络被 MCSM 受管实例占用属正常（`Resource is still in use`）。
2. **节点地址 = 面板与浏览器同一地址**，三档各不同：prod=隧道 URL、local=Caddy 域名
   （web 容器 `extra_hosts` 指到 host-gateway）、lan=宿主 LAN IP 发布端口。
3. **local 浏览器需信任 Caddy 本地根证书**（一次性），且必须**完全退出重启**浏览器，
   否则「网页直连」异常。
4. **LAN IP 是 DHCP**：换 IP 需同步 `.env` 的 `LAN_HOST_IP` + 重新 init 状态页 + 改 lan 节点地址。
5. **status config 用 `ensure_*` 绝不覆盖**：模板变更（如删端点）后须删除落盘
   `$DATA_ROOT/status/config.yaml` 再 `start`，并 `docker restart orzmc-status` 加载。
6. **macOS 的 `cp`/`rm` 被交互 alias 拦截**（`-i`）：脚本内文件读写用
   `python3 -c "import shutil; shutil.copyfile(...)"` / `os.remove(...)`。
7. **`RemoteServiceConfig/` 目录禁止放非节点配置文件**（storage `list()` 全量扫描）。
8. **Gatus API `results[0]` 是保留窗口最旧、`results[-1]` 最新**；判断当前状态以 `results[-1]`
   或日志 `[watchdog.executeEndpoint] success=true` 为准。
9. **密钥获取路径**：daemon key 在 `<DATA_ROOT>/mcsmanager/daemon/data/Config/global.json`
   `key` 字段（47 位）；面板添加节点时填该值（`apiKey` 自动写入节点配置）。
10. **还原生产**：`deploy.sh -d /Users/Shared/orzmc up`；若受管实例被重建，
   经面板/daemon API `instance/open`，等日志 `Done` + 插件 WS 认证成功。

## 6. 验收速查表（后续直接照做）

```bash
# prod
deploy.sh -d /Users/Shared/orzmc up          # 或已用 ORZMC_DATA_ROOT
deploy.sh -d /Users/Shared/orzmc status
curl -sk https://orzmcs.jokerhub.cn/api/v1/endpoints/statuses

# local（停 prod 后）
./local.sh start
curl -k https://mcs.localhost:18443           # -k：本地 CA
# 浏览器信任 .local-data/caddy/data/caddy/pki/authorities/local/root.crt 后完全重启

# lan（停 local 后）
./lan.sh start
curl http://<LAN_HOST_IP>:18090              # 真实 IP，非 .env 里过期值

# 面板加节点（key 从对应 DATA_ROOT 的 global.json 取）
# prod: ip=wss://mcs-node.<domain> / 443
# local: ip=wss://mcs-node.localhost / 18443
# lan:   ip=ws://<LAN_HOST_IP> / 24444（Windows 例外：ip=ws://mcsmanager-daemon / 24444，见 §7）
```

---

## 7. Windows 三档验收实录（2026-08-18）

> 平台：Windows 11 Home + Docker Desktop WSL2（`networkingMode=mirrored`，`wsl --shutdown`
> 冷重启生效）。本次实测结论与 §1-§6 的 macOS 实录的**差异全部由 mirrored 网络模型引入**，
> 详见 `docs/windows-deployment.md` §9/§10 与 `docs/architecture.md` ADR-020。

### 7.1 关键差异速览（相对 macOS）

| 维度 | macOS | Windows |
|---|---|---|
| 发布端口绑定 | 宿主真实网卡（可直接 LAN 可达） | mirrored 后才绑真实网卡；未冷重启前仍绑 localhost |
| 宿主访问自身 LAN IP | 可达 | **必超时**（mirrored host-loopback 陷阱，非故障） |
| 容器→宿主 LAN IP（hairpin） | 正常 | **内核级超时**（conntrack/NAT 层损坏） |
| lan 档节点地址 | `ws://<LAN_HOST_IP>:24444` | `ws://mcsmanager-daemon:24444`（内网名） |
| lan 档浏览器「网页直连」 | 可用 | **不可用**（ADR-020，已知限制） |
| Caddy CA 信任 | `security add-trusted-cert` | `certutil -user -addstore -f Root`（免管理员） |

### 7.2 验收实测结论

- **prod（E:/orzmc，EDGE=cloudflare）**：容器全 Up、cloudflared 隧道注册、4 个公网入口
  HTTP 200、面板节点在线 + 密钥验证通过、浏览器终端可用——**全部通过**。验收后按用户
  要求停用（不恢复）。
- **local（.local-data）**：Caddy `.localhost` 4 入口 `curl -k` 200；`certutil -user`
  导入 Caddy 本地根证书 + 完全重启浏览器后「网页直连」可用（机器级 `-addstore` 报
  AccessDenied，需 `-user`）。**全部通过**。
- **lan（.local-data-lan）**：5 容器 Up；`LAN_HOST_IP` 手改真实 `192.168.0.33`；局域网
  设备访问 18090/18091/18092/24444 可达（宿主自访 LAN IP 超时为预期）；节点 `ws://
  mcsmanager-daemon:24444` 在线、面板管理（实例启停/状态/文件）正常；**浏览器实时终端
  不可用**（ADR-020）。本次未创建实例（lan 档实例目录为空），实例创建步骤见
  `docs/windows-deployment.md` §9.4（按 papermc-template + Mac 经验整理，未在 Windows
  实机跑通）。

### 7.3 Windows 特有坑（完整清单见 windows-deployment.md §10 P1-P8）

1. **P1 mirrored 冷重启**：`.wslconfig` 改完必须 `wsl --shutdown`，Docker Desktop 重启
   不算——曾误判「仍 NAT、需迁移引擎」。
2. **P2 防火墙 Public profile**：Wi-Fi + Mihomo TUN 在 Public profile 入站全拦，局域网
   设备连面板 `curl 000`；加 netsh 规则后恢复。
3. **P3 win_daemon_run 相对路径 bug**：`.local-data` 相对路径传给 `--mount` 报 invalid
   mount path（已修复，绝对化后再 win_path）。
4. **P4 DAEMON_PORTS 模板缺失**：local/lan 模板曾漏（已补，提交 5c13047）。
5. **P6 核心限制**：mirrored 下「面板可达地址（bridge 内网）与浏览器可达地址（LAN IP）
   不相交」→ lan Windows 档浏览器直连不可用；唯一全功能解是 hostname 双解析（依赖路由
   器自定义 DNS，当前不具备）。
6. **P7 Caddy CA**：`certutil -user`（免管理员）；信任后须完全退出重启浏览器。
7. **P8 排查顺序**：先分服务端侧（面板日志已连接/密钥验证）vs 浏览器侧（局域网设备
   socket.io 握手），两侧共用同一节点地址。
