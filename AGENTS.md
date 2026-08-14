# OrzMC Deploy — AI 智能体指南

> 本文件是**任何 AI 智能体**（Claude Code / Cursor / Copilot / Codex 等）与人类维护者
> 修改本仓库时的通用守则。改动本仓库前请先读完本页；架构设计的历史与演进见
> `docs/architecture.md`。

## 仓库使命

OrzMC 的最小容器化部署方案：用 Docker Compose 承载平台层（MCSManager Web/Daemon、
EasyBot 统一 IM 网关），并管理 PaperMC 游戏实例。PaperMC 实例**不**直接写在
`compose.yaml` 中，而是由 MCSManager 创建和管理，生命周期不归本仓库的 compose。

## 架构铁律（最高优先级，不可破坏）

### 1. 运行时与数据分离

- **仓库只承载"运行时"**：compose 编排、镜像 digest、部署脚本、配置模板、文档。
- **全部配置与数据通过卷映射落在宿主机统一目录 `$DATA_ROOT`**（生产
  `/Users/Shared/orzmc`，本地 `.local-data/`）。
- 运行数据包括：`.env`（全部环境变量 + 密钥）、Caddyfile、EasyBot 数据、
  MCSManager 数据、cloudflared 隧道凭据、PaperMC 实例目录。
- 由此获得的能力：运行时独立演进（升级镜像/改编排不触碰数据）、数据独立
  备份/还原/迁移（备份即打包 `$DATA_ROOT`）、密钥不进入仓库。

### 2. 禁止在仓库内写数据 / 密钥

- 任何配置、密钥、运行数据**一律落 `$DATA_ROOT`**，不得写入仓库内任何路径。
- `.env`、`.local-data/`、`.local-backups/` 已在 `.gitignore` 排除；不要把它们
  `git add -f` 强制加入。
- 智能体改代码时，只改仓库内的运行时文件；不要为"跑通"而把测试数据写进仓库。

### 3. 双 Profile（local / prod），同一份 compose

| Profile | 边缘层 | 用途 | 入口 |
|---|---|---|---|
| `local` | Caddy（`.localhost` 本地 CA + 非特权端口） | 本地验证 / 回归 | `mcs.localhost` / `easybot.localhost` / `mcs-node.localhost` / `status.localhost` |
| `prod` | cloudflared（Cloudflare Tunnel） | 生产（NAT 内网免开端口） | `mcs.<domain>` / `easybot.<domain>` / `mcs-node.<domain>` / `status.<domain>` |

- `compose.yaml` 中 `reverse-proxy`(caddy) 挂 `profiles: ["local"]`，
  `cloudflared` 挂 `profiles: ["prod"]`；mcsmanager / easybot / mariadb / status 无 profile
  （两边都跑）。
- 脚本通过 `COMPOSE_PROFILE`（默认 `prod`）选择边缘层：`deploy.sh -p local ...`
  或 `./local.sh ...` 走 local，`deploy.sh ...` 走 prod。

### 4. 网络拓扑：4 个公网入口，EasyBot 插件 API 仅内网

- 公网暴露 **4 个入口**：
  - `mcs.<domain>` → MCSManager 面板（Web 登录鉴权）
  - `easybot.<domain>` → EasyBot 管理后台（登录鉴权）
  - `mcs-node.<domain>` → MCSManager daemon/节点（浏览器直连，**daemon key 鉴权**）
  - `status.<domain>` → 统一状态页（Gatus，聚合产品入口 + 实时健康；页面无鉴权，
    仅服务名与状态、不含密钥）
- **EasyBot 的插件 API 不外露**：PaperMC 插件跑在 `orzmc_default` 网络内，
  直连 `http://easybot:8080`（REST + WebSocket 同端口，内网无 TLS）。
- **应用数据库 MariaDB 默认启用**：插件挂 `orzmc_default` 内网直连 `mariadb:3306`
  （仅 `expose`，不发布宿主机端口、无公网/边缘入口），供需要 MySQL/MariaDB 的插件
  （Dynmap/CoreProtect/LuckPerms/Towny 等）使用；数据落 `$DATA_ROOT/database/mariadb`。
- **daemon 经边缘层入口可达**：MCSManager 连接模型要求面板浏览器**直连** daemon
  （终端/控制台/文件管理器，WebSocket）；生产 `mcs-node.<domain>`（Cloudflare）、
  本地 `mcs-node.localhost`（Caddy）反代到 `mcsmanager-daemon:24444`。daemon 全部
  业务路由要求密钥鉴权，无 key 无权限。
- 所有服务端口只 `expose`，**不发布宿主机端口**（PaperMC 实例端口 `25565` 由
  MCSManager 按实例配置映射，供玩家局域网直连）。

## 目录地图

```
compose.yaml            平台层编排（name: orzmc，镜像 digest 锁定，双 profile，含常驻 mariadb）
templates/              首次 init 的配置模板
  env.prod              生产 .env 模板（含 CLOUDFLARE_TUNNEL_ID）
  env.local             本地 .env 模板（.localhost）
  cloudflared-config.yml cloudflared 隧道配置模板（__PLACEHOLDER__ 由 init 替换）
  Caddyfile             local profile 反代模板（仅本地使用）
  gatus-config.yml      Gatus 统一状态页配置模板（init 生成到 DATA_ROOT/status/config.yaml）
  gateway.local.yaml    EasyBot 覆盖配置模板（禁用微信适配器，init 生成到 DATA_ROOT）
  env.papermc           PaperMC 参数参考（compose 不消费）
lib/common.sh           共享函数库（DATA_ROOT 解析、compose 封装、目录引导）
deploy.sh               生产部署统一入口（默认 prod profile）
local.sh                本地验证统一入口（固定 local profile + .local-data）
backup.sh / restore.sh  数据备份 / 还原迁移
update-image-digests.sh 刷新 compose.yaml 镜像 digest
AGENTS.md / CLAUDE.md   本文件 / Claude Code 入口（@import 本文件）
README.md               用户入口（介绍 + 快速上手 + 命令速查 + 文档导航）
EXECUTION_PATH.md       执行路径、门禁、checklist、状态记录
docs/usage.md           用户使用指南（全生命周期分步操作）
docs/architecture.md    架构设计文档（含 ADR 决策记录，长期演进）
docs/easybot.md         EasyBot 网关与插件 easybot.yml 配置指南
docs/papermc-template.md PaperMC 实例录入参数参考
```

## 命令速查

| 场景 | 本地 | 生产 |
|---|---|---|
| 初始化目录/env/边缘配置 | `./local.sh init` | `deploy.sh init` |
| 启动平台层 | `./local.sh start` | `deploy.sh up` |
| 停止 | `./local.sh stop` | `deploy.sh stop` |
| 状态与访问地址 | `./local.sh status` | `deploy.sh status` |
| 校验配置 | `deploy.sh -d ./.local-data validate` | `deploy.sh validate` |
| 备份数据 | `./local.sh backup` | `backup.sh --stop`（含 MariaDB 逻辑备份） |
| 还原/迁移 | `./restore.sh -d <root> <归档>` | `restore.sh <归档>` |

- 生产默认 `DATA_ROOT=/srv/orzmc`，实际生产使用 `deploy.sh -d /Users/Shared/orzmc ...`
  或 `ORZMC_DATA_ROOT=/Users/Shared/orzmc`。
- `DATA_ROOT` 优先级：`-d/--data-root` 参数 > `ORZMC_DATA_ROOT` 环境变量 > 默认值。
- 所有 compose 调用统一走 `lib/common.sh` 的 `compose_cmd`（显式
  `--env-file $DATA_ROOT/.env` + `--profile $COMPOSE_PROFILE`）。

## 代码约定

- **bash 3.2 兼容**：仓库脚本在 macOS 自带 bash 3.2 下运行（`/usr/bin/env bash`）。
  `set -u` 会把双引号内**紧跟全角字符**（（ ） ， 。 等）的 `$VAR` 误判为未定义变量
  并报 `VAR�: unbound variable`。**消息字符串里的变量一律写 `${VAR}`**，不要用
  `$VAR` 直接后接全角标点。此为可移植性约定，勿回退。
- compose v2 `--env-file` 是**替换**而非叠加项目根 `.env`，必须显式传入且为真实普通文件。
- 镜像一律用 **digest 锁定**（`image: xxx@sha256:...`），升级走
  `update-image-digests.sh` + git commit，回滚走 `git revert`。
- `ensure_*` 引导函数**绝不覆盖已有文件**（`ensure_env_file`、`ensure_caddyfile`）；
  模板同步用 `deploy.sh templates --diff|--force`。
- **macOS / Docker Desktop 写盘走宿主用户**：容器内 uid 检查通过后，实际磁盘写入由
  macOS 侧文件共享进程（宿主用户）执行；`runAs 1000:1000` 的容器在宿主目录属主非该
  用户时仍会写盘失败（Operation not permitted / AccessDenied）。生产 macOS 将实例目录
  属主改为宿主用户（`sudo chown -R joker:staff <instance-dir>`）；Linux 生产无此问题，
  保持 `1000:1000`。

## 安全约束（必须遵守）

- `$DATA_ROOT/.env` 含 `QQBOT_APP_ID/CLIENT_SECRET`、`EASYBOT_ADMIN_PASSWORD`、
  `MARIADB_ROOT_PASSWORD/MARIADB_PASSWORD` 等密钥，权限收紧为 600，**永不入库**。
- `$DATA_ROOT/cloudflared/` 含账号级 `cert.pem` 与隧道凭据 `<id>.json`（可控制该
  Cloudflare 账号下的隧道）——按密钥对待：只存在于 DATA_ROOT 内、随数据备份、
  权限收紧。
- `$DATA_ROOT/mcsmanager/daemon/data/Config/global.json` 含 **daemon key**——daemon
  控制 docker.sock（可管理宿主机 Docker），该 key 等同最高权限密钥：权限 600、
  只存在于 DATA_ROOT 内、随数据备份、**永不入库**。
- `$DATA_ROOT/database/dumps/*.sql` 是 MariaDB 逻辑备份，含 `mysql` 系统库
  （用户/授权哈希）——按密钥对待：`chmod 600`、随数据备份、**永不入库**。
- `mcsmanager-daemon` 挂载 `/var/run/docker.sock`，拥有管理宿主机 Docker 的能力，
  **宿主机必须视为可信环境**。
- EasyBot 监听器仅 HTTP，`EASYBOT_ALLOW_PLAINTEXT=true` 为有意为之；TLS 由
  local=Caddy / prod=Cloudflare 边缘承担，插件 API 走内网不需 TLS。

## 修改守则（智能体改动前必读）

1. 改动运行时：先读 `AGENTS.md` 与相关脚本头注释，理解 `DATA_ROOT` / profile 机制。
2. 不破坏铁律：不往仓库写数据/密钥；不删 `.gitignore` 排除项；不把 EasyBot 插件
   API 暴露到公网。
3. 涉及架构（服务增减、入口变更、卷/网络调整）：**同步更新** `docs/architecture.md`
   （新增 ADR 记录）、`AGENTS.md`（如规则变化）、`README.md`、相关 `docs/*.md`。
4. 改动共享库 `lib/common.sh` 后，跑一遍本地回归：`./local.sh init && ./local.sh start`
   与 `deploy.sh -d ./.local-data validate`。
5. 新增 `.env` 必需变量：同步更新 `lib/common.sh` 的 `REQUIRED_ENV_VARS_PROD/LOCAL`
   与 `templates/env.*`。
6. 需要用户输入密钥/凭据时，引导用户编辑 `$DATA_ROOT/.env`，不要把真实值写进仓库或
   回显到日志/提交信息。
7. 提交前核对 `git status`：不得出现 `.env`、`.local-data/`、`.local-backups/`、
   生产 `DATA_ROOT` 内容或任何密钥。
