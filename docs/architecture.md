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
  [管理浏览器] ─https─> mcs.example.com ────┐
  [管理浏览器] ─https─> easybot.example.com ─┼─ Cloudflare 边缘 <─出站隧道─ cloudflared(容器, orzmc_default)
  [管理浏览器] ─https─> mcs-node.example.com ─┘       │                │
                                                     │                ├─ http://mcsmanager-web:23333      (MCS 面板)
                                                     │                ├─ http://easybot:8080              (EasyBot 后台)
                                                     │                └─ http://mcsmanager-daemon:24444   (daemon/节点，密钥鉴权)
内网
  [玩家] ── Mac 局域网 IP:25565 ──> PaperMC Prod（MCSManager 管理）
  [插件]  PaperMC 实例(挂 orzmc_default) ──http──> http://easybot:8080   (REST+WS，内网直连，不走公网)
  [QQ bot] EasyBot 出站连 QQ 服务器（NAT 下正常）
```

- 公网暴露 **3 个入口**：`mcs.<domain>`（MCSManager 面板）、`easybot.<domain>`
  （EasyBot 管理后台）、`mcs-node.<domain>`（daemon/节点，浏览器直连入口，密钥鉴权）。
- **EasyBot 插件 API 仅内网**：插件挂 `orzmc_default` 网络，直连 `http://easybot:8080`
  （REST + WebSocket 同端口，内网无 TLS）。
- **daemon 经边缘入口可达**：MCSManager 连接模型要求面板浏览器直连 daemon
  （终端/控制台/文件管理器），生产 `mcs-node.<domain>`（Cloudflare）、本地
  `mcs-node.localhost`（Caddy）反代到 `mcsmanager-daemon:24444`；daemon 全部业务
  路由密钥鉴权，无 key 无权限。
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
| `mcs-node.<domain>` | MCSManager daemon/节点（浏览器直连，密钥鉴权） | `DOMAIN_MCS_NODE` |

约定：**子域名 = 产品代号，无后缀即该产品管理控制台**；daemon 组件在代号后加
`-node` 后缀。本地同构镜像：`mcs.localhost` / `easybot.localhost` / `mcs-node.localhost`。

## 3. 网络与数据流

1. 管理浏览器 → Cloudflare 边缘（TLS）→ cloudflared（出站隧道，compose 网络内按
   hostname 路由）→ `mcsmanager-web:23333`（面板）/ `easybot:8080`（后台）。
2. 管理浏览器 → `mcs-node.<domain>` → Cloudflare 边缘 → `mcsmanager-daemon:24444`
   （**浏览器直连** daemon，密钥鉴权；面板服务端不代理 daemon）。
3. PaperMC 插件 → `http://easybot:8080`（REST + WS，同 `orzmc_default` 网络）。
4. MCSManager Daemon → 宿主机 Docker（挂载 `/var/run/docker.sock`），管理 PaperMC 实例。
5. EasyBot → 出站连接 QQ / Telegram / Discord / 飞书 / 微信服务器（NAT 下正常）。

## 4. 服务职责

| 服务 | 镜像 | 职责 | 网络/卷 |
|---|---|---|---|
| `reverse-proxy` (caddy) | digest 锁定 | local profile 反代 + TLS | `$DATA_ROOT/caddy/*` |
| `cloudflared` | digest 锁定 | prod 出站隧道，hostname→service 路由 | `$DATA_ROOT/cloudflared`（ro） |
| `mcsmanager-web` | digest 锁定 | MCSManager 面板 | `$DATA_ROOT/mcsmanager/web/{data,logs}` |
| `mcsmanager-daemon` | digest 锁定 | 实例生命周期 + Docker 管理 | `$DATA_ROOT/mcsmanager/daemon/{data,logs}` + `/var/run/docker.sock` |
| `easybot` | digest 锁定 | 统一 IM 网关（HTTP 监听，uid/gid=10001） | `$DATA_ROOT/easybot/data` |

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

- **状态**：已实施。
- **背景**：MCSManager 连接模型要求面板浏览器**直连** daemon（终端/控制台/文件管理器
  经 WebSocket，面板服务端不代理 daemon）。内网地址 `mcsmanager-daemon:24444` 在浏览器
  侧不可解析，面板报"无法连接到远程节点"。
- **决策**：新增第 3 个入口 `mcs-node.<domain>`（prod=Cloudflare ingress / local=Caddy
  反代）转发到 `mcsmanager-daemon:24444`。daemon 全部业务路由要求密钥鉴权
  （`checkLogin` 校验 key + session），无 key 即拒绝，公网暴露不扩大权限面。
- **影响**：环境变量新增 `DOMAIN_MCS_NODE`；`cloudflared-config.yml` / `Caddyfile`
  ingress 各加一条；MCSManager 节点配置 `ip=wss://mcs-node.<domain>:443`。命名沿用
  约定（产品代号 `mcs` + 组件 `-node`），避免泛化子域名占用。

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
