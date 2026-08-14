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
- **daemon 连接（面板内网直连；浏览器终端受限，ADR-011）**：面板**服务端**连接 daemon 走
  Docker 内网直连——节点配置 `ip=ws://mcsmanager-daemon:24444`（官方默认部署模型；勿填
  隧道 URL `wss://mcs-node.<domain>:443`：daemon 的 socket.io 在 cloudflared 转发下会被
  自身 koa 确定性拦截，节点永远离线）。`mcs-node.<domain>` 入口仍保留，设计供浏览器直连
  daemon（终端/控制台/文件管理器，密钥鉴权），但生产下受同一 koa 拦截**当前不可用**
  （已知限制）；本地 Caddy 不受影响，`mcs-node.localhost` 可用。daemon 全部业务路由
  密钥鉴权，无 key 无权限。
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

### 2.3 域名命名约定

| 子域名 | 用途 | 模板变量 |
|---|---|---|
| `mcs.<domain>` | MCSManager 面板 | `DOMAIN_MCS_WEB` |
| `easybot.<domain>` | EasyBot 管理后台 | `DOMAIN_EASY_ADMIN` |
| `mcs-node.<domain>` | MCSManager daemon/节点（浏览器直连，密钥鉴权；prod 下受限，ADR-011） | `DOMAIN_MCS_NODE` |
| `orzmcs.<domain>` | 统一状态页（Gatus，聚合入口 + 实时健康，无鉴权仅状态） | `DOMAIN_STATUS` |

约定：**子域名 = 产品代号，无后缀即该产品管理控制台**；daemon 组件在代号后加
`-node` 后缀。`orzmcs` 为平台自身入口（统一状态页）。本地同构镜像：
`mcs.localhost` / `easybot.localhost` / `mcs-node.localhost` / `orzmcs.localhost`。

## 3. 网络与数据流

1. 管理浏览器 → Cloudflare 边缘（TLS）→ cloudflared（出站隧道，compose 网络内按
   hostname 路由）→ `mcsmanager-web:23333`（面板）/ `easybot:8080`（后台）。
2. 面板服务端 → `ws://mcsmanager-daemon:24444`（Docker 内网直连，节点配置的 ip/port，
   不经边缘、不经代理；ADR-011）。浏览器直连 daemon（终端/文件管理）经
   `mcs-node.<domain>` 入口，生产下因 daemon koa 拦截 socket.io 受限（已知问题，ADR-011）；
   本地 Caddy 路径可用。
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
  easybot/data/           # EasyBot 网关数据（uid/gid=10001）
  status/config.yaml      # Gatus 统一状态页配置（init 生成、绝不覆盖；ro 挂载）
  database/               # 应用数据库 MariaDB
    mariadb/              # InnoDB 数据目录（uid/gid=999）
    dumps/                # backup.sh 自动逻辑备份（含 mysql 系统库，按密钥 chmod 600）
  instances/              # daemon 容器以同路径自挂载，文件管理器可见
    papermc-main/{server,backups}
    papermc-test/{server,backups}
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

- **状态**：已实施；**面板↔daemon 传输层由 ADR-011 修正**——面板服务端连接 daemon 改走
  Docker 内网直连（节点配置 `ip=ws://mcsmanager-daemon:24444`），不再填隧道 URL；
  `mcs-node.<domain>` 入口仍保留（设计供浏览器直连终端/文件管理，prod 下受 koa 拦截
  限制为已知问题）。
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

- **状态**：已实施。
- **背景**：MCSManager 文件管理器读 `instance.absoluteCwdPath()`（实例 `cwd` 直接是宿主
  路径）时，daemon 容器内解析不到宿主文件，`fs.existsSync` 为假会 `mkdirpSync` 自动建
  **空**目录，表现为"文件管理为空"。
- **决策**：daemon 服务把 `${DATA_ROOT}/instances` 以**同路径**自挂载进容器
  （`"${DATA_ROOT}/instances:${DATA_ROOT}/instances"`），daemon 容器内即看到真实文件；
  docker bind Source 仍由宿主解析，两者不冲突。`MCSM_DOCKER_WORKSPACE_PATH` 置为
  `${DATA_ROOT}/instances` 兜底默认布局。
- **影响**：compose daemon 卷增加一条自挂载；新增实例目录后无需改动。

### ADR-008：平台层常驻 MariaDB 数据库服务（2026-08-14）

- **状态**：已实施。
- **背景**：PaperMC 常见插件（Dynmap / CoreProtect / LuckPerms / Towny / 经济插件等）
  会把状态持久化到 MySQL/MariaDB；原栈中唯一数据库是 EasyBot 自带的 SQLite
  （`gateway.db`），插件侧无任何 DB 连接配置。
- **决策**：新增 `mariadb` 服务，**默认随平台层启用**（无 profile 门控、无开关，与
  `mcsmanager-*`/`easybot` 一致双 profile 运行）。数据落 `$DATA_ROOT/database/mariadb`；
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
    常驻 `status` 服务（双 profile 都运行），暴露第 4 入口 `orzmcs.<domain>`（最初定为
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
  `dashboard` 属通用基建名），违反 §2.3「子域名 = 产品代号，避免泛化子域名占用」约定。
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

- **状态**：已实施。
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
| 服务增减 / 入口变更 | `compose.yaml`、`templates/*`、`README.md`、`docs/architecture.md`(ADR)、`AGENTS.md` |
| `.env` 必需变量增减 | `templates/env.*`、`lib/common.sh`(REQUIRED_ENV_VARS_PROD/LOCAL) |
| 卷 / 网络调整 | `compose.yaml`、`lib/common.sh`(ensure_data_dirs) |
| 镜像升级/回滚 | `compose.yaml`(digest)、`update-image-digests.sh`(映射) |
| 安全边界变化 | `docs/architecture.md`(ADR)、`AGENTS.md`(安全约束) |
| 文档索引 / 命令变化 | `README.md`、`AGENTS.md` |
