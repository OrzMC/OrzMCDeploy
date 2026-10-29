# PaperMC 实例字段参考

> **定位**：在 MCSManager 面板创建 PaperMC Docker 实例时逐项照抄的字段表（唯一来源）。
> **读者**：正在建实例的服主。这些字段属**运行数据**，由面板写入
> `InstanceConfig/<uuid>.json`，不在仓库配置里；操作流程见 [usage §6](usage.md#6-papermc-实例)。

## 1. 实例拆分（示例命名/端口，可自定）

- 测试服（如 `papermc-test`）：功能验证 / 插件测试 / 临时活动服，错开正式服端口
- 正式服（如 `papermc-main`）：对玩家的生存服

## 2. 必填字段

| 字段 | 测试服示例 | 正式服示例 | 说明 |
|---|---|---|---|
| 实例名 | `papermc-test` | `papermc-main` | 同时建议作为目录名和容器名 |
| 显示名 | `OrzMC Test` | `OrzMC Main` | 面板显示名称 |
| 镜像名 | `eclipse-temurin:25-jre` | `eclipse-temurin:25-jre` | 按 Paper 版本选 Java（Paper 26.2→Java 25；1.21.x→`eclipse-temurin:21-jre`） |
| 服务端口 | `25566` | `25565` | 测试服避开正式服默认端口 |
| 端口映射 | `25566:25566/tcp`（启用 Geyser 再加 `19133:19133/udp`） | `25565:25565/tcp`（启用 Geyser 再加 `19132:19132/udp`） | `宿主:容器/协议`，一个对外端口一条；启用 Geyser 必须**显式发布 UDP**，仅写 TCP 时基岩通道在容器外不可达（见 §7） |
| 服务目录 | `$DATA_ROOT/mcsmanager/daemon/data/InstanceData/<uuid>` | `$DATA_ROOT/mcsmanager/daemon/data/InstanceData/<uuid>` | 面板实例 cwd（持久化世界、插件、配置）；`$DATA_ROOT` 由你部署时指定（无默认值，见 usage §4.1） |
| 挂载定义 | `.../InstanceData/<uuid>:/server` | `.../InstanceData/<uuid>:/server` | 核心数据挂载（`<uuid>` 由面板生成） |
| Java 版本 | `25` | `25` | 根据目标 Paper 版本选择（同上一行） |
| 最小内存 | `2G` | `4G` | 测试服保守，正式服更稳妥 |
| 最大内存 | `2G` | `4G` | 建议与最小值一致，降低抖动 |
| 启动命令 | `java -XX:+UseG1GC -XX:+ParallelRefProcEnabled -Xms<内存> -Xmx<内存> -jar paper.jar --nogui` | 同左 | 面板里直接填固定字符串，`<内存>` 与 `docker.memory` 一致 |
| Minecraft 版本 | `1.21.1` | `1.21.1` | 业务版本 |
| Jar 文件名 | `paper.jar` | `paper.jar` | 镜像内实际服务端文件名 |
| 接受 EULA | `true` | `true` | 必须开启 |
| 正版验证 | `true` | `true` | 按服务器策略调整 |
| MOTD | `OrzMC Test Server` | `OrzMC Survival Server` | 列表描述 |
| 最大玩家数 | `10` | `20` | 按定位调整 |

## 3. 建议固定字段

| 字段 | 推荐值 | 说明 |
|---|---|---|
| 运行方式 | `docker` | 与当前容器化架构保持一致 |
| 镜像拉取策略 | `IfNotPresent` | 避免无意中升级镜像 |
| 工作目录 | `/server` | 与挂载定义保持一致 |
| 重启策略 | `unless-stopped` | 平台层统一约定 |
| 协议 | `tcp` / `udp` | 按通道分别发布：Java 用 `tcp`，Geyser 基岩用 `udp`（`docker.ports` 每项自带协议） |
| 监听地址 | `0.0.0.0` | 允许容器监听全部地址 |
| 网络模式 | `bridge` | 与平台层编排一致 |
| 挂载模式 | `rw` | 运行目录必须可写 |
| 运行 UID/GID | `1000/1000` | 容器内 uid；macOS 宿主属主需为宿主用户（ADR-006） |
| 额外 JVM 参数 | `-XX:+UseG1GC -XX:+ParallelRefProcEnabled` | 作为起步参数 |
| 停止命令 | `stop` | 适配 Minecraft 控制台 |
| 控制台编码 | `UTF-8` | 避免日志乱码 |
| Ready 关键字 | `Done` | 用于判断启动完成 |
| 更新策略 | `manual` | 服务端和插件升级建议手动确认 |

## 4. 已验证的最小可运行组合

macOS + Docker Desktop + MCSManager Docker 实例实测：

- 镜像 `eclipse-temurin:25-jre`（Paper 26.2；1.21.x 用 `21-jre`），工作目录 `/server`
- 启动命令 `java -XX:+UseG1GC -XX:+ParallelRefProcEnabled -Xms<堆> -Xmx<堆> -jar paper.jar --nogui`
  （`<堆>` 与 `docker.memory` 一致，小服 2G、常规 4G，按人数定）
- 端口 `宿主:容器/tcp`（Java）与 `宿主:容器/udp`（Geyser，启用时）
- 宿主机预置：`paper.jar`、`eula.txt`（`eula=true`）、`server.properties`；
  离线进服把 `online-mode` 设 `false`

## 5. Docker 模式注意事项

- 如果 `cwd` 已经指向宿主机服务目录，且容器工作目录设为 `/server`，MCSManager 会自动把工作目录挂到容器内。
- 不要再把同一个宿主机目录通过 `extraVolumes` 重复挂载到 `/server`，否则会报错：`Duplicate mount point: /server`。
- 如果要额外挂载备份目录或导入目录，请确保容器目标路径与工作目录挂载目标不同，例如 `/backups`、`/import`。

## 6. Docker 实例字段格式（实测踩坑）

- **端口映射必须是字符串数组**：`"ports": ["25565:25565/tcp", "19132:19132/udp"]`
  （`宿主:容器/协议`）；对象数组会报 `此容器的开放端口配置有误！`。
- **内存单位是 MB**：`docker.memory: 4096` = 4G（填字节值会让配额错乱）。
- **`terminalOption.pty: true` 必开**：非 pty 时 stdout/stderr 两路复用错位，日志每行首字符
  乱码（`D[10:52…`）；开 pty 后单路文本流，日志干净且 Paper 输出 ANSI 彩色。
- **改配置必须停机**：`InstanceConfig/<uuid>.json` 是 daemon 内存副本 + 刷盘，运行中改会被
  覆盖、先改后 `docker restart` 也会被退出刷盘回写。顺序：停 daemon → 改 JSON → 启 daemon
  （详见 [usage §6.5](usage.md#65-生命周期与配置持久化)）。
- **实例 `cwd` 落面板默认位置**：`data/InstanceData/<uuid>/`（经 bind 落宿主），文件管理器可读；
  macOS 需把实例目录属主改为宿主用户（ADR-006）。
- **网络挂 `orzmc_default`**：插件才能内网直连 `http://easybot:8080`。
- 同目录 `extraVolumes` 不要再挂 `/server`（`Duplicate mount point`）；额外目录用 `/backups` 等。

## 7. 端口映射与多实例分配（Geyser/基岩必读）

> 现象锚点（issue #15）：容器内 Geyser 正常监听、日志 `Started Geyser on UDP port 19132`，
> 但宿主机/局域网探测返回 `WinError 10054`（ICMP 端口不可达）——**docker 型实例的容器端口
> 不会自动发布**，`docker.ports` 没写的协议/端口即便容器内监听也传不到宿主机。此时按
> [`security.md`](security.md) 用 `./orzmc.sh firewall apply` 放行的 `19132/udp` 规则**完全无效**
> （宿主没有该端口的转发），极易误判为防火墙 / Geyser 配置 / 客户端问题。

### 铁律：端口必须从配置推导，并逐条显式发布

`docker.ports` 每一项写成 **`宿主:容器/协议`**，一个对外端口一条。不要照抄默认值——
宿主端口 ≠ 容器端口是常态，且各服务端口来自实例实际配置：

| 通道 | 端口权威来源 | 是否必发布 |
|---|---|---|
| Java | `server.properties: server-port`（默认 `25565`） | ✅ 必发布 |
| 基岩（Geyser） | `config.yml: bedrock.port`（默认 `19132`，可改） | ✅ 启用 Geyser 时必发布（`/udp`） |
| Query | `server.properties: query.port`（`enable-query=true` 时） | 按需 |
| RCON | `server.properties: rcon.port` | 按需 |
| 语音（Simple Voice Chat 等） | 插件配置（UDP） | 按需 |

- **面板的 `pingConfig.port` / `basePort` 是容器端口语义**，不能当宿主端口填。
- **`clone-remote-port` 在「宿主≠容器」时必须保持 `false`**，否则端口映射错乱。
- 基岩客户端**不支持 SRV 记录**，玩家必须手填 `主机:端口`，因此每个基岩服需要独立的宿主 UDP 端口。
- 容器之间 netns 隔离，容器内都绑 `19132` 并不冲突；**冲突只发生在宿主发布层**——两个实例
  都发 `19132:19132/udp` 时，后启动的会因宿主端口占用创建失败。

### 多实例宿主端口分配范式

同一宿主多实例按实例号排块，宿主端口尽量与容器端口一致（Geyser 直接改 `bedrock.port`），
让 **RakNet pong 回报的端口 / 玩家填写的端口 / 配置文件端口** 三者一致：

| 实例 | Java（TCP） | 基岩（UDP） |
|---|---|---|
| #1 | `<端口1>:25565/tcp` | `<udp端口1>:19132/udp` |
| #2 | `<端口2>:25565/tcp` | `<udp端口2>:19132/udp` |

```jsonc
// InstanceConfig/<uuid>.json 中的 docker.ports（字符串数组）
"ports": ["<宿主端口>:25565/tcp", "<宿主udp端口>:19132/udp"]   // 左值是宿主端口，每个实例唯一
```

### 验证与边界

- **改完重启实例**，宿主应出现 `0.0.0.0:25565->25565/tcp` 与 `0.0.0.0:19132->19132/udp`；
  宿主机 `127.0.0.1:25565` Java 握手 Ping、`127.0.0.1:19132` RakNet Ping 均应通。
- **基岩 UDP 需要 UDP 通道**：端口转发/路由器映射要放行 UDP（`19132/udp` 等）；
  HTTP 反代只承载 TCP，基岩请用 UDP 端口映射或 UDP 中继。
- **无停机改端口（进阶，实测）**：面板 HTTP API `PUT /api/instance` 需 `ROLE.ADMIN`
  （普通用户 `403`）；可改用 daemon 自身 socket.io 协议——连 `http://<daemon>:24444`
  （`path=/socket.io`，key 取 `daemon/data/Config/global.json` 的 `key`），依次
  `auth` → `instance/detail` → `instance/update`，daemon 立即更新内存并落盘，无需停 daemon。
  仅在无法使用面板 / 无 admin key 时采用；常规仍推荐 [usage.md §6.5](usage.md#65-生命周期与配置持久化)
  的停机改写姿势（语义清晰、可审计）。

## 8. 选填字段（按玩法/资源调整）

RCON 开关 `false`（端口 `25575` 正式 / `25576` 测试）· 备份目录 `.../backups` 与计划
`0 5 * * *` / `0 6 * * *` · 导入目录 `.../import` · CPU 限额 `4`（测试 2）· 难度 `normal` ·
模式 `survival` · 视距 `10`（测试 8）· 模拟距离 `8`（测试 6）· PvP `true` · 白名单 `false` ·
出生点保护 `16` · 自动备份 `true`。

## 9. 插件数据库（默认用本地存储）

平台层不内置 MariaDB（ADR-025）：LuckPerms 用 h2，AuthMe / EzShops / GriefPrevention 等默认落
本地文件，插件数据随实例目录被 `backup.sh` 整包带走，零额外组件。

确需 MySQL/MariaDB（多实例共享、大存档）时：在 `$DATA_ROOT/compose.site.yaml` 加回服务
（站点增量，升级不丢；`MARIADB_*` 写 `.env`）：

```yaml
services:
  mariadb:
    image: mariadb@sha256:<digest>
    container_name: orzmc-mariadb
    restart: unless-stopped
    environment:
      TZ: "${TZ}"
      MARIADB_ROOT_PASSWORD: "${MARIADB_ROOT_PASSWORD}"
      MARIADB_DATABASE: "${MARIADB_DATABASE}"
      MARIADB_USER: "${MARIADB_USER}"
      MARIADB_PASSWORD: "${MARIADB_PASSWORD}"
    volumes:
      - "${DATA_ROOT}/database/mariadb:/var/lib/mysql"
```

插件指向 `jdbc:mysql://mariadb:3306/<库名>`，实例网络挂 `orzmc_default`。
⚠️ 站点加回的库**不在**备份的逻辑 dump 范围内（冷目录随 tar 打包）；要逻辑快照请自行
`docker exec orzmc-mariadb mariadb-dump --all-databases > dump.sql`。
