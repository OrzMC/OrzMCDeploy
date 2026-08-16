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

### 3. 单 Profile（EDGE 边缘层 + ENABLE_* 可选服务），同一份 compose

**Profile 模型（ADR-017）**：去掉 prod/local/lan 三 profile，改为**一个运行集 + 可插拔边缘层 + 可插拔服务**：

| 维度 | 配置 | 说明 |
|---|---|---|
| 边缘层 | `.env` 里 `EDGE=`（`cloudflare`/`local`/`lan`/`none`） | `compose_cmd` 按 EDGE 追加 `compose.edge.<edge>.yaml` override |
| 可选服务 | `.env` 里 `ENABLE_EASYBOT`/`ENABLE_MARIADB`/`ENABLE_STATUS`（缺省 `true`） | 按启用项追加 `--profile <name>`；核心 web/daemon 常驻 |
| 入口 | `./orzmc.sh`（唯一入口，三平台一致） | `./orzmc.sh [-d DATA_ROOT] [-e EDGE] init\|up\|stop\|status\|validate\|backup\|templates` |

- **EDGE 边缘层**（决定 4 个源站对外如何可达）：
  - `cloudflare` → `compose.edge.cloudflare.yaml`（cloudflared 出站隧道，生产，真实 HTTPS，免开端口）
  - `local` → `compose.edge.local.yaml`（Caddy `.localhost` 本地 CA + 非特权端口 18080/18443）
  - `lan` → `compose.edge.lan.yaml`（无边缘层，4 源站发宿主端口，纯 HTTP，局域网）
  - `none` → 不追加 override（仅内网 `orzmc_default`，不对外）
- **ENABLE_* 可选服务**：easybot / mariadb / status 带 `profiles: ["<name>"]` 标签，
  默认全启用；置 `false` 即从 `--profile` 移除。status 仅依赖核心 web/daemon。
- 脚本通过 `EDGE`（或兼容的旧 `COMPOSE_PROFILE`，`prod`→`cloudflare` 自动映射）选择：
  `./orzmc.sh -e cloudflare`、`./orzmc.sh -e local`、`./orzmc.sh -e lan`。
  旧入口 `deploy.sh -p ...`/`local.sh`/`lan.sh`/`windows.sh` 保留兼容（deprecated）。

### 4. 网络拓扑：4 个公网入口（lan 无边缘层），EasyBot 插件 API 仅内网

- 公网/局域网暴露 4 个入口（prod/local 走边缘层域名；**lan 无边缘层**，走宿主发布端口
  `http://<LAN_HOST_IP>:<LAN_*_PORT>`，见 ADR-012）：
  - `mcs.<domain>` → MCSManager 面板（Web 登录鉴权）
  - `easybot.<domain>` → EasyBot 管理后台（登录鉴权）
  - `mcs-node.<domain>` → MCSManager daemon/节点（浏览器直连，**daemon key 鉴权**）
  - `orzmcs.<domain>` → 统一状态页（Gatus，聚合产品入口 + 实时健康；页面无鉴权，
    仅服务名与状态、不含密钥）
- **EasyBot 的插件 API 不外露**：PaperMC 插件跑在 `orzmc_default` 网络内，
  直连 `http://easybot:8080`（REST + WebSocket 同端口，内网无 TLS）。
- **应用数据库 MariaDB 默认启用**：插件挂 `orzmc_default` 内网直连 `mariadb:3306`
  （仅 `expose`，不发布宿主机端口、无公网/边缘入口），供需要 MySQL/MariaDB 的插件
  （Dynmap/CoreProtect/LuckPerms/Towny 等）使用；数据落 `$DATA_ROOT/database/mariadb`。
- **daemon 连接（三档浏览器直连均可用）**：节点地址统一「面板服务端与浏览器**同一地址**」，
  按档不同：
  - **prod**：节点 `ip` 填 `wss://mcs-node.<domain>:443`——经 cloudflared 隧道连 daemon。
    隧道 socket.io 已实测可用（polling/websocket + `{uuid,data}` 鉴权全通；ADR-011 的 koa
    拦截结论已过时，见 ADR-013）。代价：面板↔daemon 走 Cloudflare 边缘（延迟略增、依赖
    隧道在线；`connectOpts.reconnection` 兜底重连）。
  - **local**：节点 `ip` 填 `wss://mcs-node.localhost` + 端口 `18443`（Caddy 非特权 TLS 端
    口）；`compose.yaml` 的 `mcsmanager-web` 有 `extra_hosts: mcs-node.localhost:host-gateway`
    使容器把 `.localhost` 解析到宿主 Caddy（ADR-014）。浏览器直连前须一次性信任 Caddy 本
    地根证书并完全重启浏览器（`security add-trusted-cert -d -r trustRoot -k
    ~/Library/Keychains/login.keychain $DATA_ROOT/caddy/data/caddy/pki/authorities/local/root.crt`）。
  - **lan**：节点 `ip` 填 `ws://<LAN_HOST_IP>` + 端口 `<LAN_MCS_DAEMON_PORT>`——daemon 端口
    本就发布到宿主，浏览器/局域网设备经 LAN IP 直连，解除 ADR-011 lan 遗留（ADR-014）。
    ⚠️ LAN IP 多为 DHCP，换 IP 需同步改 `.env` 与节点配置。
  - 三档浏览器**终端/控制台/文件管理器均可用**；节点配置在
    `$DATA_ROOT/mcsmanager/web/data/RemoteServiceConfig/*.json`，改后
    `docker restart orzmc-mcsmanager-web`。daemon 全部业务路由要求密钥鉴权，无 key 无权限。
- 服务端口**默认只 `expose`，不发布宿主机端口**（cloudflare/local；PaperMC 实例端口 `25565`
  由 MCSManager 按实例配置映射，供玩家局域网直连）。**lan 直连模式例外**：经
  `compose.edge.lan.yaml` 把 4 个源站发布到宿主 `LAN_*_PORT`，纯 HTTP 仅限可信局域网
  （ADR-012）。

## 目录地图

```
compose.yaml            平台层编排（name: orzmc，镜像 digest 锁定，核心 web/daemon 常驻 + 可选服务带 profiles 标签）
compose.edge.cloudflare.yaml  EDGE=cloudflare 边缘层 override（cloudflared 出站隧道）
compose.edge.local.yaml       EDGE=local 边缘层 override（Caddy，.localhost）
compose.edge.lan.yaml         EDGE=lan 边缘层 override（无边缘层：给 4 个源站发布宿主端口，纯 HTTP）
templates/              首次 init 的配置模板
  env.prod              生产 .env 模板（含 CLOUDFLARE_TUNNEL_ID）
  env.local             本地 .env 模板（.localhost）
  env.lan               局域网 .env 模板（LAN_HOST_IP + LAN_*_PORT，无 DOMAIN_*/CLOUDFLARE）
  cloudflared-config.yml cloudflared 隧道配置模板（__PLACEHOLDER__ 由 init 替换）
  Caddyfile             local profile 反代模板（仅本地使用）
  gatus-config.yml      Gatus 统一状态页配置模板（init 生成到 DATA_ROOT/status/config.yaml）
  gateway.local.yaml    EasyBot 覆盖配置模板（禁用微信适配器，init 生成到 DATA_ROOT）
  env.papermc           PaperMC 参数参考（compose 不消费）
lib/common.sh           共享函数库（DATA_ROOT 解析、compose 封装、目录引导、平台层 detect_os/win_path/win_daemon_*）
orzmc.sh               统一部署入口（ADR-017 起唯一入口；EDGE/ENABLE_* 从 .env 读，三平台一致）
install.sh             免克隆一键安装（ADR-018：下载 Release tarball + 校验 sha256 + 解压）
deploy.sh               生产部署统一入口（默认 EDGE=cloudflare，兼容保留）
local.sh                本地验证入口（固定 EDGE=local + .local-data，兼容保留）
lan.sh                  局域网直连入口（固定 EDGE=lan + .local-data-lan，兼容保留）
windows.sh              Windows 部署入口（默认 DATA_ROOT=E:/orzmc；兼容保留，ADR-016）
backup.sh / restore.sh  数据备份 / 还原迁移
update-image-digests.sh 刷新 compose.yaml 镜像 digest
.github/workflows/ci.yml CI 质量门禁（push/PR：bash -n + shellcheck(含 tests/) + 模板 YAML + EDGE×ENABLE validate + windows-branch 单测）
tests/windows_ci.sh   Windows 分支单元测试（mock uname 强制 MINGW，校验 win_path/win_daemon_*/compose_cmd 命令构造）
AGENTS.md / CLAUDE.md   本文件 / Claude Code 入口（@import 本文件）
README.md               用户入口（介绍 + 快速上手 + 命令速查 + 文档导航）
EXECUTION_PATH.md       执行路径、门禁、checklist、状态记录
docs/usage.md           用户使用指南（全生命周期分步操作）
docs/architecture.md    架构设计文档（含 ADR 决策记录，长期演进）
docs/easybot.md         EasyBot 网关与插件 easybot.yml 配置指南
docs/papermc-template.md PaperMC 实例录入参数参考
docs/windows-deployment.md Windows 平台部署指南（问题/根因/解法，含 ADR-015/016，三平台统一命令）
```

## 命令速查（统一 orzmc.sh）

| 场景 | 命令 |
|---|---|
| 初始化目录/env/边缘配置 | `./orzmc.sh [-e <edge>] init` |
| 启动平台层 | `./orzmc.sh [-e <edge>] up` |
| 停止 | `./orzmc.sh stop` |
| 状态与访问地址 | `./orzmc.sh status` |
| 校验配置 | `./orzmc.sh validate` |
| 备份数据 | `./orzmc.sh backup [--stop]`（含 MariaDB 逻辑备份） |
| 还原/迁移 | `./restore.sh -d <root> <归档> [--force]` |

- `EDGE`（`cloudflare`/`local`/`lan`/`none`）在 `$DATA_ROOT/.env` 里配（`EDGE=`），
  `-e` 参数临时覆盖；可选服务 `ENABLE_EASYBOT`/`ENABLE_MARIADB`/`ENABLE_STATUS`
  也在 `.env` 里（缺省 `true`）。
- 生产默认 `DATA_ROOT=/srv/orzmc`（macOS `/Users/Shared/orzmc`、Windows `E:/orzmc`）。
- `DATA_ROOT` 优先级：`-d/--data-root` 参数 > `ORZMC_DATA_ROOT` 环境变量 > 默认值。
- 所有 compose 调用统一走 `lib/common.sh` 的 `compose_cmd`（显式
  `--env-file $DATA_ROOT/.env` + 按 EDGE/ENABLE_* 追加 `-f` override 与 `--profile`）。
- 旧入口 `deploy.sh -p ...` / `local.sh` / `lan.sh` / `windows.sh` 兼容保留（deprecated），
  `-p prod` 自动映射 `EDGE=cloudflare`。

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
  local=Caddy / prod=Cloudflare 边缘承担，插件 API 走内网不需 TLS。**lan 无边缘层**：
  EasyBot 面板口令与 daemon 端口均以**明文 HTTP** 暴露给局域网——仅限可信局域网
  （ADR-012），接入不可信 Wi-Fi 时应改用 prod/local。
- **lan 对局域网开放 daemon 端口**（`LAN_MCS_DAEMON_PORT`）：daemon key 鉴权（可管理
  docker.sock），等同对局域网开放最高权限密钥的探测面——仅限可信局域网。

## 修改守则（智能体改动前必读）

1. 改动运行时：先读 `AGENTS.md` 与相关脚本头注释，理解 `DATA_ROOT` / profile 机制。
2. 不破坏铁律：不往仓库写数据/密钥；不删 `.gitignore` 排除项；不把 EasyBot 插件
   API 暴露到公网。
3. 涉及架构（服务增减、入口变更、卷/网络调整）：**同步更新** `docs/architecture.md`
   （新增 ADR 记录）、`AGENTS.md`（如规则变化）、`README.md`、相关 `docs/*.md`。
4. 改动共享库 `lib/common.sh` 后，跑一遍本地回归：`./orzmc.sh -e local init && ./orzmc.sh up`
   与 `./orzmc.sh validate`（push/PR 后 CI 会自动跑 shellcheck + EDGE×ENABLE validate，
   见 `.github/workflows/ci.yml`）。
5. 新增 `.env` 必需变量：同步更新 `lib/common.sh` 的 `required_env_list`
   与 `templates/env.*`（ENABLE_* 开关也在此）。
6. 需要用户输入密钥/凭据时，引导用户编辑 `$DATA_ROOT/.env`，不要把真实值写进仓库或
   回显到日志/提交信息。
7. 提交前核对 `git status`：不得出现 `.env`、`.local-data/`、`.local-backups/`、
   生产 `DATA_ROOT` 内容或任何密钥。
