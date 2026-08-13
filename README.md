# OrzMC Docker 部署

OrzMC 的最小容器化落地方案。平台层包括：

- `Caddy` 作为统一入口和 HTTPS 终止
- `MCSManager Web` + `MCSManager Daemon` 管理实例
- `EasyBot` 统一 IM 网关（QQ / Telegram / Discord / 飞书 / 微信）

`PaperMC` 不直接写在 `compose.yaml` 中，而是由 `MCSManager` 创建和管理。

如果要推进部署方案，请优先阅读 `EXECUTION_PATH.md`：从当前状态推进到 MVP 再到生产化的执行路径与 checklist。

## 架构原则：运行时与数据分离

**仓库只承载"运行时"**——compose 编排、镜像 digest、部署脚本、配置模板；
**全部配置与数据通过卷映射落在宿主机统一目录 `$DATA_ROOT`**（生产默认 `/srv/orzmc`）。

```text
运行时（Git 仓库 deploy/）                数据（$DATA_ROOT，随数据整体迁移/备份）
  compose.yaml        镜像 digest 锁定        .env                    # 全部环境变量+密钥
  templates/          env.prod/env.local      caddy/{Caddyfile,data,config}
                      /env.papermc/Caddyfile  mcsmanager/{web,daemon}/{data,logs}
  deploy.sh  local.sh  backup.sh  restore.sh  easybot/data            # EasyBot 网关数据
  lib/common.sh  update-image-digests.sh      instances/...            # PaperMC 实例
  README / EXECUTION_PATH / docs/
```

带来的能力：

- **运行时可独立演进**：升级镜像（`update-image-digests.sh`）或改编排，不触碰 `$DATA_ROOT`。
- **数据可独立备份/还原/迁移**：备份即打包 `$DATA_ROOT`，迁移即拷贝该目录（详见下文）。
- **密钥不进入仓库**：`.env`、Caddyfile 等都在 `$DATA_ROOT`，已被 `.gitignore` 排除。

## 目录说明

- `compose.yaml`：平台层编排（`name: orzmc`，镜像 digest 锁定）
- `templates/`：首次 init 使用的配置模板（`env.prod` / `env.local` / `env.papermc` / `Caddyfile`）
- `lib/common.sh`：各脚本共享的函数库（DATA_ROOT 解析、compose 封装、目录引导）
- `deploy.sh`：生产部署统一入口
- `local.sh`：本地验证统一入口
- `backup.sh` / `restore.sh`：数据备份与还原/迁移
- `update-image-digests.sh`：刷新镜像 digest，配合 Git 做升级与回滚
- `EXECUTION_PATH.md`：阶段执行路径、门禁规则和 checklist
- `docs/papermc-template.md`：在 MCSManager 中录入 PaperMC 实例的字段建议
- `docs/easybot.md`：EasyBot 网关与插件 `easybot.yml` 配置指南

## 命令速查

| 场景 | 本地 | 生产 |
|---|---|---|
| 初始化目录/env/Caddyfile | `./local.sh init` | `deploy.sh init` |
| 启动平台层 | `./local.sh start` | `deploy.sh up` |
| 停止 | `./local.sh stop` | `deploy.sh stop` |
| 查看状态与访问地址 | `./local.sh status` | `deploy.sh status` |
| 校验配置 | `deploy.sh -d ./.local-data validate` | `deploy.sh validate` |
| 备份数据 | `./local.sh backup` | `backup.sh --stop` |
| 还原/迁移数据 | `./restore.sh -d <root> <归档>` | `restore.sh <归档>` |

生产环境如需非默认目录：`deploy.sh -d /path/to/root ...` 或 `ORZMC_DATA_ROOT=/path deploy.sh ...`。

## 第一次部署（生产）

```bash
# 1. init：创建 $DATA_ROOT，生成 .env 与 Caddyfile（DATA_ROOT 默认 /srv/orzmc）
sudo deploy.sh init

# 2. 编辑 .env，至少修改：
#    DATA_ROOT、CADDY_EMAIL、DOMAIN_MCS_WEB、DOMAIN_MCS_NODE、
#    DOMAIN_EASY_ADMIN、DOMAIN_EASY_API、EASYBOT_ADMIN_PASSWORD、
#    QQBOT_APP_ID、QQBOT_CLIENT_SECRET
sudo vim /srv/orzmc/.env

# 3. 校验配置
sudo deploy.sh validate

# 4. 启动平台层
sudo deploy.sh up
```

验证平台层：

- 打开 `https://${DOMAIN_MCS_WEB}`，确认 `MCSManager Web` 可访问
- 打开 `https://${DOMAIN_EASY_ADMIN}`，确认 EasyBot 管理后台可访问
- 在 `MCSManager` 中添加节点，使用 `https://${DOMAIN_MCS_NODE}` 对应的守护进程入口
- EasyBot 管理后台创建「客服类 API Key」与会话，按 `docs/easybot.md` 配置插件

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
- 域名改为 `*.localhost`（Caddy 本地证书）
- 数据与备份目录（`.local-data/`、`.local-backups/`）均被 `.gitignore` 排除

## EasyBot

- EasyBot 取代 NapCat，统一接入 QQ / Telegram / Discord / 飞书 / 微信，监听器仅 HTTP，
  必须由 Caddy 前置 TLS，端口只 `expose` 不发布宿主机。
- QQ 适配器使用 QQ 开放平台凭据（`.env` 中 `QQBOT_APP_ID` / `QQBOT_CLIENT_SECRET`），
  与旧 NapCat 个人账号扫码是不同接入模型。
- 插件通过 `easybot.yml` 的 `api_server` / `ws_server` 指向 `DOMAIN_EASY_API`。
  详细配置见 `docs/easybot.md`。

## PaperMC 的创建边界

`PaperMC` 不是 `compose.yaml` 的常驻服务，而是后续在 `MCSManager` 面板里新增的实例：

- 平台层由 `docker compose` 管理
- `PaperMC` 生命周期由 `MCSManager Daemon` 管理
- `PaperMC` 数据持久化在 `$DATA_ROOT/instances/`

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

- 归档整个 `$DATA_ROOT`（含 `.env` 与 Caddyfile），默认输出到
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

- `80/443`：Caddy
- `23333`：MCSManager Web（容器内）
- `24444`：MCSManager Daemon（容器内）
- `8080`：EasyBot（容器内，经 Caddy 反代，不发布宿主机）
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
- EasyBot 监听器仅 HTTP，`EASYBOT_ALLOW_PLAINTEXT=true` 为有意为之，TLS 由 Caddy 承担。
- EasyBot 以 `uid/gid=10001` 运行；`deploy.sh init` 以 root 执行时会 chown 其数据目录（Linux 生产常态）。
- `Caddy` 自动签发 HTTPS 证书依赖真实域名解析到宿主机，且 `80/443` 可从公网访问。
- `templates/env.papermc` 与 `docs/papermc-template.md` 中的 PaperMC 参数仅供参考，compose 不消费。
