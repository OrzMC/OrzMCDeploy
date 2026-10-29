# OrzMC Docker 部署

[![CI](https://github.com/OrzMC/OrzMCDeploy/actions/workflows/ci.yml/badge.svg)](https://github.com/OrzMC/OrzMCDeploy/actions/workflows/ci.yml)

Minecraft 服务器的最小容器化部署方案：用 Docker Compose 跑**平台层**
（MCSManager 面板 + daemon、EasyBot 统一 IM 网关），再由 MCSManager 创建和管理
**PaperMC 实例**（实例生命周期不归 compose 管）。

- **MCSManager**：Web 面板管理实例（启动/停止/控制台/文件）——`http://<LAN_HOST_IP>:18090`
- **EasyBot**：QQ / Telegram / Discord / 飞书 / 微信统一网关，插件内网直连——`http://<LAN_HOST_IP>:18091`
- **PaperMC**：面板创建，可多实例，玩家 `IP:25565` 直连；数据落 `$DATA_ROOT` 随备份迁移
- **只有局域网模式**（ADR-027）：纯 HTTP、仅限可信内网；对外访问（DDNS + 端口映射 / TLS 反代 /
  VPN）由站点自备，本仓库不管

## 快速开始

```bash
git clone <仓库地址> orzmc-deploy && cd orzmc-deploy
./orzmc.sh -d <你的数据目录> init    # 必填：数据/密钥/备份都落在这里（无默认路径）
vi <你的数据目录>/.env              # 改 LAN_HOST_IP / EASYBOT_ADMIN_PASSWORD / QQBOT_*
./orzmc.sh -d <你的数据目录> validate
./orzmc.sh -d <你的数据目录> up
./orzmc.sh -d <你的数据目录> status  # 打印访问地址 + 容器状态
```

`DATA_ROOT` **没有默认值**：必须用 `-d <路径>` 或 `export ORZMC_DATA_ROOT=<路径>` 显式指定，
脚本不回落到任何平台路径（先确认数据放哪、磁盘够不够，再 init）。三平台命令一致；
Windows 注意 `DATA_ROOT` 要用原生路径（见 [usage 附录 F](docs/usage.md#附录-f-windows-平台要点)）。

免克隆安装（下载 Release tarball + sha256 校验）：`curl -fsSL .../install.sh | bash`，
详见 [`install.sh`](install.sh)。

## 常用命令

| 场景 | 命令 |
|---|---|
| 初始化 / 启动 / 停止 | `./orzmc.sh -d <数据目录> init` · `up` · `stop` |
| 状态 / 校验 | `./orzmc.sh -d <数据目录> status` · `validate` |
| 防火墙限源（ADR-028） | `./orzmc.sh -d <数据目录> firewall apply`（`show` 查看） |
| 备份 / 还原 | `./orzmc.sh backup [--stop] [--keep N]` · `./restore.sh -d <目标> <归档> [--force]` |
| 升级镜像 | `./update-image-digests.sh` → `git commit` → `stop && up`（禁止面板内自助升级） |

`DATA_ROOT` 优先级：`-d` > `ORZMC_DATA_ROOT`（**两者都没有时报错**，无默认路径）。

## 关键约束

- **运行时与数据分离**：仓库只放 compose / 脚本 / 模板；全部配置、密钥、数据落 `$DATA_ROOT`。
  `.env`（含密钥）与 daemon key 权限 600、随备份、**永不入库**。
- **镜像 digest 锁定**：升级 = 改 digest + commit，回滚 = `git revert`；不要容器内升级。
- **站点增量不写包内文件**：站点特有 env/挂载写 `$DATA_ROOT/compose.site.yaml`，升级换包不丢。

## 文档

| 文档 | 内容 |
|---|---|
| [`docs/usage.md`](docs/usage.md) | **使用手册**：安装、配置、运维、实例管理、排障、迁移（含 Windows 要点） |
| [`docs/security.md`](docs/security.md) | 暴露面与访问控制：三层限源模型、对外暴露方案、TLS 反代配方 |
| [`docs/architecture.md`](docs/architecture.md) | 架构与设计决策（ADR-001…031） |
| [`docs/papermc-template.md`](docs/papermc-template.md) | 面板里录入 PaperMC 实例的字段参考 |
| [`AGENTS.md`](AGENTS.md) / [`CLAUDE.md`](CLAUDE.md) | AI 智能体与协作者守则（改仓库前必读；含基线、门禁与待办） |
| [`CHANGELOG.md`](CHANGELOG.md) | 版本变更记录 |

## 安全

面板与 EasyBot 都是 **HTTP + 口令登录**，只暴露给局域网：默认端口绑 `0.0.0.0`，请用
`./orzmc.sh firewall apply` 把来源收回 `LAN_CIDR`（ADR-028）；要公网访问**必须**加 TLS 反代
或改用 VPN。`mcsmanager-daemon` 挂载 `/var/run/docker.sock`（可管理宿主机 Docker），
宿主机须视为可信环境。详见 [`docs/security.md`](docs/security.md)。
