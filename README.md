# OrzMC Docker 部署

[![CI](https://github.com/OrzMC/OrzMCDeploy/actions/workflows/ci.yml/badge.svg)](https://github.com/OrzMC/OrzMCDeploy/actions/workflows/ci.yml)

OrzMC 的最小容器化落地方案。平台层包括：

- **局域网直连**：面板与 EasyBot 直接发布宿主端口（纯 HTTP），局域网设备访问
- 对外访问由站点自备（DDNS + 端口映射 / 反向代理 / VPN），**本仓库不管理**
- `MCSManager Web` + `MCSManager Daemon` 管理实例
- `EasyBot` 统一 IM 网关（QQ / Telegram / Discord / 飞书 / 微信）

> 需要数据库 / 状态页时，按站点增量（`compose.site.yaml`）自行加回（ADR-025/027）。

`PaperMC` 不直接写在 `compose.yaml` 中，而是由 `MCSManager` 创建和管理。

> **完整使用指南见 [`docs/usage.md`](docs/usage.md)**：从零安装、配置、日常运维、
> 管理 PaperMC 实例、EasyBot 接入、故障排查与整服迁移的全生命周期分步操作。
>
> **AI 智能体与协作者请先读 [`AGENTS.md`](AGENTS.md)**：仓库的架构铁律（运行时与数据
> 分离）、运行模型、网络拓扑与安全约束；架构设计与决策记录见
> [`docs/architecture.md`](docs/architecture.md)。
>
> 如果要推进部署方案，请优先阅读 [`EXECUTION_PATH.md`](EXECUTION_PATH.md)：执行路径、
> 门禁规则与 checklist。

## 架构原则：运行时与数据分离

**仓库只承载"运行时"**——compose 编排、镜像 digest、部署脚本、配置模板；
**全部配置与数据通过卷映射落在宿主机统一目录 `$DATA_ROOT`**（生产 macOS
`/Users/Shared/orzmc`，Linux 默认 `/srv/orzmc`，Windows 默认 `E:/orzmc`）。由此获得：
运行时独立演进、数据独立备份/还原/迁移、密钥不进入仓库。

**三平台统一命令**（macOS / Linux / Windows）：同一套 `init|up|stop|status|validate|backup|firewall`
在任意平台行为一致。Windows（Docker Desktop/WSL2）下脚本自动完成 MSYS→原生路径转换；
daemon 默认由 compose 管理，仅进程模式实例需要注入 `DAEMON_PORTS` 时才走 `docker run`
（ADR-029）。详见 [`docs/windows-deployment.md`](docs/windows-deployment.md)。

## 运行模型：只有局域网模式（ADR-027）

一个运行集、零边缘层，全部在 `$DATA_ROOT/.env` 里配置，唯一入口 `./orzmc.sh`：

| 维度 | 配置（`.env`） | 说明 |
|---|---|---|
| 局域网入口 | `LAN_HOST_IP` / `LAN_MCS_WEB_PORT`(18090) / `LAN_EASYBOT_PORT`(18091) | 面板与 EasyBot 发布到宿主端口，纯 HTTP |
| 可选服务 | `ENABLE_EASYBOT`（缺省 `true`） | 置 `false` 即停用 EasyBot；核心 web/daemon 常驻 |

**2 个局域网入口**：`http://<LAN_HOST_IP>:18090`（MCSManager 面板）、
`http://<LAN_HOST_IP>:18091`（EasyBot 管理后台）。

- **daemon 不发布任何端口**（ADR-026）：MCSManager 10.22 的面板中转数据面
  （`dataPlane=proxy`）让浏览器↔daemon 流量经面板端口，节点地址固定内网名
  `ws://mcsmanager-daemon:24444`。终端/控制台/文件管理照常可用。
- **EasyBot 插件 API 仅内网**：插件挂 `orzmc_default` 网络直连 `http://easybot:8080`。
- **对外访问**：在路由器做 DDNS + 端口映射，或在前面加反向代理/VPN——暴露哪个端口、
  是否加 TLS 都由你决定。⚠️ 面板默认口令登录、无 TLS，直接映射到公网前请务必加
  TLS 反代（或用 VPN 而非公网映射），并换成强口令。

**站点增量与升级不丢**（ADR-022）：站点特有配置（如飞书 `FEISHU_*`、额外 env/挂载）
写入 `$DATA_ROOT/compose.site.yaml`（`init` 生成、存在即自动 `-f` 追加），升级换包不丢；
也可用 `.env` 的 `COMPOSE_FILE_EXTRA=` 追加任意路径 compose 文件。详见
[`docs/usage.md` §4.5](docs/usage.md)。daemon 容器内存与 Node 堆上限由 `.env` 的
`DAEMON_MEMORY_LIMIT` / `DAEMON_NODE_HEAP_MB` 派生（缺省 `512M` / `384`），并带 TCP healthcheck；
easybot 内存上限由 `.env` 的 `EASYBOT_MEMORY_LIMIT` 派生（缺省 `512M`，issue #16/ADR-024）。

## 免克隆安装（无需 git clone）

从 GitHub Release 下载"运行时" tarball 即可，无需克隆仓库（无 `.git`、无数据/密钥，铁律：
运行时与数据分离，见 ADR-018）：

```bash
# 一键安装最新 release 到默认目录（~/.local/share/orzmc-deploy）
curl -fsSL https://raw.githubusercontent.com/OrzMC/OrzMCDeploy/main/install.sh | bash

# 或指定版本 / 安装目录 / 仓库
curl -fsSL https://raw.githubusercontent.com/OrzMC/OrzMCDeploy/main/install.sh \
  | bash -s -- -v v1.2.3 -d /opt/orzmc-deploy

# 装好后与 git clone 部署完全一致：
cd <安装目录>
./orzmc.sh init                # 建目录树 + 生成 .env
./orzmc.sh validate             # 校验配置
./orzmc.sh up                   # 启动
```

- 脚本会**校验 tarball 的 sha256**（防篡改/损坏），失败即中止。
- **幂等**：可重复运行；运行时/数据分离保证不会触碰 `$DATA_ROOT`。
- 更新到新版本：重跑脚本（默认取最新 release）。
- 一键脚本 URL = `https://raw.githubusercontent.com/OrzMC/OrzMCDeploy/main/install.sh`
  （仓库/版本不同时用 `-r owner/repo`、`-v vX.Y.Z` 覆盖）。

> 也可以直接 `git clone` 部署（等价，只是多了 `.git` 目录）。两种方式最终都得到
> 同一套 `orzmc.sh` 与配置文件，行为一致。

## 快速上手

```bash
git clone <你的仓库地址> orzmc-deploy && cd orzmc-deploy
./orzmc.sh -d /srv/orzmc init   # 生成 .env（改 LAN_HOST_IP / 口令 / QQ 凭据）
./orzmc.sh -d /srv/orzmc up     # 启动平台层
./orzmc.sh -d /srv/orzmc status # 打印局域网访问地址 + 容器状态
```

默认 `DATA_ROOT`：Linux `/srv/orzmc`、macOS `/Users/Shared/orzmc`、Windows `E:/orzmc`
（也可用 `-d` 或 `ORZMC_DATA_ROOT` 指定）。

完整流程与每步预期输出见 [`docs/usage.md`](docs/usage.md) 第 3 章。

## 命令速查（唯一入口 orzmc.sh）

| 场景 | 命令 |
|---|---|
| 初始化目录/env | `./orzmc.sh [-d DATA_ROOT] init` |
| 启动平台层 | `./orzmc.sh [-d DATA_ROOT] up` |
| 停止 | `./orzmc.sh stop` |
| 状态与访问地址 | `./orzmc.sh status` |
| 校验配置 | `./orzmc.sh validate` |
| 备份数据 | `./orzmc.sh backup [--stop] [--keep N]` |
| 防火墙收敛（默认限源） | `./orzmc.sh firewall show` / `./orzmc.sh firewall apply` |
| 还原/迁移 | `./restore.sh -d <目标> <归档> [--force]` |
| 刷新镜像 digest | `./update-image-digests.sh [服务]` |

`<DATA_ROOT>` 优先级：`-d/--data-root` 参数 > `ORZMC_DATA_ROOT` 环境变量 > 平台默认
（macOS `/Users/Shared/orzmc`、Linux `/srv/orzmc`、Windows `E:/orzmc`）。三平台命令完全一致；
Windows 下 daemon 默认由 compose 管理，仅**进程模式实例**需注入 `DAEMON_PORTS` 时才走脚本
生成的 `docker run`（`lib/common.sh` 的 `win_daemon_run`，ADR-029），
`orzmc.sh stop && orzmc.sh up` 即完成重建。可选服务开关 `ENABLE_EASYBOT` 也在 `.env` 里配。

> 旧入口 `deploy.sh -p ...` / `local.sh` / `lan.sh` / `windows.sh` 已随 ADR-027 删除；
> 现在只有 `./orzmc.sh` 一个入口。

## 质量门禁（CI）

push 到 `main` 或开 PR 时，GitHub Actions 自动跑三道校验（见 `.github/workflows/ci.yml`）：

- **lint**：shell 语法（`bash -n`）+ `shellcheck`（含 `tests/`）+ 模板 YAML 解析 + 禁入路径守卫
  （`.env` / `.local-data*` / `.local-backups*` 永不入库）
- **validate**：`init && validate`（模板全量）+ `ENABLE_EASYBOT=false` 最小集
  + `LAN_*_PORT` / `LAN_BIND_ADDR` 生效 + `firewall apply --dry-run` 来源限源
  （必需环境变量检查 + `docker compose config -q`，纯解析不拉镜像、不触碰生产 `$DATA_ROOT`）
- **windows-branch**：Windows 分支逻辑单元测试（ADR-016 / ADR-029）——mock `uname` 强制 MINGW，
  校验 `win_path` / `win_daemon_*` / `compose_cmd` Windows 分支的命令构造，以及
  `read_env_value` 的「首次出现优先 + CRLF 容错」（`tests/windows_ci.sh`）。
  覆盖主 job 在 Linux 上走不到的 Windows 特有代码路径。

本地想先自查同一套检查，跑 `./orzmc.sh -d /tmp/orzmc-test init && ./orzmc.sh -d /tmp/orzmc-test validate`
覆盖 env 与 compose 解析；`bash tests/windows_ci.sh` 覆盖 Windows 分支；`shellcheck *.sh lib/*.sh tests/*.sh`
覆盖静态检查。

## 文档导航

- [`docs/usage.md`](docs/usage.md) —— **用户使用指南**（全生命周期分步操作）
- [`docs/architecture.md`](docs/architecture.md) —— 架构设计文档（含 ADR 决策记录）
- [`docs/easybot.md`](docs/easybot.md) —— EasyBot 网关与插件 `easybot.yml` 配置指南
- [`docs/papermc-template.md`](docs/papermc-template.md) —— PaperMC 实例录入参数参考
- [`docs/security.md`](docs/security.md) —— **暴露面与访问控制**（默认限源 / 对外暴露三档方案）
- [`docs/windows-deployment.md`](docs/windows-deployment.md) —— **Windows 平台部署指南**（问题/根因/解法，含 ADR-015/016，三平台统一命令）
- [`AGENTS.md`](AGENTS.md) / [`CLAUDE.md`](CLAUDE.md) —— AI 智能体守则
- [`EXECUTION_PATH.md`](EXECUTION_PATH.md) —— 执行路径、门禁、checklist、状态记录
- [`CHANGELOG.md`](CHANGELOG.md) —— 版本变更记录（Release 说明）

## 安全

- `$DATA_ROOT/.env`、daemon key（`global.json`）均属密钥：权限收紧、随数据备份、
  **永不入库**。
- 局域网暴露 **2 个入口**（`mcs` 面板 / `easybot` 后台，均有登录鉴权）；daemon 端口不发布
  （面板中转，ADR-026）；`mcsmanager-daemon` 挂载 `/var/run/docker.sock`，宿主机须视为可信
  环境。面板与 EasyBot 都是 **HTTP + 口令登录**，**仅限可信局域网**（ADR-027）；要对外访问
  请自备 TLS 反代或 VPN，并用 `./orzmc.sh firewall apply` 把来源收回 `LAN_CIDR`（ADR-028）。
  详见 [`docs/security.md`](docs/security.md)。
