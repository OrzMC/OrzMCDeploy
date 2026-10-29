# OrzMC Docker 部署

[![CI](https://github.com/OrzMC/OrzMCDeploy/actions/workflows/ci.yml/badge.svg)](https://github.com/OrzMC/OrzMCDeploy/actions/workflows/ci.yml)

Minecraft 服务器的最小容器化部署方案：用 Docker Compose 跑**平台层**（MCSManager 面板 +
daemon、EasyBot 统一 IM 网关），再由 MCSManager 创建和管理 **PaperMC 实例**
（实例生命周期不归 compose 管）。

| 组成 | 作用 | 入口 |
|---|---|---|
| **MCSManager** | Web 面板管理实例：启停 / 控制台 / 文件 | `http://<LAN_HOST_IP>:18090` |
| **EasyBot** | QQ / Telegram / Discord / 飞书 / 微信网关（插件内网直连） | `http://<LAN_HOST_IP>:18091` |
| **PaperMC** | 面板创建，可多实例，玩家 `<LAN_HOST_IP>:25565` 直连 | 由 MCSManager 发布 |

只有局域网模式（ADR-027）：面板与 EasyBot 走纯 HTTP、仅限可信内网；对外访问（DDNS + 端口
映射 / TLS 反代 / VPN）由站点自备。

## 快速开始

```bash
git clone <仓库地址> orzmc-deploy && cd orzmc-deploy
./orzmc.sh -d <数据目录> init     # 必填：数据 / 密钥 / 备份都落在这里
vi <数据目录>/.env                # 改 LAN_HOST_IP、EASYBOT_ADMIN_PASSWORD、QQBOT_*
./orzmc.sh -d <数据目录> validate
./orzmc.sh -d <数据目录> up
./orzmc.sh -d <数据目录> status   # 访问地址 + 容器状态
```

- **`DATA_ROOT` 没有默认值**：必须 `-d <数据目录>` 或 `export ORZMC_DATA_ROOT=<数据目录>`，
  脚本不会回落到任何平台路径。先确认放哪、磁盘够不够，再 `init`。
- 三平台命令一致；Windows 需用原生路径（`<盘符>:/...`）并加入 Docker Desktop 文件共享白名单，
  其余差异见 [usage 附录 F](docs/usage.md#附录-f-windows-平台要点)。
- 免克隆安装（Release tarball + sha256 校验）：
  `curl -fsSL https://raw.githubusercontent.com/OrzMC/OrzMCDeploy/main/install.sh | bash`

## 常用命令

```bash
./orzmc.sh -d <数据目录> init                  # 初始化（首次；建目录 + 生成 .env）
./orzmc.sh -d <数据目录> up                    # 启动平台层
./orzmc.sh -d <数据目录> stop                  # 停止
./orzmc.sh -d <数据目录> status                # 访问地址 + 容器状态
./orzmc.sh -d <数据目录> validate              # 配置校验
./orzmc.sh -d <数据目录> firewall apply        # 防火墙限源（show 查看现状）
./orzmc.sh -d <数据目录> backup [--stop] [--keep N]
./restore.sh -d <数据目录> <归档> [--force]    # 还原 / 迁移
./update-image-digests.sh [服务]               # 刷新镜像 digest（升级用）
```

升级流程：`update-image-digests.sh` → `git commit` →
`./orzmc.sh -d <数据目录> stop && ./orzmc.sh -d <数据目录> up`；回滚 `git revert`。
**禁止**使用面板内置自助升级（会偏离 digest 锁定）。`ORZMC_DATA_ROOT` 可替代 `-d`
（长期使用建议 export）；两者都没有时命令直接报错。

## 关键约束

- **运行时与数据分离**：仓库只放 compose / 脚本 / 模板；配置、密钥、实例数据全落 `$DATA_ROOT`
  （`.env` 与 daemon key 权限 600、随备份、**永不入库**）。
- **站点增量不写包内文件**：站点特有 env / 挂载写 `$DATA_ROOT/compose.site.yaml`，升级不丢。
- **单一边缘**：daemon 不对宿主发布端口（面板中转），局域网只有面板 / EasyBot 两个入口；
  默认限源三层（绑定地址 + 防火墙 + 容器网络，ADR-028）。

## 文档

| 文档 | 内容 |
|---|---|
| [`docs/usage.md`](docs/usage.md) | **使用手册**：安装、配置、运维、实例、EasyBot、排障、迁移、Windows 要点 |
| [`docs/security.md`](docs/security.md) | 暴露面与访问控制：三层限源、对外暴露方案、TLS 反代配方 |
| [`docs/papermc-template.md`](docs/papermc-template.md) | 面板录入 PaperMC 实例的字段参考 |
| [`docs/architecture.md`](docs/architecture.md) | 架构与设计决策（ADR-001 … ADR-033） |
| [`AGENTS.md`](AGENTS.md) / [`CLAUDE.md`](CLAUDE.md) | 智能体与协作者守则（改仓库前必读） |
| [`CHANGELOG.md`](CHANGELOG.md) | 版本变更记录 |

## 安全

面板与 EasyBot 都是 **HTTP + 口令登录**，只服务局域网：用
`./orzmc.sh -d <数据目录> firewall apply` 把来源收回 `LAN_CIDR`；要公网访问**必须**加 TLS
反代或改用 VPN。`mcsmanager-daemon` 挂载 `/var/run/docker.sock`，宿主机须视为可信环境。
详见 [`docs/security.md`](docs/security.md)。
