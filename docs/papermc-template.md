# PaperMC 实例模板建议

本文档用于配合 `.env.example.full`，帮助在 `MCSManager` 中创建 `PaperMC` Docker 实例。

## 建议的模板拆分

- `PaperMC Test`
  - 使用 `PAPERMC_TEST_*` 参数
  - 面向功能验证、插件测试、临时活动服
- `PaperMC Prod`
  - 使用 `PAPERMC_PROD_*` 参数
  - 面向正式生存服

## 必填字段

| 字段 | 测试服示例 | 正式服示例 | 说明 |
|---|---|---|---|
| 实例名 | `papermc-test` | `papermc-main` | 同时建议作为目录名和容器名 |
| 显示名 | `OrzMC Test` | `OrzMC Main` | 面板显示名称 |
| 镜像名 | `eclipse-temurin:21-jre` | `eclipse-temurin:21-jre` | 已验证可运行的 Java 21 基础镜像 |
| 服务端口 | `25566` | `25565` | 测试服避开正式服默认端口 |
| 端口映射 | `25566:25566/tcp`（启用 Geyser 再加 `19133:19133/udp`） | `25565:25565/tcp`（启用 Geyser 再加 `19132:19132/udp`） | `宿主:容器/协议`，一个对外端口一条；启用 Geyser 必须**显式发布 UDP**，仅写 TCP 时基岩通道在容器外不可达（见「端口映射与多实例分配」） |
| 服务目录 | `/srv/orzmc/mcsmanager/daemon/data/InstanceData/<uuid>` | `/srv/orzmc/mcsmanager/daemon/data/InstanceData/<uuid>` | 面板实例 cwd（持久化世界、插件、配置） |
| 挂载定义 | `.../InstanceData/<uuid>:/server` | `.../InstanceData/<uuid>:/server` | 核心数据挂载（`<uuid>` 由面板生成） |
| Java 版本 | `21` | `21` | 根据目标 Paper 版本选择 |
| 最小内存 | `2G` | `4G` | 测试服保守，正式服更稳妥 |
| 最大内存 | `2G` | `4G` | 建议与最小值一致，降低抖动 |
| 启动命令 | `java ${PAPERMC_JVM_OPTS} -Xms${PAPERMC_TEST_MEMORY_MIN} -Xmx${PAPERMC_TEST_MEMORY_MAX} -jar ${PAPERMC_SERVER_JAR_NAME} --nogui` | `java ${PAPERMC_JVM_OPTS} -Xms${PAPERMC_PROD_MEMORY_MIN} -Xmx${PAPERMC_PROD_MEMORY_MAX} -jar ${PAPERMC_SERVER_JAR_NAME} --nogui` | 实际录入时可直接替换成固定字符串 |
| Minecraft 版本 | `1.21.1` | `1.21.1` | 业务版本 |
| Jar 文件名 | `paper.jar` | `paper.jar` | 镜像内实际服务端文件名 |
| 接受 EULA | `true` | `true` | 必须开启 |
| 正版验证 | `true` | `true` | 按服务器策略调整 |
| MOTD | `OrzMC Test Server` | `OrzMC Survival Server` | 列表描述 |
| 最大玩家数 | `10` | `20` | 按定位调整 |

## 建议固定字段

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

## 已验证的最小可运行组合

以下组合已经在本地 `macOS + Docker Desktop + MCSManager Docker 实例` 模式下验证通过：

- 镜像：`eclipse-temurin:25-jre`（Paper 26.2 / Java 25；Paper 1.21.1 用 `eclipse-temurin:21-jre`）
- 工作目录：`/server`
- 宿主机服务目录：`<server-dir>`（生产 macOS 建议属主改为宿主用户，见下文"Docker 实例字段格式"）
- 启动命令：`java -XX:+UseG1GC -XX:+ParallelRefProcEnabled -Xms2G -Xmx2G -jar paper.jar --nogui`
  （正式服可用 `-Xms4G -Xmx4G`）
- 端口映射：`25566:25566/tcp`（测试服） / `25565:25565/tcp`（正式服）；启用 Geyser 时
  另加 `19133:19133/udp`（测试服） / `19132:19132/udp`（正式服）
- `paper.jar`：预先下载到宿主机服务目录
- `eula.txt`：预先写入 `eula=true`
- 正版验证：需要离线进服时把 `server.properties` 的 `online-mode` 设为 `false`

建议的最小宿主机预置文件：

- `paper.jar`
- `eula.txt`
- `server.properties`

## Docker 模式注意事项

- 如果 `cwd` 已经指向宿主机服务目录，且容器工作目录设为 `/server`，MCSManager 会自动把工作目录挂到容器内。
- 不要再把同一个宿主机目录通过 `extraVolumes` 重复挂载到 `/server`，否则会报错：`Duplicate mount point: /server`。
- 如果要额外挂载备份目录或导入目录，请确保容器目标路径与工作目录挂载目标不同，例如 `/backups`、`/import`。

## Docker 实例字段格式（实测踩坑）

以下为本仓库生产实例（`papermc-main`，uuid `e92495...`）实测结论（MCSManager v10）：

- **端口映射必须为字符串数组**：`docker.ports` 填 `["25565:25565/tcp", "19132:19132/udp"]`
  （`host:container/protocol` 字符串，daemon 内部 `split("/")` + `split(":")` 解析）；
  **不要**用对象数组 `[{"host":..., "container":..., "protocol":...}]`，否则启动报
  `此容器的开放端口配置有误！`。**启用 Geyser 时必须显式写 `.../udp` 条目**（详见
  「端口映射与多实例分配」）。
- **内存单位为 MB**：`docker.memory: 4096` 即 4G（daemon 内部 `*1024*1024` 换算成字节）；
  填字节值（如 `4294967296`）会让容器内存配额错乱。
- **强烈建议 `terminalOption.pty: true`**：docker 实例非 pty 时 stdout/stderr 是两路独立
  流，Docker 用 8 字节帧头复用，MCSManager 解复用错位导致**每行日志首字符乱码**
  （如 `D[10:52:13 ...`）。开启 pty 后容器分配伪终端（`Tty=true`），单路文本流，日志
  干净且 Paper 自动启用 ANSI 彩色输出（面板终端为 xterm 渲染，能正确处理 `\r`/`[K`/颜色）。
- **修改实例配置的姿势**：实例**运行中**直接改 `InstanceConfig/<uuid>.json` 会被 daemon
  用内存副本覆盖（stop/start 会写回磁盘，`pty` 变回 `false`）。而且**先改 JSON 再
  `docker restart daemon` 也会丢**——daemon 退出时把内存副本刷回磁盘。正确顺序：先停
  **daemon 容器** → 改 JSON → 再启 daemon（启动时以磁盘为准）→ 面板启动实例。详见
  [usage.md §6.5](usage.md#65-生命周期与配置持久化)。
- **实例 `cwd` 由面板默认写入 daemon 的 `data/InstanceData/<uuid>/`**；该目录经
  `daemon/data` bind 落到宿主 `$DATA_ROOT/mcsmanager/daemon/data/InstanceData/`，文件管理器
  能读到真实文件（ADR-019 取代了 ADR-007 的 instances 自挂载方案）。
- **macOS 目录属主**：容器内 `runAs 1000:1000` 但磁盘写入由宿主用户进程执行，实例目录
  属主需改为宿主用户（`sudo chown -R joker:staff <instance-dir>`）；Linux 生产保持
  `1000:1000`（见 ADR-006）。
- **网络挂 `orzmc_default`**：实例需与 easybot 同网才能内网直连 `http://easybot:8080`，
  也与 mariadb 同网才能用 `jdbc:mysql://mariadb:3306/...`（见下文"插件接入 MariaDB"）。

## 端口映射与多实例分配（Geyser/基岩必读）

> 现象锚点（issue #15）：容器内 Geyser 正常监听、日志 `Started Geyser on UDP port 19132`，
> 但宿主机/局域网探测返回 `WinError 10054`（ICMP 端口不可达）——**docker 型实例的容器端口
> 不会自动发布**，`docker.ports` 没写的协议/端口即便容器内监听也传不到宿主机。此时按
> [windows-deployment.md §9.1](windows-deployment.md#91-前置每档都依赖) 放行的 `19132/udp`
> 防火墙规则**完全无效**（宿主没有该端口的转发），极易误判为防火墙 / Geyser 配置 / 客户端问题。

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
| #1（正式） | `25565:25565/tcp` | `19132:19132/udp` |
| #2（测试） | `25566:25565/tcp` | `19133:19132/udp` |

```jsonc
// InstanceConfig/<uuid>.json 中的 docker.ports（字符串数组）
"ports": ["25565:25565/tcp", "19132:19132/udp"]   // #1；#2 改左值宿主端口
```

### 验证与边界

- **改完重启实例**，宿主应出现 `0.0.0.0:25565->25565/tcp` 与 `0.0.0.0:19132->19132/udp`；
  宿主机 `127.0.0.1:25565` Java 握手 Ping、`127.0.0.1:19132` RakNet Ping 均应通。
- **Cloudflare Tunnel 只承载 TCP**：**基岩 UDP 无法走 cloudflared**，远程基岩需 playit.gg
  之类的 UDP 隧道或自建 UDP 中继；Java 通道不受影响。
- **无停机改端口（进阶，实测）**：面板 HTTP API `PUT /api/instance` 需 `ROLE.ADMIN`
  （普通用户 `403`）；可改用 daemon 自身 socket.io 协议——连 `http://<daemon>:24444`
  （`path=/socket.io`，key 取 `daemon/data/Config/global.json` 的 `key`），依次
  `auth` → `instance/detail` → `instance/update`，daemon 立即更新内存并落盘，无需停 daemon。
  仅在无法使用面板 / 无 admin key 时采用；常规仍推荐 [usage.md §6.5](usage.md#65-生命周期与配置持久化)
  的停机改写姿势（语义清晰、可审计）。

## 选填字段

| 字段 | 建议 | 说明 |
|---|---|---|
| RCON 开关 | 默认 `false` | 没有远程控制需求时先关闭 |
| RCON 端口 | `25576/25575` | 测试服和正式服分开 |
| 备份目录 | `.../backups` | 建议尽早规划 |
| 导入目录 | `.../import` | 用于导入地图或插件 |
| CPU 限额 | `2/4` | 按宿主机资源分配 |
| 难度 | `normal` | 按玩法调整 |
| 默认模式 | `survival` | 按玩法调整 |
| 视距 | `8/10` | 正式服可略高 |
| 模拟距离 | `6/8` | 配合视距控制性能 |
| PvP | `true` | 按服务器规则调整 |
| 白名单 | `false` | 活动或内测期可切换为 `true` |
| 出生点保护 | `16` | 常用起始值 |
| 自动备份 | `true` | 正式服强烈建议开启 |
| 备份计划 | `0 6 * * *` / `0 5 * * *` | 测试服和正式服错峰备份 |
| 维护窗口 | `04:00-05:00` / `03:00-05:00` | 用于约束计划维护时段 |
| 地图模板 | `default-test` / `default-survival` | 仅在有初始化模板时使用 |
| EasyBot 联动 | `false` | 后续再扩展；插件经 `easybot.yml` 连接 EasyBot 网关，配置见 `docs/easybot.md` |

## 插件接入 MariaDB（可选）

平台层**默认启用** MariaDB 应用数据库（`compose.yaml` 的 `mariadb` 服务），插件挂
`orzmc_default` 网络内网直连 `mariadb:3306`。需要 MySQL/MariaDB 的插件（Dynmap /
CoreProtect / LuckPerms / Towny / 经济插件等）把数据库指向它即可：

- **通用 JDBC**：`jdbc:mysql://mariadb:3306/<MARIADB_DATABASE>`（端口恒为 3306，
  主机名 `mariadb` 由 compose 服务名解析；账号/密码用 `.env` 的 `MARIADB_USER` /
  `MARIADB_PASSWORD`）。
- **Dynmap**：storage 用 `mysql`，`server=mariadb`、端口 `3306`，库名/账号/密码同上。
- **LuckPerms**：`storage-method=mysql`，`data/address=mariadb:3306`，
  `data/database=<MARIADB_DATABASE>`。
- **CoreProtect**：`database.type=MYSQL`，`database.host=mariadb`，端口 `3306`。

前提：实例**网络挂 `orzmc_default`**（与 easybot / mariadb 同网）；数据库凭据与 `.env`
保持一致，改密码需同步改插件配置。备份随整机 `backup.sh` 自动含逻辑 dump（见
[docs/usage.md](usage.md) §5.5）。

## 建议的录入顺序

1. 先录入实例名、镜像、端口、目录和内存
2. 再录入 `MOTD`、玩家数、`online-mode`
3. 最后补备份、RCON、维护窗口等运维项

## 第一阶段建议

- 先只创建 `PaperMC Test`
- 验证 `启动 / 停止 / 重启 / 数据持久化 / 插件目录 / 日志目录`
- 跑通后再按同样模板创建 `PaperMC Prod`
