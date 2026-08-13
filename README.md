# OrzMC Docker 部署

OrzMC 的最小容器化落地方案。平台层包括：

- `cloudflared`（生产，prod profile）作为公网入口——Cloudflare Tunnel 出站隧道，
  Cloudflare 边缘终止真实 HTTPS
- `Caddy`（本地验证，local profile）作为 `.localhost` 反代 + 本地 CA
- `MCSManager Web` + `MCSManager Daemon` 管理实例
- `EasyBot` 统一 IM 网关（QQ / Telegram / Discord / 飞书 / 微信）

`PaperMC` 不直接写在 `compose.yaml` 中，而是由 `MCSManager` 创建和管理。

> **AI 智能体与协作者请先读 `AGENTS.md`**：仓库的架构铁律（运行时与数据分离）、
> 双 Profile、网络拓扑与安全约束；架构设计与决策记录见 `docs/architecture.md`。
>
> 如果要推进部署方案，请优先阅读 `EXECUTION_PATH.md`：从当前状态推进到 MVP 再到
> 生产化的执行路径与 checklist。

## 架构原则：运行时与数据分离

**仓库只承载"运行时"**——compose 编排、镜像 digest、部署脚本、配置模板；
**全部配置与数据通过卷映射落在宿主机统一目录 `$DATA_ROOT`**（生产 `/srv/orzmc`）。

```text
运行时（Git 仓库 deploy/）                数据（$DATA_ROOT，随数据整体迁移/备份）
  compose.yaml        镜像 digest 锁定        .env                    # 全部环境变量+密钥
  templates/          env.prod/env.local      caddy/{Caddyfile,data,config}
                      /env.papermc            cloudflared/{config.yml,cert.pem,<id>.json}
                      /cloudflared-config.yml mcsmanager/{web,daemon}/{data,logs}
  deploy.sh  local.sh  backup.sh  restore.sh  easybot/data            # EasyBot 网关数据
  lib/common.sh  update-image-digests.sh      instances/...            # PaperMC 实例
  AGENTS.md  CLAUDE.md  README / EXECUTION_PATH / docs/
```

带来的能力：

- **运行时可独立演进**：升级镜像（`update-image-digests.sh`）或改编排，不触碰 `$DATA_ROOT`。
- **数据可独立备份/还原/迁移**：备份即打包 `$DATA_ROOT`，迁移即拷贝该目录（详见下文）。
- **密钥不进入仓库**：`.env`、cloudflared 凭据等都在 `$DATA_ROOT`，已被 `.gitignore` 排除。

## 双 Profile（local / prod）

| Profile | 边缘层 | 用途 | 公网入口 |
|---|---|---|---|
| `local` | Caddy（`.localhost` + 本地 CA + 非特权端口） | 本地验证 / 回归 | `mcs.localhost` / `easybot.localhost` / `mcs-node.localhost` |
| `prod` | cloudflared（Cloudflare Tunnel） | 生产（NAT 内网免开端口） | `mcs.<domain>` / `easybot.<domain>` / `mcs-node.<domain>` |

公网/本地暴露 **3 个入口**：`mcs`（MCSManager 面板）、`easybot`（EasyBot 管理后台）、
`mcs-node`（MCSManager daemon/节点——面板浏览器需直连 daemon 才能用终端/文件管理，
生产走 `mcs-node.<domain>`、本地走 `mcs-node.localhost`，daemon 全部业务路由密钥鉴权）。
**EasyBot 插件 API 仅内网**——插件挂 `orzmc_default` 网络直连 `http://easybot:8080`，
无 `easybot-api` 子域名。

## 目录说明

- `compose.yaml`：平台层编排（`name: orzmc`，镜像 digest 锁定，双 profile）
- `templates/`：首次 init 使用的配置模板（`env.prod` / `env.local` / `env.papermc`
  / `Caddyfile` / `cloudflared-config.yml`）
- `lib/common.sh`：各脚本共享的函数库（DATA_ROOT 解析、compose 封装、目录引导）
- `deploy.sh`：生产部署统一入口（默认 prod profile）
- `local.sh`：本地验证统一入口（固定 local profile + `.local-data`）
- `backup.sh` / `restore.sh`：数据备份与还原/迁移
- `update-image-digests.sh`：刷新镜像 digest，配合 Git 做升级与回滚
- `AGENTS.md` / `CLAUDE.md`：AI 智能体守则（跨工具通用 / Claude Code 入口）
- `EXECUTION_PATH.md`：阶段执行路径、门禁规则和 checklist
- `docs/architecture.md`：架构设计文档（含 ADR 决策记录，长期演进）
- `docs/papermc-template.md`：在 MCSManager 中录入 PaperMC 实例的字段建议
- `docs/easybot.md`：EasyBot 网关与插件 `easybot.yml` 配置指南

## 命令速查

| 场景 | 本地 | 生产 |
|---|---|---|
| 初始化目录/env/边缘配置 | `./local.sh init` | `deploy.sh init` |
| 启动平台层 | `./local.sh start` | `deploy.sh up` |
| 停止 | `./local.sh stop` | `deploy.sh stop` |
| 查看状态与访问地址 | `./local.sh status` | `deploy.sh status` |
| 校验配置 | `deploy.sh -d ./.local-data validate` | `deploy.sh validate` |
| 备份数据 | `./local.sh backup` | `backup.sh --stop` |
| 还原/迁移数据 | `./restore.sh -d <root> <归档>` | `restore.sh <归档>` |

生产环境如需非默认目录：`deploy.sh -d /path/to/root ...` 或 `ORZMC_DATA_ROOT=/path deploy.sh ...`。
Profile 可用 `-p local|prod` 显式指定（默认 prod）。

## 第一次部署（生产）

生产主机在 NAT 内网、公网 80/443 不可达时，采用 Cloudflare Tunnel（出站连接），
**无需开放任何端口、无需 ACME**。

```bash
# 1. 隧道一次性初始化（交互；需浏览器授权，见 EXECUTION_PATH.md Stage 2）
docker run --rm -v /srv/orzmc/cloudflared:/home/cloudflared cloudflare/cloudflared tunnel login
docker run --rm -v /srv/orzmc/cloudflared:/home/cloudflared cloudflare/cloudflared tunnel create orzmc
docker run --rm -v /srv/orzmc/cloudflared:/home/cloudflared cloudflare/cloudflared tunnel route dns orzmc mcs.example.com
docker run --rm -v /srv/orzmc/cloudflared:/home/cloudflared cloudflare/cloudflared tunnel route dns orzmc easybot.example.com
docker run --rm -v /srv/orzmc/cloudflared:/home/cloudflared cloudflare/cloudflared tunnel route dns orzmc mcs-node.example.com

# 2. init：创建 $DATA_ROOT，生成 .env 与 cloudflared/config.yml
deploy.sh -d /srv/orzmc init

# 3. 编辑 .env，至少修改：CLOUDFLARE_TUNNEL_ID、DOMAIN_MCS_WEB、DOMAIN_EASY_ADMIN、
#    DOMAIN_MCS_NODE、EASYBOT_ADMIN_PASSWORD、QQBOT_APP_ID、QQBOT_CLIENT_SECRET
vim /srv/orzmc/.env

# 4. 校验配置
deploy.sh -d /srv/orzmc validate

# 5. 启动平台层
deploy.sh -d /srv/orzmc up
```

验证平台层：

- 打开 `https://${DOMAIN_MCS_WEB}`（`mcs.<domain>`），确认 `MCSManager Web` 可访问
- 打开 `https://${DOMAIN_EASY_ADMIN}`（`easybot.<domain>`），确认 EasyBot 管理后台可访问
- 打开 `https://${DOMAIN_MCS_NODE}`（`mcs-node.<domain>`），应出现 daemon 的鉴权
  错误/无会话提示（无 key 不可用属预期，说明入口已通）
- 在 `MCSManager` 中添加节点，地址用内部 `http://mcsmanager-daemon:24444` + daemon key；
  随后在节点设置里把连接地址改为 `wss://mcs-node.<domain>:443`（浏览器直连 daemon）
- EasyBot 管理后台创建「客服类 API Key」与会话，按 `docs/easybot.md` 配置插件（内网
  直连 `http://easybot:8080`）

## 本地验证模式

macOS / Docker Desktop 建议使用 `./local.sh`（自动生成 `.local-data/`）：

```bash
./local.sh init
./local.sh start
./local.sh status
./local.sh stop
```

本地默认调整：

- `DATA_ROOT` 指向仓库下的 `.local-data`
- 对外端口改为 `18080/18443`
- 域名改为 `mcs.localhost` / `easybot.localhost` / `mcs-node.localhost`（Caddy 本地证书）
- 数据与备份目录（`.local-data/`、`.local-backups/`）均被 `.gitignore` 排除

## EasyBot

- EasyBot 取代 NapCat，统一接入 QQ / Telegram / Discord / 飞书 / 微信，监听器仅 HTTP，
  TLS 由边缘层承担（prod=Cloudflare / local=Caddy），端口只 `expose` 不发布宿主机。
- QQ 适配器使用 QQ 开放平台凭据（`.env` 中 `QQBOT_APP_ID` / `QQBOT_CLIENT_SECRET`），
  与旧 NapCat 个人账号扫码是不同接入模型。
- 插件通过 `easybot.yml` 的 `api_server` / `ws_server` 指向 **`http://easybot:8080`**
  （内网直连，实例须挂 `orzmc_default` 网络）。详细配置见 `docs/easybot.md`。

## PaperMC 的创建边界

`PaperMC` 不是 `compose.yaml` 的常驻服务，而是后续在 `MCSManager` 面板里新增的实例：

- 平台层由 `docker compose` 管理
- `PaperMC` 生命周期由 `MCSManager Daemon` 管理
- `PaperMC` 数据持久化在 `$DATA_ROOT/instances/`
- `PaperMC` 实例网络挂到 `orzmc_default`，插件才能内网直连 EasyBot

好处：不会出现两套控制入口冲突；新增第二个 Minecraft 实例无需改平台编排；
`$DATA_ROOT/instances/` 随整体数据目录一并备份/迁移。

## 备份 / 还原 / 迁移

### 备份

```bash
./backup.sh --stop          # 先停 compose 再打包再拉起（更一致）
./backup.sh                 # 在线打包（best-effort）
./backup.sh --keep 7        # 只保留最近 7 份
./backup.sh -o /mnt/backups # 指定备份目录
```

- 归档整个 `$DATA_ROOT`（含 `.env`、Caddyfile、cloudflared 凭据），默认输出到
  `$(dirname $DATA_ROOT)/orzmc-backups`（在 DATA_ROOT 之外，避免自我包含）。
- `--stop` 只保证 compose 服务一致性；MCSManager 管理的 PaperMC 实例不属于 compose，
  如需完全一致快照请先在面板停止实例。

### 还原 / 迁移

```bash
# 新宿主机：先装好 docker + 拉取本仓库（运行时），再还原数据
./restore.sh /path/to/orzmc-backup-*.tar.gz
./restore.sh -d /srv/orzmc /path/to/orzmc-backup-*.tar.gz --start   # 还原并拉起
```

- 目标目录非空时默认拒绝，`--force` 会把旧目录移为 `.old-<时间>`（不删除）。
- 归档顶层目录名与目标名不一致时默认拒绝，`--force` 解压后改名。
- 还原到新路径时自动改写 `.env` 内的 `DATA_ROOT`（迁移核心），并保留 `.env.bak-restore`。

## 端口约定

- 生产（prod）：**不发布任何宿主机端口**（Cloudflare Tunnel 出站；所有服务仅 `expose`）。
- 本地（local）：`18080/18443`（Caddy 非特权端口）
- `23333`：MCSManager Web（容器内）
- `24444`：MCSManager Daemon（容器内；浏览器经 `mcs-node.<domain>` 直连）
- `8080`：EasyBot（容器内，内网直连，不发布宿主机）
- `25565`：建议保留给 PaperMC 正式服
- `25566`：建议保留给 PaperMC 测试服

## 升级与回滚

`compose.yaml` 使用镜像摘要锁定，升级分两步：

```bash
./update-image-digests.sh          # 或指定服务: ./update-image-digests.sh easybot
git diff -- compose.yaml
git add compose.yaml && git commit -m "chore: update docker image digests"
./local.sh start                   # 或生产: deploy.sh up
```

回滚：`git revert <commit>` 后重新拉起。升级/回滚不触碰 `$DATA_ROOT`，数据保持不变。

## 重要说明

- `mcsmanager-daemon` 挂载了 `/var/run/docker.sock`，拥有管理宿主机 Docker 的能力，必须把宿主机视为可信环境。
- EasyBot 监听器仅 HTTP，`EASYBOT_ALLOW_PLAINTEXT=true` 为有意为之，TLS 由边缘层承担。
- EasyBot 以 `uid/gid=10001` 运行；`deploy.sh init` 以 root 执行时会 chown 其数据目录（Linux 生产常态）。
- `$DATA_ROOT/cloudflared/` 含账号级 `cert.pem` 与隧道凭据 `<id>.json`——按密钥对待，
  只存在于 DATA_ROOT 内、随数据备份、权限收紧。
- `$DATA_ROOT/mcsmanager/daemon/data/Config/global.json` 含 **daemon key**（控制
  docker.sock），权限 600、随数据备份、永不入库，按最高权限密钥对待。
- macOS / Docker Desktop：容器内 uid 检查通过但磁盘写入由宿主用户进程执行，实例目录
  属主需改为宿主用户（`sudo chown -R joker:staff <instance-dir>`），见
  `docs/papermc-template.md`。
- `templates/env.papermc` 与 `docs/papermc-template.md` 中的 PaperMC 参数仅供参考，compose 不消费。
