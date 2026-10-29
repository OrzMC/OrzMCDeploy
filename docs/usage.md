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
- [3 快速开始（三路径）](#3-快速开始三路径)
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
| **局域网直连** | 面板与 EasyBot 发布宿主端口、纯 HTTP，局域网设备直连（唯一运行形态，ADR-027） |
| **运行时与数据分离** | 仓库只承载"运行时"，全部配置与数据落宿主机 `$DATA_ROOT`，随数据整体备份/迁移 |

### 1.2 架构一图流

```mermaid
flowchart TB
    subgraph 局域网（可信内网，纯 HTTP）
        U1[浏览器/手机] -- "http://LAN_HOST_IP:18090" --> WEB
        U2[浏览器/手机] -- "http://LAN_HOST_IP:18091" --> EB
        P[玩家] -- "LAN_HOST_IP:25565" --> PLG
    end
    subgraph 宿主机 Docker（orzmc_default 网络）
        WEB["MCSManager Web :23333"]
        DAE["MCSManager Daemon :24444<br/>（挂 docker.sock）"]
        EB["EasyBot :8080"]
        PLG["PaperMC 实例容器<br/>（插件 OrzMC）"]
    end
    WEB -- "数据面中转<br/>（dataPlane=proxy）" --> DAE
    DAE -- 创建 / 管理 --> PLG
    PLG -- "http://easybot:8080<br/>（REST + WS 内网直连）" --> EB
```

要点（详见 [docs/architecture.md](architecture.md)）：

- **只有局域网模式**（ADR-027）：面板与 EasyBot 发布到宿主端口、纯 HTTP，局域网设备直连。
  对外访问由站点自备（DDNS + 端口映射 / 反代 / VPN），本项目不参与。
- **daemon 不发布端口**（ADR-026）：节点地址固定 `ws://mcsmanager-daemon:24444`；MCSManager
  10.22 起面板自己中转浏览器↔daemon 的数据流（`dataPlane=proxy`），终端/控制台/文件管理
  都经面板端口走。daemon 业务路由仍要 **daemon key** 鉴权。
- **插件 API 仅内网**：PaperMC 插件挂 `orzmc_default` 网络，直连 `http://easybot:8080`。

### 1.3 术语表

| 术语 | 含义 |
|---|---|
| **DATA_ROOT** | 宿主机上的统一数据目录，存放全部配置与密钥。默认值按平台：macOS `/Users/Shared/orzmc`、Linux `/srv/orzmc`、Windows `E:/orzmc`（`-d` / `ORZMC_DATA_ROOT` 可覆盖） |
| **局域网模式** | 本项目唯一的运行形态（ADR-027）：宿主发布 `LAN_*_PORT`，纯 HTTP |
| **daemon key** | MCSManager Daemon 的鉴权密钥，等同最高权限（daemon 可管理宿主机 Docker）。位于 `$DATA_ROOT/mcsmanager/daemon/data/Config/global.json` |
| **会话 key** | EasyBot 后台为某个平台会话分配的标识（如 `qq:xxxxxxxx`），填进插件 `easybot.yml` |
| **digest 锁定** | `compose.yaml` 里镜像用 `image:xxx@sha256:...` 固定版本，升级/回滚走 git |
| **dataPlane** | MCSManager 面板设置（`SystemConfig.dataPlane=proxy\|direct`）：proxy 时面板中转浏览器↔daemon 数据流 |

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
| 网络 | 局域网可达；宿主有固定/保留 IP 更稳 | 对外访问由路由器/反代/VPN 负责 |
| 账号（按需） | **QQ 开放平台** AppID / ClientSecret | 仅接入 EasyBot QQ 需要 |

> 提示：本项目**不需要域名、不需要 Cloudflare 账号、不需要证书**（ADR-027）。
> 要从外网访问，见 §3.4 的三条路子（VPN 最省心）。

---

## 3 快速开始（单一路径）

### 3.1 先做决定：入口只要局域网

本项目自 ADR-027 起**只提供局域网模式**：面板与 EasyBot 发布到宿主端口，纯 HTTP，
局域网设备直连。**对外访问由你自备**——DDNS + 端口映射、反向代理、或 VPN（Tailscale 等），
本仓库不参与。

- 只在自己电脑上用 → 直接用 `http://127.0.0.1:<端口>`
- 家里手机/平板/其它电脑都要用 → 把 `LAN_HOST_IP` 设成宿主局域网 IP
- 要从外网访问 → 路由器做 DDNS + 端口映射（⚠️ 面板无 TLS，公网暴露前请加 TLS 反代或改用 VPN）

### 3.2 初始化与启动（15 分钟）

```bash
# 在仓库根目录
./orzmc.sh -d /path/to/orzmc init     # 生成 .env（DATA_ROOT 按实际路径改写）
# 编辑 /path/to/orzmc/.env：
#   - LAN_HOST_IP        ← 宿主机局域网 IP（局域网设备访问入口）
#   - EASYBOT_ADMIN_PASSWORD / QQBOT_*  ← 改强口令 / 填 QQ 凭据
./orzmc.sh -d /path/to/orzmc validate # 必需变量 + compose 解析校验
./orzmc.sh -d /path/to/orzmc up       # 启动平台层
./orzmc.sh -d /path/to/orzmc status   # 打印访问地址 + 容器状态
```

省略 `-d` 时用平台默认 DATA_ROOT（Linux `/srv/orzmc`、macOS `/Users/Shared/orzmc`、
Windows `E:/orzmc`）。

**预期看到**：

- `up`：compose 拉起 `mcsmanager-web`、`mcsmanager-daemon`、`easybot`
  （`ENABLE_EASYBOT=false` 时只有前两个）。
- `status` 打印：

  | 地址 | 用途 |
  |---|---|
  | `http://<LAN_HOST_IP>:18090` | MCSManager 面板（`LAN_MCS_WEB_PORT`） |
  | `http://<LAN_HOST_IP>:18091` | EasyBot 管理后台（`LAN_EASYBOT_PORT`） |

- 端口发布核对：`docker compose --env-file <DATA_ROOT>/.env -f compose.yaml --profile easybot config`
  应只看到 `published: "18090"` 与 `"18091"`（**没有** 24444——daemon 不发布）。

### 3.3 建管理员、加节点、建实例

1. 浏览器打开面板 → 首次访问创建管理员账号。
2. 节点管理 → 添加节点：`ip = ws://mcsmanager-daemon`，`port = 24444`，key 见 §6.3。
3. 创建实例（字段参考 [`docs/papermc-template.md`](papermc-template.md)），玩家用
   `<LAN_HOST_IP>:25565` 进服。

### 3.4 对外访问（由你自备）

| 方式 | 做法 | 注意 |
|---|---|---|
| DDNS + 端口映射 | 路由器把公网端口映射到 `<宿主IP>:18090` | ⚠️ 面板是 HTTP + 口令登录：**必须**在前面加 TLS 反代（Caddy/Nginx/域名证书），并换强口令 |
| VPN（推荐） | Tailscale / WireGuard 组网，手机直接访问 `<宿主IP>:18090` | 无需开公网端口，链路加密，最省心 |
| 反向代理 | 任意带 TLS 的反代放在本机/旁路设备 | 注意 WebSocket 要放行（面板与终端都用 WS） |

> **安全前提**：局域网明文 HTTP，仅限可信内网。`LAN_HOST_IP` 变化（DHCP 重新分配）需
> 同步改 `.env` 并重新 `init`；建议给宿主做 DHCP 保留或静态 IP。
> daemon 端口不发布（ADR-026），外部无法直连 daemon。

---

## 4 配置详解

### 4.1 DATA_ROOT 与 .env

**DATA_ROOT 优先级**：命令行 `-d/--data-root` 参数 > 环境变量 `ORZMC_DATA_ROOT` >
平台默认值（macOS `/Users/Shared/orzmc`、Linux `/srv/orzmc`、Windows `E:/orzmc`）。所有脚本
（deploy / backup / restore）统一按此解析，并用 `compose_cmd` 显式 `--env-file
$DATA_ROOT/.env` 调用 compose。

`.env` 是**唯一配置源**（含密钥）。首次由 `init` 从 `templates/env` 生成，之后**改配置 =
编辑 `.env`**。必需变量清单由 `lib/common.sh` 的 `required_env_list` 定义（`orzmc.sh validate`
校验）：

| 变量 | 必需 | 说明 |
|---|---|---|
| `TZ` | ✔ | 时区，如 `Asia/Shanghai` |
| `LAN_HOST_IP` | ✔ | 宿主机局域网 IP（打印访问地址用；DHCP 变更需同步更新） |
| `LAN_MCS_WEB_PORT` | ✔ | 面板宿主发布端口（默认 `18090`） |
| `LAN_EASYBOT_PORT` | ✔ | EasyBot 宿主发布端口（默认 `18091`） |
| `MCS_WEB_PORT` | ✔ | MCSManager Web 容器内端口（默认 `23333`） |
| `MCS_DAEMON_PORT` | ✔ | MCSManager Daemon 容器内端口（默认 `24444`，不发布） |
| `EASYBOT_PORT` | ✔ | EasyBot 容器内端口（默认 `8080`） |
| `EASYBOT_ADMIN_PASSWORD` | ✔ | EasyBot 管理后台密码（强密码） |
| `QQBOT_APP_ID` / `QQBOT_CLIENT_SECRET` | ✔（启用 EasyBot 时） | QQ 开放平台凭据 |
| `ENABLE_EASYBOT` | 可选 | 缺省 `true`；`false` 则不启动 EasyBot |
| `LAN_BIND_ADDR` | 可选 | 端口绑定地址（缺省 `0.0.0.0`；`127.0.0.1` 仅本机，ADR-028） |
| `LAN_CIDR` / `ALLOW_EXTRA_CIDRS` | 可选 | 防火墙放行来源（只需 `firewall` 时关心） |
| `MC_TCP_PORTS` / `MC_UDP_PORTS` / `RCON_PORTS` | 可选 | 实例进服端口的防火墙放行清单（仅 `firewall` 使用） |
| `DAEMON_MEMORY_LIMIT` / `DAEMON_NODE_HEAP_MB` | 可选 | daemon 容器/堆上限（缺省 512M / 384） |
| `EASYBOT_MEMORY_LIMIT` | 可选 | EasyBot 上限（缺省 512M） |
| `DAEMON_PORTS` | 可选 | 仅 Windows 进程模式实例：daemon `-p` 注入（默认置空） |
| `COMPOSE_FILE_EXTRA` | 可选 | 追加任意路径 compose 文件（空格/逗号分隔） |

可选适配器：EasyBot 支持 Telegram / Discord / 飞书，在 `.env` 按需启用对应变量即可
（模板里已有注释示例）。微信为扫码登录、默认自动启用，不需要时禁用，见
[docs/easybot.md](easybot.md)（`gateway.local.yaml`）。

**插件数据库默认用本地存储**：平台层不内置 MariaDB（ADR-025）。需要 MySQL/MariaDB 时
在 `$DATA_ROOT/compose.site.yaml` 用站点增量加回，升级换包不丢（见
[papermc-template.md](papermc-template.md) 的「插件数据库」一节）。

### 4.2 运行模型：局域网模式（ADR-027）

只有一个运行集：面板与 EasyBot 发布宿主端口，纯 HTTP。全部配置在 `$DATA_ROOT/.env`，
唯一入口 `orzmc.sh`：

| 维度 | 配置（`.env`） | 说明 |
|---|---|---|
| 局域网入口 | `LAN_HOST_IP` / `LAN_MCS_WEB_PORT`(18090) / `LAN_EASYBOT_PORT`(18091) | `compose.yaml` 直接把这两个端口发布到宿主 |
| 可选服务 | `ENABLE_EASYBOT`（缺省 `true`） | 置 `false` 即从 `--profile` 移除；核心 web/daemon 常驻 |
| 入口命令 | `./orzmc.sh [-d DATA_ROOT] init\|up\|stop\|status\|validate\|backup\|firewall` | 三平台一致 |

- **没有边缘层服务**：不跑 cloudflared / Caddy，也没有 `compose.edge.*.yaml`。
  历史上按 `EDGE=cloudflare|local|lan|none` 切换的四档已随 ADR-027 移除。
- **daemon 不发布端口**（ADR-026）：面板中转浏览器↔daemon 数据流，节点地址固定内网名。
- **对外访问**：DDNS + 端口映射 / 反代 / VPN，均由站点自备（见 §3.4）。

### 4.3 入口与端口约定

| 入口 | 地址 | 说明 |
|---|---|---|
| 面板 | `http://<LAN_HOST_IP>:<LAN_MCS_WEB_PORT>` | 缺省 18090；登录鉴权 |
| EasyBot 后台 | `http://<LAN_HOST_IP>:<LAN_EASYBOT_PORT>` | 缺省 18091；登录鉴权 |
| 插件 API | `http://easybot:8080` | 仅 `orzmc_default` 内网可达，不对外 |
| PaperMC 实例 | `<LAN_HOST_IP>:<实例端口>` | 由 MCSManager 按实例配置发布（如 25565） |

- 本项目**不使用域名、不配置 TLS**（ADR-027）。需要对外访问时自备反代/VPN，见 §3.4。
- 端口冲突时改 `.env` 的 `LAN_*_PORT` 后 `up` 重建即可。

### 4.4 引导文件与模板

`init` 会生成/补齐这些运行文件（**绝不覆盖已有文件**，`ensure_*` 系列）：

| 文件 | 内容 |
|---|---|
| `$DATA_ROOT/.env` | 由 `templates/env` 生成（`DATA_ROOT` 行按生效值改写） |
| `$DATA_ROOT/compose.site.yaml` | 站点增量模板（`templates/compose.site.yaml`） |
| `$DATA_ROOT/easybot/data/gateway.local.yaml` | EasyBot 本地覆盖（`templates/gateway.local.yaml`） |

想用仓库新模板重建某个文件时：先备份/删除旧文件，再 `./orzmc.sh init`（`ensure_*`
永不覆盖已有文件）。

### 4.5 站点增量 override：`compose.site.yaml`（升级不丢）

`compose.yaml` 是**包内运行时文件**，升级换包（`git pull` 或重下
Release tarball）会整体替换。站点特有增量（如飞书 `FEISHU_*`、额外环境变量、额外挂载）
直接写进包内文件，升级后必丢（表现为「升级后机器人不工作了」）。

为此提供官方**站点增量挂载点** `$DATA_ROOT/compose.site.yaml`（`init` 生成模板，绝不覆盖）：

- `compose_cmd` 检测到该文件即自动追加 `-f`，与包内文件彻底解耦；文件在 `$DATA_ROOT`
  （随数据备份/迁移），升级/换包不丢。
- 另支持 `.env` 的 `COMPOSE_FILE_EXTRA=`（空格/逗号分隔）追加**任意路径**的 compose 文件
  （可放仓库/数据目录之外）。
- 合并语义是 Docker Compose 原生 override：同名字段「后加载覆盖先加载」，`environment` 等
  map 逐键合并，`volumes` 列表追加。
- 值优先放 `.env`（密钥不入库），site 文件用 `${VAR}` 引用。改完 `./orzmc.sh validate`
  校验、`./orzmc.sh up` 生效。

例：给 `easybot` 增加飞书适配器（`FEISHU_APP_ID` / `FEISHU_APP_SECRET` 填 `$DATA_ROOT/.env`）：

```yaml
services:
  easybot:
    environment:
      FEISHU_APP_ID: "${FEISHU_APP_ID}"
      FEISHU_APP_SECRET: "${FEISHU_APP_SECRET}"
```

> 模板文件是 `templates/compose.site.yaml`（含注释示例）；也可直接编辑已生成的
> `$DATA_ROOT/compose.site.yaml`。

---

## 5 日常运维

### 5.1 启停与状态

| 场景 | 命令 |
|---|---|
| 启动平台层 | `./orzmc.sh -d <DATA_ROOT> up` |
| 停止 | `./orzmc.sh -d <DATA_ROOT> stop` |
| 状态与访问地址 | `./orzmc.sh -d <DATA_ROOT> status` |
| 校验配置 | `./orzmc.sh -d <DATA_ROOT> validate` |
| 备份 | `./orzmc.sh -d <DATA_ROOT> backup [--stop]` |

`stop` 内部就是 `compose down --remove-orphans`，`status` 打印访问地址后再跑 `compose ps`，
`validate` 跑必需变量检查 + `compose config -q`。看服务日志：
`docker logs -f orzmc-<服务名>`（如 `orzmc-mcsmanager-daemon`）。

### 5.2 改配置

1. 编辑 `$DATA_ROOT/.env`。
2. `./orzmc.sh -d <DATA_ROOT> validate` 校验。
3. 让改动生效：`./orzmc.sh -d <DATA_ROOT> up`（端口等字段变更会重建容器）。

### 5.3 平台层升级与回滚

`compose.yaml` 里的镜像一律 **digest 锁定**（`image:xxx@sha256:...`）。升级分两步：

```bash
# 1. 拉取并刷新 digest（默认 3 个服务：mcsmanager-web / daemon / easybot）
./update-image-digests.sh
#    指定服务：./update-image-digests.sh easybot
#    easybot 用**发布 tag**（非 latest）：EASYBOT_TAG=0.0.43 ./update-image-digests.sh easybot
#    （上游 `latest` 跟踪 main 分支，不是发布构建）

# 2. 审查改动并提交（回到仓库根目录）
git diff -- compose.yaml
git add compose.yaml && git commit -m "chore: update docker image digests"
git push

# 3. 重新拉起（digest 变了必须重建容器，up -d 会识别并重建）
./orzmc.sh stop && ./orzmc.sh up
```

**回滚**：`git revert <commit>` 后重新 `up`。升级/回滚**不触碰 `$DATA_ROOT`**，数据不变。

> 🚫 **不要使用面板内置的「自助升级」**（MCSManager 10.19+ 新增，默认取 GitHub release
> manifest，备用源 mcsmanager.com）。原因：
> 1. 它在**容器内**替换程序文件，偏离 `compose.yaml` 里锁定的 digest——`git revert` 无法回滚；
> 2. 任何 `stop && up` / 改 digest / `docker compose down` 都会把它抹掉，状态不可复现；
> 3. 与备份/还原假设不一致（归档里是自升级后的文件，换机重放得到不同版本）。
>
> 升级唯一路径：`update-image-digests.sh` → git commit → `stop && up`（附回滚）。
> 面板里看到「有新版本」提示时，把版本号记下来，按上面流程改 digest 即可。

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
     [第 6.5 节](#65-生命周期与配置持久化)的正确姿势（**先停 daemon → 改 JSON → 再启
     daemon**），运行中改会被内存副本覆盖。

3. **替换 jar 并重启**（面板文件管理或宿主机目录均可，先停实例）：

   ```bash
   # 实例 cwd 由 MCSManager 面板管理，落 daemon/data/InstanceData/<uuid>/
   SRV=$DATA_ROOT/mcsmanager/daemon/data/InstanceData/<实例uuid>
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

- 归档**整个 `$DATA_ROOT`**（含 `.env`、面板与 EasyBot 数据、
  `mcsmanager/daemon/data/InstanceData/`（面板实例数据）），默认输出到
  `$(dirname $DATA_ROOT)/orzmc-backups`（在 DATA_ROOT 之外，避免自我包含）。
- 归档名：`orzmc-backup-YYYYmmdd-HHMMSS.tar.gz`。
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
- 详细迁移流程见[第 10 章](#10-迁移到新主机)。

---

## 6 管理 PaperMC 实例

PaperMC 实例**不是** `compose.yaml` 的常驻服务，而是在 MCSManager 面板里创建的
**实例**，由 MCSManager Daemon 管理，生命周期与平台层解耦。好处：加第二个服不用改
编排；实例数据落 `$DATA_ROOT/mcsmanager/daemon/data/InstanceData/<uuid>/`，随整体数据
一起备份/迁移。

### 6.1 首次登录与建管理员

1. 打开面板入口：`http://<LAN_HOST_IP>:<LAN_MCS_WEB_PORT>`（缺省 18090）。
2. 首次进入按引导**创建管理员账号**（MCSManager 默认初始密码在面板提示中，首次登录
   强制改密）。
3. 登录后进入「实例列表」首页。

### 6.2 添加节点

MCSManager 需要把 **daemon** 作为"节点"接入 Web 端：

1. 面板 → **节点管理** → **添加节点**。
2. 地址（`ip` + `port`）固定为 `ws://mcsmanager-daemon` / `24444`
   （详见 §6.3；面板中转模式下浏览器不需要直连 daemon）。
3. **daemon key** 在 `$DATA_ROOT/mcsmanager/daemon/data/Config/global.json` 的 `key`
   字段（权限 600，属最高权限密钥，不要外泄）。
4. 保存后节点应显示 `connected`（已连接）。

### 6.3 节点连接地址（一条规则，ADR-026）

节点的「连接地址」被**面板服务端**用来连 daemon。自 MCSManager 10.22 + 本项目 ADR-026 起，
**所有平台都填同一个地址**：

| 字段 | 值 |
|---|---|
| `ip` | `ws://mcsmanager-daemon` |
| `port` | `24444` |

原理：10.22 引入「面板中转数据模式」（`SystemConfig.dataPlane=proxy`，**新装默认**），
面板自己中转浏览器↔daemon 的数据流：

- 下载/上传/断点上传（`/download/*`、`/upload-*/*`）由面板的数据面网关代理，浏览器只拿到
  面板签发的短时 token；
- 终端/控制台数据通道（`POST /stream_channel`）返回**面板自己的地址 + token**；
- 节点地址只在面板服务端使用，浏览器**再也不需要**能解析或直连 daemon。

**收益**：daemon 端口不发布、不设额外入口；局域网只有面板 / EasyBot 两个入口；
终端/控制台/文件管理在 macOS/Linux/Windows 三平台行为一致（历史上 ADR-011/013/014/020
反复纠错的三档地址表已取消）。

**旧部署一次性动作**（新装跳过）：面板配置里没有 `dataPlane` 键时按 direct 处理，
需要手工切换（面板退出会回写配置，必须停机改）：

```bash
docker stop orzmc-mcsmanager-web
# 编辑 $DATA_ROOT/mcsmanager/web/data/SystemConfig/config.json，加/改 "dataPlane": "proxy"
docker start orzmc-mcsmanager-web
```

改完后把节点地址改成上表的值（或删掉节点重新添加）。`./orzmc.sh init` 会检测并提示
（`warn_legacy_data_plane`），不会自动改你的运行数据。

daemon 全部业务路由仍要求 daemon key 鉴权，无 key 无权限——这是有意的安全边界；
key 在 `$DATA_ROOT/mcsmanager/daemon/data/Config/global.json`，权限 600，永不入库。

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

### 6.5 生命周期与配置持久化

#### 实例启停：一律走面板

- 面板内可对实例：**启动 / 停止 / 重启 / 控制台 / 文件管理 / 配置编辑**。生命周期一律
  走面板（或 daemon API），**不要**直接 `docker restart MCSM-<uuid>`——会被 daemon 当作
  停止而回收容器。
- 平台层 `stop`/`up` 只影响 web/daemon 等平台容器；**实例不随之启停**（实例由 daemon
  启动时按 `autoStart` 决定是否拉起，见下）。

#### 实例配置的权威来源是 daemon 内存（不是磁盘）

`daemon/data/InstanceConfig/<uuid>.json` 看起来像配置文件，实际是 **daemon 启动时读入
内存、并在状态变化/退出时把内存副本刷回磁盘** 的缓存：

- **运行中直接改 JSON 会被回写覆盖**（实测约 5 分钟后被刷回原值），静默无效；
- **先改 JSON 再 `docker restart daemon` 也会丢**——daemon 退出时会把内存副本刷回磁盘，
  覆盖你刚写的改动；只停**实例**（`docker stop MCSM-<uuid>`）同样不够，daemon 仍在内存
  里持有旧配置。

正确顺序是**先停 daemon，再改文件，再启 daemon**（启动时以磁盘为准）：

```bash
# 1. 面板停止相关实例（避免运行中的实例被 daemon 关闭时回写）
# 2. 停 daemon 容器（三平台容器同名；Windows 下也是 docker run 创建的同一容器名）
docker stop orzmc-mcsmanager-daemon
# 3. 编辑 $DATA_ROOT/mcsmanager/daemon/data/InstanceConfig/<uuid>.json
# 4. 启动 daemon（此时以磁盘内容为准）
docker start orzmc-mcsmanager-daemon
# 5. 面板按需启动实例
```

> 关键点：`docker stop` 的刷盘发生在**编辑之前**，所以磁盘改动不会被覆盖。

#### `autoStart` / `autoRestart` 语义（互不相关）

| 字段 | 含义 | 触发时机 |
|---|---|---|
| `eventTask.autoStart` | **daemon 启动时**是否自动拉起该实例 | daemon 容器启动 / 重启时 |
| `eventTask.autoRestart` | 实例进程**异常退出**时 daemon 是否自动重启它 | 实例崩溃 / 被 OOM kill 等 |

- 两者**相互独立**：`autoStart=true` 不会让实例崩溃后自动重启，`autoRestart=true` 也不会
  在 daemon 启动时拉起实例。
- **实例「上次是运行/停止」不做持久化**：重启后的行为由上述开关与当前内存态决定，因此
  同一份配置在不同实例上观察到不同行为（一个被拉起、一个没有）属预期，不是 bug。
- 想完全**手动启停**（不跟随 daemon/宿主重启自动起来）：把该实例的 `autoStart` 与
  `autoRestart` 都置为 `false`，再按上面的「停 daemon → 改 → 启 daemon」流程生效。

> 面板开关的 tooltip 目前只显示名称，语义以上表为准。

---

## 7 EasyBot 接入

EasyBot 是统一 IM 网关。QQ 走 **QQ 开放平台**官方 bot 凭据
（`.env` 的 `QQBOT_APP_ID` / `QQBOT_CLIENT_SECRET`），非个人账号扫码登录。

### 7.1 后台初始化

1. 打开后台：`http://<LAN_HOST_IP>:<LAN_EASYBOT_PORT>`（缺省 18091）。
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
| daemon key | `$DATA_ROOT/mcsmanager/daemon/data/Config/global.json` | 等同最高权限（可管理宿主机 Docker），600、随备份、永不入库 |
| EasyBot API key / 会话 key | 插件 `easybot.yml` | 密钥，不入库 |

- **局域网暴露 2 个端口**：面板 `LAN_MCS_WEB_PORT`、EasyBot `LAN_EASYBOT_PORT`
  （均有登录鉴权）；daemon 端口不发布（ADR-026，面板中转）。
  **EasyBot 插件 API 仅内网**（`http://easybot:8080`）。明文 HTTP **仅限可信局域网**。
- ⚠️ **对公网暴露前必须加保护**：面板与 EasyBot 都是 **HTTP + 口令登录**。做 DDNS
  端口映射前，请至少：换强口令 · 加 TLS 反代 · 或改用 VPN（推荐，无需开放公网端口）。
- **默认限源三层模型（ADR-028）**：`LAN_BIND_ADDR`（绑定地址）+ `LAN_CIDR`
  （防火墙来源）+ daemon 不发布端口。落地运行 `./orzmc.sh firewall apply`
  （Windows 需 UAC），自检 `./orzmc.sh firewall show` 与 `./orzmc.sh status`。
  详细设计与三档配置见 [security.md](security.md)。
- **daemon 端口不发布**（ADR-026）：节点的业务路由仍要 **daemon key** 鉴权（daemon 可管理
  宿主机 Docker，等同最高权限）；端口不出容器网络，不存在“局域网探测面”。
- **可信边界**：`mcsmanager-daemon` 挂载 `/var/run/docker.sock`，能管理宿主机 Docker——
  宿主机必须视为可信环境。
- **git 卫生**：`.env`、`.local-data/`、`.local-backups/`、生产 `DATA_ROOT` 内容都在
  `.gitignore`，不要 `git add -f`；提交前 `git status` 核对无数据/密钥泄漏。

---

## 9 故障排查

> 通用诊断顺序：`./orzmc.sh -d <DATA_ROOT> status`（看服务状态）→ `validate`（看配置）
> → `docker logs orzmc-<服务名>`（看日志）。

| 症状 | 原因 | 解决 |
|---|---|---|
| 面板/后台打不开 | 服务没起 / 端口未发布 / 防火墙拦截 / 用错了 IP | `./orzmc.sh status` 看服务；`docker ps` 核对宿主端口；确认访问的是 `LAN_HOST_IP` 而非 `localhost`（手机/别的机器）；检查 Windows 防火墙入站规则 |
| 实例日志每行首字符乱码 | `terminalOption.pty: false` | 按[第 6.4 节](#64-创建实例)开启 pty 后重启 |
| 插件发消息 403 | key 缺 `messagessend` 权限，或会话未授权 | 按[第 7.5 节](#75-权限模型403-排查入口)两层检查 |
| EasyBot 报 `SQLITE_CORRUPT`（code 11） | 用外部 `sqlite3` CLI 读了运行中的 `gateway.db`（WAL 并发） | **勿用外部 sqlite3 读活跃库**；停网关正常关库 checkpoint 后可无损恢复；日常查询走后台/API |
| 实例容器"消失" | 直接 `docker restart MCSM-<uuid>` 被 daemon 当作停止并回收 | 实例生命周期一律走面板/daemon API |
| 玩家进不去 `25565` | 实例未启动 / 端口映射错 / `online-mode` 阻挡 | 面板启动实例；核对 `docker.ports`；离线服把 `server.properties` 的 `online-mode` 设 `false` |
| 改了实例 JSON 又回退 | 实例运行中直接改被内存副本覆盖；先改后 `docker restart` 也会被退出刷盘覆盖 | 按[第 6.5 节](#65-生命周期与配置持久化)正确顺序：**停 daemon → 改 → 启 daemon** |

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
| macOS → Linux | 实例目录属主改为 `chown -R 1000:1000 <mcsmanager/daemon/data/InstanceData>`（Linux 容器内 uid 写盘）；反之 Linux → macOS 改为宿主用户属主（ADR-006） |
| 实例自启 | `eventTask.autoStart` 默认 `false`，还原后需在面板手动启动实例 |
| 实例镜像 | `eclipse-temurin:25-jre` 等实例镜像是 **tag 不是 digest**，新机需 `docker pull` |
| 平台层镜像 | `compose.yaml` 已 digest 锁定，还原后 `up` 自动拉取 |

备份/还原命令细节见[第 5.5 / 5.6 节](#55-备份)。

---

## 附录 A 命令速查

| 场景 | 命令 |
|---|---|
| 初始化目录/env | `./orzmc.sh -d <DATA_ROOT> init` |
| 启动平台层 | `./orzmc.sh -d <DATA_ROOT> up` |
| 停止 | `./orzmc.sh -d <DATA_ROOT> stop` |
| 状态与访问地址 | `./orzmc.sh -d <DATA_ROOT> status` |
| 校验配置 | `./orzmc.sh -d <DATA_ROOT> validate` |
| 备份数据 | `./orzmc.sh -d <DATA_ROOT> backup [--stop] [--keep N]` |
| 还原/迁移 | `./restore.sh -d <目标> <归档> [--force]` |
| 打印 DATA_ROOT | `./orzmc.sh -d <DATA_ROOT> print-root` |
| 刷新镜像 digest | `./update-image-digests.sh [服务]` |
| 防火墙收敛 | `./orzmc.sh firewall show` / `apply` |

- `<DATA_ROOT>` 默认值：macOS `/Users/Shared/orzmc`、Linux `/srv/orzmc`、Windows `E:/orzmc`。
- 统一入口解析：`-d` 参数 > `ORZMC_DATA_ROOT` 环境变量 > 平台默认值。
- 非 Windows 平台的 `firewall apply` 需 root/管理员（Linux 走 `ufw`，macOS 只打印 `pf` 规则）。

## 附录 B 端口约定

| 端口 | 用途 | 说明 |
|---|---|---|
| `18090` / `18091` | 宿主发布端口：面板 / EasyBot | `LAN_*_PORT` 可覆盖 |
| `24444` | MCSManager Daemon | 容器内端口，不发布到宿主；面板服务端经内网名 `mcsmanager-daemon` 连接，浏览器数据面走面板中转（ADR-026） |
| `23333` | MCSManager Web | 容器内端口（宿主经 `LAN_MCS_WEB_PORT` 映射） |
| `8080` | EasyBot | 容器内端口（宿主经 `LAN_EASYBOT_PORT` 映射）；插件内网直连 |
| `25565` | PaperMC 正式服 | 由 MCSManager 实例映射，玩家局域网直连 |
| `25566` | PaperMC 测试服 | 同上 |
| `25575` / `25576` | RCON（可选） | 参考，默认关 |

> 除上面两个 `LAN_*_PORT` 源站端口外，其余端口都不发布到宿主（仅容器网络内可达）。
> PaperMC 实例端口由 MCSManager 按实例配置发布，供局域网玩家直连。

## 附录 C DATA_ROOT 目录树

```text
$DATA_ROOT/                        # 全部配置与数据（随备份整体迁移）
├── .env                           # 环境变量 + 密钥（权限收紧）
├── compose.site.yaml              # 站点增量 override（升级换包不丢）
├── mcsmanager/
│   ├── web/{data,logs}
│   └── daemon/
│       ├── data/Config/global.json    # daemon key（密钥）
│       ├── data/InstanceData/<uuid>/  # 面板创建的实例数据（cwd，含 world/plugins/...）
│       └── logs/
└── easybot/
    └── data/                      # gateway.db 等网关数据
```

> ADR-025/027 之前的旧部署可能还留有 `database/`、`status/`、`caddy/`、`cloudflared/`，
> 确认不再需要后可删除（`cloudflared/` 内含隧道凭据，属密钥，先归档再删）。

## 附录 D 服务与镜像

| 服务 | 容器名 | 说明 | 镜像（digest 锁定） |
|---|---|---|---|
| `mcsmanager-web` | `orzmc-mcsmanager-web` | 常驻，宿主 `LAN_MCS_WEB_PORT` | `githubyumao/mcsmanager-web` |
| `mcsmanager-daemon` | `orzmc-mcsmanager-daemon` | 常驻 | `githubyumao/mcsmanager-daemon` |
| `easybot` | `orzmc-easybot` | 可选（`ENABLE_EASYBOT`），宿主 `LAN_EASYBOT_PORT` | `ghcr.io/easyindie/easybot` |

镜像版本以 `compose.yaml` 中的 `image:xxx@sha256:...` 为准；刷新用
`update-image-digests.sh`（三个服务的镜像映射只在该脚本一处维护）。

## 附录 E 术语表

见[第 1.3 节](#13-术语表)（DATA_ROOT、局域网模式、daemon key、会话 key、digest 锁定、dataPlane）。

## 附录 F 硬件选型（按在线人数）

> 本文档的**平台层**（mcsmanager-web / daemon / easybot，见附录 D）实测占用
> **固定约 0.2–0.3 GB / 1 核**，不随玩家数变化——
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

\* 网络上行指"玩家从公网进服"（端口转发/VPN）时的持续上行；本方案默认玩家局域网直连
25565，那个场景下千兆局域网即可。


### 为什么是这些数（底层逻辑）

1. **平台层成本固定**：mcsmanager（web+daemon）+ easybot 实测约
   0.25–0.3 GB / 1 核。20→200 人档平台层开销一样，涨的全是 MC 实例。
2. **MC 的硬瓶颈是单线程 tick**：20 TPS 主循环只跑在一个核上，**单核主频比核数更重要**——
   100 人档也要"顶级单核"而不是堆低主频核。核数的用处是 Paper 的**异步区块生成**、GC 线程，
   以及 150 人以上把世界拆给多个实例。内存随**已加载区块数**涨（约每玩家 100–200 MB），
   粗略估算：`堆内存 ≈ 同时在线 × 0.15–0.2 GB`，
   整机内存 ≈ 堆 + 平台约 0.3G + 系统约 2G。
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

### 平台层各服务内存上限（可调，issue #16）

平台层固定占用很小，但**容器内存上限（fuse）与服务实际工作集不匹配**时会变成 OOM 重启风暴。
可调项收敛到 `.env`，站点级覆盖写 `$DATA_ROOT/compose.site.yaml`（升级换包不丢）：

| 服务 | `.env` 变量 | 缺省上限 | 说明 |
|---|---|---|---|
| `mcsmanager-daemon` | `DAEMON_MEMORY_LIMIT` / `DAEMON_NODE_HEAP_MB` | `512M` / `384` | 堆须与上限对齐，见 issue #10 |
| `easybot` | `EASYBOT_MEMORY_LIMIT` | `512M` | 与旧值一致的**紧**上限；v0.0.41 已修空载内存泄漏（上游 #139），放大上限会掩盖回归 |
| `mcsmanager-web` | —（`compose.yaml` 硬编码） | `512M` | 面板服务，占用平稳 |

> **easybot 上限刻意保持紧**（缺省 `512M`，与原硬编码值一致）：EasyBot v0.0.41 修掉了空载
> 内存泄漏后，不要为了“保险”把上限放大——放大只会让未来的内存回归更晚暴露。仅当站点确有
> 更重负载（多适配器/大量插件回传）且确认是**正常**工作集超限时，才 `.env` 写
> `EASYBOT_MEMORY_LIMIT=1G` 后 `./orzmc.sh up`；下调同理。判断是否 OOM：
> `docker inspect orzmc-easybot --format '{{.RestartCount}}'` 持续增长 +
> 宿主 `dmesg` 出现 `Killed process ... easybot`。

### 如何查看/调整实例内存

当前生产实例配置为 `-Xms4G -Xmx4G`（堆 4G），`InstanceConfig/<uuid>.json` 中 `memory: 4096`
（单位 MB）。调低可压低最低要求（1–3 人小服可降到 2–3G → 整机 4–5G 即可）；调高方法见
[6.5 节](#65-生命周期与配置持久化)（⚠️ 先停 daemon → 改 → 再启 daemon 的顺序）。

### 一句话买机建议

- **≤50 人**：8–16 GB 高主频 VPS，或家用 Mac/PC（本仓库当前生产即 20 人档：4G 堆，
  整机 8G 即可——平台层约 0.3G 后仍有 1G+ 余量）
- **50–100 人**：16–24 GB **独立服务器/裸金属**，优先单核主频，SSD 必须
- **≥150 人**：别在单实例上堆钱，直接规划 hub + 分实例架构
