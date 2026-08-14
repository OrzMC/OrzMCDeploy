# OrzMC Docker 执行路径与 Checklist

本文档用于把本部署仓库从“已完成平台层验证的部署草案”推进到“最小可执行 MVP”，并继续推进到生产化落地。

后续无论是人工继续执行，还是在多轮 AI 对话中继续推进，都应以本文档为单一执行基线，避免遗忘前置约束、当前状态和阶段目标。

## 1. 当前基线

当前已确认的状态如下：

- 本仓库已具备平台层编排能力，核心文件包括：
  - `compose.yaml`（顶层 `name: orzmc`，镜像 digest 锁定）
  - `templates/`（`env.prod` / `env.local` / `env.papermc` / `Caddyfile`）
  - `deploy.sh` / `local.sh` / `backup.sh` / `restore.sh`
  - `lib/common.sh` / `update-image-digests.sh`
- 平台层边界已经确定：
  - `Caddy` 负责统一入口与 HTTPS
  - `MCSManager Web` 提供控制面板
  - `MCSManager Daemon` 管理实例
  - `EasyBot` 提供统一 IM 网关（QQ / Telegram / Discord / 飞书 / 微信）
  - `PaperMC` 不写入 `compose.yaml`，而是由 `MCSManager` 创建和管理
- 架构原则（2026-08 起）：仓库只承载”运行时”，全部配置与数据落宿主机统一目录 `$DATA_ROOT`
  - `.env` 与已落盘 Caddyfile 位于 `$DATA_ROOT`，随数据整体备份/迁移
  - 升级运行时不触碰数据，还原/迁移只搬 `$DATA_ROOT`
- 本地验证迹象（历史，2026-04，抽取前）：
  - `.local-data/caddy` 已生成本地证书
  - `.local-data/mcsmanager` 已生成面板和守护进程数据
  - `MCSManager Web` 与 `MCSManager Daemon` 已有过成功连接记录
- 当前未完成事项：
  - 尚未创建真实的 `PaperMC Test` 实例（本仓库为抽取后的独立仓库，`.local-data` 未随迁）
  - 尚未形成”从 clone 到可进服”的完整验收闭环
  - 尚未补齐生产化安全、运维和自动化校验
- 当前风险：
  - 运行态目录（`$DATA_ROOT` / `.local-data`）含真实私密数据，必须保持 `.gitignore` 忽略，不得提交

## 2. 执行原则

后续推进必须遵守以下原则：

1. 先做 `MVP`，再做生产化。
2. 先验证 `PaperMC Test`，再考虑 `PaperMC Prod`。
3. `PaperMC` 继续由 `MCSManager` 管理，不回退成 `compose.yaml` 常驻服务。
4. 不提交运行态文件：
   - `.env`
   - `.env.local`
   - `.local-data/`
   - 任意包含真实 token、key、登录态、证书、密钥的文件
5. 每完成一个阶段，必须补“完成证据”，再进入下一阶段。
6. 如果发现实际状态与本文档不一致，先更新本文档的“状态记录”再继续执行。

## 3. 阶段划分

后续推进分为 4 个阶段：

- Phase 0：基线固化
- Phase 1：最小可执行 MVP
- Phase 2：生产化落地
- Phase 3：自动化与长期运维

### Phase 0 完成定义

目标：把当前已知结论沉淀成可持续执行的仓库文档和边界规则。

退出条件：

- 本文档已存在并可作为后续单一执行基线
- README 中有明确入口可跳转到本文档
- 团队对“平台层已验证，业务层未闭环”的判断一致

### Phase 1 完成定义

目标：从当前状态推进到最小可执行 MVP。

这里的 MVP 指：

- 平台层可通过 `local.sh` 或等效命令稳定拉起
- `MCSManager Web` 可访问
- `MCSManager Daemon` 已连接
- 成功创建并运行一个 `PaperMC Test` 实例
- 完成 `启动 / 停止 / 重启 / 数据持久化 / 插件目录 / 日志目录 / 端口暴露` 验证
- README 或附属文档里存在一条可复现的最短执行路径

### Phase 2 完成定义

目标：把 MVP 推进为可生产使用的部署方案。

退出条件：

- 生产 `.env` 模板使用方式明确
- DNS、端口、公网访问、HTTPS、备份、恢复、回滚有明确步骤
- `PaperMC Prod` 录入方式明确且经验证
- 管理员权限、token、节点 key 的保存与轮换规则明确

### Phase 3 完成定义

目标：把“手工操作经验”收束为“自动化检查和标准运维动作”。

退出条件：

- 至少存在一个环境自检脚本或验收脚本
- 至少存在一组基础自动化校验
- 升级与回滚流程可按文档重复执行

## 4. 当前推荐执行路径

严格按下面顺序推进，不建议跨阶段并行：

1. 固化基线与规则
2. 重放平台层本地启动验证
3. 创建并验证 `PaperMC Test`
4. 把 MVP 的最短执行路径写回文档
5. 再进入生产化准备

## 5. MVP Checklist

以下清单是当前阶段最重要的执行清单。

### A. 基线固化

- [x] 把部署文件纳入版本控制
- [x] 确认 `.gitignore` 继续忽略 `.env`、`.env.local`、`.local-data/`
- [x] 在 README 中增加执行路径入口
- [x] 明确当前架构边界：`PaperMC` 仍由 `MCSManager` 管理
- [x] 明确当前结论：平台层已验证，`PaperMC` 尚未落地

### B. 平台层重放验证

- [x] 执行 `./local.sh init`
- [x] 执行 `./local.sh start`
- [x] 执行 `deploy.sh -d ./.local-data status`
- [x] 访问 `https://mcs.localhost:18443`，确认 `MCSManager Web` 可访问
- [x] 访问 `https://easyadmin.localhost:18443`，确认 `EasyBot` 管理后台可访问
- [x] 检查 `MCSManager Web` 中节点状态，确认 `local-daemon` 已连接
- [x] 执行 `./local.sh status`，记录访问地址和容器状态
- [x] 执行 `./local.sh stop`，确认可干净停止

### C. PaperMC Test 落地

- [x] 选定 `PaperMC Test` 使用的镜像来源与版本
- [x] 准备测试服目录：
  - `server/`
  - `backups/`
  - `import/`（如需）
- [x] 按 `docs/papermc-template.md` 在 `MCSManager` 中创建 `PaperMC Test`
- [x] 首次启动实例，确认 EULA、Jar、工作目录、挂载目录均正确
- [x] 验证能从 `MCSManager` 面板正常停止实例
- [x] 验证能从 `MCSManager` 面板正常重启实例
- [x] 验证世界数据在宿主机目录持久化
- [x] 验证 `plugins/` 目录可用
- [x] 验证 `logs/` 目录可用
- [x] 验证宿主机端口 `25566` 可访问

### D. MVP 验收

- [x] 输出一条“从本地拉起平台层到测试服可运行”的最短操作路径
- [x] 在文档中补充 `PaperMC Test` 的实际录入参数或最终模板
- [x] 补充已验证项与未验证项
- [x] 记录至少 1 份日志或截图证据的位置
- [x] 明确 MVP 已完成，允许进入 Phase 2

## 6. Phase 2 Checklist

当且仅当 MVP 完成后，再进入本阶段。

> 架构（2026-08-13 更新）：采用 **Cloudflare Tunnel**（prod profile，cloudflared 出站
> 隧道）替代 Caddy；公网暴露 **3 个入口** `mcs.<domain>`（面板）/ `easybot.<domain>`
> （后台）/ `mcs-node.<domain>`（daemon，浏览器直连、密钥鉴权）；EasyBot 插件 API 仅
> 内网直连 `http://easybot:8080`，无 `easybot-api` 域名；本地验证保留 Caddy（local
> profile，`mcs.localhost` / `easybot.localhost` / `mcs-node.localhost`）。详见
> `docs/architecture.md`。

### A. 生产环境准备

- [x] 选择生产宿主机路径（本机 `/Users/Shared/orzmc`）
- [x] 按最小模板准备 `.env`（含 `CLOUDFLARE_TUNNEL_ID` 与 3 个真实域名）
- [x] 明确公网域名与隧道路由（Cloudflare Tunnel `route dns`，无需解析 A 记录到本机）
- [x] 确认生产主机可出站（cloudflared 出站连接，**无需公网 `80/443` 入站**）
- [ ] 明确 `MCSManager`、`PaperMC`、`EasyBot` 的资源预算
- [ ] 明确宿主机备份与监控责任边界

### B. 平台层生产验证

- [x] 在生产环境执行目录初始化（`deploy.sh -d /Users/Shared/orzmc init`）
- [x] 启动平台层容器（`deploy.sh -d /Users/Shared/orzmc up`）
- [x] 验证 cloudflared 隧道已注册（`docker logs orzmc-cloudflared`）
- [x] 验证 MCSManager Web 可公网访问（`https://mcs.<domain>`）
- [x] 验证 Daemon 节点连接（面板添加节点用内部地址 + daemon key；浏览器直连经
  `wss://mcs-node.<domain>:443`，密钥验证通过）
- [x] 验证 EasyBot 管理后台可公网访问（`https://easybot.<domain>`，即 `DOMAIN_EASY_ADMIN`）
- [x] 验证 EasyBot 数据持久化（`$DATA_ROOT/easybot/data`）
- [ ] 验证插件**内网直连** EasyBot 的 REST 与 WebSocket（`http://easybot:8080`，
  实例挂 `orzmc_default`；见 `docs/easybot.md`；依赖 monorepo 侧 OrzMC plugin，属下期边界）
- [x] 执行一次 `backup.sh --stop` + `restore.sh` 备份还原演练

### C. PaperMC Prod 落地

- [x] 准备正式服目录（`$DATA_ROOT/instances/papermc-main/{server,backups}`）
- [x] 创建 `PaperMC Prod`（uuid `e9249511571a411db4901e640237931a`，网络 `orzmc_default`）
- [x] 验证端口 `25565`（服务监听，日志 `Done`；客户端进服待用户确认）
- [ ] 验证备份目录与保留策略
- [ ] 验证插件更新与回滚方式
- [ ] 验证升级窗口与停机流程

### D. 安全收口

- [x] 明确 MCSManager 管理员账号创建与保管方式（面板登录创建，凭据在 `$DATA_ROOT` 数据内）
- [x] 明确 Daemon key 保存方式（`daemon/Config/global.json`，权限 600，按最高权限密钥对待）
- [x] 明确 EasyBot API key 与会话 key 保存方式（`$DATA_ROOT/easybot/data`）
- [x] 明确哪些配置允许入库，哪些必须只保留在线下（`.env`/cloudflared 凭据/daemon key 不入库）
- [x] 明确 `docker.sock` 风险与宿主机可信边界

## 7. Phase 3 Checklist

### A. 自动化校验

- [ ] 增加 `docker compose config` 校验入口
- [ ] 增加 shell 脚本静态检查
- [ ] 增加环境变量缺失检查
- [ ] 增加目录存在性检查

### B. 运维动作标准化

- [ ] 固化升级步骤
- [ ] 固化回滚步骤
- [ ] 固化备份恢复演练步骤
- [ ] 固化常见故障排查步骤

### C. 文档持续维护

- [ ] 每次阶段性完成后更新本文档
- [ ] 每次新增实际限制后更新 README
- [ ] 每次新增脚本后更新“最短执行路径”

## 8. 完成证据要求

每完成一个阶段，至少留存以下证据之一：

- 一段实际执行命令记录
- 一份关键日志路径
- 一张访问成功的截图
- 一段最终生效配置
- 一条写回仓库文档的结论

没有证据，不视为完成。

## 9. 已验证的 MVP 最短路径

以下路径已在本地验证通过：

1. 执行 `./local.sh start`
2. 准备测试服目录：`.local-data/instances/papermc-test/{server,backups,import}`
3. 下载 `paper-1.21.1-133.jar` 到测试服 `server/` 目录，并重命名为 `paper.jar`
4. 在 `server/` 目录预置 `eula.txt` 和 `server.properties`
5. 在 `MCSManager` 中创建一个 Docker 实例：
   - 镜像：`eclipse-temurin:21-jre`
   - 工作目录：`/server`
   - 宿主机服务目录：`.../papermc-test/server`
   - 启动命令：`java -XX:+UseG1GC -XX:+ParallelRefProcEnabled -Xms2G -Xmx2G -jar paper.jar --nogui`
   - 端口映射：`25566:25566/tcp`
6. 启动实例，观察日志出现 `Done`
7. 验证 `25566` 端口、`plugins/`、`logs/latest.log`、`world/` 持久化目录
8. 通过 `MCSManager` 执行停止与重启

## 10. 当前最小下一步

从现在开始，优先按以下顺序推进：

1. 完成 2026-08 架构改造后的本地重放验证（EasyBot 替换 + 运行时/数据分离 + 备份还原演练）
2. 将本次改造与验证结果提交为 Git 提交
3. 整理生产环境 `.env` 与目录规划（`/srv/orzmc`）
4. 准备 DNS、公网端口和 HTTPS 条件
5. 进入 Phase 2 的生产化验证

在 Phase 2 开始前，不要修改 `PaperMC` 的职责边界。

## 11. 状态记录模板

后续每完成一轮推进，都按以下模板追加记录：

```md
### YYYY-MM-DD

- 当前阶段：
- 已完成：
- 新发现问题：
- 下一步：
- 证据：
```

## 12. 状态记录

### 2026-04-25

- 当前阶段：Phase 1
- 已完成：
  - 11 个源码与文档文件已加入 Git 跟踪
  - 已确认 `.gitignore` 继续忽略 `.env`、`.env.local`、`.local-data/`
  - 已执行 `./local.sh init`
  - 已执行 `./local.sh start`
  - 已执行 `docker compose --env-file .env.local -f compose.yaml ps`
  - 已执行 `./local.sh status`
  - 已执行 `./local.sh stop`
  - 已通过 `curl -k -I` 验证 `MCSManager Web` 与 `EasyBot` 反代入口可访问
  - 已通过 `MCSManager Web` 当前日志验证 `local-daemon` 节点连接成功且密钥验证通过
- 新发现问题：
  - 当前只是“已加入 Git 跟踪”，还没有形成 Git 提交
  - 平台层验证已完成，但 `PaperMC Test` 仍未创建，MVP 还差业务层闭环
- 下一步：
  - 选择 `PaperMC Test` 使用镜像与版本
  - 在 `MCSManager` 中创建 `PaperMC Test`
  - 验证启动、停止、重启、数据持久化、插件目录、日志目录、端口 `25566`
- 证据：
  - Git 跟踪结果：`git status --short`
  - 平台层状态：`docker compose --env-file .env.local -f compose.yaml ps`
  - 访问验证：`curl -k -I https://mcs.localhost:18443`
  - 访问验证：`curl -k -I https://qqbot.localhost:18443`
  - 节点日志：`.local-data/mcsmanager/web/logs/current.log`
  - 守护进程日志：`.local-data/mcsmanager/daemon/logs/current.log`

### 2026-04-25 PaperMC Test

- 当前阶段：Phase 1
- 已完成：
  - 已选定 `eclipse-temurin:21-jre` 作为本地验证使用的 Java 21 Docker 镜像
  - 已准备 `.local-data/instances/papermc-test/{server,backups,import}`
  - 已下载 `paper-1.21.1-133.jar` 并落盘为 `paper.jar`
  - 已预置 `eula.txt` 和 `server.properties`
  - 已通过 `MCSManager` 官方实例 API 创建 `PaperMC Test`
  - 已验证首次启动成功，日志出现 `Done`
  - 已验证宿主机端口 `25566` 可访问
  - 已验证世界目录、`plugins/`、`logs/latest.log` 已持久化到宿主机目录
  - 已验证通过 `MCSManager` 生命周期接口执行停止与重启
  - 已将可运行参数和踩坑记录写回 `docs/papermc-template.md`
- 新发现问题：
  - `cwd` 指向宿主机服务目录时，MCSManager 会自动挂载工作目录，不能再把同一目录通过 `extraVolumes` 重复挂到 `/server`
  - 当前本地测试管理员 `apiKey` 为临时调试用途，仅存在于 `.local-data`，不能进入版本控制，也不应复用于生产环境
- 下一步：
  - 提交当前部署配置变更
  - 进入 Phase 2，准备生产 `.env`、目录规划和公网访问条件
- 证据：
  - 实例 UUID：`773ce9e680074252938686a2d6185371`
  - 创建接口：`POST /api/instance`
  - 启动接口：`GET /api/protected_instance/open`
  - 停止接口：`GET /api/protected_instance/stop`
  - 重启接口：`GET /api/protected_instance/restart`
  - 输出日志接口：`GET /api/protected_instance/outputlog`
  - 实例配置文件：`.local-data/mcsmanager/daemon/data/InstanceConfig/773ce9e680074252938686a2d6185371.json`
  - 实例数据目录：`.local-data/instances/papermc-test/server`

### 2026-08-13 架构改造

- 当前阶段：Phase 1 → 生产化准备
- 已完成：
  - 已从 OrzMC monorepo 抽取为独立仓库并提交（`c4fefe7`），修复"尚未形成 Git 提交"的过时状态
  - 已落地"运行时/数据分离"架构：`.env` 与 Caddyfile 移入 `$DATA_ROOT`；新增 `deploy.sh` / `backup.sh` / `restore.sh` / `lib/common.sh` / `templates/`
  - 已新增 `easybot`（`ghcr.io/easyindie/easybot` digest 锁定，端口仅 `expose`，Caddy 前置 TLS）；Caddyfile 收敛为 `DOMAIN_EASY_ADMIN` / `DOMAIN_EASY_API` 两个路由
  - 已重组 env 模板：`templates/env.prod` / `env.local` / `env.papermc` 取代旧 `.env.example.minimal` / `.env.example.full` / `.env.example.local`
  - 已确认 easybot 镜像以 `uid/gid=10001` 运行，`deploy.sh init` 在 root 下 chown 其数据目录
  - 已完成本地端到端重放验证（`init → validate → start → curl → backup → restore(路径漂移) → 模板同步`），详见下文"证据"
  - 已按正式验收流程从全新 `init` 起完整重跑本地验收套件 10 项，全部 PASS（2026-08-13，清空 `.local-data`/`.local-backups` 后从零执行，证据见下）
- 新发现问题：
  - macOS 自带 bash 3.2 在 `set -u` 下会把紧跟全角字符（`（`、`，` 等）的 `$VAR` 误判为未定义变量（报 `VAR�: unbound variable`）；已全部改为 `${VAR}` 花括号定界，后续编辑消息字符串需保持该约定
  - `templates/env.local` 原缺 `CADDY_EMAIL`，导致本地 validate 失败；已补占位 `local@localhost.invalid`（本地 `*.localhost` 走 Caddy 本地 CA，不触发 ACME）
  - QQ 接入模型采用 QQ 开放平台官方 bot 凭据，需先在 QQ 开放平台注册应用取得 AppID/ClientSecret
- 下一步：
  - 提交本次架构改造（含本次验证修复：common.sh 花括号定界、deploy.sh/backup.sh 同类修复、env.local 补 CADDY_EMAIL）
  - 进入 Phase 2 生产化（整理 `/srv/orzmc` .env、DNS、公网端口、HTTPS）
- 证据（正式验收重跑，2026-08-13，从全新 init 起）：
  - `./local.sh init` 生成 `.local-data/.env`（DATA_ROOT 占位替换正确）、`.local-data/caddy/Caddyfile`（普通文件非目录）；目录树含 `caddy/` `mcsmanager/{web,daemon}/` `easybot/data/` `instances/{papermc-main,papermc-test}/`
  - `./deploy.sh -d "$PWD/.local-data" validate` → 校验通过（bash 3.2 多字节 bug 修复后）
  - `./local.sh start` → 4 容器 `orzmc-*` 运行，网络 `orzmc_default` 创建，无旧 IM 网关服务
  - `curl` 三入口均 `HTTP 200`：`https://mcs.localhost:18443`（MCS Web）、`https://easyadmin.localhost:18443`（EasyBot 管理）、`https://easyapi.localhost:18443/api/v1/live`（EasyBot API）
  - `./local.sh backup` → `.local-backups/orzmc-backup-20260813-144012.tar.gz` 校验通过，归档含 `.env`、Caddyfile、easybot 数据（含 `gateway.db`）
  - `./local.sh stop` → 0 残留容器、`orzmc_default` 网络移除、`.local-data` 数据保留
  - `./restore.sh -d /tmp/orzmc-accept/.local-data <归档> --force` → 还原成功，`.env` DATA_ROOT 自动改写为 `/tmp/orzmc-accept/.local-data`（保留 `.env.bak-restore`），还原栈 validate + up + curl 200 + stop 通过，drill 目录已清理
  - `./deploy.sh templates --diff` → 一致时无需同步；`--force` → 覆盖落盘 Caddyfile 并留 `.bak.<时间戳>`，diff 与模板一致
  - `git status --short` 仅含预期变更；`.env` / `.local-data/` / `.local-backups/` 均被 `.gitignore` 排除，仓库根无 `.env`

### 2026-08-13 Phase 2：Stage 5/6（PaperMC Prod + 安全收口）

- 当前阶段：Phase 2
- 已完成：
  - daemon 公网可达：新增 `mcs-node.<domain>` 入口（Cloudflare ingress + Caddy 反代 +
    `DOMAIN_MCS_NODE` 环境变量）；MCSManager 节点配置 `ip=wss://mcs-node.<domain>:443`，
    密钥鉴权通过（web 日志"密钥验证通过"）。
  - `PaperMC Prod`（`papermc-main`，uuid `e9249511571a411db4901e640237931a`）：端口
    `25565:25565/tcp`（字符串数组格式）、内存 `4096`（MB）、`runAs 1000:1000`、网络
    `orzmc_default`、镜像 `eclipse-temurin:25-jre`（Paper 26.2 / Java 25）、
    `online-mode=false` 生效（`OFFLINE/INSECURE MODE`），启动日志 `Done (7.792s)!`。
  - 文件管理器/配置项修复：daemon 容器自挂载 `${DATA_ROOT}/instances`（同路径，
    ADR-007），面板文件管理与配置项恢复正常。
  - 终端乱码根因：docker 实例非 pty 时 stdout/stderr 复用流解复用错位；`terminalOption.pty`
    改为 `true` 并**验证生效**（容器 `Tty=true`，日志无首字符乱码，离线可进服）。
  - 安全收口：`daemon/Config/global.json`（daemon key）收紧 600；`.env`/`cert.pem`/
    隧道凭据 600 复核；仓库密钥泄漏扫描零命中；`.env`/`.local-data` 无入库。
- 新发现问题：
  - 旧子域名 `node.<domain>` CNAME 遗留（不在 ingress，仅 404 无害），需在
    Cloudflare 控制台删除。
  - macOS / Docker Desktop 写盘走宿主用户：实例目录需 `chown` 给宿主用户
    （`sudo chown -R joker:staff ...`），见 `docs/papermc-template.md` 与 ADR-006。
  - 插件内网直连 EasyBot 未验证（依赖 monorepo 侧 OrzMC plugin，属下期边界）。
- 下一步：
  - 用户客户端进服验证（`192.168.0.26:25565`）✅ 已确认可进服。
  - pty 后日志无乱码 ✅ 已验证（容器 `Tty=true`）。
  - 删除旧 `node.<domain>` CNAME（Cloudflare 控制台）✅ 已删除。
  - 提交本阶段仓库改动（docs 同步 + 模板 + compose），先经用户确认。
- 证据：
  - daemon 密钥验证：web 日志 `[INFO] 远程节点 ... 密钥验证通过`
  - 实例启动日志：`Done (7.792s)!` + `OFFLINE/INSECURE MODE`
  - 文件管理/配置项：面板实测可见 `server.properties` / `world/` / `plugins/` / `paper.jar`
  - 实例配置：`$DATA_ROOT/mcsmanager/daemon/data/InstanceConfig/e9249511571a411db4901e640237931a.json`
  - 权限：`$DATA_ROOT/mcsmanager/daemon/data/Config/global.json` = `-rw-------`（600）

### 2026-08-13 插件与 EasyBot 端到端打通

- 当前阶段：Phase 2 — 插件 ↔ EasyBot 网关连通（边界按计划：配置就位 + 网关连通）
- 已完成：
  - 插件部署：`OrzMC-1.0.16-dev.jar`（monorepo 侧构建产物）→ 实例 `plugins/OrzMC.jar`
  - `plugins/OrzMC/easybot.yml` 配置就位：`api_server/ws_server` 指向内网
    `http://easybot:8080`，`api_key`（客服机器人，权限 `["messagessend","websocketconnect"]`），
    `platforms.qq.enabled=true` + 会话 key（管理群 `qq:6AD36...`、私聊 `qq:2556E...`）
  - 插件加载成功（`[OrzMC] 插件生效!` / `成功加载配置文件: easybot.yml`），WebSocket
    连接建立且 **认证成功**；实例重启后启动通知经 `batch-send` 送达 QQ 测试群
  - 网关 → QQ 链路：QQ 适配器在线（`bot-docker`，`QQ Gateway ready`）；向群会话发送
    测试消息 `HTTP 200` + `status:"sent"`（拿到 QQ `messageId`）
  - 经 daemon Socket.IO 协议（`auth` 事件用 daemon key 鉴权 + `instance/restart` 事件
    `{instanceUuids:[...]}`）完成实例重启，面板状态一致
- 新发现问题：
  - `gateway.db` 瞬时 **SQLITE_CORRUPT（code 11）**：本会话在网关运行期用外部 `sqlite3`
    CLI 读取活跃库（恰逢用户在后台并发添加会话授权），引发 WAL 状态不一致；停网关正常
    关库 checkpoint 后 `integrity_check`/`quick_check` 全部 ok，数据无损（sessions/api_keys/
    target_grants 行数不变）。**教训：运行中的 `gateway.db` 一律经网关 API 访问，勿用外部
    sqlite3**。恢复备份留存于 `$DATA_ROOT/easybot/db-recovery-20260813-195603`。
  - 插件配置健康检查两个非阻塞警告：`whitelist.kick_message.qq_group_id` 未配置（降级用
    `easybot.qq_group_id`）；未检测到 LuckPerms（权限管理不可用，时长查询/申请记录仍可用）。
- 下一步：
  - QQ 实弹验证：用户在 QQ 测试群发 `$h` 等命令，确认插件在服内响应
  - 可选：安装 LuckPerms 启用权限管理；配置 `qq_group_id` 消除健康警告
  - 确认后可清理 `db-recovery-*` 备份目录
- 证据：
  - 插件日志：`[OrzMC] EasyBot WebSocket 认证成功`；实例重启 `Done (8.954s)!`，无 403/500
  - 网关日志：`POST /api/v1/messages/batch-send status=200`（11:57:24，插件启动通知）
  - 投递记录：`gateway.db` `outbound_deliveries` 3 条全部 `succeeded`（平台 `qq`，
    `chat_id=6AD36...`（QQ 测试群））
  - 会话授权：`target_grants` 2 条（qq DM + 群，`subject_id=246892b3...`，含
    `messages:send`）
  - 权限：`api_keys.permissions = ["messagessend","websocketconnect"]`

### 2026-08-13 全新一致性备份基线（迁移备好现成归档）

- 动作：`backup.sh --stop -d /Users/Shared/orzmc`（先经 daemon `instance/stop` 优雅停实例，
  再 compose down → 打包 → up）→ 归档
  `$DATA_ROOT-backups/orzmc-backup-20260813-200839.tar.gz`（225M，顶层 `orzmc/`）。
- 归档完整性校验（`tar tzf` 逐项确认）：
  - `.env`、`cloudflared/config.yml`、`cloudflared/cert.pem`、
    `cloudflared/5087fc61-...json`（隧道凭据）、`mcsmanager/daemon/data/Config/global.json`、
    `InstanceConfig/e92495...json`、`easybot/data/data/gateway.db`、
    `plugins/OrzMC.jar`、`plugins/OrzMC/easybot.yml` —— 全部命中。
  - **世界确认含区块**：全维度 `.mca` 共 19 个（overworld region 4 + entities 4 + poi 3、
    the_end 4、the_nether 4）。注意新版世界区块在 `world/dimensions/minecraft/<维度>/region/`
    而非旧版扁平 `world/region/`，初查 `region: 0` 是检查路径错误，非数据缺失。
  - 归档为后续整服迁移的现成基线；迁移注意点见 `docs/architecture.md`（同 DATA_ROOT 路径、
    macOS/Linux 属主、隧道单活等）。
- 备份后实例已重启（daemon Socket.IO `instance/open` status 200）：`Done (13.455s)!`，
  插件 `EasyBot WebSocket 认证成功`，无 403/500。
- 教训补充：`tar tzf | grep 'world/region'` 检查新版世界会误报空；应查
  `world/dimensions/minecraft/` 下的 region。

### 2026-08-13 升级手册实测验证（平台层 + PaperMC 双路径）

- 当前阶段：Phase 3 — 运维动作标准化；按 `docs/usage.md` 第 5 章手册**实测**两条升级路径，
  确认文档即操作、可复制执行。
- 已完成（平台层 digest 升级）：
  - `./update-image-digests.sh` 检出新镜像：cloudflared / mcsmanager-web / mcsmanager-daemon /
    easybot 4 服务全部刷新 compose.yaml digest（提交 `8bcfbdf`，已 push origin main）。
  - `deploy.sh -d /Users/Shared/orzmc up` 重建 4 容器零报错；cloudflared
    `Registered tunnel connection`；daemon 守护进程成功启动、1 实例加载；EasyBot
    `QQ Gateway connected` + `ready`；3 个公网入口（mcs / easybot / mcs-node）全部 HTTP 200。
  - **回滚路径**：`git revert 8bcfbdf` + `deploy.sh up`（digest 锁定保证可精确回退，不触碰
    DATA_ROOT）。
- 已完成（PaperMC 同版本重放验证，build #111 → #112）：
  - 下载 paperclip `paper-26.2-112.jar`（59M，SHA-256 对官方 `fill-data.papermc.io` hash
    校验一致）；旧 jar 备份 `paper.jar.bak-20260813`；替换后经 daemon `instance/open` 重启。
  - 启动验证：`Starting minecraft server version 26.2` → `Preparing level "world"` →
    `Preparing spawn area: 100%` → `EasyBot WebSocket 认证成功` → `Done (8.487s)`；
    25565 端口监听中。
  - **世界完整性**：全维度 `.mca` 仍 19 个（overworld 11 / nether 4 / end 4，与备份基线一致）；
    `level.dat` 454B；`versions/26.2/paper-26.2.jar` 由新 paperclip 首次启动自动刷新（28M）；
    `server.properties` 关键项不变（level-name=world / online-mode=false / server-port=25565）。
  - **回滚路径**：换回 `paper.jar.bak-20260813` + 重启实例。
- 新发现/确认：
  - 新版 PaperMC 下载机制：v2/v3 API 已下线（Endpoint Retired/Unsupported），现走
    `https://fill-data.papermc.io/v1/objects/<sha256>/paper-<版本>-<build>.jar`；最新 Paper 26.2
    build #112。手册 5.4 的"下载 paperclip 命名 paper.jar"写法兼容，无需改文档。
  - daemon 容器重启会移除受管实例容器（autoStart=false），须用面板/daemon API 重新
    `instance/open`——本次实测再证，操作手册已标注（勿 `docker restart MCSM-<uuid>`）。
- 下一步（可选）：
  - 若做跨大版本升级（如 26.2 → 27），需先停服备份、核对新版本 Java 要求（26.x 需 Java 25/
    eclipse-temurin:25-jre）与插件 `api-version` 兼容性，再按 5.4 流程替换。
  - 仓库侧无待提交内容；本次无代码改动，仅有本记录。

### 2026-08-14 env 整理 + 禁用微信适配器 + 清理旧 IM 网关

- 动作：
  - 删除 6 个 monorepo 联调测试变量（`QQBOT_GUILD_ID/CHANNEL_ID/DM_GUILD_ID/PRIVATE_USER_ID/
    MEMBER_LIMIT/TEST_MESSAGE`）：`templates/env.{prod,local}` 与生产 `.env` 已清；生产
    `.env` 备份为 `.env.bak-pre-grouping`。
  - 环境变量按产品重排分组（基础 / 边缘层 / 域名 / EasyBot / MCSManager / QQ / 可选适配器）；
    生产 `.env` 同时修正了误置文末的 `DOMAIN_MCS_NODE`。
  - **禁用微信适配器**：新增 `templates/gateway.local.yaml`（`adapters.wechat.enabled: false`）
    + `ensure_easybot_local_config`（仿 Caddyfile，init 双 profile 生成、绝不覆盖）。
    生产已落盘并重启验证：日志 `Skipping adapter 'wechat' ... explicitly disabled in config`，
    `Started adapters: ["qq"]`，QQ Gateway 正常。
  - 旧 IM 网关相关字样彻底清除：`templates/env.prod` 注释、`docs/{easybot,usage,architecture}.md`
    与本文件全部清理（含 ADR-001 改写为「EasyBot 统一 IM 网关」）。
- 验证：生产 `validate` 通过；`./local.sh init` 生成 `gateway.local.yaml`（幂等不覆盖）、
  本地 `.env` 从新模板重建（14 键、无测试变量）；`deploy.sh -d ./.local-data validate`
  local profile 通过。`./local.sh start` 未跑：local 与 prod 共用 compose 项目 `orzmc`，
  生产在运行时会按本地 env 重建容器，需先停 prod。
- 教训：EasyBot 微信适配器无凭据即自动启用（扫码登录），官方文档未记载禁用方式；
  从源码确认适配器支持 `enabled: false`（`gateway.local.yaml` 覆盖层，EasyBot 从
  `EASYBOT_HOME` 读取）。

### 2026-08-14 故障修复：启用 gateway.local.yaml 后 easybot 公网入口 502

- 现象：`docker restart orzmc-easybot`（加载微信禁用覆盖）后，easybot 公网入口 502，
  cloudflared 持续报 `dial tcp 172.18.0.3:8080: connect: connection refused`
  （`originService=http://easybot:8080`）；容器 `(healthy)`，healthcheck 的
  `/api/v1/live` 在容器内仍 200。
- 根因（源码确认）：EasyBot 加载 `gateway.local.yaml` 时走 `load_config` —— 先反序列化为
  完整 `GatewayConfig` 结构体，缺失键被 **serde 默认值**补齐（`server.host` 默认
  `127.0.0.1`，见 easybot-core `config/mod.rs`），再 `to_value` 序列化后深合并进基础
  配置 —— 于是本地文件即使只写了 `adapters`，也会注入一个 `server.host: 127.0.0.1`
  覆盖基础 gateway.yaml 的 `0.0.0.0`。结果监听只绑容器回环（`/proc/net/tcp` 显示
  `0100007F:1F90`），compose 内网与 cloudflared 均不可达。
- 修复：`gateway.local.yaml` 显式钉住
  `server: { host: "0.0.0.0", port: 8080 }`（显式值不参与默认注入，能原样过 round-trip）。
  已同步 `templates/gateway.local.yaml`（模板注释记录该坑）与生产运行数据；重启后
  跨容器探活 `easybot:8080/api/v1/live` 返回 alive、公网入口 200、QQ Gateway 正常、
  微信仍禁用。
- 教训：容器 healthcheck 走 localhost，监听异常时不会体现为 unhealthy，须用跨容器探活
  或 `/proc/net/tcp` 核对监听是否为 `00000000:1F90`（0.0.0.0:8080，全部接口）。此坑为
  EasyBot ≤0.0.34 的 round-trip 默认值注入行为，v0.0.35 已根治（见下节）。

### 2026-08-14 根治：EasyBot v0.0.35 修复 round-trip 默认值注入，升级并移除 workaround

- 上游修复（`EasyIndie/EasyBot` v0.0.35）：新增 `load_config_value` 按原始 YAML Value
  解析本地覆盖（不反序列化结构体，不再注入 `server.host` 默认 `127.0.0.1`），合并后
  仍校验 webhook 防 SSRF；`plugin_cli` 合并路径同步修正。带回归测试
  （`test_load_config_value_no_default_injection` /
  `test_merge_local_raw_value_preserves_base_server_host`）。release.yml 全绿
  （verify / build-binaries / create-release / docker multi-arch + Trivy）。
- 部署升级：`update-image-digests.sh easybot` 锁 v0.0.35 digest，`deploy.sh up` 升级；
  生产 `gateway.local.yaml` 移除 `server:` 段（恢复只写 adapters），重启后
  `/proc/net/tcp` 显示 `00000000:1F90`（0.0.0.0:8080，修复生效）、公网入口 200、
  QQ Gateway 正常、微信仍禁用。
- 模板/文档同步：`templates/gateway.local.yaml` 与 `docs/easybot.md` 去掉 `server` 段
  与 ⚠️ 警告，改为「≥0.0.35 已修复，仅需写显式覆盖键；镜像 digest 已锁定 0.0.35+」。
- 回滚：deploy `git revert` digest commit → 旧镜像（旧镜像需配合钉 `server.host` 的
  `gateway.local.yaml`）；EasyBot 可发 0.0.36 取代。

### 2026-08-14 平台层常驻 MariaDB（默认启用）+ 备份/还原集成 + 硬件选型修订

- 当前阶段：Phase 2 — 平台层新增应用数据库（ADR-008），为 PaperMC 插件
  （Dynmap/CoreProtect/LuckPerms/Towny/economy 等）提供内网 `mariadb:3306`。
- 已完成（代码 + 文档）：
  - `compose.yaml` 新增 `mariadb` 服务（11.4 LTS，digest 锁定 `sha256:67873d30...`，**无
    profile 默认启用**，`expose 3306`，healthcheck 官方脚本，数据落
    `$DATA_ROOT/database/mariadb`）。
  - `lib/common.sh`：新增 `wait_for_mariadb` / `dump_db_logical` / `db_root_pw`；
    `ensure_data_dirs` 常驻创建并 chown `999:999` `database/mariadb`；
    `MARIADB_ROOT_PASSWORD/DATABASE/USER/PASSWORD` 加入 `REQUIRED_ENV_VARS_PROD/LOCAL`。
  - `backup.sh`：`compose down` 之前自动 `mariadb-dump --all-databases` 逻辑快照
    （`$DATA_ROOT/database/dumps/`，chmod 600，`--keep` 一并剪枝）；dump 失败 `|| warn`
    兜底不中断整机备份。
  - `restore.sh`：校验还原内容含 `database/mariadb` 冷数据目录（权威），缺目录仅提示
    手动导入 dump（兜底）。
  - `templates/env.{prod,local}` 末尾追加 4 个 `MARIADB_*` 必需变量；`update-image-digests.sh`
    注册 `mariadb:11.4`（4 处）；`docs/{architecture,usage,papermc-template}.md`、`env.papermc`、
    `AGENTS.md`、`README.md` 同步（含 **ADR-008** 与 **附录 F 硬件选型修订**：平台层固定成本
    ~250 MB → 0.5–0.6 GB，mariadb 约 0.3 GB）。
- 本地验证（`.local-data`，macOS + Docker Desktop，全套 PASS）：
  - 迁移演练：既有 `.env` 无 `MARIADB_*` → `validate` 报缺失 → 手动补 4 行 → local validate
    通过；负向（清空 `MARIADB_DATABASE`）正确报"缺少必需变量"。
  - `./local.sh start` 后 `orzmc-mariadb` `(healthy)`；`docker port` 无输出（未发布端口）；
    daemon 容器解析 `mariadb` → 172.18.0.7（orzmc_default）；`SELECT 1` 返回 1。
  - 备份往返：写入标记表 `t1` → `./local.sh backup --keep 2` → 归档含
    `database/dumps/mariadb-all-*.sql`（含标记行）与 `database/mariadb/`；dump 文件 600；
    `--keep` 正确剪除旧归档。
  - 还原往返：`./local.sh stop` → `restore.sh -d /tmp/orzmc-restore-test/.local-data <归档>
    --start` → 还原栈 mariadb healthy、`SELECT * FROM t1` 返回 `1|roundtrip-ok`、`.env`
    DATA_ROOT 改写为 `/tmp` 路径、`.env.bak-restore` 保留、4 个 `MARIADB_*` 原样保留 →
    清理 /tmp 栈并 `./local.sh start` 恢复本地栈。
  - `./update-image-digests.sh mariadb` 交叉检查：未变化（digest 已正确）。
- 新发现问题（本次验证发现并修复，均已在仓库内落地）：
  1. **mariadb-dump 免密失败**：设置 `MARIADB_ROOT_PASSWORD` 后 root 需密码登录，
     `dump_db_logical` 原以无密码执行 dump 失败（backup 降级只含数据目录）。修复：
     dump/ping 均通过 `MYSQL_PWD` 环境变量传入密码（避免 `-p` 出现在进程列表）。
  2. **restore.sh --start 遗留 bug**：`source lib/common.sh` 会把 `SCRIPT_DIR` 覆写为
     `lib/`（BASH_SOURCE），导致 `${SCRIPT_DIR}/deploy.sh` 解析成 `lib/deploy.sh` 不存在。
     修复：改以 `REPO_ROOT`（common.sh 正确按仓库根计算）定位 `deploy.sh`。
  3. **restore 同父目录改名还原隐患**：把 `.local-data` 的归档 `--force` 还原成同父目录下
     `.local-data-2` 时，tar 会把归档**解压合并进在用的 `.local-data`**，再 mv 整体改名，
     等于把在用数据目录一起改走。修复：restore.sh 新增守卫——目标父目录已存在与归档顶层
     同名的旧目录时一律拒绝（无论 `--force`），提示改用独立父目录。
- 下一步：
  - 提交本阶段改动（compose + lib/common.sh + backup/restore + 模板 + 文档 + 本记录）。
  - 存量生产 `.env` 需手动补 4 个 `MARIADB_*`（`deploy.sh validate` 强制校验；ADR-008）。
  - 低内存(<8G)环境按附录 F 备注调 `--innodb-buffer-pool-size=64M`。
