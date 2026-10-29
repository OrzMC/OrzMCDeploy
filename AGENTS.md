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
- **全部配置与数据通过卷映射落在宿主机统一目录 `$DATA_ROOT`**（**无默认路径**：必须
  `-d/--data-root` 或 `ORZMC_DATA_ROOT` 显式指定，见 `docs/usage.md` §4.1 / ADR-033）。
- 运行数据包括：`.env`（全部环境变量 + 密钥）、`compose.site.yaml`、EasyBot 数据、
  MCSManager 数据、PaperMC 实例目录。
- 由此获得的能力：运行时独立演进（升级镜像/改编排不触碰数据）、数据独立
  备份/还原/迁移（备份即打包 `$DATA_ROOT`）、密钥不进入仓库。

### 2. 禁止在仓库内写数据 / 密钥

- 任何配置、密钥、运行数据**一律落 `$DATA_ROOT`**，不得写入仓库内任何路径。
- `.env`、`.local-data/`、`.local-backups/` 已在 `.gitignore` 排除；不要把它们
  `git add -f` 强制加入。
- 智能体改代码时，只改仓库内的运行时文件；不要为"跑通"而把测试数据写进仓库。

### 3. 运行模型：只有局域网模式（ADR-027）

| 维度 | 配置 | 说明 |
|---|---|---|
| 局域网入口 | `.env` 的 `LAN_HOST_IP` / `LAN_MCS_WEB_PORT` / `LAN_EASYBOT_PORT` | 面板与 EasyBot 发布到宿主端口，纯 HTTP |
| 可选服务 | `.env` 的 `ENABLE_EASYBOT`（缺省 `true`） | 置 `false` 即停用；核心 web/daemon 常驻 |
| 入口脚本 | `./orzmc.sh`（唯一入口，三平台一致） | `./orzmc.sh [-d DATA_ROOT] init\|up\|stop\|status\|validate\|backup\|firewall` |

- **没有边缘层服务**：不跑 cloudflared / Caddy。对外访问由站点自备
  （DDNS + 端口映射 / 反向代理 / VPN），**本仓库不管理**。
- **默认限源（ADR-028）**：`LAN_BIND_ADDR` 控制端口绑定地址，`LAN_CIDR` /
  `ALLOW_EXTRA_CIDRS` 控制防火墙放行来源；`./orzmc.sh firewall apply` 幂等应用。
  默认只信任局域网，**禁止把规则来源改成 Any**（面板是 HTTP + 口令登录）。
- 可选服务仅 easybot；平台层不含数据库/状态页（ADR-025）。
- 历史 ADR（多边缘层时代）只在 `docs/architecture.md` 保留一行索引，正文在 git 历史。

### 4. 网络拓扑：局域网 2 个入口，EasyBot 插件 API 仅内网

局域网暴露 **2 个入口**（宿主发布端口，纯 HTTP）：
- `http://<LAN_HOST_IP>:<LAN_MCS_WEB_PORT>`（缺省 18090）→ MCSManager 面板（登录鉴权）
- `http://<LAN_HOST_IP>:<LAN_EASYBOT_PORT>`（缺省 18091）→ EasyBot 管理后台（登录鉴权）
- 对外访问由站点自备（DDNS + 端口映射 / 反代 / VPN）；直接映射到公网前必须加 TLS 反代/VPN。
- **daemon 不对外暴露任何入口**（ADR-026）：MCSManager 10.22 起面板自身中转浏览器↔daemon
  的数据流（`SystemConfig.dataPlane=proxy`，新装默认），因此：
  - 节点地址**固定** `ws://mcsmanager-daemon:24444`（内网名）；
  - 浏览器终端/控制台/文件管理经面板端口中转，daemon 端口不发布；
  - `.env` 里不需要任何 daemon 地址变量。
- **EasyBot 的插件 API 不外露**：PaperMC 插件跑在 `orzmc_default` 网络内，
  直连 `http://easybot:8080`（REST + WebSocket 同端口，内网无 TLS）。
- **平台层不含数据库 / 状态页（ADR-025）**：需要时用 `compose.site.yaml`
  站点增量自行加回，不影响包内文件升级。
- 只有面板与 EasyBot 发布宿主端口（`LAN_*_PORT`，纯 HTTP，仅限可信局域网）；
  其余端口不发布到宿主（仅 `orzmc_default` 内网可达）。PaperMC 实例端口（`25565` 等）由 MCSManager 按实例配置映射，
  供玩家局域网直连。

## 目录地图

```
compose.yaml            平台层编排（name: orzmc，镜像 digest 锁定，核心 web/daemon 常驻 + 可选服务带 profiles 标签）
templates/              首次 init 的配置模板
  env                   唯一 .env 模板（LAN_HOST_IP + LAN_*_PORT + EasyBot 凭据）
  gateway.local.yaml    EasyBot 覆盖配置模板（禁用微信适配器，init 生成到 DATA_ROOT）
  compose.site.yaml     站点增量 override 模板（init 生成到 DATA_ROOT/compose.site.yaml，
                         升级/换包不丢；compose_cmd 检测到即 -f 追加，ADR-022）
lib/common.sh           共享函数库（DATA_ROOT 解析、compose 封装、目录引导、平台层 detect_os/win_path/win_daemon_*）
orzmc.sh               唯一部署入口（三平台一致；局域网模式，见 ADR-027）
install.sh             免克隆一键安装（ADR-018：下载 Release tarball + 校验 sha256 + 解压）
deploy.sh               orzmc.sh 的内部实现（init/up/stop/status/validate 命令体）
backup.sh / restore.sh  数据备份 / 还原迁移
lib/firewall.sh         防火墙收敛（./orzmc.sh firewall show|apply，ADR-028）
update-image-digests.sh 刷新 compose.yaml 镜像 digest（easybot 用发布 tag：EASYBOT_TAG）
.github/workflows/ci.yml CI 质量门禁（push/PR：bash -n + shellcheck + 模板 YAML + init/validate + windows-branch 单测）
tests/windows_ci.sh   Windows 分支单元测试（mock uname 强制 MINGW，校验 win_path/win_daemon_*/compose_cmd 命令构造）
AGENTS.md / CLAUDE.md   本文件 / Claude Code 入口（@import 本文件）
README.md               用户入口（介绍 + 快速上手 + 命令速查 + 文档导航）
CHANGELOG.md            版本变更记录（Keep a Changelog；随 Release 打包，ADR-018）
docs/usage.md           使用手册（唯一操作入口）：安装/配置/运维/实例/EasyBot/排障/迁移 + Windows（附录 F）
docs/architecture.md    架构与设计决策（拓扑/数据流 + ADR-001…033；已废止仅留索引）
docs/security.md        暴露面与访问控制（三层限源、三档配置、对外暴露与反代配方）
docs/papermc-template.md PaperMC 实例字段参考（面板运行数据，不在仓库配置里）
```

## 命令速查（统一 orzmc.sh）

| 场景 | 命令 |
|---|---|
| 初始化目录/env | `./orzmc.sh -d <数据目录> init` |
| 启动平台层 | `./orzmc.sh -d <数据目录> up` |
| 停止 | `./orzmc.sh -d <数据目录> stop` |
| 状态与访问地址 | `./orzmc.sh -d <数据目录> status` |
| 校验配置 | `./orzmc.sh -d <数据目录> validate` |
| 备份数据 | `./orzmc.sh -d <数据目录> backup [--stop] [--keep N]` |
| 防火墙收敛（默认限源） | `./orzmc.sh -d <数据目录> firewall show` / `apply` |
| 还原/迁移 | `./restore.sh -d <数据目录> <归档> [--force]` |

- 表中 `-d <数据目录>` 必填（或 `export ORZMC_DATA_ROOT=...`），无默认路径。
- 局域网入口在 `$DATA_ROOT/.env` 里配：`LAN_HOST_IP` + `LAN_MCS_WEB_PORT`(18090) +
  `LAN_EASYBOT_PORT`(18091)；可选服务开关 `ENABLE_EASYBOT` 也在 `.env` 里（缺省 `true`）。
  `-e/--edge` 参数与 `local.sh`/`lan.sh`/`windows.sh` 入口已随 ADR-027 移除。
- **`DATA_ROOT` 无默认路径**（ADR-033）：`-d/--data-root` > `ORZMC_DATA_ROOT`，两者都没有
  时脚本报错退出。别为方便再加平台默认值。
- 所有 compose 调用统一走 `lib/common.sh` 的 `compose_cmd`（显式
  `--env-file $DATA_ROOT/.env` + 站点 override + `--profile easybot`）。
- **站点增量**放 `$DATA_ROOT/compose.site.yaml`（`init` 生成、存在即自动 `-f` 追加），
  或 `.env` 的 `COMPOSE_FILE_EXTRA`（空格/逗号分隔，任意路径）。站点特有 env/挂载
  **不改包内 `compose.yaml`**——升级换包会丢（ADR-022，issue #11）。

## 基线与门禁

**当前基线**：3 个服务（web/daemon 常驻 + easybot 可选，`ENABLE_EASYBOT=false` 时 2 个）；
入口只有 2 个局域网 HTTP 端口；daemon 不发布端口（节点地址固定 `ws://mcsmanager-daemon:24444`，
浏览器数据面经面板中转）；全部配置/数据落 `$DATA_ROOT`；镜像 digest 锁定。

**本地门禁**（与 CI 等价，改完必跑）：

```bash
for f in *.sh lib/*.sh tests/*.sh; do bash -n "$f"; done
shellcheck -x --shell=bash *.sh lib/*.sh tests/*.sh
bash tests/windows_ci.sh
./orzmc.sh -d /tmp/orzmc-test init && ./orzmc.sh -d /tmp/orzmc-test validate
```

CI 另跑：模板/compose YAML 解析 · `ENABLE_EASYBOT=false` 开关用例 · `LAN_BIND_ADDR` 生效 ·
`firewall apply --dry-run` 来源限源 · 禁入路径守卫。打 `v*` tag 时打包 Release tarball
（ADR-018）——`ci.yml` 的 tar 清单必须与仓库实际文件一致，删脚本时要同步删。

**待办**：对外访问前加 TLS 反代或改走 VPN；公网 TLS 端口是「不得为 `Any`」的唯一例外
（见安全约束）；旧 `.env` 里的 `EDGE`/`CLOUDFLARE_*`/`DOMAIN_*`/`LAN_MCS_DAEMON_PORT`
已无消费者、可清理；升级镜像后按「digest → commit → `stop && up`」回归。

## 代码约定

- **bash 3.2 兼容**：仓库脚本在 macOS 自带 bash 3.2 下运行（`/usr/bin/env bash`）。
  `set -u` 会把双引号内**紧跟全角字符**（（ ） ， 。 等）的 `$VAR` 误判为未定义变量
  并报 `VAR�: unbound variable`。**消息字符串里的变量一律写 `${VAR}`**，不要用
  `$VAR` 直接后接全角标点。此为可移植性约定，勿回退。
  另外 bash 3.2 **没有** `mapfile` / `readarray` / `declare -A` / `${var,,}`：批量读行用
  `while IFS= read -r x; do …; done < <(...)`；可能为空的数组一律用
  `${arr[@]+"${arr[@]}"}` 展开（bash <4.4 下裸 `"${arr[@]}"` 遇空数组会报 unbound）。
- compose v2 `--env-file` 是**替换**而非叠加项目根 `.env`，必须显式传入且为真实普通文件。
- 镜像一律用 **digest 锁定**（`image: xxx@sha256:...`），升级走
  `update-image-digests.sh` + git commit，回滚走 `git revert`。
- `ensure_*` 引导函数**绝不覆盖已有文件**（`ensure_env_file`、`ensure_site_override`、
  `ensure_easybot_local_config`）；想用新模板重建引导文件：删旧文件后重新 `./orzmc.sh init`。
- **macOS / Docker Desktop 写盘走宿主用户**：容器内 uid 检查通过后，实际磁盘写入由
  macOS 侧文件共享进程（宿主用户）执行；`runAs 1000:1000` 的容器在宿主目录属主非该
  用户时仍会写盘失败（Operation not permitted / AccessDenied）。生产 macOS 将实例目录
  属主改为宿主用户（`sudo chown -R <宿主用户>:staff <instance-dir>`）；Linux 生产无此问题，
  保持 `1000:1000`。

## 文档写作约定（改文档前必读）

一个读者任务 = 一个位置，不复述、不写死设备信息：

- **分工**：`README`=落地页（是什么/怎么跑/去哪读）；`docs/usage.md`=唯一操作手册；
  `docs/security.md`=暴露面与反代；`docs/papermc-template.md`=字段表；
  `docs/architecture.md`=设计与 ADR 历史。详细步骤只写在使用手册，其余文档用链接指向。
- **占位符统一**：命令里用 `<数据目录>`（用户 `-d` 指定的宿主机目录）、`<LAN_HOST_IP>`、
  `<实例端口>`、`<归档>`；描述变量或目录内部路径时用 `$DATA_ROOT/<子路径>`。
- **代码块可复制**：块内命令写全（含 `-d <数据目录>`），不用省略号或"同上"；正文叙述中提到
  命令时可用短形式（如 `firewall apply`、`init`），但不要给出会被误抄的半截命令。
- **禁止写死站点信息**：具体 IP/域名/端口/路径/用户名/实例 uuid 一律用占位符；
  示例值必须紧跟"示例"字样（如 `LAN_CIDR=192.168.0.0/24  # 示例，改成你的网段`）。
- **标题格式**：章 `## 1. 标题`，子节 `### 1.1 标题`，附录 `## 附录 A 标题`；
  每篇开头一段 `> 定位 / 读者 / 相关文档` 引用块。
- **篇幅**：单节 ≤ 40 行；重复内容合并到一处，其余位置只留一句 + 链接；
  历史背景与实测数字只写进 ADR / CHANGELOG，不进操作手册。
- 改完跑本地门禁（见下节）；CI 的 lint job 会额外校验 markdown 链接与锚点。

## 安全约束（必须遵守）

- `$DATA_ROOT/.env` 含 `QQBOT_APP_ID/CLIENT_SECRET`、`EASYBOT_ADMIN_PASSWORD`
  等密钥，权限收紧为 600，**永不入库**。
- `$DATA_ROOT/mcsmanager/daemon/data/Config/global.json` 含 **daemon key**——daemon
  控制 docker.sock（可管理宿主机 Docker），该 key 等同最高权限密钥：权限 600、
  只存在于 DATA_ROOT 内、随数据备份、**永不入库**。
- `mcsmanager-daemon` 挂载 `/var/run/docker.sock`，拥有管理宿主机 Docker 的能力，
  **宿主机必须视为可信环境**。
- EasyBot 监听器仅 HTTP，`EASYBOT_ALLOW_PLAINTEXT=true` 为有意为之（ADR-027 局域网模式）。
  面板与 EasyBot 口令以**明文 HTTP** 暴露给局域网——仅限可信内网；接入不可信 Wi-Fi
  或需要对公网开放时，必须加 TLS 反代或改用 VPN。
- daemon 端口**不发布**（ADR-026）；daemon key（可管理 docker.sock）仍属最高权限密钥。
- **防火墙默认限源**（ADR-028）：`OrzMC-*` 入站规则的 `RemoteAddress` 应为 `LAN_CIDR`
  （+ 显式追加的 VPN 网段），**不得为 `Any`**；改动后用 `./orzmc.sh firewall show` 复核。
  唯一例外：站点自备的**公网 TLS 反代端口**（如 80/443）本身就要对公网开放，
  该规则必须单独命名（如 `OrzMC-Web-TLS`）并在 `docs/security.md` 与本节「基线与门禁」
  的待办中记录，不得把已有的 `OrzMC-Panel` / `OrzMC-EasyBot` 规则改成 `Any`。

## 修改守则（智能体改动前必读）

1. 改动运行时：先读 `AGENTS.md` 与相关脚本头注释，理解 `DATA_ROOT` / profile 机制。
2. 不破坏铁律：不往仓库写数据/密钥；不删 `.gitignore` 排除项；不把 EasyBot 插件
   API 暴露到公网。
3. 涉及架构（服务增减、入口变更、卷/网络调整）：**同步更新** `docs/architecture.md`
   （新增 ADR 记录）、`AGENTS.md`（如规则变化）、`README.md`、相关 `docs/*.md`。
4. 改动共享库 `lib/common.sh` 后，跑一遍本地回归：
   `./orzmc.sh -d /tmp/orzmc-test init && ./orzmc.sh -d /tmp/orzmc-test validate`
   与 `bash tests/windows_ci.sh`（push/PR 后 CI 会自动跑 shellcheck + init/validate +
   Windows 分支单测，见 `.github/workflows/ci.yml`）。
5. 新增 `.env` 必需变量：同步更新 `lib/common.sh` 的 `required_env_list`
   与 `templates/env`（`ENABLE_EASYBOT` 开关也在此）。
6. 需要用户输入密钥/凭据时，引导用户编辑 `$DATA_ROOT/.env`，不要把真实值写进仓库或
   回显到日志/提交信息。
6.1 **禁止使用面板内置自助升级**（MCSManager 10.19+）：它在容器内替换程序文件，会偏离
   digest 锁定、无法用 `git revert` 回滚，且容器重建即丢失。升级只走
   `update-image-digests.sh` + commit（见 `docs/usage.md` §5.3）。
7. 提交前核对 `git status`：不得出现 `.env`、`.local-data/`、`.local-backups/`、
   生产 `DATA_ROOT` 内容或任何密钥。
