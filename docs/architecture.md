# OrzMC Deploy 架构文档

> 本文档是**长期演进**的架构设计文档，记录设计目标、拓扑、数据流、决策记录与演进路径。
> 每次架构改动（服务增减、入口变更、卷/网络调整、安全边界变化）都必须在本页新增 ADR
> 记录，并同步 `AGENTS.md` / `README.md` / 相关 `docs/*.md`。
> 智能体快速守则见 `AGENTS.md`；用户入口见 `README.md`。

## 1. 设计目标

- **运行时与数据分离**：仓库只承载运行时，全部配置与数据落宿主机统一目录 `$DATA_ROOT`，
  使运行时与数据可独立演进、独立备份/还原/迁移，密钥不进入仓库。
- **NAT 内网免开端口**：生产主机位于 NAT 内网、公网 80/443 不可达，采用 Cloudflare Tunnel
  （出站连接）获得公网真实 HTTPS，无需开放任何端口、无需 ACME、无需自签。
- **单一控制面**：MCSManager 作为 PaperMC 实例唯一控制入口；本仓库 compose 只管平台层。
- **可验证、可回滚**：镜像 digest 锁定 + git commit；`deploy.sh validate` 做配置门禁。

## 2. 拓扑

### 2.1 生产（prod profile：Cloudflare Tunnel）

```text
公网（真 HTTPS，Cloudflare 边缘终止 TLS）
  [管理浏览器] ─https─> mcs.example.com          ┐
  [管理浏览器] ─https─> easybot.example.com      ┼─ Cloudflare 边缘 <─出站隧道─ cloudflared(容器, orzmc_default)
  [管理浏览器] ─https─> mcs-node.example.com     ┤
  [管理浏览器] ─https─> orzmcs.example.com       ┘
                                                             │           ├─ http://mcsmanager-web:23333      (MCS 面板)
                                                             │           ├─ http://easybot:8080              (EasyBot 后台)
                                                             │           ├─ http://mcsmanager-daemon:24444   (daemon/节点，密钥鉴权)
                                                             │           └─ http://status:8080              (Gatus 统一状态页)
内网
  [玩家] ── Mac 局域网 IP:25565 ──> PaperMC Prod（MCSManager 管理）
  [插件]  PaperMC 实例(挂 orzmc_default) ──http──> http://easybot:8080   (REST+WS，内网直连，不走公网)
  [插件]  PaperMC 实例(挂 orzmc_default) ──jdbc──> mariadb:3306         (应用数据库，默认启用，内网直连)
  [QQ bot] EasyBot 出站连 QQ 服务器（NAT 下正常）
```

- 公网暴露 **4 个入口**：`mcs.<domain>`（MCSManager 面板）、`easybot.<domain>`
  （EasyBot 管理后台）、`mcs-node.<domain>`（daemon/节点，浏览器直连入口，密钥鉴权）、
  `orzmcs.<domain>`（统一状态页，Gatus，聚合产品入口 + 实时健康；页面无鉴权，仅服务名与
  状态、不含密钥）。
- **EasyBot 插件 API 仅内网**：插件挂 `orzmc_default` 网络，直连 `http://easybot:8080`
  （REST + WebSocket 同端口，内网无 TLS）。
- **应用数据库 MariaDB 默认启用**：插件挂 `orzmc_default` 网络，直连 `mariadb:3306`
  （仅 `expose`，不发布宿主机端口、无公网/边缘入口），供需要 MySQL/MariaDB 的插件使用。
- **daemon 连接（macOS/Linux 三档浏览器直连均可用，ADR-013 + ADR-014 + ADR-020）**：
  节点地址统一「面板服务端与浏览器同一地址」，按档不同：prod `wss://mcs-node.<domain>:443`
  （cloudflared 隧道，隧道 socket.io 已实测可用——ADR-011 的 koa 拦截结论已过时，见
  ADR-013）；local `wss://mcs-node.localhost:18443`（Caddy，web 容器 `extra_hosts:
  mcs-node.localhost:host-gateway` 使容器把 `.localhost` 解析到宿主，ADR-014）；lan
  `ws://<LAN_HOST_IP>:<LAN_MCS_DAEMON_PORT>`（daemon 端口本就发布到宿主，浏览器/局域网
  设备经 LAN IP 可达，解除 ADR-011 lan 遗留，ADR-014）。macOS/Linux 三档浏览器终端/
  控制台/文件管理器均可用；**Windows 例外（ADR-020）**：lan 档节点改填内网名
  `ws://mcsmanager-daemon:24444`（面板侧在线、管理可用，浏览器「网页直连」不可用）。
  prod 代价是面板↔daemon 依赖隧道在线。daemon 全部业务路由密钥鉴权，无 key 无权限。
- 所有服务端口只 `expose`，不发布宿主机端口（PaperMC 实例端口 `25565` 由 MCSManager
  按实例配置映射，供玩家局域网直连）。

### 2.2 本地验证（local profile：Caddy）

```text
[管理浏览器] ─https─> mcs.localhost:18443 ─┐
[管理浏览器] ─https─> easybot.localhost:18443 ── Caddy(.localhost + 本地 CA)
                                            └──> 同 prod 的内部服务（expose，不发布端口）
```

- 与生产共用同一份 `compose.yaml`，通过 `profiles` 切换边缘层：`reverse-proxy`(caddy)
  挂 `profiles: ["local"]`，`cloudflared` 挂 `profiles: ["prod"]`。

### 2.3 局域网直连（lan profile：无边缘层）

```text
[局域网设备] ─http─> http://192.168.0.26:18090  ─┐
[局域网设备] ─http─> http://192.168.0.26:18091  ── 4 个源站直接发布宿主端口（纯 HTTP）
[局域网设备] ─http─> http://192.168.0.26:18092  ─┤
[局域网设备] ─http─> http://192.168.0.26:24444  ─┘（daemon API，key 鉴权）
                                                      └──> 同 prod 的内部服务
```

- **无边缘层**：`--profile lan` 下 `reverse-proxy`(caddy) 与 `cloudflared` 均不匹配
  `profiles` 不运行；`compose_cmd` 追加 `-f compose.lan.yaml` override，给
  `mcsmanager-web` / `easybot` / `status` / `mcsmanager-daemon` 各加 `ports:`
  （多值字段与 base 的 `expose` 拼接）发布宿主 `LAN_*_PORT` 端口（默认
  `18090` / `18091` / `18092` / `24444`，避开 local Caddy 的 18080/18443 与实例端口
  25565/25566）。局域网设备用 `http://<LAN_HOST_IP>:<port>` 访问。
- **纯 HTTP、无域名/TLS**：`LAN_HOST_IP`（宿主局域网 IP）+ `LAN_*_PORT` 取代
  `DOMAIN_*`，无 `CLOUDFLARE_TUNNEL_ID` / `CADDY_EMAIL`；TLS 终止不做（可信内网假设）。
- **daemon 节点地址 = LAN IP（ADR-014）**：节点配置 `ws://<LAN_HOST_IP>:<LAN_MCS_DAEMON_PORT>`
  ——面板容器经宿主网络、浏览器/局域网设备经 LAN IP，同一地址双向可达，浏览器「网页直连」
  终端**可用**（解除 ADR-011 lan 遗留）。⚠️ LAN IP 多为 DHCP，换 IP 需同步改 `.env` 与
  节点配置。
- **Gatus 健康检查走内网 URL**：lan 下 `ensure_status_config` 把端点 `url` 设为
  `http://mcsmanager-web:23333` / `http://easybot:8080`（hide-url），按钮仍用
  `LAN_HOST_IP`——gatus 容器经宿主真实 LAN IP 访问发布端口会超时（macOS Docker Desktop
  实测容器不可达宿主 LAN IP；见 ADR-012），内网探测只验证进程存活。

### 2.4 域名命名约定

| 子域名 | 用途 | 模板变量 |
|---|---|---|
| `mcs.<domain>` | MCSManager 面板 | `DOMAIN_MCS_WEB` |
| `easybot.<domain>` | EasyBot 管理后台 | `DOMAIN_EASY_ADMIN` |
| `mcs-node.<domain>` | MCSManager daemon/节点（浏览器直连，密钥鉴权；三档均可用，ADR-013/014） | `DOMAIN_MCS_NODE` |
| `orzmcs.<domain>` | 统一状态页（Gatus，聚合入口 + 实时健康，无鉴权仅状态） | `DOMAIN_STATUS` |

约定：**子域名 = 产品代号，无后缀即该产品管理控制台**；daemon 组件在代号后加
`-node` 后缀。`orzmcs` 为平台自身入口（统一状态页）。本地同构镜像：
`mcs.localhost` / `easybot.localhost` / `mcs-node.localhost` / `orzmcs.localhost`。
**lan 无域名**：无边缘层时不存在子域名，4 个入口改用 `http://<LAN_HOST_IP>:<LAN_*_PORT>`
（LAN_HOST_IP = 宿主局域网 IP，见 §2.3）。

## 3. 网络与数据流

1. 管理浏览器 → Cloudflare 边缘（TLS）→ cloudflared（出站隧道，compose 网络内按
   hostname 路由）→ `mcsmanager-web:23333`（面板）/ `easybot:8080`（后台）。
2. 面板服务端 → 节点地址（macOS/Linux 与浏览器同一地址，ADR-013 + ADR-014 + ADR-020）：
   prod `wss://mcs-node.<domain>:443`（cloudflared 隧道，浏览器直连终端可用，隧道 socket.io
   已实测通过——ADR-011 的 koa 拦截结论已过时）；local `wss://mcs-node.localhost:18443`
   （Caddy，浏览器直连可用）；lan `ws://<LAN_HOST_IP>:<LAN_MCS_DAEMON_PORT>`（宿主发布
   端口，浏览器/局域网设备直连可用）。macOS/Linux 三档浏览器终端/控制台/文件管理器均可用；
   **Windows 例外（ADR-020）**：lan 档节点改内网名 `ws://mcsmanager-daemon:24444`——面板
   侧在线、管理可用，浏览器「网页直连」/实时终端不可用。
3. 管理浏览器 → `orzmcs.<domain>` → Cloudflare 边缘 → `status:8080`（Gatus 统一状态页，
   聚合产品入口 + 实时健康；页面无鉴权，仅服务名与状态、不含密钥）。
4. PaperMC 插件 → `http://easybot:8080`（REST + WS，同 `orzmc_default` 网络）。
5. PaperMC 插件 → `mariadb:3306`（MySQL/MariaDB 插件数据持久化，同 `orzmc_default` 网络，
   默认启用；备份含逻辑 dump）。
6. MCSManager Daemon → 宿主机 Docker（挂载 `/var/run/docker.sock`），管理 PaperMC 实例。
7. EasyBot → 出站连接 QQ / Telegram / Discord / 飞书 / 微信服务器（NAT 下正常）。

## 4. 服务职责

| 服务 | 镜像 | 职责 | 网络/卷 |
|---|---|---|---|
| `reverse-proxy` (caddy) | digest 锁定 | local profile 反代 + TLS | `$DATA_ROOT/caddy/*` |
| `cloudflared` | digest 锁定 | prod 出站隧道，hostname→service 路由 | `$DATA_ROOT/cloudflared`（ro） |
| `mcsmanager-web` | digest 锁定 | MCSManager 面板 | `$DATA_ROOT/mcsmanager/web/{data,logs}` |
| `mcsmanager-daemon` | digest 锁定 | 实例生命周期 + Docker 管理 | `$DATA_ROOT/mcsmanager/daemon/{data,logs}` + `/var/run/docker.sock` |
| `easybot` | digest 锁定 | 统一 IM 网关（HTTP 监听，uid/gid=10001） | `$DATA_ROOT/easybot/data` |
| `mariadb` | digest 锁定 | 应用数据库（MariaDB 11.4，uid/gid=999），插件数据持久化 | `$DATA_ROOT/database/mariadb`（仅内网 expose 3306） |
| `status` | digest 锁定 | 统一首页/状态页（Gatus，scratch 镜像无 shell），聚合入口 + 实时健康 | `$DATA_ROOT/status/config.yaml`（ro，init 生成不覆盖） |

## 5. `$DATA_ROOT` 目录树

```text
$DATA_ROOT/
  .env                    # 全部环境变量 + 密钥（权限 600，不入 Git）
  caddy/                  # 仅 local profile 使用
    Caddyfile  data/  config/
  cloudflared/            # 仅 prod profile 使用；含密钥（cert.pem / <id>.json）
    config.yml  cert.pem  <tunnel-id>.json
  mcsmanager/
    web/{data,logs}
    daemon/
      {data,logs}         # Config/global.json 含 daemon key（权限 600，最高权限密钥）
    daemon/data/InstanceData/<uuid>/   # MCSManager 面板创建的实例数据（cwd，含 world/plugins/...）
  easybot/data/           # EasyBot 网关数据（uid/gid=10001）
  status/config.yaml      # Gatus 统一状态页配置（init 生成、绝不覆盖；ro 挂载）
  database/               # 应用数据库 MariaDB
    mariadb/              # InnoDB 数据目录（uid/gid=999）
    dumps/                # backup.sh 自动逻辑备份（含 mysql 系统库，按密钥 chmod 600）
```

## 6. ADR 决策记录

### ADR-001：EasyBot 统一 IM 网关（2026-08-13）

- **状态**：已实施。
- **背景**：需要一个统一 IM 网关承载 QQ / Telegram / Discord / 飞书 / 微信多平台消息。
- **决策**：采用 EasyBot 作为统一 IM 网关；QQ 适配器使用 QQ 开放平台官方 bot 凭据
  （AppID + ClientSecret）。
- **影响**：`docs/easybot.md` 记录了接入模型；监听器仅 HTTP，TLS 由边缘层承担。

### ADR-002：运行时与数据分离（2026-08-13）

- **状态**：已实施。
- **背景**：Phase 1 重构目标——运行时与数据解耦，独立演进与备份/迁移。
- **决策**：仓库只承载运行时；全部配置/数据通过卷映射落 `$DATA_ROOT`；脚本统一
  `compose_cmd --env-file $DATA_ROOT/.env`。
- **影响**：`README.md` 架构原则、`AGENTS.md` 铁律第 1-2 条。

### ADR-003：Caddy → Cloudflare Tunnel（2026-08-13，Phase 2）

- **状态**：已实施。
- **背景**：生产主机在 NAT 内网，公网 80/443 不可达，域名未解析到本机，Caddy ACME
  公网签发不可行。
- **决策**：compose 移除 Caddy，改用 cloudflared 出站隧道；Cloudflare 边缘终止真实
  HTTPS 并按 hostname 路由；本地验证保留 Caddy（`profiles: ["local"]`），生产用
  cloudflared（`profiles: ["prod"]`）。
- **影响**：无宿主机端口开放、无 ACME、无自签；`CLOUDFLARE_TUNNEL_ID` 入 `.env`。

### ADR-004：EasyBot 插件 API 仅内网（2026-08-13）

- **状态**：已实施。入口数量部分被 **ADR-005** 修正（公网入口 2→3，新增
  `mcs-node`）；"不设 `easybot-api` 子域名" 部分仍有效。
- **背景**：插件与 EasyBot 同属 `orzmc_default` 网络，无公网暴露需求；且内网直连
  不经 Cloudflare 边缘（规避免费版 ~100s HTTP/WS 空闲超时限制）。
- **决策**：公网只暴露 `mcs.<domain>` / `easybot.<domain>` 两个控制台入口；插件
  `easybot.yml` 直连 `http://easybot:8080`（REST + WS）。不设 `easybot-api` 子域名。
- **影响**：`templates/cloudflared-config.yml` ingress 仅两条 + 兜底 404；`DOMAIN_EASY_API`
  从环境变量中移除。

### ADR-005：daemon 经边缘层入口暴露（mcs-node，密钥鉴权）（2026-08-13，Phase 2）

- **状态**：已实施；**面板↔daemon 传输层由 ADR-011 修正，又由 ADR-013（2026-08-15）回改**——
  面板服务端连接 daemon 现经隧道 URL `wss://mcs-node.<domain>:443`，`mcs-node.<domain>`
  入口在 prod 下浏览器直连终端/文件管理**可用**（ADR-013 实测推翻 ADR-011 的 koa 拦截
  结论）。
- **背景**：MCSManager 连接模型要求面板浏览器**直连** daemon（终端/控制台/文件管理器
  经 WebSocket，面板服务端不代理 daemon）。内网地址 `mcsmanager-daemon:24444` 在浏览器
  侧不可解析，面板报"无法连接到远程节点"。
- **决策**：新增第 3 个入口 `mcs-node.<domain>`（prod=Cloudflare ingress / local=Caddy
  反代）转发到 `mcsmanager-daemon:24444`。daemon 全部业务路由要求密钥鉴权
  （`checkLogin` 校验 key + session），无 key 即拒绝，公网暴露不扩大权限面。
- **影响**：环境变量新增 `DOMAIN_MCS_NODE`；`cloudflared-config.yml` / `Caddyfile`
  ingress 各加一条；MCSManager 节点配置 `ip=wss://mcs-node.<domain>:443`（ADR-011 后改
  内网直连）。命名沿用约定（产品代号 `mcs` + 组件 `-node`），避免泛化子域名占用。

### ADR-006：macOS Docker Desktop 写盘走宿主用户（uid 例外）（2026-08-13，Phase 2）

- **状态**：已实施（生产 macOS）。
- **背景**：容器内以 `runAs 1000:1000` 创建进程、容器内 uid 检查通过，但 Docker Desktop
  的 gRPC-FUSE 文件共享由 macOS 侧宿主用户进程执行实际磁盘写入；宿主目录属主非该
  用户时 `chmod 777` 仍失败（Operation not permitted）。
- **决策**：生产 macOS 上实例目录属主改为**宿主用户**（`sudo chown -R joker:staff
  <instance-dir>`），让所有容器用户（root/1000/501）都可写；Linux 生产保持
  `1000:1000` 约定不受影响。
- **影响**：`docs/papermc-template.md` 注明平台差异；实例 `runAs` 仍填 `1000:1000`
  （容器内 uid），宿主属主按平台处理。

### ADR-007：daemon 容器自挂载实例目录（文件管理器可见）（2026-08-13，Phase 2）

- **状态**：已实施，**已被 ADR-019 取代**（2026-08-16 移除 `instances/` 自挂载，见下）。
- **背景**：MCSManager 文件管理器读 `instance.absoluteCwdPath()`（实例 `cwd` 直接是宿主
  路径）时，daemon 容器内解析不到宿主文件，`fs.existsSync` 为假会 `mkdirpSync` 自动建
  **空**目录，表现为"文件管理为空"。
- **决策**：daemon 服务把 `${DATA_ROOT}/instances` 以**同路径**自挂载进容器
  （`"${DATA_ROOT}/instances:${DATA_ROOT}/instances"`），daemon 容器内即看到真实文件；
  docker bind Source 仍由宿主解析，两者不冲突。`MCSM_DOCKER_WORKSPACE_PATH` 置为
  `${DATA_ROOT}/instances` 兜底默认布局。
- **影响**：compose daemon 卷增加一条自挂载；新增实例目录后无需改动。
- **ADR-019 取代（2026-08-16）**：改为不设 `instances/` 目录，实例数据统一由 MCSManager
  面板写入默认的 `data/InstanceData/<uuid>/`（已通过 `daemon/data` bind 落到宿主
  `$DATA_ROOT/mcsmanager/daemon/data/InstanceData/`，随整包备份），不再需要独立的
  `instances/` 自挂载与 `MCSM_DOCKER_WORKSPACE_PATH`。见 `docs/architecture.md` §7 ADR-019。

### ADR-008：平台层常驻 MariaDB 数据库服务（2026-08-14）

- **状态**：已实施。
- **背景**：PaperMC 常见插件（Dynmap / CoreProtect / LuckPerms / Towny / 经济插件等）
  会把状态持久化到 MySQL/MariaDB；原栈中唯一数据库是 EasyBot 自带的 SQLite
  （`gateway.db`），插件侧无任何 DB 连接配置。
- **决策**：新增 `mariadb` 服务，**默认随平台层启用**（无 profile 门控、无开关，与
  `mcsmanager-*`/`easybot` 一致三 profile 运行，含 ADR-012 后的 lan）。数据落 `$DATA_ROOT/database/mariadb`；
  端口 3306 仅 `expose`，不发布宿主机、不设公网/边缘入口，插件挂 `orzmc_default` 内网
  直连 `mariadb:3306`。`MARIADB_ROOT_PASSWORD / MARIADB_DATABASE / MARIADB_USER /
  MARIADB_PASSWORD` 为必需变量（`REQUIRED_ENV_VARS_PROD/LOCAL` + `templates/env.*`）。
  `backup.sh` 在 `--stop` 之前自动执行 `mariadb-dump --all-databases` 逻辑快照（落
  `$DATA_ROOT/database/dumps/`，随整机 tar 归档，`chmod 600`），还原以冷数据目录为权威、
  dump 为兜底。
- **影响**：4 个新必需变量（存量 `.env` 需手动补，`ensure_env_file` 不覆盖）；`ensure_data_dirs`
  新增 `database/mariadb` 并 chown `999:999`；`backup.sh` 新增逻辑 dump 与 `--keep` 剪枝；
  `restore.sh` 校验数据目录存在；`update-image-digests.sh` 注册 `mariadb:11.4`（LTS）；
  `docs/usage.md` 附录 F 硬件选型修订（平台层固定成本 ~250 MB → ~0.5–0.6 GB）。

### ADR-009：统一首页/状态页（Gatus，第 4 入口）（2026-08-14）

- **状态**：已实施。
- **背景**：此前 3 个入口（`mcs` / `easybot` / `mcs-node`）各自为政，无统一聚合入口，
  平台层与游戏实例健康不可见。需求：主页面聚合各产品服务入口 + 实时健康状态，风格简洁
  专业、响应式多端。
- **决策**：
  - 采用 **Gatus**（`twinproduction/gatus`，digest 锁定）作为统一状态页，新增无 profile
    常驻 `status` 服务（三 profile 都运行），暴露第 4 入口 `orzmcs.<domain>`（最初定为
    `status.<domain>`，后按 ADR-010 改名）。
  - 配置 `${DATA_ROOT}/status/config.yaml` 由 `init` 的 `ensure_status_config` 按 profile
    替换占位符生成，**绝不覆盖已有文件**（用户可自行扩展 endpoints/buttons）。
  - 页头 `ui.buttons` 以真实链接聚合三个产品入口；健康检查走各产品**真实公网/本地入口**
    （可达性）；daemon / MariaDB / 状态页自检走内网 TCP；local profile 经
    `extra_hosts: host-gateway` 解析 `.localhost` 并 `client.insecure: true` 跳过本地 CA
    校验。
  - 存储用默认**内存**（实时健康，无历史持久化）；页面**无鉴权**——仅服务名与状态、
    不含密钥（`ui.buttons` 指向的产品入口本身有登录鉴权）。如需登录/历史可后续加
    `security` 块与 sqlite（future 选项）。
- **影响**：
  - 新增必需变量 `DOMAIN_STATUS` / `STATUS_PORT`（`REQUIRED_ENV_VARS_PROD/LOCAL` +
    `templates/env.*`，存量 `.env` 需手动补）。
  - 第 4 入口贯穿全链路：`compose.yaml`（reverse-proxy env + `status` 服务）/
    `Caddyfile` / `cloudflared-config.yml` ingress / `update-image-digests.sh`。
  - 游戏实例卡片经 `host.docker.internal` 探测宿主映射端口（25565/25566），无实例时如实
    DOWN。
  - **修复历史遗留 bug**：Caddyfile 引用 `{$DOMAIN_MCS_NODE}` 但 `reverse-proxy`
    `environment` 自 Phase 2 起缺该变量，导致 local profile 下 Caddy 崩溃循环
    （"server block without any key"）；已补 `DOMAIN_MCS_NODE` 入环境块。
  - 文档同步：`AGENTS.md` / `README.md` / `docs/architecture.md` / `docs/usage.md` /
    `EXECUTION_PATH.md`。

### ADR-010：统一状态页域名改为 orzmcs（2026-08-14）

- **状态**：已实施。
- **背景**：`status.<domain>` 是泛化功能名（`status`/`health`/`uptime`/`monitor`/
  `dashboard` 属通用基建名），违反 §2.4「子域名 = 产品代号，避免泛化子域名占用」约定。
  且 `jokerhub.cn` 为多产品共用域名：`www` → GitHub Pages 个人站、根域 TXT 挂飞书站点验证、
  `*.jokerhub.cn` 通配符全量代理到 Cloudflare——未来任一产品要加状态/健康页，`status`
  均易撞车。
- **决策**：统一状态页公网域名从 `status.<domain>` 改为 **`orzmcs.<domain>`**（平台自身
  入口，产品代号，无后缀=该产品入口，与 `mcs`/`easybot` 同构）。本地同构镜像改为
  `orzmcs.localhost`。**仅改域名值**：变量名 `DOMAIN_STATUS`、`STATUS_PORT`，compose 服务名
  `status`、容器 `orzmcs-status` 不变。
- **影响**：
  - 仓库：`templates/env.prod` / `env.local` 默认值与注释、`README.md` / `AGENTS.md` /
    `docs/architecture.md` / `docs/usage.md` / `EXECUTION_PATH.md` 各域名表与入口描述。
  - 运行时：生产 `.env` 与本地 `.env` 的 `DOMAIN_STATUS` 值；已生成 `cloudflared/config.yml`
    ingress、`status/config.yaml`（删后 `init` 重新生成，遵循"绝不覆盖"）。
  - DNS：新增 `orzmcs.<domain>` CNAME，清理旧 `status.<domain>` 记录（通配符下旧名虽可解析
    但不再路由到隧道，必须显式删）。

### ADR-011：面板↔daemon 改 Docker 内网直连（隧道 socket.io 被 daemon koa 拦截）（2026-08-14）

- **状态**：已实施；**已被 ADR-013（2026-08-15）部分推翻**——prod 节点地址回改隧道 URL
  `wss://mcs-node.<domain>:443`，浏览器直连可用；**ADR-014（2026-08-15）解除剩余限制**——
  local 用 Caddy + web `extra_hosts`、lan 用 LAN IP 发布端口，三档浏览器直连均可用。
  本 ADR 的 koa 拦截结论在当栈已过时，保留为历史决策记录。
- **背景**：面板「节点管理」中 `orzmc-daemon` 离线/异常，状态页同步显示测试服不健康。
  面板经隧道 URL `wss://mcs-node.<domain>:443/socket.io` 连接 daemon。排查排除了三层：
  ① 宿主 fake-ip 代理（Clash/Surge 类）把域名解析成 198.18.0.0/15 假地址（`dns:` 覆写
  缓解，非根因）；② Node ≥17 verbatim 解析（AAAA 优先）+ 容器无 IPv6 路由 → ENETUNREACH
  （`NODE_OPTIONS=--dns-result-order=ipv4first` 缓解，仍非根因）；③ **真正根因**——daemon
  的 socket.io（挂同一 httpServer）事件分发在 **cloudflared 转发路径下会被自身 koa 确定性
  拦截**：koa 是 'request' 监听 #1、socket.io 是监听 #2，直连时 socket.io 先赢，经
  cloudflared 转发时 koa 恒赢 → 轮询 404 / WebSocket EOF。全 Cloudflare 头、keep-alive 复用
  均无法复现，属 cloudflared 转发路径 + daemon 事件分发层的固有问题；**daemon 镜像不可改**。
- **决策**：
  - 面板节点配置 `ip` 由 `wss://mcs-node.<domain>` + `port 443` 改为 **`ws://mcsmanager-daemon`
    + `port 24444`**（Docker 网络内直连，即 MCSManager 官方默认部署模型；apiKey 不变）。
  - 改节点配置属**运行时数据**（`$DATA_ROOT/mcsmanager/web/data/RemoteServiceConfig/*.json`，
    不入库）；改后需 `docker restart orzmc-mcsmanager-web`（仅改 JSON 不重建容器）。
  - 移除 investiga 期在 compose.yaml `mcsmanager-web` 加的 `dns:` / `NODE_OPTIONS`
    （连接已内网化，注释过时）；cloudflared 的 `dns:` 隧道加固仍保留——解析器参数化为
    可选变量 `DNS_PRIMARY` / `DNS_SECONDARY`（缺省 `223.5.5.5` + `1.1.1.1`，仅 prod；
    仅因宿主 fake-ip 代理劫持 DNS 才需要，无代理宿主可删）。
- **影响**：
  - 面板↔daemon 连接不再依赖公网域名，天然避开 fake-ip 与 IPv6 路径；节点上线稳定
    （验证：面板「远程节点 orzmc-daemon 已连接 / 密钥验证通过」，daemon「会话验证身份成功」）。
  - **浏览器直连 daemon**（终端/控制台/文件管理器，前端按节点 ip/port 拼 socket.io）在
    prod 下本就走隧道 `mcs-node.<domain>`、同样被 koa 拦截而**本就不可用**；改内网后浏览器
    解析不到 `mcsmanager-daemon` → **无功能回退**。`mcs-node.<domain>` 入口保留（设计供
    浏览器直连），当前为已知限制。本地 Caddy 不受此 koa 拦截影响，`mcs-node.localhost` 可用。
    面板节点详情页「网页直连」状态因此显示**异常**——预期现象，非故障；面板服务端的实例
    管理（启动/停止/配置/状态）经内网连接不受影响。
  - 后续新增远程节点一律在面板填**内网地址** `ws://mcsmanager-daemon:24444`（勿填隧道 URL；
    usage.md §6.2 已如此指引）。
  - 文档同步：`AGENTS.md` §4、`docs/usage.md` §1.2/§6.2、`EXECUTION_PATH.md`。

### ADR-012：lan 直连模式（无 TLS 终止边缘层，局域网）（2026-08-14）

- **状态**：已实施。
- **背景**：既有双 profile（local/prod）都覆盖不到局域网——`local`（`.localhost` 按 RFC
  只解析回环，局域网其他设备解析到自己的 127.0.0.1）与 `prod`（强制公网域名 + Cloudflare
  Tunnel）均不适用。真实需求是**支持一个不需要做 TLS 终止的可选模式**，局域网部署是
  典型场景。
- **决策**：
  - 新增第三 profile `lan`：**无边缘层**（`--profile lan` 下 reverse-proxy/cloudflared
    均不匹配 `profiles` 不运行），新增 `compose.lan.yaml` override（`compose_cmd` 在
    `COMPOSE_PROFILE=lan` 时追加 `-f` 合并，多值字段 `ports` 与 base 的 `expose` 拼接）
    给 4 个源站发布宿主 `LAN_*_PORT` 端口，纯 HTTP、无域名/TLS。
  - 新增必需变量 `LAN_HOST_IP` + `LAN_MCS_WEB_PORT` / `LAN_EASYBOT_PORT` /
    `LAN_STATUS_PORT` / `LAN_MCS_DAEMON_PORT`（默认 `18090`/`18091`/`18092`/`24444`，
    避开 local Caddy 的 18080/18443 与实例端口 25565/25566）；无 `DOMAIN_*` /
    `CLOUDFLARE_TUNNEL_ID` / `CADDY_EMAIL`。新增 `lan.sh` 入口（固定 `-p lan` +
    `templates/env.lan`，`DATA_ROOT=.local-data-lan`）。
  - **daemon 节点连接地址 = LAN IP（ADR-014 修订）**：初始设计沿用内网直连
    `ws://mcsmanager-daemon:24444`（ADR-011）；2026-08-15 验收后改为
    `ws://<LAN_HOST_IP>:<LAN_MCS_DAEMON_PORT>`——daemon 端口本就发布到宿主，面板容器与
    浏览器经同一地址双向可达，浏览器「网页直连」终端可用（ADR-014）。
  - **Gatus 健康检查走内网 URL**：lan 分支把端点 `url` 改为
    `http://mcsmanager-web:23333` / `http://easybot:8080`（hide-url），按钮仍用
    `LAN_HOST_IP`（面向局域网真机浏览器）。
- **影响**：
  - 容器不可达宿主真实 LAN IP 的实证：macOS Docker Desktop 下 gatus 容器经
    `http://192.168.0.26:<port>`（宿主 LAN IP + 发布端口）探测会超时，只能经
    `host.docker.internal` / 内网服务名可达——故 lan 健康检查端点改用内网 URL（进程存活
    语义），按钮保留 LAN_IP。local 的 `extra_hosts: *.localhost:host-gateway` 是另一种
    机制（Caddy 反代场景 URL 相同、只需解析），lan 因检查 URL 与按钮 URL 本就不同需拆
    占位符（`__*_ENDPOINT__` 与 `__*_BASE__`）。
  - 安全边界：lan 为局域网明文 HTTP（面板/EasyBot 登录口令走局域网）+ daemon 端口对
    局域网开放（daemon key 鉴权，可管理 docker.sock）——**仅限可信局域网**（接入不可信
    Wi-Fi 应改用 prod/local）。
  - 同机互斥：lan 与 local/prod 共用 compose 项目名 `orzmc` 与容器名，一次只跑一个，
    切换需先 stop（写入 `lan.sh` 头注释）。
  - 文档同步：`AGENTS.md`（三 Profile 表/§4 lan 形态/命令速查/安全约束/目录地图）、
    `README.md`、`docs/usage.md`（三路径 + env/profile 表 + 附录）、`docs/easybot.md`、
    `EXECUTION_PATH.md`。

### ADR-013：prod 面板节点地址回改隧道 URL（浏览器直连恢复可用）（2026-08-15）

- **状态**：已实施。
- **背景**：ADR-011（2026-08-14）判定「daemon 的 socket.io 在 cloudflared 转发路径下会被
  自身 koa 确定性拦截」，把 prod 节点地址由隧道 URL 改回 Docker 内网直连
  `ws://mcsmanager-daemon:24444`——面板服务端恢复稳定，但浏览器直连 daemon（终端/控制台/
  文件管理器）因解析不到内网主机名而不可用，被记为「已知限制」。2026-08-15 排查浏览器
  报错（「浏览器无法连接到地址：ws://mcsmanager-daemon:24444」）时对**当前栈**重测隧道
  路径，结论与 ADR-011 相反：
  - `GET /socket.io/?EIO=4&transport=polling` 经 `wss://mcs-node.<domain>` 返回有效
    Engine.IO 握手（sid + upgrades）；polling / websocket 两种传输均可建立；
  - 以面板同款 socket.io-client + `{uuid,data}` 信封发 `auth` 返回 `data:true`
    （daemon 日志同步记「会话(::ffff:172.18.0.4) 验证身份成功」，来源即 cloudflared
    容器）；即面板服务端经隧道连 daemon 的整条协议链路实测可用。
  - **ADR-011 的 koa 拦截结论在当栈已不成立**（可能随 daemon 镜像演进消解，未回溯）。
- **决策**：
  - prod 面板节点配置 `ip` 改回 `wss://mcs-node.<domain>` + `port 443`——面板服务端与
    浏览器**同一地址**，都经 cloudflared 隧道。改运行时数据（
    `$DATA_ROOT/mcsmanager/web/data/RemoteServiceConfig/*.json`，不入库）后
    `docker restart orzmc-mcsmanager-web`。
  - 浏览器终端/控制台/文件管理器恢复可用（前端按节点 ip/port 拼 socket.io 直连 daemon，
    `wss://mcs-node.<domain>:443` 浏览器可达、协议实测通过）。
  - lan/local 当时保持原样，后续由 ADR-014（2026-08-15）各自解决：local 给 web 容器加
    `extra_hosts: mcs-node.localhost:host-gateway` 使 `.localhost` 解析到宿主 Caddy；lan
    节点地址改 `ws://<LAN_HOST_IP>:<LAN_MCS_DAEMON_PORT>`（宿主发布端口）——三档浏览器
    直连终端均可用。
- **影响**：
  - 面板↔daemon 从 Docker 内网改为经 Cloudflare 边缘：延迟略增（面板 API 多一跳）、依赖
    隧道在线；`connectOpts` 自带重连（`reconnection:true`）兜底。
  - `mcs-node.<domain>` 入口从「设计用途/已知限制」转为**实际可用**。
  - 运维教训：`RemoteServiceConfig/` 目录被 storage `list()` 全量扫描（`readdirSync` +
    剥扩展名），**禁止**在该目录放置任何非节点配置文件——本次误置 `.bak` 导致面板启动
    崩溃 `Cannot read properties of null (reading 'ip')`（把 `.bak` 文件名当作第二个节点
    uuid 加载 null）；配置备份一律放 `$DATA_ROOT/backups/`。
  - 文档同步：`AGENTS.md` §4、`docs/architecture.md`（本 ADR + §2.1/§3.2/§2.4）、
    `docs/usage.md`（§1.2/§5/§6.2/§6.3）、`EXECUTION_PATH.md`。

### ADR-014：local/lan 面板节点地址改为浏览器可达地址（三档浏览器直连全部可用）（2026-08-15）

- **状态**：已实施。
- **背景**：ADR-013 解决 prod 浏览器直连（节点地址回改隧道 URL）。local 与 lan 仍有同
  一根因的遗留：面板节点地址用 Docker 内网主机名（`mcsmanager-daemon`），浏览器解析不
  了——local 面板服务端能连、浏览器直连却「异常」；lan 实例页报「浏览器无法连接到地址：
  ws://mcsmanager-daemon:24444」。本质是违反「节点地址 = 面板服务端与浏览器同一地址」
  原则（浏览器按节点 ip/port 拼 socket.io 直连 daemon）。
- **决策**：
  - **local**：节点配置 `ip=wss://mcs-node.localhost` + `port 18443`（Caddy 非特权 TLS
    端口）。面板容器把 `.localhost` 按 RFC 6761 解析成自身回环 `127.0.0.1`、连不到宿主
    Caddy（节点「离线」）——在 `compose.yaml` 的 `mcsmanager-web` 服务加
    `extra_hosts: ["mcs-node.localhost:host-gateway"]`（`host-gateway` 解析到宿主，Docker
    ≥20.10；与 status 服务既有 `*.localhost:host-gateway` 做法一致；prod/lan 下该主机名
    未使用、无副作用）。
  - **lan**：节点配置 `ip=ws://<LAN_HOST_IP>` + `port <LAN_MCS_DAEMON_PORT>`——daemon
    端口经 `compose.lan.yaml` 本就发布到宿主（`24444`），面板容器经宿主网络、浏览器/局
    域网设备经 LAN IP，**同一地址双向可达**；纯 HTTP，无 CA 信任问题。
  - **local 浏览器 CA 信任（一次性）**：导入 Caddy 本地根证书到钥匙串并**完全重启**浏览器
    （否则「网页直连」异常）：
    ```
    security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain \
      $DATA_ROOT/caddy/data/caddy/pki/authorities/local/root.crt
    ```
    验证技巧：Node 进程不读 macOS 钥匙串，本机 Node 严格 TLS 测试须
    `NODE_EXTRA_CA_CERTS=<root.crt>` 才能复刻浏览器行为；用 `curl` 不带 `-k` 验证系统信任。
  - 改节点配置属运行时数据（`$DATA_ROOT/.../RemoteServiceConfig/*.json`，不入库），改后
    `docker restart orzmc-mcsmanager-web`。
- **影响**：
  - 三档浏览器终端/控制台/文件管理器**全部可用**：prod=隧道、local=Caddy、lan=LAN IP；
    ADR-011「lan 无边缘层下浏览器直连不可用」的遗留**解除**。
  - **⚠️ LAN IP 多为 DHCP**：换 IP 需同步改 `.env` 的 `LAN_HOST_IP`、删 `status/config.yaml`
    重新 init（状态页按钮）、并改 lan 节点配置——`LAN_HOST_IP` 过期（曾配 `192.168.1.100`
    死地址、实际 `192.168.0.26`）会让 lan.sh 入口与状态页按钮全指向不可达地址。
  - local 浏览器首次使用前需信任 Caddy 本地 CA；Caddy 数据在 `$DATA_ROOT`，重装后需重新
    信任。lan 无边缘层为明文 HTTP + daemon 端口开放——仅限可信局域网（ADR-012 不变）。
  - 文档同步：`AGENTS.md` §4、`docs/architecture.md`（本 ADR + §2.1/§2.3/§2.4/§3.2 +
    ADR-011/012/013 状态修订）、`docs/usage.md`（§1.2/§5/§6.2/§6.3）、
    `docs/acceptance.md`（三档验收实录）、`EXECUTION_PATH.md`。

### ADR-015：Windows(Docker Desktop/WSL2) 平台支持与适配（2026-08-16，Windows 实测）

- **状态**：已实施（Windows 11 家庭版 + Docker Desktop 4.86 / WSL2 实测通过）。
- **背景**：项目默认按 macOS/Linux 设计（ADR-006/007）。首次移植 Windows 时暴露多处
  与 Docker Desktop/WSL2 的兼容问题，逐一修复后全栈可用。完整部署实录见
  `docs/windows-deployment.md`；此处记录**架构层面的决策**，避免重复踩坑。
- **决策**：
  - **daemon 不受 compose 管理（Windows）**：ADR-007 曾用实例自挂载卷
    `"${DATA_ROOT}/instances:${DATA_ROOT}/instances"`，在 Windows 下 `DATA_ROOT=E:/...`
    含驱动器冒号，Docker Compose 序列化 bind mount 时剥离 `E:` 报 `too many colons`。
    **`docker compose up` 无法创建 daemon**，须用 `docker run --mount type=bind` 手动创建。
    （ADR-019 已移除 instances 自挂载；daemon/data 与 daemon/logs 的 bind 无驱动器冒号问题，
    但 daemon 仍走 docker run，见 ADR-016。）
  - **手动创建容器须补服务名别名**：compose 创建的容器自动有服务名别名；`docker run`
    手动创建的 daemon/status 没有，面板/状态页按 `mcsmanager-daemon`/`status` 解析失败。
    须 `docker network connect --alias <service> orzmc_default <容器>` 补别名。
  - **prod 面板节点地址严格 `wss://<domain>:443`**（ADR-013 基础上明确协议前缀）：填
    `https://` 会拼出非法 `ws://https://...`，填纯域名默认 `ws://` 明文经隧道 400。
    必须带 `wss://` 前缀（面板据此用 wss 并自动拼 `/socket.io` 路径）。三种 profile 对照
    见 ADR-013/014 与 `docs/windows-deployment.md` §6。
  - **cloudflared 管理命令统一 `-e HOME=/home/cloudflared` + 挂载**：默认 HOME=
    `/home/nonroot` 使 cert.pem 写容器层、`--rm` 即丢；设 HOME 指向挂载目录才落盘
    `$DATA_ROOT`。
  - **隧道凭据丢失可从 cert.pem 重建**：凭据 JSON 仅创建时本地生成一次、控制台无下载；
    但可解码 cert.pem（ARGO TUNNEL TOKEN，含 accountID/zoneID/apiToken）→ CF API
    `/accounts/{account}/cfd_tunnel/{id}/token` 取回 TunnelSecret → 重建
    `<id>.json`。详见 `docs/windows-deployment.md` §2.2。
  - **WSL Docker 数据可迁数据盘**：Docker Desktop 的 WSL 数据默认在 C 盘，可迁移 vhdx 到
    数据盘（改 Lxss 注册表 BasePath）避免占满系统盘；生产用 E 盘与 `$DATA_ROOT` 分离。
- **影响**：
  - Windows 下 daemon/status 生命周期不归 compose（`docker compose up/down` 不作用于
    二者），靠 `--restart unless-stopped` 自动恢复，升级/回滚须手动 `docker rm -f` +
    `docker run`。
  - 新增 `docs/windows-deployment.md` 作为 Windows 平台部署与排障权威文档；`README.md`
    文档导航、`AGENTS.md` §4 同步提及 Windows 支持与差异。
  - 平台差异总览、7 个已解决问题（根因/解法）、Windows 维护速查与待上游改进建议均见
    `docs/windows-deployment.md`。

### ADR-016：Windows 平台支持脚本化（三平台统一命令，仅 daemon 走 docker run）（2026-08-16）

- **状态**：已实施（Windows 11 家庭版 + Docker Desktop 4.86 / WSL2 实测通过）。
- **背景**：ADR-015 让 Windows 跑通，但依赖多处**手工**操作：daemon/status 须手动
  `docker run --mount`、手动 `docker network connect --alias` 补服务名别名、手传
  Windows 原生路径（`E:/...`）规避 MSYS `/c/...`。用户命令与 macOS/Linux 不一致，
  不符合"三平台统一、配置最简化"目标。
- **根因精确化**：经实测（compose v5.3.1，Windows/WSL2），Docker Compose 对 bind 卷
  的序列化**只在「target 含驱动器冒号」时报 `too many colons`**；source 含冒号无碍
  （`- "E:/orzmc/instances:/data"` 可创建，`- "E:/orzmc/instances:E:/orzmc/instances"`
  报错，错误为 `source path "/orzmc/instances:E:/orzmc/instances:rw" too many colons`）。
  而 daemon 的实例自挂载（ADR-007）target 必须等于容器内 `absoluteCwdPath()` 解析结果
  `/opt/mcsmanager/daemon/E:/orzmc/instances`——**含 `E:` 是结构性必然**（MCSManager
  实例 `cwd` 同时充当宿主 bind source 与容器内文件路径，Windows 下 cwd=`E:/...` 在
  Linux 容器内非绝对路径、拼到工作目录）。因此 daemon 在 Windows 走 `docker run --mount`
  **不是可绕过的 bug，而是模型使然**。
  > **ADR-019（2026-08-16）修正**：实例自挂载已移除，`too many colons` 诱因消失；daemon
  > 走 `docker run` 改为**仅为保持三平台一致**（不再因驱动器冒号强制），见 ADR-019。
- **决策**（脚本层抽象平台差异，用户命令与 macOS/Linux 完全一致）：
  - **lib/common.sh 新增平台层**：`detect_os`（MINGW/MSYS/CYGWIN→windows）、`win_path`
    （MSYS/原生路径→Windows 原生正斜杠，docker 用）、`daemon_image`（awk 从 compose.yaml
    读 daemon digest，不依赖 python/yq）。
  - **`compose_cmd` Windows 分支**：`up -d` 时用 `--no-deps` + 显式列出该 profile 下
    **除 daemon 外全部服务**，让 compose 完全跳过 daemon（不破坏 depends_on——daemon 仍
    是有效服务，仅不被拉起）；`down` 先 `win_daemon_rm` 再 compose down；裸 `status/ps`
    补一行 daemon 状态。macOS/Linux 走原生 compose 全流程，零行为变化。同时 Windows 下
    `COMPOSE_FILE`/lan override/env-file 均过 `win_path`，根治 MSYS `/c/...` 路径坑。
  - **`win_daemon_run`**：脚本自动生成 ADR-015 §3 的完整 `docker run --mount` 命令（data
    /logs 挂载、docker.sock、`--network orzmc_default`、lan 下补 `-p LAN_MCS_DAEMON_PORT`）；
    幂等（已存在则跳过）；创建后 `win_daemon_alias` 补 `mcsmanager-daemon` 别名。ADR-019
    起不再挂载 `instances/`，实例数据由面板写 `daemon/data/InstanceData/<uuid>`。
    **`DAEMON_PORTS`（.env，逗号分隔）**：进程模式 PaperMC 实例（cwd 在 daemon 内部）
    的进服端口须由 daemon 容器 `-p` 暴露——生产 `DAEMON_PORTS=25565:25565/tcp,19132:19132/udp`
    （2026-08-16 生产迁移实测发现：旧手动 daemon 带 `-p 25565/19132`，脚本重建前会丢端口，
    已加此配置修复）。
  - **status/web/easybot/mariadb/cloudflared/边缘层回归 compose**：ADR-015 当时把它们
    一并手动 docker-run 是不必要的——它们的卷 target 均无冒号（`/opt/...`、`/data/...`、
    `/var/lib/...`、`/config/config.yaml:ro`），Windows 下 compose 可直接创建。现在仅
    daemon 一个容器脱离 compose 管理，且由脚本全自动处理。
  - **新增 `windows.sh`** 薄封装入口：与 `local.sh`/`lan.sh` 同构，默认 `DATA_ROOT` 取
    `ORZMC_DATA_ROOT` 或 `E:/orzmc`，命令 `init|start|stop|status|validate|backup` 与
    macOS/Linux 完全一致。
- **影响**：
  - **用户操作三平台统一**：同一套命令在 macOS/Linux/Windows 上行为一致，Windows 无需
    手工 docker run / 补别名 / 转路径。
  - **仅 daemon 脱离 compose（Windows）**：`docker compose up/down` 不作用于 daemon，
    靠 `--restart unless-stopped` 自动恢复；升级/回滚需 `win_daemon_rm` 后重跑
    `compose_cmd up`（由脚本封装，用户执行 `windows.sh stop && windows.sh start` 即可）。
  - **幂等安全**：`win_daemon_alias` 仅在别名缺失时操作，且须 `disconnect`+`connect --alias`
    补别名（`connect --alias` 无法给已连接容器更新别名，2026-08-16 生产迁移实测修复）；
    已就绪 daemon 无操作、不干扰（生产实测通过）。
  - 文档同步：`docs/windows-deployment.md`（§0 总览修订、§3 daemon 改为脚本自动、
    §4 别名自动、§7 维护速查更新、新增 `windows.sh`）、`AGENTS.md`、`README.md`。
  - **CI 覆盖**：主 job（lint/validate）在 ubuntu 上走不到 Windows 分支（detect_os
    返回 posix）。新增 `tests/windows_ci.sh` 单元测试 + `windows-branch` CI job——
    mock `uname` 强制 MINGW，真实执行 `win_path`/`win_daemon_run`/`win_daemon_alias`/
    `compose_cmd` 的 Windows 分支并断言命令构造（mock docker/cygpath，不真连 Docker、
    路径位置无关）。lint job 的 bash -n/shellcheck 纳入 `tests/*.sh`。

## 7. 演进路径

- **未来候选**（尚未排期）：
  - Phase 3：环境自检脚本 / 自动化校验 / 升级回滚标准化（见 `EXECUTION_PATH.md`）。
  - PaperMC 插件端到端消息验证（依赖 monorepo 侧 OrzMC plugin）。
  - 备份保留策略与异地备份。
- **如何改动架构**：新增一条 ADR，说明背景/决策/影响；同步 `AGENTS.md`（如铁律变化）、
  `README.md`、`templates/*`、`docs/*`；跑 `./local.sh` 本地回归 + `deploy.sh validate`。

## 8. 改动时需同步的位置清单

| 架构改动类型 | 必同步文件 |
|---|---|
| 服务增减 / 入口变更 | `compose.yaml`、`compose.edge.*.yaml`（边缘层 override）、`templates/*`、`README.md`、`docs/architecture.md`(ADR)、`AGENTS.md` |
| `.env` 必需变量增减 | `templates/env.*`、`lib/common.sh`(required_env_list / ENABLE_*) |
| 卷 / 网络调整 | `compose.yaml`、`lib/common.sh`(ensure_data_dirs) |
| 镜像升级/回滚 | `compose.yaml`(digest)、`update-image-digests.sh`(映射) |
| 安全边界变化 | `docs/architecture.md`(ADR)、`AGENTS.md`(安全约束) |
| 文档索引 / 命令变化 | `README.md`、`AGENTS.md` |

---

## 9. ADR 决策记录

### ADR-017：单 profile + 可插拔边缘层 + 可插拔服务（2026-08-16，Windows 迁移演练后）

**背景**：ADR-015/016 演进后，部署仍有三种 profile（`prod`/`local`/`lan`），理解成本高：
- 三套入口脚本（`deploy.sh`/`local.sh`/`lan.sh`/`windows.sh`）+ 三套 env 模板 + 三套
  `REQUIRED_ENV_VARS_*` + `compose.yaml` 的 `profiles:` 机制 + `compose.lan.yaml` override
  + `common.sh` 里成堆 `case "$COMPOSE_PROFILE"` 分支。
- **关键洞察**：三 profile 的唯一本质差异是「边缘层」（怎么让 4 个源站对外可达）——
  local=Caddy(.localhost)、prod=cloudflared(Cloudflare Tunnel)、lan=无边缘层(源站发宿主端口)。
  其余服务（web/daemon/easybot/mariadb/status）完全一致。

**决策**：把「边缘层」从 profile 剥离成独立可插拔组件，profile 从三态降为单运行集：

1. **`EDGE` 变量**（`.env` 里 `EDGE=`，或 `orzmc.sh -e`）选择边缘层：
   `cloudflare` / `local` / `lan` / `none`。`compose_cmd` 按 EDGE 追加对应 override：
   - `compose.edge.cloudflare.yaml`（cloudflared）
   - `compose.edge.local.yaml`（Caddy）
   - `compose.edge.lan.yaml`（4 源站发宿主端口）
   - `none` → 不追加（仅内网 `orzmc_default`）
2. **`ENABLE_*` 变量**（`.env`，缺省 `true`）控制可选服务：
   `ENABLE_EASYBOT` / `ENABLE_MARIADB` / `ENABLE_STATUS`。对应 compose `profiles: ["easybot"/"mariadb"/"status"]` 标签，`compose_cmd` 按启用项追加 `--profile <name>`。核心 web/daemon 无 profile 常驻。
3. **唯一入口 `orzmc.sh`**：`./orzmc.sh [-d DATA_ROOT] [-e EDGE] init|up|stop|status|validate|backup|templates`。三平台命令一致。
4. **旧入口兼容**：`deploy.sh`/`local.sh`/`lan.sh`/`windows.sh` 保留，`-p` 旧值 `prod`→`cloudflare` 自动映射（`normalize_edge`）；`COMPOSE_PROFILE` 未设 `EDGE` 时作为回退。

**影响**：
- `compose.yaml`：移除 reverse-proxy/cloudflared 两个边缘层服务 → 移入 `compose.edge.*.yaml`；easybot/mariadb/status 加 `profiles:` 标签成为可选；status 的 `depends_on` 精简为只依赖核心 web/daemon（避免 ENABLE_* 禁用时依赖报错）。
- `lib/common.sh`：`normalize_edge` / `edge_override_file` / `enabled_profiles` / `required_env_list`（按 EDGE+ENABLE 动态必需变量）；`compose_cmd`/`ensure_status_config`/`print_access_info`/`win_daemon_run`(lan 端口) 全部改按 EDGE。
- env 模板仍按 EDGE 分（`env.prod`/`env.local`/`env.lan`），`orzmc.sh` 自动选择——保留变量精简，不合并成全量模板。
- 三平台行为一致（macOS/Linux/Windows）；Windows 下 daemon 仍走 `win_daemon_run`（ADR-016 不变）。
- 新增边缘层只需：新建 `compose.edge.<name>.yaml` + `normalize_edge` 加一行 + `edge_override_file` 加一行 + 必要 env 变量进 `required_env_list`。相比旧的动七八处，理解与扩展成本大幅降低。

### ADR-018：免克隆部署（GitHub Release tarball + install.sh）（2026-08-16）

**背景**：当前部署必须先 `git clone` 仓库。对生产机/内网/无 git 环境，希望**不克隆仓库**
也能跑起来——因为仓库只承载"运行时"（无数据/密钥，铁律 1/2），天然可打包分发。

**决策**：
1. **CI 打包 job**（`ci.yml` 新增 `package` job）：打 tag（`v*`）时用 `tar` 把运行时
   打成 `orzmc-<version>.tar.gz` + `.sha256`，上传为 GitHub Release 资产。
   - 打包内容：入口脚本 + `lib/` + `templates/` + `compose*.yaml` + `docs/` + 文档。
   - 显式排除 `.git` / `.github` / `tests` / `EXECUTION_PATH.md` / `.env` / `.local-data*`
     （铁律：密钥与数据不入包）；包内做禁止路径守卫（发现即失败）。
   - `softprops/action-gh-release@v2` 创建/更新 Release 并上传资产（contents: write）。
2. **`install.sh` 一键安装脚本**（仓库根，也打包进 tarball）：
   - `./install.sh [-d DIR] [-v VER] [-r REPO]`：解析最新 release（GitHub API）或指定版本
     → 下载 tarball 及其 sha256 → 校验（`sha256sum`/`openssl`）→ 解压到安装目录 → 之后
     照常 `./orzmc.sh`。
   - 幂等（可重复跑）；运行时/数据分离保证不触碰 `$DATA_ROOT`；三平台一致。

**影响**：
- 新增 `install.sh`、`ci.yml` 的 `package` job、README「免克隆安装」章节。
- 部署等价性：`git clone` 与 tarball 得到同一套 `orzmc.sh` 与模板，行为一致。
- 安全：sha256 校验防篡改/下载损坏；包内无密钥（CLOUDFLARE 凭据/密码仍只落 `$DATA_ROOT`）。

### ADR-019：移除 instances/ 目录，实例数据统一由面板管理（2026-08-16）

**背景**：MCSManager 面板创建的实例默认把数据（`cwd`）写入 daemon 的
`data/InstanceData/<uuid>/`（容器内 `/opt/mcsmanager/daemon/data/InstanceData/<uuid>`）。
原 ADR-007 的 `instances/` 自挂载（`${DATA_ROOT}/instances:${DATA_ROOT}/instances` +
`MCSM_DOCKER_WORKSPACE_PATH`）是为「实例 `cwd` 直接指向宿主 `instances/` 路径」设计的
另一条路径。实际部署中实例走面板默认布局，`instances/` 只是 init 建出的空壳，既不承载
数据、也造成「实例数据在哪」的困惑（见 §5 数据树）。

**决策**：
1. 移除 daemon 的 `instances/` 自挂载卷（compose.yaml 与 Windows `win_daemon_run` 的
   `--mount`/`--env MCSM_DOCKER_WORKSPACE_PATH` 一并删除）。
2. 实例数据统一由 MCSManager 面板管理，落 `data/InstanceData/<uuid>/`；该目录经
   `daemon/data` 的 bind 挂载天然落宿主 `$DATA_ROOT/mcsmanager/daemon/data/InstanceData/`，
   随 `backup.sh` 整包打包自动覆盖，无需额外备份逻辑。
3. `ensure_data_dirs` 不再创建 `instances/papermc-{main,test}`；删除 `$DATA_ROOT/instances`。
4. `templates/env.papermc` 参考路径改为 `.../data/InstanceData/<uuid>/`。

**影响**：
- compose.yaml / lib/common.sh / tests/windows_ci.sh 同步移除相关挂载与断言。
- 备份/恢复**无变化**（本就整包打包 `$DATA_ROOT`，InstanceData 已含）。
- 升级路径：`orzmc.sh stop` 后 `docker rm` daemon → `orzmc.sh up` 重建（去掉 instances 挂载），
  删除 `$DATA_ROOT/instances`；已有实例数据在 `InstanceData/`，不受影响。

### ADR-020：Windows mirrored 下 lan 档节点地址改内网名，浏览器直连不可用（2026-08-18，Windows 三档实机验收）

**背景**：2026-08-18 Windows 三档实机验收发现，ADT-014 的「lan 节点填 `ws://<LAN_HOST_IP>:24444`
（面板服务端与浏览器同一地址）」在 Windows 上**不成立**。Windows 宿主用 WSL2
`networkingMode=mirrored`（`.wslconfig` + `wsl --shutdown` 冷重启，ADR-015 延伸）才能让
发布端口绑定真实网卡、局域网可达；但 mirrored 模式有一个内核级陷阱：**VM（面板容器）对
「宿主自身 LAN IP 的已发布端口」的本地投递在 conntrack/NAT 层损坏**，表现为连接超时。

- **决定性证据**：面板容器经同一路径（bridge 网关 `172.18.0.1`）进入 VM，目标
  `172.18.0.1:24444` 通（socket.io 握手 HTTP 200）、目标 `192.168.0.33:24444` 超时——
  入口相同、仅目标 IP 不同。
- 尝试过的补救均无效：容器内 `ip route add`（改路由不修 conntrack）、`/etc/hosts` 注入
  （字面 IP 不查 hosts）、`docker exec --privileged` 提权 NET_ADMIN（同样只改路由）。
- macOS 无此问题（Docker Desktop 正确实现宿主 LAN IP 的 hairpin），故 ADR-014 原结论
  在 macOS/Linux 成立、在 Windows 不成立。

**决策**：
1. **Windows lan 档**：节点 `ip` 填内网名 `ws://mcsmanager-daemon`、端口 `24444`（与
   ADR-011 相同，零运行时改动）。节点在线、面板服务端管理（实例启停/状态/文件管理）正常。
2. **接受浏览器限制**：浏览器解析不了 Docker 内网主机名 `mcsmanager-daemon`，lan 档
   Windows 上「网页直连」/实时终端**不可用**——这是 mirrored 下「面板可达地址（bridge 内网）
   与浏览器可达地址（LAN IP）不相交」的硬约束，面板与浏览器共用同一节点地址无法兼得。
3. **全功能解的可行路线（记录备查）**：节点地址用自定义主机名（如 `mcs-node.lan`）双解析
   ——面板容器 `extra_hosts: mcs-node.lan:host-gateway`（已实测面板侧可达，socket.io 200）
   + 浏览器经**路由器自定义 DNS** 解析到 LAN IP。依赖路由器支持自定义 DNS 记录，当前环境
   不具备；具备时按此启用即可恢复浏览器终端。
4. **需要浏览器终端时**：用 local 档（宿主浏览器，Caddy `.localhost`）或 prod 档
   （公网域名，任意设备）——这两个入口浏览器可达，无此限制。

**影响**：
- `templates/env.lan` 补充注释说明 lan Windows 节点地址（内网直连 + 浏览器不可用）。
- AGENTS.md / docs/usage.md §6.3 / docs/architecture.md §2.x 的「三档浏览器直连均可用」
  需加「macOS/Linux」限定与 Windows lan 例外。
- 文档同步：`AGENTS.md` §4、`docs/usage.md` §6.3、`docs/windows-deployment.md` §7/§9/§10、
  `docs/acceptance.md`（Windows 验收实录）、`EXECUTION_PATH.md`。
