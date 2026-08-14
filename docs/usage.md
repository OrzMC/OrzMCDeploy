# OrzMC 部署使用指南

> 面向**服主与运维**的全生命周期操作手册：从零开始把 OrzMC 部署栈跑起来、日常维护、
> 接入聊天机器人、故障排查与整服迁移。
>
> - 想快速看看这个项目是什么、怎么跑 —— 先读 [README](../README.md)
> - 想在 MCSManager 面板里录入 PaperMC 实例 —— 对照 [docs/papermc-template.md](papermc-template.md)
> - 想深入 EasyBot 网关与插件配置 —— 读 [docs/easybot.md](easybot.md)
> - 想了解架构原理与决策记录（维护者向）—— 读 [docs/architecture.md](architecture.md)

## 目录

- [1 认识项目](#1-认识项目)
- [2 前置条件](#2-前置条件)
- [3 快速开始（双路径）](#3-快速开始双路径)
- [4 配置详解](#4-配置详解)
- [5 日常运维](#5-日常运维)
- [6 管理 PaperMC 实例](#6-管理-papermc-实例)
- [7 EasyBot 接入](#7-easybot-接入)
- [8 安全基线](#8-安全基线)
- [9 故障排查](#9-故障排查)
- [10 迁移到新主机](#10-迁移到新主机)
- [附录 A 命令速查](#附录-a-命令速查)
- [附录 B 端口约定](#附录-b-端口约定)
- [附录 C DATA_ROOT 目录树](#附录-c-data_root-目录树)
- [附录 D 服务与镜像](#附录-d-服务与镜像)
- [附录 E 术语表](#附录-e-术语表)
- [附录 F 硬件选型（按在线人数）](#附录-f-硬件选型按在线人数)

---

## 1 认识项目

### 1.1 这是什么

**OrzMC 是最小容器化的 Minecraft 服务器部署方案**。它用 Docker Compose 编排**平台层**，
再由平台层里的 **MCSManager** 创建和管理实际的 **PaperMC** 游戏实例，并内置
**EasyBot** 统一 IM 网关让服内插件可以收发 QQ / Telegram / Discord / 飞书 / 微信消息。

一次部署能得到：

| 能力 | 说明 |
|---|---|
| **MCSManager 面板** | Web 界面管理 PaperMC 实例：启动/停止/控制台/文件/配置 |
| **EasyBot 网关** | 统一 IM 网关 + 管理后台，插件经它收发聊天平台消息 |
| **PaperMC 游戏服** | 由面板创建，可多实例，玩家局域网 `IP:25565` 直连 |
| **两种运行形态** | `local`（本机验证）/ `prod`（Cloudflare Tunnel 公网上线） |
| **运行时与数据分离** | 仓库只承载"运行时"，全部配置与数据落宿主机 `$DATA_ROOT`，随数据整体备份/迁移 |

### 1.2 架构一图流

```mermaid
flowchart TB
    subgraph 公网
        U1[管理浏览器] -- https --> CF["Cloudflare 边缘<br/>（真实 HTTPS）"]
        P[玩家] -- "局域网 IP:25565" --> MC
    end
    subgraph 宿主机（NAT 内网，无需开端口）
        subgraph orzmc_default 网络
            CD["cloudflared<br/>出站隧道"]
            WEB["MCSManager Web :23333"]
            DAE["MCSManager Daemon :24444<br/>（挂 docker.sock）"]
            EB["EasyBot :8080"]
            PLG["PaperMC 实例容器<br/>（插件 OrzMC）"]
        end
    end
    CF -- 出站隧道 --> CD
    CD -- "mcs.&lt;domain&gt;" --> WEB
    CD -- "easybot.&lt;domain&gt;" --> EB
    CD -- "mcs-node.&lt;domain&gt;" --> DAE
    DAE -- 创建 / 管理 --> PLG
    PLG -- "http://easybot:8080<br/>（REST + WS 内网直连）" --> EB
```

要点（详见 [docs/architecture.md](architecture.md)）：

- **生产（prod）**：`cloudflared` 主动**出站**连 Cloudflare，公网 HTTPS 由 Cloudflare 边缘
  终止。宿主机不开任何端口，NAT 内网也能用。
- **本地（local）**：换成 Caddy 反代 `.localhost` 域名 + 本地 CA，用于本机验证。
- **插件 API 仅内网**：PaperMC 插件挂 `orzmc_default` 网络，直连 `http://easybot:8080`，
  不走公网，没有 `easybot-api` 域名。
- **daemon 连接**：面板服务端**内网直连** daemon——节点配置填 `ws://mcsmanager-daemon:24444`，
  勿填隧道 URL（daemon 的 socket.io 在 cloudflared 转发下被自身 koa 拦截，节点离线；
  ADR-011）。`mcs-node.<domain>` 入口仍保留，设计供浏览器直连 daemon（终端/文件管理），
  但生产下受同一 koa 拦截**当前不可用**（已知限制）。daemon 全部业务路由要
  **daemon key** 鉴权。

### 1.3 术语表

| 术语 | 含义 |
|---|---|
| **DATA_ROOT** | 宿主机上的统一数据目录，存放全部配置与密钥。生产 macOS 常用 `/Users/Shared/orzmc`，Linux 默认 `/srv/orzmc`，本地为仓库下 `.local-data/` |
| **Profile** | 运行形态选择：`local`（Caddy 本地验证）或 `prod`（Cloudflare 公网）。同一份 `compose.yaml` 用 profiles 区分 |
| **daemon key** | MCSManager Daemon 的鉴权密钥，等同最高权限（daemon 可管理宿主机 Docker）。位于 `$DATA_ROOT/mcsmanager/daemon/data/Config/global.json` |
| **会话 key** | EasyBot 后台为某个平台会话分配的标识（如 `qq:xxxxxxxx`），填进插件 `easybot.yml` |
| **digest 锁定** | `compose.yaml` 里镜像用 `image:xxx@sha256:...` 固定版本，升级/回滚走 git |
| **隧道** | Cloudflare Tunnel：容器内 cloudflared 出站连接，按主机名路由到内部服务 |

### 1.4 文档地图

| 文档 | 什么时候读 |
|---|---|
| **本篇 `docs/usage.md`** | 日常使用：安装、配置、运维、排障、迁移 |
| `README.md` | 30 秒了解项目、快速上手、命令速查 |
| `docs/papermc-template.md` | 在 MCSManager 里录入 PaperMC 实例的字段参考 |
| `docs/easybot.md` | EasyBot 网关与插件 `easybot.yml` 的深度配置 |
| `docs/architecture.md` | 架构原理、ADR 决策记录（维护者/贡献者） |
| `AGENTS.md` / `CLAUDE.md` | AI 智能体与协作者守则（改仓库代码前必读） |

---

## 2 前置条件

| 项 | 要求 | 说明 |
|---|---|---|
| 系统 | macOS（Docker Desktop）或 Linux（Docker Engine） | 本指南以 macOS 为例，Linux 差异有标注 |
| 软件 | 已装 **docker**、**git** | `docker info` 能正常输出 |
| 网络 | 出站可达即可 | 生产靠 cloudflared 出站，NAT 内网不用开端口 |
| 账号（按需） | **Cloudflare** 账号 + 托管域名 | 仅生产 `prod` 需要 |
| 账号（按需） | **QQ 开放平台** AppID / ClientSecret | 仅接入 EasyBot QQ 需要 |

**不需要**在宿主机安装 cloudflared —— 隧道工具走官方容器镜像执行。

> 提示：想快速体验，不满足账号条件也没关系，走第 3 章的**路径 A 本地体验**即可，
> 全程不需要 Cloudflare 和域名。

---

## 3 快速开始（双路径）

### 3.1 先做决定：local 还是 prod？

| 你的情况 | 走哪条路径 |
|---|---|
| 只想本机跑起来看看 / 开发验证 / 没有域名 | **路径 A 本地体验**（15 分钟） |
| 想让公网玩家访问，且已有 Cloudflare 账号 + 域名 | **路径 B 生产上线**（约 30 分钟） |
| 已有生产部署，想升级/备份/迁移 | 直接看 [第 5 章](#5-日常运维) 与 [第 10 章](#10-迁移到新主机) |

两条路径共用同一份 `compose.yaml` 和同一套命令入口，区别只是边缘层（Caddy vs cloudflared）
与 `$DATA_ROOT` 位置。

### 3.2 路径 A：本地体验（15 分钟）

在终端执行（以下均在**仓库根目录**）：

```bash
# 1. 拉取仓库
git clone <你的仓库地址> orzmc-deploy && cd orzmc-deploy

# 2. 初始化本地数据目录（生成 .local-data/.env）
./local.sh init

# 3. 启动平台层
./local.sh start

# 4. 查看状态与访问地址
./local.sh status
```

**预期看到**：

- `init`：生成 `.local-data/.env`（从 `templates/env.local`，权限 600）与数据目录。
- `start`：compose 按 `local` profile 拉起 `mcsmanager-web`、`mcsmanager-daemon`、`easybot`
  与 `reverse-proxy`（Caddy），无报错。
- `status`：打印四个访问地址（Caddy 本地证书，首次访问有自签警告，放行即可）：

  | 地址 | 用途 |
  |---|---|
  | `https://mcs.localhost:18443` | MCSManager 面板 |
  | `https://easybot.localhost:18443` | EasyBot 管理后台 |
  | `https://mcs-node.localhost:18443` | MCSManager daemon（浏览器直连） |
  | `https://orzmcs.localhost:18443` | 统一状态页（Gatus：聚合产品入口 + 实时健康） |

浏览器打开 MCSManager 面板，按[第 6 章](#6-管理-papermc-实例)建管理员并创建一个测试
PaperMC 实例。启动成功后，玩家可用 `Mac 局域网 IP:25566` 进服（测试服端口，见附录 B）。

停止：

```bash
./local.sh stop
```

> 本地数据在仓库 `.local-data/`，已 `.gitignore` 排除，不会进 git。

### 3.3 路径 B：生产上线（约 30 分钟）

生产主机在 NAT 内网、公网 80/443 不可达时，用 **Cloudflare Tunnel**（出站连接），
**无需开放任何端口、无需 ACME**。下面 `$DATA_ROOT` 用 `<DATA_ROOT>` 占位：
macOS 生产填 `/Users/Shared/orzmc`，Linux 可省（默认 `/srv/orzmc`）。

```bash
# 0. 前置：数据目录可写（macOS 建议 /Users/Shared/orzmc，Linux 用 /srv/orzmc）

# 1. 隧道一次性初始化（交互；需浏览器授权；把 orzmc 换成你的隧道名）
docker run --rm -v <DATA_ROOT>/cloudflared:/home/cloudflared \
  cloudflare/cloudflared tunnel login
docker run --rm -v <DATA_ROOT>/cloudflared:/home/cloudflared \
  cloudflare/cloudflared tunnel create orzmc
docker run --rm -v <DATA_ROOT>/cloudflared:/home/cloudflared \
  cloudflare/cloudflared tunnel route dns orzmc mcs.<domain>
docker run --rm -v <DATA_ROOT>/cloudflared:/home/cloudflared \
  cloudflare/cloudflared tunnel route dns orzmc easybot.<domain>
docker run --rm -v <DATA_ROOT>/cloudflared:/home/cloudflared \
  cloudflare/cloudflared tunnel route dns orzmc mcs-node.<domain>
docker run --rm -v <DATA_ROOT>/cloudflared:/home/cloudflared \
  cloudflare/cloudflared tunnel route dns orzmc orzmcs.<domain>
```

- `login`：浏览器里给 Cloudflare 账号授权，`cert.pem` 落到 `<DATA_ROOT>/cloudflared/`。
- `create orzmc`：生成隧道凭据 `<tunnel-id>.json` 与隧道 UUID。
- `route dns`：在 Cloudflare 建四条 CNAME（`mcs` / `easybot` / `mcs-node` / `orzmcs`），

```bash
# 2. 初始化生产数据目录与 .env（生成 .env 与 cloudflared/config.yml）
deploy.sh -d <DATA_ROOT> init

# 3. 编辑 .env，至少修改以下项（用编辑器打开 <DATA_ROOT>/.env）
#    - CLOUDFLARE_TUNNEL_ID   ← create 输出的隧道 UUID
#    - DOMAIN_MCS_WEB / DOMAIN_EASY_ADMIN / DOMAIN_MCS_NODE / DOMAIN_STATUS  ← 你的四个真实子域名
#    - EASYBOT_ADMIN_PASSWORD ← 设一个强密码
#    - QQBOT_APP_ID / QQBOT_CLIENT_SECRET ← 需要 QQ bot 时填写

# 4. 校验配置（预期：校验通过，无缺失变量）
deploy.sh -d <DATA_ROOT> validate

# 5. 启动平台层
deploy.sh -d <DATA_ROOT> up
```

**预期看到**：

- `validate`：提示必需环境变量齐全、compose 配置合法。
- `up` 后：`docker logs orzmc-cloudflared` 出现"隧道已注册 / Registered tunnel"；
  公网 `curl -I https://mcs.<domain>` 返回 200。
- 四个公网入口：

  | 地址 | 用途 |
  |---|---|
  | `https://mcs.<domain>` | MCSManager 面板 |
  | `https://easybot.<domain>` | EasyBot 管理后台 |
  | `https://mcs-node.<domain>` | MCSManager daemon（无 key 会提示鉴权，属预期） |
  | `https://orzmcs.<domain>` | 统一状态页（Gatus：聚合产品入口 + 实时健康，无鉴权仅状态） |

之后按[第 6 章](#6-管理-papermc-实例)建管理员、加节点、建实例；正式服端口 `25565`
供玩家局域网直连。

> 生产 `DATA_ROOT` 的 `.env`、cloudflared 凭据等含密钥，权限 600，**永不入库**。

---

## 4 配置详解

### 4.1 DATA_ROOT 与 .env

**DATA_ROOT 优先级**：命令行 `-d/--data-root` 参数 > 环境变量 `ORZMC_DATA_ROOT` > 默认值
（`/srv/orzmc`）。所有脚本（deploy / local / backup / restore）统一按此解析，并用
`compose_cmd` 显式 `--env-file $DATA_ROOT/.env` 调用 compose。

`.env` 是**唯一配置源**（含密钥）。首次由 `init` 从模板生成，之后**改配置 = 编辑
`.env`**。必需变量分两套（见 `lib/common.sh`）：

| 变量 | prod | local | 说明 |
|---|---|---|---|
| `TZ` | ✔ | ✔ | 时区，如 `Asia/Shanghai` |
| `CLOUDFLARE_TUNNEL_ID` | ✔ | — | 隧道 UUID（`tunnel create` 输出） |
| `DOMAIN_MCS_WEB` | ✔ | ✔ | MCSManager 面板域名：`mcs.<domain>` / `mcs.localhost` |
| `DOMAIN_EASY_ADMIN` | ✔ | ✔ | EasyBot 后台域名：`easybot.<domain>` / `easybot.localhost` |
| `DOMAIN_MCS_NODE` | ✔ | ✔ | daemon 直连域名：`mcs-node.<domain>` / `mcs-node.localhost` |
| `DOMAIN_STATUS` | ✔ | ✔ | 统一状态页域名：`orzmcs.<domain>` / `orzmcs.localhost` |
| `CADDY_EMAIL` | — | ✔ | Caddy 证书邮箱（本地模板用占位） |
| `PROXY_HTTP_PORT` | — | ✔ | 本地 Caddy HTTP 端口（默认 `18080`） |
| `PROXY_HTTPS_PORT` | — | ✔ | 本地 Caddy HTTPS 端口（默认 `18443`） |
| `EASYBOT_PORT` | ✔ | ✔ | EasyBot 内网端口（默认 `8080`） |
| `EASYBOT_ADMIN_PASSWORD` | ✔ | ✔ | EasyBot 管理后台密码（强密码） |
| `MCS_WEB_PORT` | ✔ | ✔ | MCSManager Web 端口（默认 `23333`） |
| `MCS_DAEMON_PORT` | ✔ | ✔ | MCSManager Daemon 端口（默认 `24444`） |
| `STATUS_PORT` | ✔ | ✔ | Gatus 状态页内网端口（默认 `8080`，仅 expose） |
| `QQBOT_APP_ID` | ✔ | ✔ | QQ 开放平台 AppID（接 QQ 时必填） |
| `QQBOT_CLIENT_SECRET` | ✔ | ✔ | QQ 开放平台 ClientSecret（接 QQ 时必填） |
| `MARIADB_ROOT_PASSWORD` | ✔ | ✔ | MariaDB root 密码（强密码，密钥） |
| `MARIADB_DATABASE` | ✔ | ✔ | 插件默认数据库名（如 `papermc`） |
| `MARIADB_USER` | ✔ | ✔ | 插件连接用户名（如 `mc`） |
| `MARIADB_PASSWORD` | ✔ | ✔ | 插件连接密码（强密码，密钥） |

可选适配器：EasyBot 支持 Telegram / Discord / 飞书，在 `.env` 按需启用对应变量即可
（模板里已有注释示例）。微信为扫码登录、默认自动启用，不需要时禁用，见
[docs/easybot.md](easybot.md)（`gateway.local.yaml`）。

**应用数据库 MariaDB**：平台层常驻服务（默认启用，无开关）。插件挂 `orzmc_default`
内网直连 `jdbc:mysql://mariadb:3306/<MARIADB_DATABASE>`（仅 `expose` 3306，不发布
宿主机、无公网/边缘入口）。数据落 `$DATA_ROOT/database/mariadb`，随整机备份。
> ⚠️ **既有部署迁移**：`ensure_env_file` 不覆盖已有 `.env`，存量环境需手动把上面
> `MARIADB_*` 四项与 `DOMAIN_STATUS` / `STATUS_PORT` 两行补进 `$DATA_ROOT/.env`，再跑
> `deploy.sh validate`（会强制校验）。

### 4.2 双 Profile

| Profile | 边缘层 | 用途 | 入口 | 触发方式 |
|---|---|---|---|---|
| `local` | Caddy（`.localhost` + 本地 CA + 非特权端口） | 本地验证 / 回归 | `mcs.localhost` / `easybot.localhost` / `mcs-node.localhost` / `orzmcs.localhost` | `./local.sh ...`（固定 local） |
| `prod` | cloudflared（Cloudflare Tunnel） | 生产（NAT 免开端口） | `mcs.<domain>` / `easybot.<domain>` / `mcs-node.<domain>` / `orzmcs.<domain>` | `deploy.sh ...`（默认 prod） |

`compose.yaml` 中 `reverse-proxy`（Caddy）挂 `profiles: ["local"]`、`cloudflared`
挂 `profiles: ["prod"]`；`mcsmanager-web` / `mcsmanager-daemon` / `easybot` / `mariadb` /
`status` 无 profile，两种模式都运行。脚本通过 `COMPOSE_PROFILE`（默认 `prod`）选择边缘层；
`deploy.sh -p local ...` 也可显式切换。

### 4.3 域名约定

子域名 = 产品代号，无后缀即该产品管理控制台；`orzmcs` 为平台自身入口（统一状态页）。

| 子域名 | 用途 |
|---|---|
| `mcs.<domain>` | MCSManager 面板 |
| `easybot.<domain>` | EasyBot 管理后台 |
| `mcs-node.<domain>` | MCSManager daemon（浏览器直连，daemon key 鉴权） |
| `orzmcs.<domain>` | 统一状态页（Gatus：聚合产品入口 + 实时健康，无鉴权仅状态） |

**插件 API 不设域名**——PaperMC 插件跑在 `orzmc_default` 网络内直连 `http://easybot:8080`。

### 4.4 模板同步

改动了仓库 `templates/` 下的边缘模板后，需要同步到 `$DATA_ROOT`：

```bash
deploy.sh -d <DATA_ROOT> templates --diff     # 只看差异（默认）
deploy.sh -d <DATA_ROOT> templates --force    # 备份旧文件后覆盖
```

`init` 生成的引导文件**绝不覆盖已有文件**（`ensure_*` 系列）；模板变更一律用上面的命令同步。

---

## 5 日常运维

### 5.1 启停与状态

| 场景 | 本地 | 生产 |
|---|---|---|
| 启动平台层 | `./local.sh start` | `deploy.sh -d <DATA_ROOT> up` |
| 停止 | `./local.sh stop` | `deploy.sh -d <DATA_ROOT> stop` |
| 状态与访问地址 | `./local.sh status` | `deploy.sh -d <DATA_ROOT> status` |
| 校验配置 | `deploy.sh -d ./.local-data validate` | `deploy.sh -d <DATA_ROOT> validate` |

`stop` 等价于 `down --remove-orphans`，`status` 等价于 `ps`，`validate` 等价于 `config`
（别名可互换）。看服务日志：`docker logs -f orzmc-<服务名>`（如 `orzmc-mcsmanager-daemon`）。

### 5.2 改配置

1. 编辑 `.env`（或改仓库 `templates/` 后同步）。
2. `deploy.sh -d <DATA_ROOT> validate` 校验。
3. `deploy.sh -d <DATA_ROOT> up` 生效（compose 会重建变更的服务）。

> 边缘层改配置需重启生效：Caddy 不热加载 bind 挂载的 Caddyfile，cloudflared 启动时读
> config——同步后执行 `stop && up`。

### 5.3 平台层升级与回滚

`compose.yaml` 镜像一律 **digest 锁定**（`image:xxx@sha256:...`）。升级分两步：

```bash
# 1. 拉取并刷新 digest（可指定服务：./update-image-digests.sh easybot；默认全部 6 个）
./update-image-digests.sh

# 2. 审查改动并提交（回到仓库根目录）
git diff -- compose.yaml
git add compose.yaml && git commit -m "chore: update docker image digests"
git push

# 3. 重新拉起
deploy.sh -d <DATA_ROOT> up
```

**回滚**：`git revert <commit>` 后重新 `up`。升级/回滚**不触碰 `$DATA_ROOT`**，数据不变。

### 5.4 PaperMC 实例版本升级

PaperMC 实例**不在 compose 内**，由 MCSManager 管理；实例的 `updateCommand` 为空 =
**手动升级**。本质是**替换 `server/paper.jar` + 重启实例**（paperclip 结构：`paper.jar`
是启动器，实际服务端 jar 在 `versions/<版本>/`，首次启动自动拉取）。

1. **先备份**（跨版本必做）：面板停止实例 → `backup.sh -d <DATA_ROOT> --stop` →
   校验归档含 `world/`。
2. **确认新版本的 Java 要求**：

   | Paper 版本 | 需要的 Java | 对应镜像 |
   |---|---|---|
   | 26.2（本仓库当前） | Java 25 | `eclipse-temurin:25-jre` |
   | 1.21.1 | Java 21 | `eclipse-temurin:21-jre` |

   - 同代小版本：镜像不用动。
   - 跨代升 Java：需改 `InstanceConfig/<uuid>.json` 的 `docker.image`，走
     [第 6.5 节](#65-生命周期与改配置)的正确姿势（停实例 → 改 JSON → 重启 daemon
     容器 → 再启动），运行中改会被内存副本覆盖。

3. **替换 jar 并重启**（面板文件管理或宿主机目录均可，先停实例）：

   ```bash
   SRV=$DATA_ROOT/instances/<实例名>/server
   mv "$SRV/paper.jar" "$SRV/paper.jar.bak-$(date +%Y%m%d)"   # 备份旧启动器（回滚用）
   # 从 papermc.io/downloads 下载目标版本的 paperclip jar，命名为 paper.jar 放入 $SRV/
   ```

   在**面板**启动实例（⚠️ 不要 `docker restart MCSM-<uuid>`，会被 daemon 当停止回收）。
   首次启动自动拉取 `versions/<新版本>/`；观察：`Done (Xs)!`、`[OrzMC] EasyBot WebSocket
   认证成功`、世界加载无报错。

4. **跨大版本注意**：
   - **世界格式只前向兼容**：升大版本后旧版通常读不了新世界，升级前那份含 `world/` 的
     备份是唯一降级手段。
   - **插件兼容**：OrzMC 插件 api-version 26.1.2 随 Paper 26.x；换大版本需确认插件版本匹配。
   - **配置兼容**：`server.properties` 与 Paper 的 `config/` 全局配置跨版本可能要求迁移，
     以启动日志为准。

**回滚**：把 `paper.jar.bak-<日期>` 改回 `paper.jar`（或 restore 世界备份）→ 面板重启。
若世界已被新版本写过格式，旧版可能读不了——跨版本前务必先备份。

### 5.5 备份

```bash
./backup.sh -d <DATA_ROOT> --stop      # 先停 compose 再打包再拉起（更一致）
./backup.sh -d <DATA_ROOT>             # 在线打包（best-effort）
./backup.sh -d <DATA_ROOT> --keep 7    # 只保留最近 7 份
./backup.sh -d <DATA_ROOT> -o /mnt/backups   # 指定归档目录
```

- 归档**整个 `$DATA_ROOT`**（含 `.env`、cloudflared 凭据、各服务数据、`instances/`、
  `database/`），默认输出到 `$(dirname $DATA_ROOT)/orzmc-backups`（在 DATA_ROOT 之外，
  避免自我包含）。
- 归档名：`orzmc-backup-YYYYmmdd-HHMMSS.tar.gz`。
- **MariaDB 逻辑备份**：打包前自动 `mariadb-dump --all-databases --single-transaction`
  产出一致快照到 `$DATA_ROOT/database/dumps/mariadb-all-*.sql`（随归档一起备份），
  **无论是否 `--stop`** 归档都含一致逻辑快照；dump 失败不中断整机备份（归档仍含
  冷数据目录）。`--keep` 会同步剪掉过期的逻辑备份。
- ⚠️ **重要**：PaperMC 实例**不在 compose 内**（由 MCSManager 管理），`--stop` 只保证
  compose 一致性。要完全一致的快照，请先在面板**停止实例**再备份。
- 迁移基线建议：先面板停实例 → `backup.sh --stop` → 校验归档（`tar tzf`）确认含
  `world/` 与各密钥文件。

### 5.6 还原

```bash
./restore.sh -d <目标DATA_ROOT> <归档.tar.gz>       # 还原
./restore.sh -d <目标DATA_ROOT> <归档.tar.gz> --force --start   # 覆盖非空目标并拉起
```

- 目标目录非空时默认拒绝，`--force` 把旧目录移为 `.old-<时间>`（不删除）。
- 归档顶层目录名与目标不一致时默认拒绝，`--force` 解压后改名。
- 还原到**新路径**时自动改写 `.env` 内的 `DATA_ROOT`（迁移核心），并保留
  `.env.bak-restore`。
- **应用数据库**：整树解包自动还原 `database/mariadb`（冷数据目录，**权威**）与
  `database/dumps/*.sql`（逻辑快照，**兜底**）。`restore.sh` 会校验数据目录存在；
  若归档只有逻辑备份（冷目录缺失/损坏），解压后手动导入再启动：
  `docker exec -i orzmc-mariadb mariadb -uroot -p"<MARIADB_ROOT_PASSWORD>" < database/dumps/mariadb-all-*.sql`
  （⚠️ 归档解压在 DATA_ROOT 内，命令须在该 DATA_ROOT 对应的栈上执行）。
- 详细迁移流程见[第 10 章](#10-迁移到新主机)。

---

## 6 管理 PaperMC 实例

PaperMC 实例**不是** `compose.yaml` 的常驻服务，而是在 MCSManager 面板里创建的
**实例**，由 MCSManager Daemon 管理，生命周期与平台层解耦。好处：加第二个服不用改
编排；`$DATA_ROOT/instances/` 随整体数据一起备份/迁移。

### 6.1 首次登录与建管理员

1. 打开面板入口：生产 `https://mcs.<domain>`，本地 `https://mcs.localhost:18443`。
2. 首次进入按引导**创建管理员账号**（MCSManager 默认初始密码在面板提示中，首次登录
   强制改密）。
3. 登录后进入「实例列表」首页。

### 6.2 添加节点

MCSManager 需要把 **daemon** 作为"节点"接入 Web 端：

1. 面板 → **节点管理** → **添加节点**。
2. 地址填**内部地址**：`http://mcsmanager-daemon:24444`。
3. **daemon key** 在 `$DATA_ROOT/mcsmanager/daemon/data/Config/global.json` 的 `key`
   字段（权限 600，属最高权限密钥，不要外泄）。
4. 保存后节点应显示 `connected`（已连接）。

### 6.3 节点连接地址（内网直连，ADR-011）

节点的「连接地址」同时被**面板服务端**（实例生命周期管理）与**浏览器**（终端/控制台/
文件管理）使用。**一律填内网地址** `ws://mcsmanager-daemon:24444`（与 §6.2 一致）：

- **面板服务端**经 Docker 内网直连 daemon → 实例启动/停止/配置/状态管理稳定可用。
- **勿填**公网隧道地址 `wss://mcs-node.<domain>:443`：daemon 的 socket.io 在 cloudflared
  转发路径下会被自身 koa 确定性拦截（轮询 404 / WebSocket EOF），节点永远离线
  （ADR-011；§6.2 填内部地址即已规避）。
- **浏览器直连**（终端/控制台/文件管理）在 prod 下本就走隧道、同样被拦截，**当前不可用**
  （daemon 镜像不可改，已知限制）；内网主机名浏览器侧也不可解析，无回退。本地 Caddy
  不受该 koa 拦截影响，`mcs-node.localhost` 入口保留。

daemon 全部业务路由要求 daemon key 鉴权，无 key 无权限——这是有意的安全边界。

### 6.4 创建实例

面板 → 节点 → **创建实例** → 类型选 `Minecraft Java`。完整字段参考
[`docs/papermc-template.md`](papermc-template.md)。以下是实测最容易踩的坑：

| 注意点 | 正确做法 | 说明 |
|---|---|---|
| 端口映射 | `docker.ports` 填**字符串数组** `["25566:25566/tcp"]` | 不要用对象数组，否则启动报"开放端口配置有误" |
| 内存单位 | `docker.memory: 4096`（= 4G，**MB 单位**） | 填字节值会让容器内存配额错乱 |
| 日志乱码 | `terminalOption.pty: true` | 非 pty 时 stdout/stderr 双路复用错位，每行首字符乱码（如 `D[10:52...`） |
| 插件连 EasyBot | 网络挂 **`orzmc_default`** | 实例与 easybot 同网，插件才能内网直连 `http://easybot:8080` |
| macOS 属主 | 实例目录 `chown` 给宿主用户（`sudo chown -R joker:staff <instance-dir>`） | macOS 容器内 uid 检查通过但写盘走宿主用户，`1000:1000` 会写盘失败 |
| Linux 属主 | 保持 `runAs 1000:1000` | Linux 无 macOS 问题 |
| 镜像 | 建议 digest 锁定（如 `eclipse-temurin:25-jre` 对应 Paper 26.2） | 避免无意升级；模板建议用固定 tag |

字段速记：运行方式 `docker`、工作目录 `/server`、镜像拉取策略 `IfNotPresent`、
重启策略 `unless-stopped`、Ready 关键字 `Done`、编码 `utf8`、启动命令
`java -XX:+UseG1GC -XX:+ParallelRefProcEnabled -Xms4G -Xmx4G -jar paper.jar --nogui`。

### 6.5 生命周期与改配置

- 面板内可对实例：**启动 / 停止 / 重启 / 控制台 / 文件管理 / 配置编辑**。生命周期一律
  走面板（或 daemon API），**不要**直接 `docker restart MCSM-<uuid>`——会被 daemon 当作
  停止而回收容器。
- ⚠️ **改实例配置（InstanceConfig JSON）的正确姿势**：实例**运行中**直接改
  `InstanceConfig/<uuid>.json` 会被 daemon 用内存副本覆盖写回。正确顺序：

  ```bash
  # 1. 面板先停止实例
  # 2. 编辑 $DATA_ROOT/mcsmanager/daemon/data/InstanceConfig/<uuid>.json
  # 3. 重启 daemon 容器，从磁盘重载
  docker restart orzmc-mcsmanager-daemon
  # 4. 面板再启动实例
  ```

---

## 7 EasyBot 接入

EasyBot 是统一 IM 网关。QQ 走 **QQ 开放平台**官方 bot 凭据
（`.env` 的 `QQBOT_APP_ID` / `QQBOT_CLIENT_SECRET`），非个人账号扫码登录。

### 7.1 后台初始化

1. 打开后台：生产 `https://easybot.<domain>`，本地 `https://easybot.localhost:18443`。
2. 用 `.env` 的 `EASYBOT_ADMIN_PASSWORD` 登录/初始化。
3. 确认 QQ 适配器在线：`docker logs orzmc-easybot` 出现 `QQ Gateway ready` / `bot 在线`。

### 7.2 API Key 与会话

1. 后台 → **API 密钥** → 创建**客服类**密钥，得到 `sk-xxxxxxxx` / `eb_xxxxxxxx`，
   记下来填进插件 `easybot.yml`。
2. 后台 → **会话管理** → 为各平台创建会话，复制**会话 key**（如 `qq:conv_xxxxxx`）。
   - 注意：这些是 EasyBot 后台分配的会话 key，**不是**平台原生 ID（QQ 群号等）。

### 7.3 插件 easybot.yml

PaperMC 实例在面板打开 `plugins/OrzMC/easybot.yml`（实例须挂 `orzmc_default` 网络）：

```yaml
api_server: 'http://easybot:8080'
ws_server: 'ws://easybot:8080'
api_key: 'sk-xxxxxxxxxxxxxxxx'        # 7.2 创建的客服类 API Key
platforms:
  qq:
    enabled: true
    admin_group: 'qq:conv_xxxxxxxx'   # 管理群会话 key
    player_group: ''                  # 玩家群（留空降级 admin_group）
    admin_dm: 'qq:conv_yyyyyyyy'      # 管理员私聊会话 key
```

### 7.4 验证

- 实例日志出现：`[OrzMC] EasyBot WebSocket 认证成功`。
- 插件启动通知：EasyBot 日志 `POST /api/v1/messages/batch-send status=200`。
- QQ 测试群收到消息（依赖 QQ 开放平台 bot 审核通过）。

### 7.5 权限模型（403 排查入口）

发送消息需要**两层授权**同时满足：

1. **API key 权限**：`api_keys.permissions` 需含 `messagessend`（和 `websocketconnect`）。
2. **会话授权**：`target_grants` 里有该 key 的 `subject_id` 对目标 `platform+chat_id`
   的 `messages:send` 授权。

发消息报 `403` 时，按这两层查（详见 [docs/easybot.md](easybot.md)「运维注意」）。

---

## 8 安全基线

| 对象 | 位置 | 处理 |
|---|---|---|
| 全部环境变量 + 密钥 | `$DATA_ROOT/.env` | 权限 600，**永不入库** |
| Cloudflare 隧道凭据 | `$DATA_ROOT/cloudflared/cert.pem`、`<tunnel-id>.json` | 按密钥对待：仅 DATA_ROOT 内、随备份、权限收紧 |
| daemon key | `$DATA_ROOT/mcsmanager/daemon/data/Config/global.json` | 等同最高权限（可管理宿主机 Docker），600、随备份、永不入库 |
| EasyBot API key / 会话 key | 插件 `easybot.yml` | 密钥，不入库 |
| MariaDB 密码 | `$DATA_ROOT/.env` 的 `MARIADB_ROOT_PASSWORD` / `MARIADB_PASSWORD` | 600、随备份、永不入库 |
| MariaDB 逻辑备份 | `$DATA_ROOT/database/dumps/*.sql` | 含 `mysql` 系统库（用户/授权），600、随备份、永不入库 |

- **公网暴露面只有 4 个入口**：`mcs` / `easybot` / `mcs-node`（均有鉴权）+ `status`
  （统一状态页，无鉴权仅服务名与状态、不含密钥）。
  **EasyBot 插件 API 仅内网**（`http://easybot:8080`），无公网域名。
- **prod 不发布任何宿主机端口**（全部服务仅 `expose`）。
- **可信边界**：`mcsmanager-daemon` 挂载 `/var/run/docker.sock`，能管理宿主机 Docker——
  宿主机必须视为可信环境。
- **git 卫生**：`.env`、`.local-data/`、`.local-backups/`、生产 `DATA_ROOT` 内容都在
  `.gitignore`，不要 `git add -f`；提交前 `git status` 核对无数据/密钥泄漏。

---

## 9 故障排查

> 通用诊断顺序：`deploy.sh -d <DATA_ROOT> status`（看服务状态）→ `validate`（看配置）
> → `docker logs orzmc-<服务名>`（看日志）。

| 症状 | 原因 | 解决 |
|---|---|---|
| 面板/后台打不开 | 服务没起 / 域名未解析 / 隧道没注册 | `status` 看服务；`docker logs orzmc-cloudflared` 看隧道是否注册；确认 DNS CNAME 已生效 |
| 本地 Caddy 自签警告 | 本地 CA 首次访问 | 浏览器放行即可（.localhost 本地证书） |
| 实例日志每行首字符乱码 | `terminalOption.pty: false` | 按[第 6.4 节](#64-创建实例)开启 pty 后重启 |
| 插件发消息 403 | key 缺 `messagessend` 权限，或会话未授权 | 按[第 7.5 节](#75-权限模型403-排查入口)两层检查 |
| EasyBot 报 `SQLITE_CORRUPT`（code 11） | 用外部 `sqlite3` CLI 读了运行中的 `gateway.db`（WAL 并发） | **勿用外部 sqlite3 读活跃库**；停网关正常关库 checkpoint 后可无损恢复；日常查询走后台/API |
| 实例容器"消失" | 直接 `docker restart MCSM-<uuid>` 被 daemon 当作停止并回收 | 实例生命周期一律走面板/daemon API |
| 玩家进不去 `25565` | 实例未启动 / 端口映射错 / `online-mode` 阻挡 | 面板启动实例；核对 `docker.ports`；离线服把 `server.properties` 的 `online-mode` 设 `false` |
| 隧道连不上 | `cert.pem`/隧道凭据缺失，或旧主机隧道仍活跃 | 确认 `<DATA_ROOT>/cloudflared/` 有 `cert.pem` 与 `<id>.json`；同一子域名只能归一个隧道，停旧机 cloudflared |
| 改了实例 JSON 又回退 | 实例运行中直接改被内存副本覆盖 | 按[第 6.5 节](#65-生命周期与改配置)正确顺序：停→改→重启 daemon→起 |

更多实战教训记录在 `EXECUTION_PATH.md`。

---

## 10 迁移到新主机（整服搬迁）

整服迁移 = **运行时**（仓库）与**数据**（`$DATA_ROOT`）分开搬：新机装好运行时后，
`restore.sh` 还原数据目录即可。

### 分步流程

```bash
# 源机：
# 1. 先在 MCSManager 面板停止所有 PaperMC 实例（保证世界一致快照）
# 2. 备份（含数据目录与密钥）
./backup.sh -d <DATA_ROOT> --stop
# 3. 拷贝归档到新机（scp / U 盘 / 对象存储均可）

# 新机：
# 4. 装好 docker + git，克隆本仓库（运行时）
git clone <你的仓库地址> orzmc-deploy && cd orzmc-deploy
# 5. 还原到目标目录（覆盖非空目标用 --force，想还原后直接拉起加 --start）
./restore.sh -d <新DATA_ROOT> <归档.tar.gz> --force --start
# 6. 校验：validate → 三个入口可达 → 面板启动实例
```

### 差异清单（迁移注意）

| 项 | 说明 |
|---|---|
| **建议同路径** | 实例 `InstanceConfig/*.json` 的 `cwd` 是**绝对路径**，`restore.sh` 只改写 `.env` 的 `DATA_ROOT`，不改写 `cwd`。**新机建议用与源机相同的 `DATA_ROOT` 路径**，否则需手动改实例 `cwd` |
| macOS → Linux | 实例目录属主改为 `chown -R 1000:1000 <instances>`（Linux 容器内 uid 写盘）；反之 Linux → macOS 改为宿主用户属主（ADR-006） |
| 隧道单活 | 同一子域名只能归一个隧道：迁移后**停旧机 cloudflared**，新机隧道才生效 |
| 实例自启 | `eventTask.autoStart` 默认 `false`，还原后需在面板手动启动实例 |
| 实例镜像 | `eclipse-temurin:25-jre` 等实例镜像是 **tag 不是 digest**，新机需 `docker pull` |
| 平台层镜像 | `compose.yaml` 已 digest 锁定，还原后 `up` 自动拉取 |

备份/还原命令细节见[第 5.5 / 5.6 节](#55-备份)。

---

## 附录 A 命令速查

| 场景 | 本地 | 生产 |
|---|---|---|
| 初始化目录/env/边缘配置 | `./local.sh init` | `deploy.sh -d <DATA_ROOT> init` |
| 启动平台层 | `./local.sh start` | `deploy.sh -d <DATA_ROOT> up` |
| 停止 | `./local.sh stop` | `deploy.sh -d <DATA_ROOT> stop` |
| 状态与访问地址 | `./local.sh status` | `deploy.sh -d <DATA_ROOT> status` |
| 校验配置 | `deploy.sh -d ./.local-data validate` | `deploy.sh -d <DATA_ROOT> validate` |
| 模板同步 | `deploy.sh -d ./.local-data -p local templates --diff` | `deploy.sh -d <DATA_ROOT> templates --diff` |
| 备份数据 | `./local.sh backup` | `backup.sh -d <DATA_ROOT> --stop` |
| 还原/迁移 | `./restore.sh -d <目标> <归档>` | `restore.sh -d <目标> <归档> --force` |
| 打印 DATA_ROOT | `deploy.sh -p local print-root` | `deploy.sh -d <DATA_ROOT> print-root` |
| 刷新镜像 digest | `./update-image-digests.sh [服务]` | 同左 |

- `<DATA_ROOT>`：macOS 生产 `/Users/Shared/orzmc`，Linux 默认 `/srv/orzmc`。
- 别名：`stop|down`、`status|ps`、`validate|config` 可互换。
- 统一入口解析：`-d` 参数 > `ORZMC_DATA_ROOT` 环境变量 > 默认值。

## 附录 B 端口约定

| 端口 | 用途 | 说明 |
|---|---|---|
| `18080` / `18443` | local Caddy HTTP / HTTPS | 宿主机映射，仅本地 |
| `80` / `443` | Caddy 容器内监听 | local profile |
| `23333` | MCSManager Web | 容器内仅 `expose` |
| `24444` | MCSManager Daemon | 容器内仅 `expose`；浏览器经 `mcs-node.<domain>` 直连 |
| `8080` | EasyBot | 容器内仅 `expose`；插件内网直连 |
| `8080` | Gatus 状态页 | 容器内仅 `expose`（`STATUS_PORT`，与 EasyBot 各自独立容器内、互不冲突） |
| `25565` | PaperMC 正式服 | 由 MCSManager 实例映射，玩家局域网直连 |
| `25566` | PaperMC 测试服 | 同上 |
| `25575` / `25576` | RCON（可选） | 参考，默认关 |

> prod 模式**不发布任何宿主机端口**。

## 附录 C DATA_ROOT 目录树

```text
$DATA_ROOT/                        # 全部配置与数据（随备份整体迁移）
├── .env                           # 环境变量 + 密钥（权限 600）
├── caddy/
│   ├── Caddyfile                  # local profile 反代（init 生成）
│   ├── data/                      # 本地 CA 证书等
│   └── config/
├── cloudflared/
│   ├── config.yml                 # 隧道路由（init 生成，600）
│   ├── cert.pem                   # 账号级授权（密钥）
│   └── <tunnel-id>.json           # 隧道凭据（密钥）
├── mcsmanager/
│   ├── web/{data,logs}
│   └── daemon/
│       ├── data/Config/global.json    # daemon key（密钥）
│       └── logs/
├── easybot/
│   └── data/                      # gateway.db 等网关数据
├── status/
│   └── config.yaml                # Gatus 状态页配置（init 生成，绝不覆盖）
├── database/
│   ├── mariadb/                   # InnoDB 数据目录（uid/gid=999）
│   └── dumps/                     # backup.sh 逻辑备份（含系统库，密钥，600）
└── instances/
    ├── papermc-main/{server,backups}
    └── papermc-test/{server,backups}
```

## 附录 D 服务与镜像

| 服务 | 容器名 | profile | 镜像（digest 锁定） |
|---|---|---|---|
| `reverse-proxy` | `orzmc-caddy` | local | `caddy` |
| `cloudflared` | `orzmc-cloudflared` | prod | `cloudflare/cloudflared` |
| `mcsmanager-web` | `orzmc-mcsmanager-web` | 两者 | `githubyumao/mcsmanager-web` |
| `mcsmanager-daemon` | `orzmc-mcsmanager-daemon` | 两者 | `githubyumao/mcsmanager-daemon` |
| `easybot` | `orzmc-easybot` | 两者 | `ghcr.io/easyindie/easybot` |
| `mariadb` | `orzmc-mariadb` | 两者 | `mariadb:11.4`（应用数据库，插件用） |
| `status` | `orzmc-status` | 两者 | `twinproduction/gatus`（统一状态页） |

镜像版本以 `compose.yaml` 中 `image:xxx@sha256:...` 为准；刷新用 `update-image-digests.sh`。

## 附录 E 术语表

见[第 1.3 节](#13-术语表)（DATA_ROOT、Profile、daemon key、会话 key、digest 锁定、隧道）。

## 附录 F 硬件选型（按在线人数）

> 本文档的**平台层**（mcsmanager / easybot / cloudflared / mariadb / status，见附录 D）
> 实测占用**固定约 0.5–0.6 GB / 1 核**（其中 mariadb 常驻约 0.3 GB；status/Gatus 为 scratch
> 镜像，占用可忽略），不随玩家数变化——
> 所有档位的资源大头都是 PaperMC 实例本身。

### 前提：档位 = 同时在线

**"20 人服"指同时在线 20 人（concurrent），不是注册 20 人。** 100 个注册玩家同时在线 10 人，
就按 10 人档算。下表全部按"同时在线"给出。

### 分档最低要求总表

| 同时在线 | CPU（核数/单核） | 整机内存 | 磁盘(SSD) | 网络上行* | 单实例判断 |
|---|---|---|---|---|---|
| **20** | 2 核 / ≥3.5 GHz | **8 GB** | 20 GB | 20–40 Mbps | 轻松，无压力 |
| **50** | 4 核 / ≥4 GHz | **12–16 GB** | 40 GB | 50–100 Mbps | 可行，需预生成 + 视距 ≤8 |
| **100** | 6–8 核 / 顶级单核 | **16–24 GB** | 100 GB | 100–200 Mbps | **单实例临界**，必须调优 |
| **150** | 8–12 核 / 顶级单核 | **24–32 GB** | 150 GB | 150–300 Mbps | 很吃力，建议分实例 |
| **200** | 12 核+ / 顶级单核 | **32–48 GB** | 200 GB+ | ≥300 Mbps | 单实例不建议，须 hub+多实例 |

\* 网络上行指"玩家从公网进服"（隧道/端口转发）时的持续上行；本方案默认玩家局域网直连
25565，那个场景下千兆局域网即可。

> MariaDB 常驻约 0.3 GB（默认 buffer pool 128M），上表各档整机内存**已含**该固定成本且仍
> 富余（重算见下）。低内存（<8 GB）环境可调 `--innodb-buffer-pool-size=64M` 再压约 0.15 GB。
> 磁盘方面 mariadb 初始约 1 GB（系统库 + redo 日志），对 20 GB 起步的磁盘档位可忽略。

### 为什么是这些数（底层逻辑）

1. **平台层成本固定**：mcsmanager + easybot + cloudflared + mariadb 实测约
   0.5–0.6 GB / 1 核（mariadb 默认 buffer pool 128M，约 0.3 GB；可调
   `--innodb-buffer-pool-size` 压到约 0.15 GB）。20→200 人档平台层开销一样，
   涨的全是 MC 实例。
2. **MC 的硬瓶颈是单线程 tick**：20 TPS 主循环只跑在一个核上，**单核主频比核数更重要**——
   100 人档也要"顶级单核"而不是堆低主频核。核数的用处是 Paper 的**异步区块生成**、GC 线程，
   以及 150 人以上把世界拆给多个实例。内存随**已加载区块数**涨（约每玩家 100–200 MB），
   粗略估算：`堆内存 ≈ 同时在线 × 0.15–0.2 GB`，
   整机内存 ≈ 堆 + 平台(含 mariadb) 约 0.6G + 系统约 2G。
3. **三个杠杆能压配置，让"临界"档活下来**：
   - **视距**：10 → 6，实体/区块负载可降 40%+，最有效的旋钮
   - **预生成世界**（`/pregen` 类工具）：消掉"边玩边生成区块"这个最大的 CPU 尖峰，
     100 人档常靠这个不卡
   - **实体上限**：`mob-spawn-range` / `entity-activation-range` 收紧，200 人档刚需
4. **单实例天花板约 100–150 同时在线**（纯生存 vs 大量红石/刷怪塔差别极大）。150–200 档的
   最优解不是堆硬件，而是**架构改变**：hub（Velocity 类）+ 多个游戏实例分流，每实例退回
   50 人档配置。这超出本仓库"单 PaperMC 实例"模型，属架构级改动。
5. **100 人以上网络变成硬约束**：家用宽带上行普遍 20–40 Mbps，撑不住 100+ 人持续区块流，
   该档位需要机房裸金属（≥1 Gbps 上行）。

### 如何查看/调整实例内存

当前生产实例配置为 `-Xms4G -Xmx4G`（堆 4G），`InstanceConfig/<uuid>.json` 中 `memory: 4096`
（单位 MB）。调低可压低最低要求（1–3 人小服可降到 2–3G → 整机 4–5G 即可）；调高方法见
[6.5 节](#65-生命周期与改配置)（⚠️ 改配置的"停 → 改 → 重启 daemon → 启动"顺序）。

### 一句话买机建议

- **≤50 人**：8–16 GB 高主频 VPS，或家用 Mac/PC（本仓库当前生产即 20 人档：4G 堆，
  整机 8G 即可——含 mariadb 常驻约 0.3G 后仍有 1G+ 余量）
- **50–100 人**：16–24 GB **独立服务器/裸金属**，优先单核主频，SSD 必须
- **≥150 人**：别在单实例上堆钱，直接规划 hub + 分实例架构
