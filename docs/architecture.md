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
- **可验证、可回滚**：镜像 digest 锁定 + git commit；`./orzmc.sh validate` 做配置门禁。

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

- **状态**：已实施。
- **背景**：需要一个统一 IM 网关承载 QQ / Telegram / Discord / 飞书 / 微信多平台消息。
- **决策**：采用 EasyBot 作为统一 IM 网关；QQ 适配器使用 QQ 开放平台官方 bot 凭据
  （AppID + ClientSecret）。
- **影响**：`docs/easybot.md` 记录了接入模型；监听器仅 HTTP（ADR-027 后只在局域网暴露，
  对公网暴露须站点自备 TLS 反代或 VPN）。

### ADR-002：运行时与数据分离（2026-08-13）

- **状态**：已实施。
- **背景**：Phase 1 重构目标——运行时与数据解耦，独立演进与备份/迁移。
- **决策**：仓库只承载运行时；全部配置/数据通过卷映射落 `$DATA_ROOT`；脚本统一
  `compose_cmd --env-file $DATA_ROOT/.env`。
- **影响**：`README.md` 架构原则、`AGENTS.md` 铁律第 1-2 条。

### ADR-004：EasyBot 插件 API 仅内网（2026-08-13）

- **状态**：已实施。入口数量部分被 **ADR-005** 修正（公网入口 2→3，新增
  `mcs-node`）；"不设 `easybot-api` 子域名" 部分仍有效。
- **背景**：插件与 EasyBot 同属 `orzmc_default` 网络，无公网暴露需求；且内网直连
  不经 Cloudflare 边缘（规避免费版 ~100s HTTP/WS 空闲超时限制）。
- **决策**：公网只暴露 `mcs.<domain>` / `easybot.<domain>` 两个控制台入口；插件
  `easybot.yml` 直连 `http://easybot:8080`（REST + WS）。不设 `easybot-api` 子域名。
- **影响**：`templates/cloudflared-config.yml` ingress 仅两条 + 兜底 404；`DOMAIN_EASY_API`
  从环境变量中移除。

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
  `instances/` 自挂载与 `MCSM_DOCKER_WORKSPACE_PATH`。见本页 ADR-019。

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
4. `templates/env.papermc` 参考路径改为 `.../data/InstanceData/<uuid>/`
   （该文件已于 ADR-031 删除，字段参考统一看 `docs/papermc-template.md`）。

**影响**：
- compose.yaml / lib/common.sh / tests/windows_ci.sh 同步移除相关挂载与断言。
- 备份/恢复**无变化**（本就整包打包 `$DATA_ROOT`，InstanceData 已含）。
- 升级路径：`orzmc.sh stop` 后 `docker rm` daemon → `orzmc.sh up` 重建（去掉 instances 挂载），
  删除 `$DATA_ROOT/instances`；已有实例数据在 `InstanceData/`，不受影响。

### ADR-022：站点增量挂载点 / DAEMON_PORTS 自动忽略 / daemon 堆-限额对齐（#9–#12）（2026-09-10）

**背景**：0.0.3 发布后远端提交 4 个 issue（#9–#12），均为「默认值/文档让用户踩坑」型：

1. **#9 `DAEMON_PORTS` 默认非空 + 仅告警**：模板默认 `25565:25565/tcp,19132:19132/udp`，
   用户按模板部署（docker 型实例）时 daemon 先抢宿主 25565，实例启动报
   `port is already allocated`——表现为「实例起不来」，且 daemon 创建时实例尚不存在，
   仅告警无法阻止窗口期。
2. **#10 daemon 容器 512M vs 镜像 CMD `--max-old-space-size=8192`**：V8 按 8G 规划堆，
   重负载有 cgroup OOM kill 风险；daemon 无 healthcheck，被杀后实例失去跟踪。两数字分居
   `compose.yaml` / `win_daemon_run`，易漂移。
3. **#11 无官方站点增量挂载点**：站点特有的 `FEISHU_*` / 额外 env/挂载只能改包内
   `compose.yaml`，升级换包即丢（「升级后机器人不工作」），无 diff 提示。
4. **#12 实例配置持久化语义未文档化**：`InstanceConfig/<uuid>.json` 是 daemon 内存缓存 +
   刷盘副本，运行中改会被回写；先改再 `docker restart` 也会被退出刷盘覆盖；`autoStart` /
   `autoRestart` 语义与手动启停姿势无文档。

**决策**：

1. **站点增量挂载点 `$DATA_ROOT/compose.site.yaml`**（issue #11）：`init` 生成模板（绝不
   覆盖），`compose_cmd` 通过 `collect_site_override_files` 检测到即自动 `-f` 追加；另支持
   `.env` 的 `COMPOSE_FILE_EXTRA`（空格/逗号分隔）追加任意路径 compose 文件。文件在
   `$DATA_ROOT`，随数据备份/迁移，与包内文件彻底解耦。**不提供仓库内 site 文件**（铁律：
   配置/密钥不入库）。
2. **`DAEMON_PORTS` 自动忽略 + 模板默认置空**（issue #9）：新增 `find_docker_instance` /
   `win_effective_daemon_ports`，Windows daemon 创建时扫描 `InstanceConfig/*.json`，检测到
   `processType: docker` 即**忽略** `DAEMON_PORTS`（info 说明；存量 daemon 额外提示重建）；
   `templates/env`（当时为三份 `env.*`）把 `DAEMON_PORTS` 默认**注释置空**，消除「daemon 先创建抢端口」
   窗口。macOS/Linux daemon 走 compose 不消费该变量，无影响。
3. **daemon 内存/堆对齐 + healthcheck**（issue #10）：内存上限与 Node 堆上限收敛到 `.env`
   的 `DAEMON_MEMORY_LIMIT`（默认 `512M`）/ `DAEMON_NODE_HEAP_MB`（默认 `384`），compose 与
   Windows `docker run` 共用；**覆盖镜像 CMD** 为 `node --max-old-space-size=<heap> app.js`
   （命令行 flag 优先级高于 `NODE_OPTIONS`，仅设 env 无效）；daemon 增 TCP healthcheck
   （node net 探 `24444`）。
4. **实例生命周期文档**（issue #12）：`docs/usage.md` §6.5 改名为「生命周期与配置持久化」，
   写清配置权威来源（daemon 内存 + 刷盘）、正确顺序「停 daemon → 改 JSON → 启 daemon」、
   `autoStart`/`autoRestart` 语义与表格、完全手动启停做法；`papermc-template.md` 与
   `windows-deployment.md` P13 同步。

**影响**：
- 代码：`lib/common.sh`（site override + `win_effective_daemon_ports` + `win_daemon_run`
  内存/堆/健康检查）、`deploy.sh`（init 生成 site 模板）、`compose.yaml`（daemon
  command/healthcheck/limits）、`templates/compose.site.yaml`（新增）、`templates/env`。
- 测试：`tests/windows_ci.sh` 新增 #9/#10/#11 断言（Windows 分支命令构造）。
- 文档：`README.md`、`docs/usage.md` §4.5/§6.5、`docs/architecture.md`（本 ADR + §5/§8）、
  `docs/windows-deployment.md` §4/§7、`AGENTS.md`、`CHANGELOG.md`、
  `EXECUTION_PATH.md`。
- **兼容性**：新增 `.env` 变量均**可选带默认值**（不入 `required_env_list`）；site override
  为新增可选文件；`DAEMON_PORTS` 仅在用户显式启用且无 docker 型实例时生效。旧 `.env`
  无需改动即可升级（唯一行为差异：非空 `DAEMON_PORTS` 在 docker 型实例存在时不再发布）。

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

1. **MariaDB（ADR-008）从未被使用**：`SHOW DATABASES` 显示 `papermc` 库 **0 张表**，
   两个实例的 LuckPerms 均为 `storage-method: h2`，AuthMe/EzShops/GriefPrevention
   全走本地存储，`information_schema.processlist` 无业务连接。
   它的真实成本却一直在：1 个容器（109 MB 常驻）、162 MB 数据目录、每次备份一次的
   `mariadb-dump`（+`dumps/` 轮转）、4 个 `.env` 变量（含 2 个密钥）、
   issue #7 专门重写的 healthcheck，以及 `db_root_pw`/`wait_for_mariadb`/
   `dump_db_logical` 共 48 行库代码。
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
  "固定内网名 + 面板中转"）、`docs/windows-deployment.md` §3/§4、本文件 §2/§3；
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
  也可用 VPN/反代；Cloudflare 隧道受跨境路由影响（实测到边缘 TTFB 中位数 0.76 s，
  且关掉代理直连 CF 时 `connect` 0.19–0.52 s、2/6 请求失败），维护成本高而收益低。
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
| L3 宿主防火墙 | `./orzmc.sh firewall apply`，来源取 `LAN_CIDR` + `ALLOW_EXTRA_CIDRS` | 仅 `192.168.0.0/24` |

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
（Docker Desktop 4.95 / compose 29.8）**Windows 原生 compose 能正常创建 daemon**
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
5. **`read_env_value` 语义固定并容错**：同名键**首次出现优先**（写入注释）、剥除 CRLF
   （Windows 编辑器写出的 `\r` 会让 `ENABLE_EASYBOT` / `LAN_BIND_ADDR` 静默失效）。
6. **删 `ensure_data_dirs` 里的 `caddy/`**：ADR-027 后无边缘层，新装不再建这个空目录。
7. **`firewall` 平台行为对齐文档**：Linux `show` 的端口正则改逐端口拼接（原实现末尾
   `|` 导致 `grep -E` 匹配全部行，且 `25565,25566` 永远匹配不到）；macOS `apply` 改为
   打印等价 `pf` 规则（原实现实际打印 iptables）；缺 `.env` 时直接拒绝（不再用缺省值
   建规则）。
8. **文档与实现对齐**：AGENTS/README/usage/windows-deployment/papermc-template 清理
   边缘层与 `-e <edge>` 残留；`windows-deployment.md` 不再教用户写 `-RemoteAddress Any`
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
  `docs/security.md`、`docs/windows-deployment.md`、`docs/papermc-template.md`、
  `EXECUTION_PATH.md`、`CHANGELOG.md`。
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
   `docs/usage.md` / `docs/security.md` / `docs/easybot.md`。
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
  - Phase 3：环境自检脚本 / 自动化校验 / 升级回滚标准化（见 `EXECUTION_PATH.md`）。
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
| 文档索引 / 命令变化 | `README.md`、`AGENTS.md`、`orzmc.sh` usage |
| 发布打包内容 | `.github/workflows/ci.yml`(`package` job 的 tar 文件清单，删文件时必须同步) |

---

