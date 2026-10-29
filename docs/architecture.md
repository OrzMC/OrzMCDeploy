# OrzMC Deploy 架构文档

> 本文档是**长期演进**的架构设计文档，记录设计目标、拓扑、数据流、决策记录与演进路径。
> 每次架构改动（服务增减、入口变更、卷/网络调整、安全边界变化）都必须在本页新增 ADR
> 记录，并同步 `AGENTS.md` / `README.md` / 相关 `docs/*.md`。
> 智能体快速守则见 `AGENTS.md`；用户入口见 `README.md`。

## 1. 设计目标

- **运行时与数据分离**：仓库只承载运行时，全部配置与数据落宿主机统一目录 `$DATA_ROOT`，
  使运行时与数据可独立演进、独立备份/还原/迁移，密钥不进入仓库。
- **局域网内闭环**：平台层只服务可信局域网（纯 HTTP，ADR-027）；**对外访问由站点自备**
  （DDNS + 端口映射 / TLS 反代 / VPN），本仓库不提供也不管理边缘层。
- **单一控制面**：MCSManager 作为 PaperMC 实例唯一控制入口；本仓库 compose 只管平台层。
- **可验证、可回滚**：镜像 digest 锁定 + git commit；`./orzmc.sh -d <目录> validate` 做配置门禁。

## 2. 拓扑（局域网单一模式，ADR-027）

```text
局域网（可信内网，纯 HTTP）
  [管理浏览器/手机] ─http─> http://<LAN_HOST_IP>:18090  ─┐
  [管理浏览器/手机] ─http─> http://<LAN_HOST_IP>:18091  ─┴─ Docker(orzmc)
                                                            ├─ mcsmanager-web:23333   (MCS 面板)
                                                            ├─ easybot:8080           (EasyBot 后台)
                                                            └─ mcsmanager-daemon:24444（仅 orzmc_default，不发布）
内网
  [面板服务端] ──ws──> mcsmanager-daemon:24444    (节点地址固定内网名)
  [面板中转]   ──数据面代理──> daemon            (dataPlane=proxy：下载/上传/终端流)
  [玩家] ──<LAN_HOST_IP>:25565──> PaperMC 实例（MCSManager 管理，实例自身发布端口）
  [插件] PaperMC 实例(挂 orzmc_default) ──http──> http://easybot:8080   (REST+WS，内网直连)
  [QQ bot] EasyBot 出站连 QQ 服务器（NAT 下正常）
对外
  [路由器/反代/VPN] ──> 站点自备，本项目不参与（DDNS + 端口映射 / TLS 反代 / Tailscale）
```

- 局域网暴露 **2 个入口**：`http://<LAN_HOST_IP>:18090`（MCSManager 面板）、
  `http://<LAN_HOST_IP>:18091`（EasyBot 管理后台），端口可用
  `LAN_MCS_WEB_PORT` / `LAN_EASYBOT_PORT` 覆盖。
- **daemon 不发布任何端口**（ADR-026）：面板自己中转浏览器↔daemon 的数据流
  （`SystemConfig.dataPlane=proxy`），节点地址固定 `ws://mcsmanager-daemon:24444`；
  终端/控制台/文件管理全部经面板端口。
- **EasyBot 插件 API 仅内网**：插件挂 `orzmc_default` 网络直连 `http://easybot:8080`。
- **对外访问由站点自备**（ADR-027）：DDNS + 端口映射、反向代理或 VPN。
  ⚠️ 面板是 HTTP + 口令登录，公网暴露前**必须**加 TLS 反代或改用 VPN。
- 服务端口除上述两个外一律不发布到宿主（仅 `orzmc_default` 内网可达）；PaperMC 实例端口（`25565` 等）由 MCSManager
  按实例配置发布，供局域网玩家直连。

## 3. 网络与数据流

1. 管理浏览器 → `http://<LAN_HOST_IP>:18090` → `mcsmanager-web:23333`（面板）；
   `:18091` → `easybot:8080`（后台）。
2. 面板服务端 → `ws://mcsmanager-daemon:24444`（内网名）。浏览器不直连 daemon：
   终端/控制台/文件管理的数据面由面板中转（`dataPlane=proxy`，ADR-026）。
3. PaperMC 插件 → `http://easybot:8080`（REST + WS，同 `orzmc_default` 网络）。
4. MCSManager Daemon → 宿主机 Docker（挂载 `/var/run/docker.sock`），管理 PaperMC 实例。
5. EasyBot → 出站连接 QQ / Telegram / Discord / 飞书 / 微信服务器（NAT 下正常）。
6. （可选，站点自备）外部设备 → 路由器/反代/VPN → 上述两个局域网端口。

## 4. 服务职责

| 服务 | 镜像 | 职责 | 网络/卷 |
|---|---|---|---|
| `mcsmanager-web` | digest 锁定 | MCSManager 面板 | `$DATA_ROOT/mcsmanager/web/{data,logs}` |
| `mcsmanager-daemon` | digest 锁定 | 实例生命周期 + Docker 管理 | `$DATA_ROOT/mcsmanager/daemon/{data,logs}` + `/var/run/docker.sock` |
| `easybot` | digest 锁定 | 统一 IM 网关（HTTP 监听，uid/gid=10001） | `$DATA_ROOT/easybot/data` |

> 平台层稳态即上表 3 个（ADR-025 移除 mariadb/status，ADR-027 移除 cloudflared/caddy；
> `easybot` 可用 `ENABLE_EASYBOT=false` 关闭 → 2 个）。

## 5. `$DATA_ROOT` 目录树

```text
$DATA_ROOT/
  .env                    # 全部环境变量 + 密钥（权限 600，不入 Git）
  compose.site.yaml       # 站点增量 override：compose_cmd 检测到即自动 -f 追加
                          # （升级/换包不丢；ADR-022，issue #11）
  mcsmanager/
    web/{data,logs}
    daemon/
      {data,logs}         # Config/global.json 含 daemon key（权限 600，最高权限密钥）
    daemon/data/InstanceData/<uuid>/   # MCSManager 面板创建的实例数据（cwd，含 world/plugins/...）
  easybot/data/           # EasyBot 网关数据（uid/gid=10001）
  # 注：ADR-027 前的旧部署可能有 caddy/ 与 cloudflared/（含隧道凭据=密钥），
  # 不再使用时请先归档再删除。
  # 注：ADR-025 起平台层不再生成 status/ 与 database/；旧部署遗留的这两个目录
  # 可安全删除（或按站点增量自行加回 mariadb/gatus）。
```

## 6. ADR 决策记录

> 长期有效的决策，按编号升序排列。已废止 / 被取代的决策只在文末索引保留一行，
> 正文用 `git log -p -- docs/architecture.md` 查。新增决策按编号续写，勿再拆分成
> “本轮精简”之类按时间切分的子节（那会保证漂移）。

### ADR-001：EasyBot 统一 IM 网关（2026-08-13）

- **决策**：采用 EasyBot 承载 QQ / Telegram / Discord / 飞书 / 微信；QQ 用 QQ 开放平台官方
  bot 凭据（AppID + ClientSecret，非个人号扫码）。
- **影响**：接入与插件配置见 `docs/usage.md` §7；监听器仅 HTTP（ADR-027 后只在局域网暴露）。

### ADR-002：运行时与数据分离（2026-08-13）

- **决策**：仓库只承载运行时（compose / 脚本 / 模板）；全部配置、密钥、数据经卷映射落
  `$DATA_ROOT`，脚本统一 `compose_cmd --env-file $DATA_ROOT/.env`。
- **影响**：`AGENTS.md` 铁律 1–2、README「关键约束」；备份/迁移因此只需打包 `$DATA_ROOT`。

### ADR-004：EasyBot 插件 API 仅内网（2026-08-13）

- **决策**：插件在 `orzmc_default` 网络内直连 `http://easybot:8080`（REST + WS 同端口），
  不设 `easybot-api` 入口。
- **历史**：入口数量部分曾被 ADR-005（已废止）修改；ADR-027 后本项目无公网入口，本决策天然成立。

### ADR-006：macOS Docker Desktop 写盘走宿主用户（2026-08-13，Phase 2）

- **背景**：容器内 uid 检查通过，但 Docker Desktop 的 gRPC-FUSE 由 macOS 侧宿主用户执行实际
  写盘；实例目录属主非该用户时仍报 Operation not permitted（`chmod 777` 无效）。
- **决策**：macOS 生产把实例目录属主改为宿主用户（`sudo chown -R <user>:staff <instance-dir>`）；
  Linux 保持 `1000:1000`。
- **影响**：平台差异见 `docs/papermc-template.md`「Docker 实例字段格式」。

### ADR-007：daemon 自挂载实例目录（2026-08-13，已被 ADR-019 取代）

文件管理器读不到实例文件时，曾把 `${DATA_ROOT}/instances` 以同路径自挂载进 daemon 并令
`MCSM_DOCKER_WORKSPACE_PATH` 指向它。实际部署走面板默认布局（`data/InstanceData/<uuid>/`），
该自挂载已由 ADR-019 移除。

### ADR-018：免克隆部署（Release tarball + install.sh）（2026-08-16）

- **决策**：打 `v*` tag 时 CI 用 `tar` 把运行时打成 `orzmc-<ver>.tar.gz` + `.sha256` 上传
  Release（排除 `.git`/`.github`/`tests`/数据，包内做禁入路径守卫）；`install.sh` 解析
  release → 下载 → 校验 sha256 → 解压，幂等、三平台一致。
- **影响**：新增 `install.sh` 与 CI `package` job；`git clone` 与 tarball 行为等价。
  打包清单必须与仓库实际文件一致（ADR-030 曾因清单含已删脚本导致打包失败）。

### ADR-019：移除 instances/ 目录，实例数据由面板管理（2026-08-16）

- **背景**：面板默认把实例数据写到 daemon 的 `data/InstanceData/<uuid>/`（经 `daemon/data`
  bind 落宿主），ADR-007 的 `instances/` 只是空壳，反而让「数据在哪」变模糊。
- **决策**：删除 `instances/` 自挂载与对应的 `win_daemon_run` 参数；实例数据统一由面板管理，
  随 `$DATA_ROOT` 整包备份；`ensure_data_dirs` 不再建 `instances/`。
- **影响**：备份/恢复无变化；升级时 `stop` → `docker rm` daemon → `up` 重建即可。

### ADR-022：站点增量 / DAEMON_PORTS 自动忽略 / daemon 堆-限额对齐（#9–#12）（2026-09-10）

- **#11 站点增量**：`init` 生成 `$DATA_ROOT/compose.site.yaml`（绝不覆盖），`compose_cmd`
  检测到即自动 `-f` 追加；另支持 `.env` 的 `COMPOSE_FILE_EXTRA`。站点特有 env/挂载因此与包内
  `compose.yaml` 解耦，升级换包不丢。
- **#9 `DAEMON_PORTS`**：模板默认置空；Windows 创建 daemon 前扫描 `InstanceConfig/*.json`，
  发现 docker 型实例即自动忽略并提示（进程模式与 docker 型实例互斥，避免 daemon 先抢 25565）。
- **#10 内存**：容器上限与 Node 堆收敛到 `.env` 的 `DAEMON_MEMORY_LIMIT` /
  `DAEMON_NODE_HEAP_MB`（缺省 512M / 384），**覆盖镜像 CMD** 才生效（命令行 flag 优先于
  `NODE_OPTIONS`）；daemon 增加 TCP healthcheck。
- **#12 生命周期**：`InstanceConfig/<uuid>.json` 是 daemon 内存副本 + 刷盘，改配置必须
  「停 daemon → 改 → 启 daemon」；`autoStart` / `autoRestart` 语义见 `docs/usage.md` §6.5。

### ADR-024：easybot 内存上限恢复紧值 512M（不随 v0.0.41 修复放大）（2026-10-01）

**背景**：ADR-023 为响应 issue #16，把 easybot 硬编码的 512M 上限改为可调并**把缺省提到 1G**。
但同批 digest bump 到 EasyBot v0.0.41 已修掉该 issue 的根因（空载匿名内存泄漏，上游 #139）——
即 512M 曾“过紧”并非配置问题，而是上游泄漏把内存顶到了上限。

**决策**：`EASYBOT_MEMORY_LIMIT` 缺省值由 `1G` 恢复为 **`512M`**（与原硬编码值一致），
保留变量本身（issue #16 诉求的“可配置 + 文档化”）。理由：**放大上限会掩盖未来回归**——
内存再次异常增长时应尽快由 OOM/重启暴露，而不是被 1G 余量吞掉。确有更重负载的站点可按需上调。

**影响**：
- 运行时：`compose.yaml`（`${EASYBOT_MEMORY_LIMIT:-512M}`）、`templates/env` 注释。
- 文档：`docs/usage.md` 附录 F 表格与说明；ADR-023 保留为历史决策（本条为其修正）。
- **兼容性**：变量仍可选、旧 `.env` 无需改动；行为相对 v0.0.4（512M）无变化，相对 v0.0.5（1G）为收紧。

### ADR-025：移除平台层 MariaDB 与 Gatus 状态页（服务精简）（2026-10-29）

**背景**：站点运行数月后复盘「服务是否都在创造价值」，两个服务被证伪：

1. **MariaDB（ADR-008）从未被使用**：站点实测该库零表、无业务连接（插件各自用
   h2/sqlite/yaml 本地存储），但它带来常驻容器、每次备份的逻辑 dump、4 个 `.env`
   变量（含 2 个密钥）、专用 healthcheck，以及 `db_root_pw` / `wait_for_mariadb` /
   `dump_db_logical` 一批库代码。
2. **Gatus 状态页（ADR-009/010）成本高于价值**：只读看板、无鉴权、6 张健康卡片，
   而面板本身已显示节点/实例状态。更关键的是它**自我轮询**：`status/config.yaml`
   的端点指向公网域名，每 30 s 各走一遍 Cloudflare 隧道（实测每次约 1 s），
   与用户访问争抢同一条隧道——在「公网访问本就慢」的站点上是负收益。

**决策**：v0.1.0 起从平台层**移除** `mariadb` 与 `status` 两个服务，连带：

- `compose.yaml`：删除两个服务块（含 `profiles:` 标签）；`ENABLE_MARIADB` /
  `ENABLE_STATUS` 开关随之消失，`ENABLE_*` 只剩 `ENABLE_EASYBOT`。
- `lib/common.sh`：删除 `ensure_status_config`、`db_root_pw` / `wait_for_mariadb` /
  `dump_db_logical`；`enabled_profiles` / `required_env_list` / `print_access_info` /
  `ensure_data_dirs` 相应收敛。
- `templates/`：删除 `gatus-config.yml`；`env.{prod,local,lan}` 去掉 `DOMAIN_STATUS` /
  `STATUS_PORT` / `MARIADB_*`；`Caddyfile` 与 `cloudflared-config.yml` 各少一条入口
  （公网入口 **4 → 3**）；`compose.edge.{lan,local}.yaml` 去掉 status 相关字段。
- `backup.sh` / `restore.sh`：去掉逻辑 dump 与 `database/mariadb` 校验。
- `update-image-digests.sh`、CI 断言、`tests/windows_ci.sh` 同步。

**为什么不是"加开关默认关"**：`ENABLE_*` 已能做到，但开关本身仍需维护
（模板、必填变量、文档、CI 矩阵、备份分支各一份）。对**已验证零使用**的服务，
删除比保留开关更省——且删除是**站点级可逆**的：

**回退路径**：需要 MySQL/MariaDB 时，在 `$DATA_ROOT/compose.site.yaml` 中加回服务定义
（这正是 ADR-022 站点增量的用途，升级换包不丢），插件仍按老办法直连 `mariadb:3306`。
Gatus 同理。

**影响**：
- 运行时：稳态容器 **6 → 4**（web/daemon + 边缘层 + 可选 easybot）；隧道 ingress 4 → 3；
  `.env` 必需变量 12 → 7、密钥 4 → 2；备份步骤 3 → 2。
- 文档：`README.md`、`AGENTS.md`（铁律 §4 拓扑/§安全）、`docs/usage.md`（状态页与数据库
  章节、附录 B/C/D/F）、`docs/papermc-template.md`、`CHANGELOG.md`。
- **兼容性**：旧 `.env` 里残留的 `MARIADB_*` / `DOMAIN_STATUS` / `STATUS_PORT` /
  `ENABLE_MARIADB` / `ENABLE_STATUS` 变为**无消费者的普通行**，不报错、可随手删除；
  `$DATA_ROOT/database/`、`$DATA_ROOT/status/` 与旧容器可用
  `./orzmc.sh stop`（`down --remove-orphans`）清掉后手工删除目录。
- **不可逆点**：无。ADR-008/009/010 保留为历史决策记录。

### ADR-026：daemon 不再对外暴露——面板中转数据面成为唯一拓扑（2026-10-29）

**背景**：ADR-005/011/013/014/020 五条 ADR 都在解决同一个问题——「浏览器怎么连到
daemon」。历史上反复摇摆：隧道 socket.io 被 daemon 的 koa 拦截 → 改内网名（ADR-011）→
prod 回改隧道 URL（ADR-013）→ local 用 Caddy `.localhost`、lan 用 LAN IP 发布端口
（ADR-014）→ Windows mirrored 下 lan 又只能填内网名、浏览器终端不可用（ADR-020）。
代价是：一个 `mcs-node` 公网入口、四个 `.env` 变量（`DOMAIN_MCS_NODE` /
`LAN_MCS_DAEMON_PORT`）、外加大量"哪一档填什么地址"的文档与排障经验。

**MCSManager 10.22.0 改变了这个前提**：新增「面板中转数据模式」
（`SystemConfig.dataPlane ∈ {direct, proxy}`，**新装默认 proxy**，升级的旧装保留 direct）。
读 `web/app.js` 实现确认其在 proxy 下的行为：

- Koa 在 `koa-body` **之前**挂数据面网关，拦截 `/download/:a/:b`、`/upload-new/:id`、
  `/upload-piece/:id`、`/upload/:token`，面板持 daemon passport、给浏览器发**面板自签
  HMAC token**，请求/响应全流式零缓冲；
- `POST /stream_channel`（终端/控制台数据通道）返回
  `{ addr: browserFacingAddr(ctx), password: <面板签发的 proxyToken> }`
  ——`browserFacingAddr` 取 Referer/Origin/Host，即**面板自己的域名**。

也就是说：proxy 模式下浏览器只认面板一个地址，daemon 地址可以彻底不外露。

**决策**：

1. 平台层**移除 `mcs-node` 入口**（`compose.edge.cloudflare.yaml` / `Caddyfile` /
   `compose.edge.lan.yaml` 各少一条），公网入口 **3 → 2**（mcs / easybot）。
2. **节点地址固定** `ws://mcsmanager-daemon:24444`（内网名），不再按 EDGE/平台切换。
3. **daemon 端口不发布**：`compose.edge.lan.yaml` 删掉 daemon `ports`，
   `win_daemon_run` 删掉 lan 档的 `-p` 注入，`.env` 去掉 `DOMAIN_MCS_NODE` /
   `LAN_MCS_DAEMON_PORT`，`compose.yaml` 去掉 web 的 `extra_hosts: mcs-node.localhost`。
4. `init` 增加 `warn_legacy_data_plane`：检测到面板配置存在且 `dataPlane != proxy` 时
   打印修复步骤（面板退出会回写配置，故**只提示不自动改**）。
5. **旧装一次性动作**：停面板 → 在 `SystemConfig/config.json` 加 `"dataPlane": "proxy"`
   → 起面板；重启后节点地址即改为内网名（或删掉重建节点）。新装无需任何操作。

**影响**：

- 运行时：入口 3 → 2；`.env` 每个 EDGE 少 1–2 个必需变量；隧道 ingress 少 1 条；
  Caddy vhost 少 1 个。
- 文档：`AGENTS.md` §4、`README.md`、`docs/usage.md` §6.3（整节由"三档地址表"改为
  "固定内网名 + 面板中转"）、`docs/usage.md` 附录 F、本文件 §2/§3；
  ADR-005/011/013/014/020 标注为历史。
- **收益**：浏览器终端在任何 EDGE 档、任何平台都可用（不再有 Windows 例外）；面板↔daemon
  走内网（此前 prod 档每次 RPC 要经隧道 ~1 s）；daemon 端口彻底不暴露，攻击面缩小。
- **代价/风险**：daemon 的 HTTP 数据面流量（下载/上传/终端流）现在经面板容器中转，
  面板 512M 内存上限需留意大文件并发（实现为零缓冲流式，正常场景无影响）；
  `dataPlane` 属面板运行数据，仓库只能提示不能代改。

### ADR-027：收敛为「只有局域网模式」（2026-10-29）

**背景**：站点复盘发现"多边缘层"带来的复杂度与其价值不匹配：

- 四档 `EDGE`（cloudflare / local / lan / none）各自对应一份 override 文件、一套必需变量、
  一段访问提示、一批文档分支；CI 要跑 4 档 × ENABLE 的矩阵；旧入口 `local.sh`/`lan.sh`/
  `windows.sh` 还要维护兼容。
- 而实际使用中，公网入口的真实需求是"我自己找办法"：站点已具备 DDNS + 端口映射能力，
  也可用 VPN/反代；Cloudflare 隧道受跨境路由影响（站点实测 TTFB 中位数接近 1 s、
  偶发请求失败），维护成本高而收益低。
- ADR-026 之后公网入口只剩 `mcs` + `easybot` 两个 HTTP 站点，边缘层退化为"把一个 HTTP
  端口转出去"，完全可以由站点侧的反代/NAT 承担。

**决策**：

1. **删除边缘层概念**：移除 `compose.edge.{cloudflare,local,lan}.yaml`、
   `templates/Caddyfile`、`templates/cloudflared-config.yml`、三份 `templates/env.*`
   （合并为单份 `templates/env`）、`lib/common.sh` 的 `normalize_edge` /
   `edge_override_file` / `ensure_caddyfile` / `ensure_cloudflared_config`，
   以及 `orzmc.sh -e` / `deploy.sh -p|-e|-t` 参数与 `COMPOSE_PROFILE` 兼容层。
2. **端口发布内联到 `compose.yaml`**：`mcsmanager-web` → `${LAN_MCS_WEB_PORT:-18090}`，
   `easybot` → `${LAN_EASYBOT_PORT:-18091}`；不再需要 override 文件。
3. **删除旧入口脚本** `local.sh` / `lan.sh` / `windows.sh`（它们只是
   `deploy.sh -e/-p` 的包装，参数已不存在）。
4. **对外访问不在本项目范围**：文档改为"由站点自备（DDNS + 端口映射 / 反代 / VPN）"，
   并在安全章节强调——面板是 HTTP + 口令登录，公网暴露必须前置 TLS 反代或改用 VPN。

**影响**：

- 运行时：容器 **4 → 3**（无 cloudflared/caddy；`ENABLE_EASYBOT=false` 时 2 个）；
  `.env` 必备变量降到 **8 个左右**（时区 + 两个容器端口 + 局域网 IP/两端口 + EasyBot 凭据）。
- 仓库：删除 3 个 compose override + 3 个模板 + 3 个入口脚本；`compose_cmd` 不再有
  边缘层分支；`update-image-digests.sh` 只覆盖 3 个服务；CI 矩阵从 4 档变 1 档，
  新增"`LAN_*_PORT` 覆盖生效"用例。
- 文档：本文件 §2/§3/§4、`README.md`、`AGENTS.md` §3/§4、`docs/usage.md` §3/§4/§5/附录；
  ADR-003/005/012/017 标注为历史。
- **兼容性**：旧 `.env` 里的 `EDGE` / `CLOUDFLARE_TUNNEL_ID` / `DNS_*` / `DOMAIN_*` 变为
  无消费者的普通行，不报错、可随手删除；`$DATA_ROOT/cloudflared/`（含隧道凭据）与
  `caddy/` 目录可手工归档或删除。**隧道凭据属密钥，删除前请确认不再需要该隧道。**
- **回滚**：`git revert` 到 ADR-026 版本的 commit 即可恢复四档；数据布局未变。

### ADR-028：默认限源（三层暴露面收敛）（2026-10-29）

**背景**：站点在调试期间把所有宿主防火墙规则的来源改成了 `Any`。面板与 EasyBot 都是
HTTP + 口令登录，`Any` 意味着同网段任何设备（含访客 Wi-Fi、被入侵的 IoT）都能访问登录页；
一旦再做 DDNS 端口映射，就等于把登录页暴露到公网。

**决策**：默认姿态改为「只信任局域网，暴露必须显式」，分三层：

| 层 | 机制 | 默认值 |
|---|---|---|
| L1 容器网络 | daemon 不发布端口（ADR-026） | 已生效 |
| L2 绑定地址 | `.env` 的 `LAN_BIND_ADDR` → compose `ports` 的 host_ip | `0.0.0.0`（可改 `127.0.0.1`） |
| L3 宿主防火墙 | `./orzmc.sh firewall apply`，来源取 `LAN_CIDR` + `ALLOW_EXTRA_CIDRS` | `LAN_CIDR`（模板给的是示例网段，须改成站点网段） |

- 新增 `lib/firewall.sh` + `./orzmc.sh firewall show|apply [--dry-run]`：幂等重建
  `OrzMC-*` 入站规则（Windows 走 PowerShell `New-NetFirewallRule`，Linux 走 ufw，
  macOS 只打印建议）。
- `status` 增加「暴露面」摘要（绑定地址 + 限源建议）。
- 三层叠加的意义：单层误配（把规则改回 `Any`，或把绑定改成 `0.0.0.0`）不足以造成暴露，
  必须两个误操作同时发生。

**对外暴露的三条正规路径**（详见 `docs/security.md`）：VPN（推荐，零公网端口）→
TLS 反代（后端绑 `127.0.0.1`）→ 路由器端口映射（须强口令 + 尽量限源）。

**影响**：`compose.yaml` 端口改用 `${LAN_BIND_ADDR:-0.0.0.0}`；`templates/env` 新增
`LAN_BIND_ADDR` / `LAN_CIDR` / `ALLOW_EXTRA_CIDRS`（及可选的 `MC_TCP_PORTS` /
`MC_UDP_PORTS` / `RCON_PORTS`，注释形式给出）；新增 `docs/security.md`。

**唯一例外**：站点自备的**公网 TLS 反代端口**（如 80/443）本身就要对公网开放，可单独命名
规则（如 `OrzMC-Web-TLS`）；`firewall apply` 只重建 `OrzMC-Panel/EasyBot/MC-*/RCON` 五组
限源规则，不会把反代端口收回 `LAN_CIDR`，也不会被它改成 `Any`。

### ADR-029：Windows 档 daemon 默认交给 compose（2026-10-29）

**背景**：ADR-016 曾断言 Windows 下 compose 无法创建 daemon，故 `compose_cmd` 在 Windows
分支剔除 daemon 并改用 `docker run`。但 ADR-019 移除 `instances/` 自挂载后，本次实测
（Docker Desktop + compose v2 实测）**Windows 原生 compose 能正常创建 daemon**
（容器带 `com.docker.compose.project=orzmc` 标签）。

**决策**：Windows 档改为 **compose 优先**——`DAEMON_PORTS` 为空（docker 型实例）时直接
`compose up -d`，daemon 由 compose 管理（自动带服务名别名）；只有**进程模式实例**需要给
daemon 注入 `-p` 时（compose 无法按 `.env` 动态生成端口列表）才退回 `win_daemon_run`。

**边界仍成立**：**WSL 侧 compose 不能创建** `E:/...` 绑定（实测
`invalid volume specification: 'E:/orzmc/...:/opt/...:rw'`，短语法盘符冒号）→
`DATA_ROOT=E:/...` 时必须在 Windows 侧执行 compose。

### ADR-030：收尾 ADR-027/028 遗留（默认值/兼容性/读取语义/发布链路）（2026-10-30）

**背景**：ADR-027（删边缘层）、ADR-028（默认限源）两轮大改后，代码/文档/CI 之间留下一批
不一致，其中三处是**真故障**：

1. **Release 打包失效**：`ci.yml` 的 `package` job 仍 `tar … local.sh lan.sh windows.sh`，
   而这三个脚本已随 ADR-027 删除 → `tar: Cannot stat … exit 2` → 打 tag 不会产生 tarball，
   `install.sh` 免克隆安装（ADR-018）整体不可用。
2. **bash 3.2 兼容不成立**：`lib/common.sh` / `backup.sh` 用了 `mapfile`（bash 4 内建），
   且若个位置裸展开可能为空的数组（bash <4.4 + `set -u` 会报 unbound）——macOS 自带
   bash 3.2 上 `validate` / `backup --keep` / Windows 分支 `up` 会直接失败。
3. **可选服务开关测试是假阳性**：CI 用 `printf >> .env` 追加 `ENABLE_EASYBOT=false`，
   但 `read_env_value` 是「首次出现优先」，追加行被忽略；且断言用的 `compose config`
   未带 `--profile`，无论开关如何都不含 easybot。

**决策**：

1. **发布清单与仓库实际文件同步**：`package` job 的 `tar` 文件列表去掉已删脚本；
   注释里写明“删脚本时必须同步这里”。
2. **真兼容 bash 3.2**：删掉全部 `mapfile`，改 `while IFS= read -r`；
   可能为空的数组统一用 `${arr[@]+"${arr[@]}"}` 展开；在 `AGENTS.md` 代码约定里写死这条。
3. **开关断言改成真的走消费端**：CI 用 `sed` 原地改键 + 断言 `enabled_profiles` 为空
   + 用 `compose_cmd config --services`（不带 `--profile`）断言无 easybot；新增
   `LAN_BIND_ADDR` / `firewall apply --dry-run` 两个 ADR-028 用例。
4. **默认 `DATA_ROOT` 按平台**（`default_data_root`）：Windows `E:/orzmc`、macOS
   `/Users/Shared/orzmc`、Linux `/srv/orzmc`——此前代码恒为 `/srv/orzmc`，与文档/AGENTS
   一直宣称的平台默认值不符（Windows 上会落到 MSYS 的 `/srv/orzmc`）。
   **本条已被 ADR-033 取代**：平台默认值整体取消，`DATA_ROOT` 必须显式指定。
5. **`read_env_value` 语义固定并容错**：同名键**首次出现优先**（写入注释）、剥除 CRLF
   （Windows 编辑器写出的 `\r` 会让 `ENABLE_EASYBOT` / `LAN_BIND_ADDR` 静默失效）。
6. **删 `ensure_data_dirs` 里的 `caddy/`**：ADR-027 后无边缘层，新装不再建这个空目录。
7. **`firewall` 平台行为对齐文档**：Linux `show` 的端口正则改逐端口拼接（原实现末尾
   `|` 导致 `grep -E` 匹配全部行，且 `25565,25566` 永远匹配不到）；macOS `apply` 改为
   打印等价 `pf` 规则（原实现实际打印 iptables）；缺 `.env` 时直接拒绝（不再用缺省值
   建规则）。
8. **文档与实现对齐**：AGENTS/README/usage/Windows 要点/papermc-template 清理
   边缘层与 `-e <edge>` 残留；Windows 要点不再教用户写 `-RemoteAddress Any`
   规则（ADR-028 禁止）与容器内端口 23333；`templates/env` 补上 `MC_TCP_PORTS` /
   `MC_UDP_PORTS` / `RCON_PORTS` 注释（ADR-028 早已引用它们）；architecture 合并两处
   ADR 节并删除重复的归档索引。

**影响**：
- 代码：`lib/common.sh`（默认值/读取/空数组/目录/输出）、`backup.sh`、`lib/firewall.sh`、
  `deploy.sh`（删与 `orzmc.sh` 重复的别名）、`update-image-digests.sh`（服务→镜像映射
  只留 shell 一处，去掉 python 重复缺省值）、`install.sh`（上手提示去 CLOUDFLARE 残留）。
- CI：`package` job 恢复可用；`validate` job 新增两个 ADR-028 用例且开关用例变真；
  `tests/windows_ci.sh` 40 → 47 项（新增 `default_data_root` / CRLF / 首次出现优先）。
- 文档：本 ADR、`AGENTS.md`（铁律/代码约定）、`README.md`、`docs/usage.md`、
  `docs/security.md`、`docs/papermc-template.md`、`CHANGELOG.md`
  （`windows-deployment.md` / `EXECUTION_PATH.md` 随后由 ADR-032 合并进 usage / AGENTS）。
- **兼容性**：无破坏性变更。唯一行为变化：Windows/macOS 上省略 `-d` 时的默认 `DATA_ROOT`
  改为文档一直宣称的值；旧装显式传 `-d` / `ORZMC_DATA_ROOT` 不受影响。已存在的
  `$DATA_ROOT/caddy/` 不会被删（需手工清理）。

### ADR-031：配置文件最小化（只留有消费者的字段）（2026-10-30）

**背景**：`compose.yaml` / `templates/*` 经多轮演进后夹带了无运行时作用的字段与历史注释：

- `expose:`（web/daemon/easybot 各一条）——Compose 里 `expose` **无任何运行时效果**
  （同网络容器任意端口可达，发布端口由 `ports` 决定），纯注释性；
- daemon 的 `/etc/timezone:/etc/timezone:ro`——已由 `TZ` env + `/etc/localtime` 覆盖，
  且 macOS 宿主无此文件（Docker Desktop 会建目录），属冗余且有平台隐患；
- `templates/env.papermc`——139 行"参数参考"，但字段名（`PAPERMC_INSTANCE_GROUP` /
  `ENVIRONMENT` / `WORLD_TEMPLATE` / `MAINTENANCE_WINDOW` / `HEALTHCHECK_*` 等）**并非
  MCSManager 实例字段**，且与 `docs/papermc-template.md` 逐字段重复（还写着违反文档的
  `25566:25566` 无协议端口）→ 双重漂移源；
- 三份模板与 compose 的头部注释大量重复 ADR/文档正文（历史背景、内存上限长篇解释），
  改一次行为要在 4 处同步叙述。

**决策**：配置只保留**有消费者**的字段，解释类内容一律指向文档单点：

1. `compose.yaml`：删除全部 `expose:`；删除 daemon 的 `/etc/timezone` 挂载（保留
   `/etc/localtime` + `TZ`）；注释压缩到每处 1–3 行（保留 issue/ADR 编号作为溯源），
   文件头只留「两个宿主发布端口 + daemon 不发布」。
2. `templates/env`：按用途分组、去掉重复表述；只保留 `required_env_list` 需要的键
   （15 个）+ 可选键的注释示例；内存/适配器/防火墙的长解释改为一行指向
   `docs/usage.md` / `docs/security.md`。
3. `templates/compose.site.yaml`、`templates/gateway.local.yaml`：头部注释压到 5–8 行。
4. **删除 `templates/env.papermc`**：字段参考唯一来源改为 `docs/papermc-template.md`
   （该文档本次同时去掉 `${PAPERMC_*}` 占位符写法，改为可直接录入的固定字符串）。
5. `.gitignore` 只留当前会用到的 3 项（`.env` / `.local-data/` / `.local-backups/`）；
   CI 的禁入路径守卫与 tar `--exclude` 继续覆盖旧目录名（防御纵深，不影响新仓库）。

**影响**：

- `compose.yaml` 128 → 88 行，`templates/env` 94 → 58 行，`templates/env.papermc`
  139 行整份删除，`compose.site.yaml` 34 → 22 行；
- 行为无变化：`docker compose config` 的发布端口/环境变量/卷与改前一致（`expose` 本就不
  生效），`init && validate`、`tests/windows_ci.sh` 全通过；
- 文档：`AGENTS.md` 目录地图、`docs/usage.md` 附录 B（"仅 expose"→"不发布到宿主"）、
  `docs/papermc-template.md`、`docs/architecture.md` §2 同步措辞。
- **回退**：只需 `git revert`；无数据/接口影响。

### ADR-032：文档收敛（10 → 8 个文件，README 回归落地页）（2026-10-30）

**背景**：文档总量 2567 行 / 10 个文件，问题不在"写得多"而在**同一件事写多遍**：

- `README.md`（169 行）复制了 usage 的运行模型表、命令表、安全章节与 CI 说明，用户读完仍要
  再读 usage；
- `docs/easybot.md`（128 行）与 `docs/usage.md` §7 大段重复（后台初始化、API key、插件
  `easybot.yml`、403 排查几乎逐字相同）；
- `docs/windows-deployment.md`（87 行）只服务一个平台差异，却单独成文件，用户排查时要跨文件
  跳转；
- `EXECUTION_PATH.md`（169 行）的「状态记录」是 CHANGELOG + `git log` 的副本，而「基线 /
  门禁 / 待办」本就是维护者守则的一部分；
- `docs/papermc-template.md` 里「建议的录入顺序 / 第一阶段建议 / 选填字段」与正文重复。

**决策**（按"一个读者任务 = 一个位置"重组）：

1. **README 只做落地页**（169 → 68 行）：是什么 / 快速开始 / 常用命令 / 关键约束 / 文档表 /
   安全一句话。细节一律外链，不再复述手册内容。
2. **删除 `docs/easybot.md`**，内容并入 `docs/usage.md` §7（后台与密钥、插件 `easybot.yml`、
   验证与 403、可选适配器与微信、运维注意）。
3. **删除 `docs/windows-deployment.md`**，压成 `docs/usage.md` 附录 F「Windows 平台要点」。
4. **删除 `EXECUTION_PATH.md`**：基线 / 本地门禁 / 待办并入 `AGENTS.md`「基线与门禁」；
   状态记录由 CHANGELOG 与 git 历史承担。
5. **`docs/papermc-template.md` 只留字段与坑**：删掉"录入顺序 / 第一阶段建议"等流程性废话，
   选填字段表压缩。
6. **`docs/architecture.md` 压缩历史 ADR**：ADR-001…022（多已废止或仅剩结论）由完整叙事
   压到 3–8 行决策/影响；ADR-024…032 保持完整（近期、仍被引用）。
7. `docs/security.md` 保持单职责（暴露面/限源/反代配方），仅压缩重复解释。

**影响**：

- 文件数 **10 → 8**（README、AGENTS、CHANGELOG + `docs/{usage,architecture,security,papermc-template}.md`
  + CLAUDE 入口 shim）；文档总量 ~2567 → **~1750 行**（−30%）。
- 信息无丢失：EasyBot/Windows 细节、门禁命令、待办全部搬入新位置；`AGENTS.md` 目录地图、
  README 文档表、各文档互链、`lib/common.sh` 与 CI 内的路径注释同步更新。
- 维护成本：改一处行为只需更新 usage 一个章节 + 对应 ADR，不再要求 3–4 份文档同步措辞。
- **回退**：`git revert` 即可恢复拆分（无代码/数据影响）。

### ADR-033：取消 `DATA_ROOT` 默认路径，必须显式指定（2026-10-30）

**背景**：ADR-030 为"消除文档与代码不一致"引入平台默认值（Linux `/srv/orzmc`、
macOS `/Users/Shared/orzmc`、Windows `E:/orzmc`）。实践下来这个"便利"是负收益：

- `DATA_ROOT` 装的是**全部数据、密钥与备份源**，猜错/沿用别人机器的路径代价很高
  （卷挂到意外磁盘、备份找不到、迁移漏数据）；
- 有默认值就必须在 README/文档里写死具体路径，而这些值来源于作者机器的磁盘布局，
  对其他部署是**误导性示例**；
- "不给路径也能跑"让人跳过"数据放哪、磁盘够不够、是否在 Docker 文件共享白名单内"
  这些本该在 init 前想清楚的决策。

**决策**：

1. 删除 `lib/common.sh` 的 `default_data_root`；`resolve_data_root` 只接受
   `-d/--data-root <路径>` 或 `ORZMC_DATA_ROOT`，**两者都没有时 `die` 并打印两种指定方式**。
2. 入口脚本（`orzmc.sh` / `deploy.sh` / `backup.sh` / `restore.sh`）改为**先解析 `-d`、
   再解析环境变量**，避免"还没读到参数就因缺默认值报错"；`lib/firewall.sh` 单独调用时
   同样解析。
3. `init` 把生效路径写入 `.env` 的 `DATA_ROOT`，`validate` 继续校验「env 内值与生效值一致」
   （防脚本用一个目录、卷挂到另一个）。
4. 文档与 README 不再列任何默认路径：只说明「必须显式指定」+ 选择要点（磁盘容量、
   Windows 原生路径与文件共享白名单、备份落在 `DATA_ROOT` 之外）。

**影响**：

- 行为变更（**有意**）：以前不带 `-d` 会回落到平台路径，现在直接报错退出。旧部署的
  `.env` 里已有 `DATA_ROOT`，但每次命令仍需 `-d`；长期使用建议 `export ORZMC_DATA_ROOT=...`。
- 代码：`lib/common.sh`、4 个入口脚本、`lib/firewall.sh`；测试删除平台默认断言，新增
  「ORZMC_DATA_ROOT 生效」「未指定时报错且给出指引」两项。
- 文档：README 快速开始与命令表全部带 `-d <你的数据目录>`；AGENTS 铁律、usage §3.2/§4.1/
  附录 A/附录 F 同步；`install.sh` 的手把手提示同样带 `-d`。
- **回退**：`git revert` 本 ADR 对应提交即可恢复平台默认（但文档里的路径示例会一并回来）。

### 已归档 ADR 索引（正文见 git 历史）

下列决策已废止或被取代，仅留索引避免后来者重复踩坑：

- **ADR-003** Caddy → Cloudflare Tunnel（2026-08-13，Phase 2）
- **ADR-005** daemon 经边缘层入口暴露（mcs-node，密钥鉴权）（2026-08-13，Phase 2）
- **ADR-008** 平台层常驻 MariaDB 数据库服务（2026-08-14）
- **ADR-009** 统一首页/状态页（Gatus，第 4 入口）（2026-08-14）
- **ADR-010** 统一状态页域名改为 orzmcs（2026-08-14）
- **ADR-011** 面板↔daemon 改 Docker 内网直连（隧道 socket.io 被 daemon koa 拦截）（2026-08-14）
- **ADR-012** lan 直连模式（无 TLS 终止边缘层，局域网）（2026-08-14）
- **ADR-013** prod 面板节点地址回改隧道 URL（浏览器直连恢复可用）（2026-08-15）
- **ADR-014** local/lan 面板节点地址改为浏览器可达地址（三档浏览器直连全部可用）（2026-08-15）
- **ADR-015** Windows(Docker Desktop/WSL2) 平台支持与适配（2026-08-16，Windows 实测）
- **ADR-016** Windows 平台支持脚本化（三平台统一命令，仅 daemon 走 docker run）（2026-08-16）
- **ADR-017** 单 profile + 可插拔边缘层 + 可插拔服务（2026-08-16，Windows 迁移演练后）
- **ADR-020** Windows mirrored 下 lan 档节点地址改内网名，浏览器直连不可用（2026-08-18，Windows 三档实机验收）
- **ADR-021** Mac→Windows 迁移四问题修复（#4–#7）（2026-09-09）
- **ADR-023** EasyBot 镜像升级 v0.0.41 / easybot 内存上限可调 / 端口映射文档（#14–#16）（2026-10-01）

## 7. 演进路径

- **未来候选**（尚未排期）：
  - Phase 3：环境自检脚本 / 自动化校验 / 升级回滚标准化。
  - PaperMC 插件端到端消息验证（依赖 monorepo 侧 OrzMC plugin）。
  - 备份保留策略与异地备份。
- **如何改动架构**：新增一条 ADR，说明背景/决策/影响；同步 `AGENTS.md`（如铁律变化）、
  `README.md`、`templates/*`、`docs/*`；跑 `./orzmc.sh -d /tmp/xx init && ./orzmc.sh -d /tmp/xx validate`。

## 8. 改动时需同步的位置清单

| 架构改动类型 | 必同步文件 |
|---|---|
| 服务增减 / 端口变更 | `compose.yaml`、`templates/env`、`README.md`、`docs/architecture.md`(ADR)、`AGENTS.md` |
| `.env` 必需变量增减 | `templates/env`、`lib/common.sh`(required_env_list / ENABLE_*) |
| 卷 / 网络调整 | `compose.yaml`、`lib/common.sh`(ensure_data_dirs) |
| 站点增量/站点特有配置 | `templates/compose.site.yaml`、`lib/common.sh`(collect_site_override_files)、`docs/usage.md` §4.5 |
| 镜像升级/回滚 | `compose.yaml`(digest)、`update-image-digests.sh`(映射) |
| 安全边界变化 | `docs/architecture.md`(ADR)、`AGENTS.md`(安全约束)、`docs/security.md`、`lib/firewall.sh`、`templates/env`(LAN_*/MC_*) |
| 文档索引 / 命令变化 | `README.md`(文档表)、`AGENTS.md`(目录地图/命令速查)、`orzmc.sh` usage |
| 文档结构调整 / 章节改名 | 全量互链检查（`docs/*.md` + README + AGENTS），`docs/usage.md` 目录 |
| 发布打包内容 | `.github/workflows/ci.yml`(`package` job 的 tar 文件清单，删文件时必须同步) |

---

