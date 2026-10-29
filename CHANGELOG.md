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

## [0.1.0] - 2026-10-29

### ⚠️ 破坏性变更（升级前必读）

- **`DATA_ROOT` 不再有默认值**（ADR-033）：所有命令必须带 `-d <数据目录>` 或
  `export ORZMC_DATA_ROOT=<数据目录>`，否则直接报错。
- **删除边缘层与旧入口**（ADR-027）：不再有 `compose.edge.*.yaml` / `-e <edge>` /
  `local.sh` / `lan.sh` / `windows.sh`；只保留局域网直连。
- **daemon 不再对外发布端口**（ADR-026）：节点地址固定 `ws://mcsmanager-daemon:24444`，
  浏览器终端/文件管理经面板中转（旧装需把 `dataPlane` 切到 `proxy`，见 usage §6.3）。
- **平台层移除 MariaDB / Gatus 状态页**（ADR-025）：需要时用 `compose.site.yaml` 加回。
- **默认限源**（ADR-028）：新增 `LAN_BIND_ADDR` / `LAN_CIDR` / `ALLOW_EXTRA_CIDRS` 与
  `./orzmc.sh firewall apply`；升级后请把防火墙来源收回局域网网段。

### 修复（CI：可执行位缺失导致 firewall 用例一直失败）

- **根因**：`lib/firewall.sh` 在 git 里是 `100644`（无执行位），而 `orzmc.sh` 直接执行它 →
  CI 新检出报 `Permission denied`（本地因工作区有 `+x` 才通过），「防火墙 dry-run」用例
  自加入起一直失败。
- **修复**：`git` 中补执行位；`orzmc.sh` / `restore.sh` 内部调用改为 `bash <script>`，
  不再依赖执行位（Windows 克隆 / ZIP 下载 / `core.fileMode=false` 都不会再踩）；
  `install.sh` 解压后给 `*.sh` 与 `lib/*.sh` 补 `+x`。
- **CI 清理与加固**：
  - 新增 **可执行位守卫**（入口脚本必须 100755），防止回归；
  - markdown 链接/锚点检查抽为 `tests/docs_check.sh`（本地可复用），CI 只调一行；
  - YAML 解析扩展到 `compose.yaml` 与 `.github/workflows/ci.yml`（原来只查 templates）；
  - 打包 job 去掉已不存在的 `.local-data-lan` 排除项；禁入守卫保留旧目录名并注明原因。

### 文档（统一重写：README + docs 结构与书写规范）

- **README** 改为落地页三段式（是什么/怎么跑/去哪读）：能力表、快速开始（命令全部带
  `-d <数据目录>`）、常用命令代码块、关键约束、文档表、安全一句话。
- **使用手册**（`docs/usage.md`）：开头统一为「定位 / 读者 / 占位符约定」，章号统一为
  `## 1.`…，删掉与 README/architecture 重复的「运行模型」节，§3.1 并入快速开始引言。
- **占位符全文统一**：命令里用 `<数据目录>` / `<LAN_HOST_IP>` / `<实例端口>` / `<归档>`，
  描述变量的内部路径用 `$DATA_ROOT/<子路径>`；移除 `<DATA_ROOT>`、`/path/to/...`、
  `<你的数据目录>`、`<宿主IP>` 等混用写法。
- **字段参考**（`docs/papermc-template.md`）章号统一为 `## 1.`…，头部统一为定位/读者。
- **安全文档**头部统一为定位/读者，与使用手册互链。
- `AGENTS.md` 新增「文档写作约定」：一个读者任务=一个位置、占位符与标题格式、命令必须可复制、
  禁止写死站点信息、单节篇幅、历史数字只进 ADR/CHANGELOG。
- CI 的 `lint` job 新增 **markdown 链接与锚点校验**（文档改动的回归门禁）。

### 变更（ADR-033：取消 DATA_ROOT 默认路径）

- **`DATA_ROOT` 必须显式指定**：删除平台默认值（原先 Linux `/srv/orzmc`、macOS
  `/Users/Shared/orzmc`、Windows `E:/orzmc`）。现在必须用 `-d/--data-root <路径>` 或
  `export ORZMC_DATA_ROOT=<路径>`，两者都没有时脚本**直接报错**并给出指定方式。
  理由：该目录装全部数据/密钥/备份源，默认值会让人"不知道数据放哪"，也让文档必须写死
  作者机器的路径。
- **行为变更（有意）**：以前不带 `-d` 的命令现在会失败。旧部署 `.env` 里的 `DATA_ROOT`
  仍在，但每次调用需带 `-d`；长期使用建议 `export ORZMC_DATA_ROOT=...`。
- 入口脚本（`orzmc.sh` / `deploy.sh` / `backup.sh` / `restore.sh`）改为先解析 `-d` 再读
  环境变量；`lib/firewall.sh` 直接调用时同样要求。
- 文档：README/AGENTS/usage 删除全部默认路径；快速开始与命令表统一为
  `-d <你的数据目录>`，并补充"选位置要点"（磁盘容量、Windows 原生路径与 Docker 共享
  白名单、备份落在 `DATA_ROOT` 之外）。`install.sh` 的手把手提示同步。
- 测试：删除平台默认断言，新增「`ORZMC_DATA_ROOT` 生效」「未指定时报错并给出指引」。

### 文档（ADR-032：文档收敛，10 → 8 个文件）

- **README 回归落地页**（169 → 68 行）：是什么 / 快速开始 / 常用命令 / 关键约束 / 文档表 /
  安全一句话，不再复述使用手册。
- **删除 `docs/easybot.md`**（与 usage §7 大段重复）：内容并入 `docs/usage.md` §7
  （后台与密钥、插件 `easybot.yml`、验证与 403、可选适配器与微信、运维注意）。
- **删除 `docs/windows-deployment.md`**：压成 `docs/usage.md` 附录 F「Windows 平台要点」。
- **删除 `EXECUTION_PATH.md`**：基线/本地门禁/待办并入 `AGENTS.md`「基线与门禁」，
  状态记录由 CHANGELOG 与 git 历史承担。
- **`docs/papermc-template.md`**（234 → 172 行）只留字段与坑，删掉流程性废话。
- **`docs/architecture.md`** 压缩 ADR-001…022 的历史叙事（保留决策与影响），
  ADR-024…032 保持完整；新增 ADR-032。
- 总量 2567 → ~1800 行，全部互链与锚点已校验（0 失效）。

### 变更（ADR-031：配置最小化）

- **compose 去掉无运行时作用的字段**：删全部 `expose:`（本就不生效，发布端口由 `ports`
  决定）；删 daemon 的 `/etc/timezone` 挂载（`TZ` + `/etc/localtime` 已足够，macOS 宿主
  没有该文件）。128 → 88 行，行为不变。
- **模板瘦身**：`templates/env` 94 → 58 行（按用途分组、去掉重复叙述，只保留 15 个
  有消费者的键 + 可选键注释示例）；`compose.site.yaml` 34 → 22 行；
  `gateway.local.yaml` 精简头部。
- **删除 `templates/env.papermc`**（139 行）：字段名（`PAPERMC_INSTANCE_GROUP` /
  `ENVIRONMENT` / `WORLD_TEMPLATE` / `MAINTENANCE_WINDOW` / `HEALTHCHECK_*` 等）并非
  MCSManager 实例字段，且与 `docs/papermc-template.md` 逐项重复（还写着无协议的
  `25566:25566`）。字段参考唯一来源改为 `docs/papermc-template.md`，该文档同时改为
  可直接录入的固定字符串。
- **`.gitignore`** 只留当前会用到的 3 项；CI 禁入守卫仍覆盖旧目录名（防御纵深）。

### 修复（ADR-030：收尾 ADR-027/028 遗留）

- **Release 打包失效**：`ci.yml` 的 `package` job 仍在 tar 已删除的
  `local.sh` / `lan.sh` / `windows.sh`，打 tag 时 `tar` 直接报错退出 → 没有 tarball，
  `install.sh` 免克隆安装（ADR-018）不可用。已同步文件清单。
- **bash 3.2 兼容**：移除 `lib/common.sh` / `backup.sh` 中的 `mapfile`（bash 4 内建），
  可能为空的数组统一用 `${arr[@]+"${arr[@]}"}` 展开——之前 macOS 自带 bash 3.2 上
  `validate` / `backup --keep` / Windows 分支 `up` 会直接失败。
- **CI 开关用例假阳性**：`ENABLE_EASYBOT=false` 用例原用 `printf >> .env`（同名键首次出现
  优先 → 被忽略）且断言未带 `--profile`。改为 `sed` 原地改键，并断言 `enabled_profiles`
  为空 + `compose_cmd config --services` 无 easybot。
- **`read_env_value` 容错**：剥除 CRLF（Windows 编辑器写出的 `\r` 会让开关/绑定地址静默
  失效），并在注释中明确「同名键首次出现优先」。
- **`firewall` 平台行为**：Linux `show` 的端口正则改为逐端口拼接（原实现末尾 `|` 使
  `grep -E` 匹配全部行）；macOS `apply` 改为打印等价 `pf` 规则（原为 iptables）；
  缺 `.env` 时直接拒绝，不再用缺省值建规则。
- **`init` 不再建 `$DATA_ROOT/caddy/`**（ADR-027 后无边缘层）；已存在的目录不自动删除。
- **默认 `DATA_ROOT` 按平台**（`default_data_root`）：Windows `E:/orzmc`、macOS
  `/Users/Shared/orzmc`、Linux `/srv/orzmc`——与 README/AGENTS 一直宣称的一致。

### 文档

- `templates/env` 补上 `MC_TCP_PORTS` / `MC_UDP_PORTS` / `RCON_PORTS` 注释（ADR-028 已引用）。
- `docs/windows-deployment.md` 不再教用户写 `-RemoteAddress Any` 规则与容器内端口 `23333`，
  改为 `./orzmc.sh firewall apply`（ADR-028）。
- `docs/architecture.md`：合并两处 ADR 节为单一按编号升序列表、删除重复的「已归档 ADR 索引」、
  修正设计目标（去 Cloudflare Tunnel 残留）与交叉引用；新增 ADR-030。
- `AGENTS.md`：修 `-e <edge>` 命令表与已失效的回归命令、`ensure_caddyfile` / `templates/env.*`
  残留、bash 3.2 约定补充（禁用 `mapfile` / 空数组展开）。
- `README.md` / `docs/usage.md` / `docs/papermc-template.md`：清理三档/边缘层/域名 URL 残留，
  修复附录 A 表格结构损坏与失效链接。
- `EXECUTION_PATH.md`：待办前置、状态记录归档、过时事实（`Any` 规则 / 40 项）修正。

### 安全（ADR-028：默认限源）

- **默认只信任局域网**：新增 `LAN_BIND_ADDR`（端口绑定地址，缺省 `0.0.0.0`；可改
  `127.0.0.1` 仅本机）、`LAN_CIDR`（防火墙放行网段，缺省 `192.168.0.0/24`）、
  `ALLOW_EXTRA_CIDRS`（额外来源，如 VPN 网段）。
- 新增 `./orzmc.sh firewall show|apply [--dry-run]`（`lib/firewall.sh`）：幂等重建
  `OrzMC-*` 入站规则并限定来源；Windows 走 PowerShell（UAC 提权），Linux 走 ufw，
  macOS 只打印建议。
- `status` 增加「暴露面」摘要（绑定地址 + 限源建议）。
- 新增 `docs/security.md`：三层模型（容器网络 / 绑定地址 / 防火墙）、三档推荐配置
  （仅本机 / 局域网 / 公网三选一）、自检清单与常见暴露错误。
- ⚠️ 升级提示：若此前把防火墙规则来源设成 `Any`，请执行 `./orzmc.sh firewall apply`
  收回为 `LAN_CIDR`。


### 移除（ADR-027，收敛为只有局域网模式）

- **删除边缘层概念**：只保留局域网直连（面板/EasyBot 发布宿主端口，纯 HTTP）。
  - 删除 `compose.edge.{cloudflare,local,lan}.yaml`、`templates/Caddyfile`、
    `templates/cloudflared-config.yml`、`templates/env.{prod,local}`（三份 env 模板
    合并为单份 `templates/env`）。
  - 删除 `lib/common.sh` 的 `normalize_edge` / `edge_override_file` / `ensure_caddyfile` /
    `ensure_cloudflared_config`；`orzmc.sh -e` 与 `deploy.sh -p/-e/-t` 参数、
    `COMPOSE_PROFILE` 兼容层一并移除。
  - 删除旧入口脚本 `local.sh` / `lan.sh` / `windows.sh`（它们只是已失效参数的包装）。
  - 端口发布内联进 `compose.yaml`：`${LAN_MCS_WEB_PORT:-18090}` / `${LAN_EASYBOT_PORT:-18091}`。
- **对外访问改为站点自备**（DDNS + 端口映射 / 反向代理 / VPN）。⚠️ 面板是 HTTP +
  口令登录：公网暴露前必须加 TLS 反代或改用 VPN（文档已写入安全章节）。
- 运行时：容器 **4 → 3**（无 cloudflared/caddy）；`.env` 必备项 `EDGE` / `CLOUDFLARE_TUNNEL_ID` /
  `DNS_*` / `DOMAIN_*` 不再需要（旧值残留不报错，可删）。
- CI：4 档 `EDGE × ENABLE` 矩阵 → 单档 `init && validate` + `ENABLE_EASYBOT=false`
  最小集 + `LAN_*_PORT` 覆盖用例。

### 移除（ADR-026，daemon 不再对外暴露）

- **新增：面板中转数据模式成为标准拓扑**（MCSManager 10.22 的 `dataPlane=proxy`，
  新装默认）：浏览器终端/控制台/文件管理由面板中转，节点地址固定
  `ws://mcsmanager-daemon:24444`。
  - 删除 `mcs-node` 公网入口：隧道 ingress / Caddyfile vhost 各少一条，**入口 3 → 2**
    （`mcs` / `easybot`）。
  - 删除 `DOMAIN_MCS_NODE`、`LAN_MCS_DAEMON_PORT` 两个变量；`compose.edge.lan.yaml`
    不再发布 daemon 端口；`win_daemon_run` 不再注入 lan 档 `-p 24444`；
    `compose.yaml` 去掉 `extra_hosts: mcs-node.localhost:host-gateway`。
  - `init` 新增 `warn_legacy_data_plane`：检测到面板 `dataPlane != proxy` 时打印修复步骤
    （面板退出会回写配置，故只提示不代改）。**旧装需一次性手工切换**，新装无需操作。
  - **三平台/三档行为统一**：Windows 不再有"lan 档浏览器终端不可用"的例外
    （ADR-020 作废）；面板↔daemon 也不再经隧道（此前 prod 档每次 RPC ~1 s）。

### 变更（Windows daemon 交给 compose）

- **ADR-029**：`DAEMON_PORTS` 为空时，Windows 档的 daemon 直接由 compose 创建（ADR-019
  移除实例自挂载后已可行，本次实测 Docker Desktop 4.95 / compose 29.8）；只有**进程模式
  实例**需要 `-p` 注入时才退回 `win_daemon_run` 的 `docker run`。

### 文档

- 明确**禁止使用面板内置「自助升级」**（10.19+）：容器内自升级会偏离 digest 锁定、
  `git revert` 回滚不了、重建即丢（`docs/usage.md` §5.3、`AGENTS.md` 修改守则 6.1）。
- `DNS_PRIMARY` / `DNS_SECONDARY` 降级为"仅在无 DNS 劫持的宿主有效"（实测 Clash TUN
  下容器仍解析到 `198.18.x`，该配置无效），默认不再写进 `.env` 模板。
- `docs/usage.md` §6.3 整节重写；ADR-005/011/013/014/020 标注为历史。

### 变更（镜像升级）

- **全部服务升级到当前最新发布版**（digest 重新锁定）：

  | 服务 | 旧版 | 新版 |
  |---|---|---|
  | `mcsmanager-web` / `mcsmanager-daemon` | v10.18.0 | **v10.22.0** |
  | `easybot` | 0.0.41 | **0.0.43** |
  | ~~`cloudflared`~~ | 2026.08.14 构建 | 2026.10.5（后随 ADR-027 移除） |
  | ~~`caddy`~~ | — | 已随 ADR-027 从项目中移除（不再有本地 TLS 边缘层） |

  - **MCSManager 10.18 → 10.22 含安全修复**：上游 10.19.0 明确警告“旧版存在潜在安全问题，
    已在 10.20.0 修复”；本仓库此前钉的 10.18.0 落在受影响区间。
  - 10.22.0 新增「面板中转数据模式」：可不再开放 daemon 端口，仅靠面板一个端口运行
    分布式面板（后续可用于取消 `mcs-node` 入口，待评估）。
  - EasyBot 0.0.42/0.0.43：QQ 公/私域 intent 自动降级探测、Telegram 相册多图
    （`sendMediaGroup`）、进程外插件双重 `init` 导致握手失败修复。

### 修复

- **`update-image-digests.sh` 无法刷新全部服务**（ADR-017 拆边缘层后遗留）：
  - `cloudflared` 已移入 `compose.edge.cloudflare.yaml`，脚本仍去 `compose.yaml` 找 → 报
    “未找到服务”并中断（默认全量升级必失败）；
  - `caddy` 完全未覆盖，且它在 `compose.edge.local.yaml` 里的服务键是 `reverse-proxy`；
  - `easybot` 改用**发布 tag**（`EASYBOT_TAG`，缺省 `0.0.43`）：上游 `latest` 的
    label 是 `main`（跟踪 main 分支），直接钉 `latest` 会引入未发布构建。
  - 现在脚本按服务自动定位所在 compose 文件与服务键，默认覆盖 5 个服务。

### 移除（⚠️ 不兼容变更，计划 v0.1.0）

- **移除平台层 `mariadb` 与 `status`(Gatus) 两个服务**（ADR-025）：稳态容器 6 → 4，
  公网入口 4 → 3，`.env` 必需变量 12 → 7、密钥 4 → 2，备份步骤 3 → 2。
  - 依据：`papermc` 库 **0 张表**、两个实例的 LuckPerms 均为 `storage-method: h2`，
    MariaDB 从未被使用；Gatus 只读看板且端点指向公网域名，每 30 s 经 Cloudflare 隧道
    自我轮询（实测每次 ~1 s），反向拖慢访问。
  - 连带代码：`ensure_status_config`、`db_root_pw`/`wait_for_mariadb`/`dump_db_logical`、
    `templates/gatus-config.yml`、`DOMAIN_STATUS`/`STATUS_PORT`/`MARIADB_*`、备份逻辑 dump、
    `ENABLE_MARIADB`/`ENABLE_STATUS` 开关全部删除（`ENABLE_*` 只剩 `ENABLE_EASYBOT`）。
  - 回退：需要时在 `$DATA_ROOT/compose.site.yaml` 站点增量加回（升级换包不丢，ADR-022）。

### 修复

- **工作区换行归一化为 LF**：仓库内所有文本文件曾被 CRLF 化（无 `.gitattributes`），
  在 WSL/Linux/macOS 下直接执行脚本会报 `env: 'bash\r'`；现已统一为 LF。
- 文档漂移：`README.md` 的 `EASYBOT_MEMORY_LIMIT` 缺省值 `1G` → `512M`（与 ADR-024 一致）；
  `docs/architecture.md` §2.2/§2.3 的旧 profile 描述（`profiles: ["local"]`、
  `compose.lan.yaml`）修正为 ADR-017 的 override 模型。

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
