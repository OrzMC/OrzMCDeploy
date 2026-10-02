# Changelog

本文件记录 OrzMC Deploy 的对外发布变更。格式参考
[Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循
[语义化版本](https://semver.org/lang/zh-CN/)：

- **主版本**：架构铁律 / 数据布局不兼容变更
- **次版本**：新平台、新服务、新入口等向后兼容能力
- **修订版本**：向后兼容的缺陷修复与文档

> 免克隆安装（`install.sh`）默认拉取**最新 Release**；因此每个 Release 的 tarball 决定
> 新装用户拿到的运行时版本。详见 [ADR-018](docs/architecture.md)。

## [Unreleased]

## [0.0.6] - 2026-10-01

### 修复

- **easybot 内存上限缺省值由 `1G` 回调为 `512M`**（`EASYBOT_MEMORY_LIMIT` 仍可调）：v0.0.41
  已修掉空载内存泄漏（上游 #139），放大上限反而会**掩盖**未来的内存回归；恢复与原硬编码值
  一致的紧上限，让异常增长尽快由 OOM/重启暴露（ADR-024，修正 ADR-023 的上限决策）。

## [0.0.5] - 2026-10-01

### 修复

- **easybot 镜像升级到 v0.0.41**（digest `cd0b4e44…` → `23a6eace…`）：含 SQLite 权限加固
  失败不再中止初始化（Windows bind mount 的 `EPERM` 不再退回内存库）、存储降级显式上报
  （`/api/v1/ready` 503）、以及近空载匿名内存泄漏（上游 #139）修复——一并解决 [#14]/[#16]。
- **easybot 内存上限不再硬编码 512M**：改为 `.env` 的 `EASYBOT_MEMORY_LIMIT` 派生
  （缺省 `1G`），消除 `restart: unless-stopped` 下的 cgroup OOM 重启风暴（[#16]）。

### 文档

- `docs/papermc-template.md` 新增「端口映射与多实例分配（Geyser/基岩必读）」：端口必须从
  实例实际配置推导并逐条 `宿主:容器/协议` 显式发布（含 `19132/udp`），多实例宿主端口分配
  范式，`clone-remote-port` 语义，云隧道不承载 UDP（[#15]）。
- `docs/windows-deployment.md` §9.1/§9.4 补「先在 `docker.ports` 发布端口、防火墙规则才
  生效」前提；§10 P2 补宿主 TUN 代理抢路由导致「内网通、外网静默不可达」的判定与策略路由修法。
- `docs/usage.md` 附录 F 新增「平台层各服务内存上限（可调）」表；`README.md` 同步。

## [0.0.4] - 2026-09-11

### 修复

- **Windows**：daemon 创建时检测到 docker 型实例（`processType: docker`）会**自动忽略**
  `DAEMON_PORTS`（不再仅告警），避免 daemon 抢占 25565 → 实例启动报
  `port is already allocated`（[#9]）；三个 `templates/env.*` 的 `DAEMON_PORTS` 默认
  注释置空。
- **daemon 内存/堆对齐**：容器上限与 Node 堆上限由 `.env` 的 `DAEMON_MEMORY_LIMIT`
  （默认 `512M`）/ `DAEMON_NODE_HEAP_MB`（默认 `384`）派生，并**覆盖镜像 CMD**
  （`node --max-old-space-size=<heap> app.js`，命令行 flag 优先于 `NODE_OPTIONS`），
  消除 512M 上限 vs 8G 堆的 OOM kill 风险；daemon 补 TCP healthcheck（[#10]）。
- **实例配置持久化**：纠正「改 JSON 后 `docker restart daemon`」的错误姿势——daemon
  退出时会把内存副本刷回磁盘、覆盖改动；正确顺序为**停 daemon → 改 JSON → 启 daemon**
  （[#12]，`docs/usage.md` §6.5 / `docs/papermc-template.md`）。
- **install.sh**：默认仓库名修正为 `OrzMC/OrzMCDeploy`（原 `orzmc/orzmc-deploy` 请求
  GitHub API 返回 404，免克隆安装的默认路径不可用）；README 一键脚本 URL 补全为真实仓库。

### 新增

- **站点增量挂载点**：`init` 生成 `$DATA_ROOT/compose.site.yaml`，`compose_cmd` 检测到即
  自动 `-f` 追加；站点特有增量（飞书凭据、额外 env/挂载）写这里，升级换包不丢；另支持
  `.env` 的 `COMPOSE_FILE_EXTRA`（空格/逗号分隔，任意路径）（[#11]，ADR-022）。
- daemon 新增 TCP healthcheck（compose 与 Windows `docker run` 两侧同步）。

### 文档

- `docs/usage.md` 新增 §4.5（站点增量 override）；§6.5 重写为「生命周期与配置持久化」
  （配置权威来源/回写时机、`autoStart`/`autoRestart` 语义、手动启停姿势）（[#12]）。
- 新增 ADR-022（#9–#12 四项修复）；`docs/windows-deployment.md` §10 P9/P12/P13、
  `docs/papermc-template.md`、`README.md`、`AGENTS.md` 同步。

## [0.0.3] - 2026-09-10

### 修复

- **Windows**：`win_daemon_run` 补 `MCSM_DOCKER_WORKSPACE_PATH`，docker 型实例 `cwd`
  bind source 不再报 `bind source path does not exist`（[#4]）。
- **还原**：`restore.sh` 取归档顶层目录改用 `{ tar tzf … | head -n1; } || true`，
  消除大归档 SIGPIPE(141) 导致还原中途退出（[#5]）。
- **MariaDB**：healthcheck 改 root 经 unix socket + `MARIADB_ROOT_PASSWORD` 的 innodb
  就绪查询，修复冷数据还原后缺 `mysql@localhost` unix_socket 账号导致的 unhealthy
  误报（[#7]）。
- **Windows**：daemon 裸 `docker run` 补 `--memory 512m`，与 compose 限额对齐（[#3]）。
- **compose**：daemon 补 `MCSM_DOCKER_WORKSPACE_PATH`（macOS/Linux docker 型实例，
  ADR-019 移除 `instances/` 时误删）（[#1]）。
- **Windows**：`win_daemon_run` 相对路径 `DATA_ROOT` 先绝对化再 `win_path`，修复
  `.local-data` 下 `docker run --mount` 报 `invalid mount path`（549f03c）。
- **templates**：`env.local` / `env.lan` 补 `DAEMON_PORTS`（ADR-016 遗漏同步，5c13047）。

### 变更

- **Windows**：daemon 创建/复用时检测 docker 型实例与 `DAEMON_PORTS` 的宿主端口冲突并
  告警；模板/文档注明用 docker 型实例须置空 `DAEMON_PORTS`（[#6]）。
- **compose**：容器资源上限——`mcsmanager-web`/`daemon`/`easybot`/`mariadb` 512M，
  `status`/`cloudflared` 256M（[#2]）。
- **架构**：移除 `instances/` 目录，实例数据统一由 MCSManager 面板管理
  `daemon/data/InstanceData/<uuid>/`（ADR-019）。

### 文档

- 新增 ADR-020（Windows mirrored 下 lan 档节点地址改内网名，浏览器直连不可用）、
  ADR-021（Mac→Windows 迁移四问题修复）。
- `docs/windows-deployment.md`：三档部署/节点/实例/验收全流程（§9）+ 踩坑 P1–P11（§10）。
- `docs/acceptance.md`：Windows 三档实机验收实录。
- `docs/usage.md`：补免克隆安装入口、冷数据还原后 MariaDB healthcheck 说明。

## [0.0.2] - 2026-08-16

### 新增

- **Windows 平台支持**（ADR-015/016）：三平台统一命令；daemon 因实例自挂载 target 含
  驱动器冒号改用脚本化 `docker run`，附 `win_path` / 服务名别名补丁；新增
  `docs/windows-deployment.md`。
- **单 profile + 可插拔边缘层/服务**（ADR-017）：`EDGE=cloudflare|local|lan|none` +
  `ENABLE_EASYBOT`/`ENABLE_MARIADB`/`ENABLE_STATUS`，统一入口 `./orzmc.sh`。
- **免克隆部署**（ADR-018）：`install.sh` + GitHub Release tarball（CI `package` job，
  sha256 校验）。
- **CI 质量门禁**：`lint`（`bash -n` + shellcheck + 模板 YAML + 禁入路径守卫）、
  `validate`（EDGE×ENABLE 组合）、`windows-branch`（Windows 分支单测）。

### 修复

- 新版 shellcheck 对测试 mock 的 SC2317 误报（ca9d53a）。
- `orzmc.sh` 可执行位缺失（`git update-index --chmod=+x`，3aa4cc9）。
- tag 推送未触发 CI，`on.push` 增加 `tags:['v*']`（a52b72f）。

## [0.0.1] - 2026-08-15

### 新增

- 首个对外发布：Docker Compose 平台层——MCSManager Web/Daemon、EasyBot 统一 IM 网关、
  MariaDB 应用数据库、Gatus 统一状态页、cloudflared / Caddy 边缘层。
- 三档部署：`prod`（Cloudflare Tunnel）、`local`（Caddy `.localhost`）、`lan`（无边缘层，
  4 源站发宿主端口）。
- 运行时与数据分离（运行时在仓库、数据/密钥在 `$DATA_ROOT`）与整机 `backup.sh` /
  `restore.sh` 迁移。
- 文档：`README`、`docs/architecture.md`（ADR-001–014）、`docs/usage.md`、
  `docs/easybot.md`、`docs/papermc-template.md`。

[Unreleased]: https://github.com/OrzMC/OrzMCDeploy/compare/v0.0.6...HEAD
[0.0.6]: https://github.com/OrzMC/OrzMCDeploy/compare/v0.0.5...v0.0.6
[0.0.5]: https://github.com/OrzMC/OrzMCDeploy/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/OrzMC/OrzMCDeploy/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/OrzMC/OrzMCDeploy/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/OrzMC/OrzMCDeploy/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/OrzMC/OrzMCDeploy/releases/tag/v0.0.1
[#1]: https://github.com/OrzMC/OrzMCDeploy/pull/1
[#2]: https://github.com/OrzMC/OrzMCDeploy/pull/2
[#3]: https://github.com/OrzMC/OrzMCDeploy/pull/3
[#4]: https://github.com/OrzMC/OrzMCDeploy/issues/4
[#5]: https://github.com/OrzMC/OrzMCDeploy/issues/5
[#6]: https://github.com/OrzMC/OrzMCDeploy/issues/6
[#7]: https://github.com/OrzMC/OrzMCDeploy/issues/7
[#9]: https://github.com/OrzMC/OrzMCDeploy/issues/9
[#10]: https://github.com/OrzMC/OrzMCDeploy/issues/10
[#11]: https://github.com/OrzMC/OrzMCDeploy/issues/11
[#12]: https://github.com/OrzMC/OrzMCDeploy/issues/12
[#14]: https://github.com/OrzMC/OrzMCDeploy/issues/14
[#15]: https://github.com/OrzMC/OrzMCDeploy/issues/15
[#16]: https://github.com/OrzMC/OrzMCDeploy/issues/16
