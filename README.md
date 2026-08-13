# OrzMC Docker 部署

OrzMC 的最小容器化落地方案。平台层包括：

- `cloudflared`（生产，prod profile）作为公网入口——Cloudflare Tunnel 出站隧道，
  Cloudflare 边缘终止真实 HTTPS
- `Caddy`（本地验证，local profile）作为 `.localhost` 反代 + 本地 CA
- `MCSManager Web` + `MCSManager Daemon` 管理实例
- `EasyBot` 统一 IM 网关（QQ / Telegram / Discord / 飞书 / 微信）

`PaperMC` 不直接写在 `compose.yaml` 中，而是由 `MCSManager` 创建和管理。

> **完整使用指南见 [`docs/usage.md`](docs/usage.md)**：从零安装、配置、日常运维、
> 管理 PaperMC 实例、EasyBot 接入、故障排查与整服迁移的全生命周期分步操作。
>
> **AI 智能体与协作者请先读 [`AGENTS.md`](AGENTS.md)**：仓库的架构铁律（运行时与数据
> 分离）、双 Profile、网络拓扑与安全约束；架构设计与决策记录见
> [`docs/architecture.md`](docs/architecture.md)。
>
> 如果要推进部署方案，请优先阅读 [`EXECUTION_PATH.md`](EXECUTION_PATH.md)：执行路径、
> 门禁规则与 checklist。

## 架构原则：运行时与数据分离

**仓库只承载"运行时"**——compose 编排、镜像 digest、部署脚本、配置模板；
**全部配置与数据通过卷映射落在宿主机统一目录 `$DATA_ROOT`**（生产 macOS
`/Users/Shared/orzmc`，Linux 默认 `/srv/orzmc`，本地 `.local-data/`）。由此获得：
运行时独立演进、数据独立备份/还原/迁移、密钥不进入仓库。

## 双 Profile（local / prod）

| Profile | 边缘层 | 用途 | 入口 |
|---|---|---|---|
| `local` | Caddy（`.localhost` + 本地 CA + 非特权端口） | 本地验证 / 回归 | `mcs.localhost` / `easybot.localhost` / `mcs-node.localhost` |
| `prod` | cloudflared（Cloudflare Tunnel） | 生产（NAT 内网免开端口） | `mcs.<domain>` / `easybot.<domain>` / `mcs-node.<domain>` |

公网/本地暴露 **3 个入口**：`mcs`（MCSManager 面板）、`easybot`（EasyBot 管理后台）、
`mcs-node`（daemon 直连，daemon key 鉴权）。**EasyBot 插件 API 仅内网**——插件挂
`orzmc_default` 网络直连 `http://easybot:8080`，无 `easybot-api` 子域名。

## 快速上手（本地体验）

```bash
git clone <你的仓库地址> orzmc-deploy && cd orzmc-deploy
./local.sh init      # 生成 .local-data/.env
./local.sh start     # 启动平台层（local profile）
./local.sh status    # 查看状态与访问地址（mcs.localhost:18443 等）
```

生产上线（Cloudflare Tunnel）、完整命令与每步预期输出，见
[`docs/usage.md`](docs/usage.md) 第 3 章。

## 命令速查

| 场景 | 本地 | 生产 |
|---|---|---|
| 初始化目录/env/边缘配置 | `./local.sh init` | `deploy.sh -d <DATA_ROOT> init` |
| 启动平台层 | `./local.sh start` | `deploy.sh -d <DATA_ROOT> up` |
| 停止 | `./local.sh stop` | `deploy.sh -d <DATA_ROOT> stop` |
| 状态与访问地址 | `./local.sh status` | `deploy.sh -d <DATA_ROOT> status` |
| 校验配置 | `deploy.sh -d ./.local-data validate` | `deploy.sh -d <DATA_ROOT> validate` |
| 备份数据 | `./local.sh backup` | `backup.sh -d <DATA_ROOT> --stop` |
| 还原/迁移 | `./restore.sh -d <目标> <归档>` | `restore.sh -d <目标> <归档> --force` |
| 刷新镜像 digest | `./update-image-digests.sh [服务]` | 同左 |

`<DATA_ROOT>` 优先级：`-d/--data-root` 参数 > `ORZMC_DATA_ROOT` 环境变量 > 默认值。
生产 macOS 用 `-d /Users/Shared/orzmc`；Linux 默认 `/srv/orzmc`。

## 文档导航

- [`docs/usage.md`](docs/usage.md) —— **用户使用指南**（全生命周期分步操作）
- [`docs/architecture.md`](docs/architecture.md) —— 架构设计文档（含 ADR 决策记录）
- [`docs/easybot.md`](docs/easybot.md) —— EasyBot 网关与插件 `easybot.yml` 配置指南
- [`docs/papermc-template.md`](docs/papermc-template.md) —— PaperMC 实例录入参数参考
- [`AGENTS.md`](AGENTS.md) / [`CLAUDE.md`](CLAUDE.md) —— AI 智能体守则
- [`EXECUTION_PATH.md`](EXECUTION_PATH.md) —— 执行路径、门禁、checklist、状态记录

## 安全

- `$DATA_ROOT/.env`、cloudflared 凭据（`cert.pem`、隧道 `<id>.json`）、daemon key
  （`global.json`）均属密钥：权限收紧、随数据备份、**永不入库**。
- 公网仅暴露 3 个入口；`mcsmanager-daemon` 挂载 `/var/run/docker.sock`，宿主机须视为
  可信环境。详见 [`docs/usage.md`](docs/usage.md) 第 8 章。
