# OrzMC Docker 部署

[![CI](https://github.com/OrzMC/OrzMCDeploy/actions/workflows/ci.yml/badge.svg)](https://github.com/OrzMC/OrzMCDeploy/actions/workflows/ci.yml)

OrzMC 的最小容器化落地方案。平台层包括：

- `cloudflared`（生产，prod profile）作为公网入口——Cloudflare Tunnel 出站隧道，
  Cloudflare 边缘终止真实 HTTPS
- `Caddy`（本地验证，local profile）作为 `.localhost` 反代 + 本地 CA
- **lan profile**（无边缘层）：4 个源站直接发布宿主端口，纯 HTTP，局域网设备直连
- `MCSManager Web` + `MCSManager Daemon` 管理实例
- `EasyBot` 统一 IM 网关（QQ / Telegram / Discord / 飞书 / 微信）
- `MariaDB` 应用数据库（默认启用，供 PaperMC 插件使用，仅内网可达）
- `Gatus` 统一状态页（第 4 入口 `orzmcs.<domain>`，聚合产品入口 + 实时健康）

`PaperMC` 不直接写在 `compose.yaml` 中，而是由 `MCSManager` 创建和管理。

> **完整使用指南见 [`docs/usage.md`](docs/usage.md)**：从零安装、配置、日常运维、
> 管理 PaperMC 实例、EasyBot 接入、故障排查与整服迁移的全生命周期分步操作。
>
> **AI 智能体与协作者请先读 [`AGENTS.md`](AGENTS.md)**：仓库的架构铁律（运行时与数据
> 分离）、三 Profile、网络拓扑与安全约束；架构设计与决策记录见
> [`docs/architecture.md`](docs/architecture.md)。
>
> 如果要推进部署方案，请优先阅读 [`EXECUTION_PATH.md`](EXECUTION_PATH.md)：执行路径、
> 门禁规则与 checklist。

## 架构原则：运行时与数据分离

**仓库只承载"运行时"**——compose 编排、镜像 digest、部署脚本、配置模板；
**全部配置与数据通过卷映射落在宿主机统一目录 `$DATA_ROOT`**（生产 macOS
`/Users/Shared/orzmc`，Linux 默认 `/srv/orzmc`，Windows `windows.sh` 默认 `E:/orzmc`，
本地 `.local-data/`）。由此获得：运行时独立演进、数据独立备份/还原/迁移、密钥不进入仓库。

**三平台统一命令**（macOS / Linux / Windows）：同一套 `init|start|stop|status|validate|backup`
在任意平台行为一致。Windows（Docker Desktop/WSL2）下脚本自动完成 daemon 的
`docker run --mount` 创建、服务名别名补丁与 MSYS→原生路径转换（ADR-016）；仅 daemon
一个容器脱离 compose 管理（其实例自挂载卷 target 含驱动器冒号，compose 无法创建，
结构性必然）。详见 [`docs/windows-deployment.md`](docs/windows-deployment.md)。

## 三 Profile（local / prod / lan）

| Profile | 边缘层 | 用途 | 入口 |
|---|---|---|---|
| `local` | Caddy（`.localhost` + 本地 CA + 非特权端口） | 本地验证 / 回归 | `mcs.localhost` / `easybot.localhost` / `mcs-node.localhost` / `orzmcs.localhost` |
| `prod` | cloudflared（Cloudflare Tunnel） | 生产（NAT 内网免开端口） | `mcs.<domain>` / `easybot.<domain>` / `mcs-node.<domain>` / `orzmcs.<domain>` |
| `lan` | 无边缘层（`compose.lan.yaml` 发布宿主端口，纯 HTTP，无域名/TLS） | 局域网直连（可信内网） | `http://<LAN_HOST_IP>:<LAN_*_PORT>`（web / easybot / status / daemon 四入口） |

公网/本地暴露 **4 个入口**：`mcs`（MCSManager 面板）、`easybot`（EasyBot 管理后台）、
`mcs-node`（daemon 直连，daemon key 鉴权）、`orzmcs`（Gatus 统一状态页，聚合入口 +
实时健康，页面无鉴权仅状态、不含密钥）。lan 无边缘层，同 4 个源站改为发布宿主
`LAN_*_PORT` 端口、纯 HTTP（ADR-012）。**EasyBot 插件 API 仅内网**——插件挂
`orzmc_default` 网络直连 `http://easybot:8080`，无 `easybot-api` 子域名。

## 快速上手（本地体验）

```bash
git clone <你的仓库地址> orzmc-deploy && cd orzmc-deploy
./local.sh init      # 生成 .local-data/.env
./local.sh start     # 启动平台层（local profile）
./local.sh status    # 查看状态与访问地址（mcs.localhost:18443 等）
```

生产上线（Cloudflare Tunnel）、局域网直连（lan profile）、完整命令与每步预期输出，见
[`docs/usage.md`](docs/usage.md) 第 3 章。

## 命令速查

| 场景 | 本地 | 局域网（lan） | 生产（macOS/Linux） | Windows |
|---|---|---|---|---|
| 初始化目录/env/边缘配置 | `./local.sh init` | `./lan.sh init` | `deploy.sh -d <DATA_ROOT> init` | `./windows.sh init` |
| 启动平台层 | `./local.sh start` | `./lan.sh start` | `deploy.sh -d <DATA_ROOT> up` | `./windows.sh start` |
| 停止 | `./local.sh stop` | `./lan.sh stop` | `deploy.sh -d <DATA_ROOT> stop` | `./windows.sh stop` |
| 状态与访问地址 | `./local.sh status` | `./lan.sh status` | `deploy.sh -d <DATA_ROOT> status` | `./windows.sh status` |
| 校验配置 | `./local.sh validate` | `./lan.sh validate` | `deploy.sh -d <DATA_ROOT> validate` | `./windows.sh validate` |
| 备份数据 | `./local.sh backup` | `./lan.sh backup` | `backup.sh -d <DATA_ROOT> --stop`（含 MariaDB 逻辑备份） | `./windows.sh backup` |
| 还原/迁移 | `./restore.sh -d <目标> <归档>` | `restore.sh -d <目标> -p lan <归档>` | `restore.sh -d <目标> <归档> --force` | 同左 |
| 刷新镜像 digest | `./update-image-digests.sh [服务]` | 同左 | 同左 | 同左 |

`<DATA_ROOT>` 优先级：`-d/--data-root` 参数 > `ORZMC_DATA_ROOT` 环境变量 > 默认值。
生产 macOS 用 `-d /Users/Shared/orzmc`；Linux 默认 `/srv/orzmc`；Windows 用
`./windows.sh`（默认 `E:/orzmc`，可 `-d` 或 `ORZMC_DATA_ROOT` 覆盖）。Windows 下
`windows.sh stop && windows.sh start` 即完成 daemon 重建（compose 无法管理它）。

## 质量门禁（CI）

push 到 `main` 或开 PR 时，GitHub Actions 自动跑三道校验（见 `.github/workflows/ci.yml`）：

- **lint**：shell 语法（`bash -n`）+ `shellcheck`（含 `tests/`）+ 模板 YAML 解析 + 禁入路径守卫
  （`.env` / `.local-data*` / `.local-backups*` 永不入库）
- **validate**：`local` / `lan` / `prod` 三 profile 各自 `init && validate`
  （必需环境变量检查 + `docker compose config -q`，纯解析不拉镜像、不触碰 `$DATA_ROOT`）
- **windows-branch**：Windows 分支逻辑（ADR-016）单元测试——mock `uname` 强制 MINGW，
  校验 `win_path` / `win_daemon_*` / `compose_cmd` Windows 分支的命令构造（`tests/windows_ci.sh`）。
  覆盖主 job 在 Linux 上走不到的 Windows 特有代码路径。

本地想先自查同一套检查，跑 `./local.sh init && ./local.sh validate` 覆盖 env 与
compose 解析；`bash tests/windows_ci.sh` 覆盖 Windows 分支；`shellcheck *.sh lib/*.sh tests/*.sh`
覆盖静态检查。

## 文档导航

- [`docs/usage.md`](docs/usage.md) —— **用户使用指南**（全生命周期分步操作）
- [`docs/architecture.md`](docs/architecture.md) —— 架构设计文档（含 ADR 决策记录）
- [`docs/easybot.md`](docs/easybot.md) —— EasyBot 网关与插件 `easybot.yml` 配置指南
- [`docs/papermc-template.md`](docs/papermc-template.md) —— PaperMC 实例录入参数参考
- [`docs/windows-deployment.md`](docs/windows-deployment.md) —— **Windows 平台部署指南**（问题/根因/解法，含 ADR-015/016，三平台统一命令）
- [`AGENTS.md`](AGENTS.md) / [`CLAUDE.md`](CLAUDE.md) —— AI 智能体守则
- [`EXECUTION_PATH.md`](EXECUTION_PATH.md) —— 执行路径、门禁、checklist、状态记录

## 安全

- `$DATA_ROOT/.env`（含 `MARIADB_*`）、cloudflared 凭据（`cert.pem`、隧道 `<id>.json`）、
  daemon key（`global.json`）、MariaDB 逻辑备份（`database/dumps/*.sql`）均属密钥：
  权限收紧、随数据备份、**永不入库**。
- 公网仅暴露 4 个入口（`mcs` / `easybot` / `mcs-node` / `orzmcs`，状态页不含密钥）；
  `mcsmanager-daemon` 挂载 `/var/run/docker.sock`，宿主机须视为可信环境。
  **lan 无边缘层**：面板口令与 daemon 端口以明文 HTTP 暴露给局域网（daemon key 鉴权，
  可管理 docker.sock），**仅限可信局域网**（ADR-012）。
  详见 [`docs/usage.md`](docs/usage.md) 第 8 章。
