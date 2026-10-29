# Windows 平台部署要点

> 本项目只有**局域网模式**（ADR-027）：面板与 EasyBot 发布宿主端口、纯 HTTP，局域网设备
> 直连；对外访问由站点自备（DDNS + 端口映射 / 反代 / VPN）。
> 三平台命令完全一致，本文只记录 **Windows（Docker Desktop + WSL2）** 特有的差异。

## 1. 环境与路径

| 项 | 说明 |
|---|---|
| Docker | Docker Desktop（WSL2 后端）。`docker version` 能看到 Client + Server |
| `DATA_ROOT` | Windows 侧默认 `E:/orzmc`（`ORZMC_DATA_ROOT` 或 `-d` 可改）。**用 Windows 原生路径**（`E:/orzmc`），不要用 MSYS 的 `/e/orzmc` |
| 执行位置 | **在 Windows 侧执行 compose**（Git Bash / 带 bash 的终端）。详见 §3 |
| `.env` | 由 `./orzmc.sh init` 生成；`DATA_ROOT` 行按生效值改写 |

## 2. 常用命令

```bash
./orzmc.sh -d E:/orzmc init       # 建目录 + 生成 .env（改 LAN_HOST_IP / 口令 / 凭据）
./orzmc.sh -d E:/orzmc validate
./orzmc.sh -d E:/orzmc up
./orzmc.sh -d E:/orzmc status     # 打印 http://<LAN_HOST_IP>:<port> 与容器状态
```

## 3. 必须在 Windows 侧执行 compose（关键约束）

**WSL 侧 compose 不能创建带 `E:/...` 绑定的容器**，会报：

```
Error response from daemon: invalid volume specification:
'E:/orzmc/mcsmanager/daemon/data:/opt/mcsmanager/daemon/data:rw'
```

原因：短语法 `source:target` 里的盘符冒号在 WSL 侧被当成分隔符。表现形式：

- 在 WSL 里跑 `./orzmc.sh up` → 建容器失败（`init`/`validate` 却可能通过，因为纯解析）；
- 在 Windows 侧（Git Bash）跑同一命令 → 正常。

所以：**不要从 WSL 执行 `up`**；脚本内部对 Windows 路径的转换（`win_path`）也是为此存在。

## 4. daemon 容器：默认由 compose 管理（ADR-029）

- `DAEMON_PORTS` **为空**（站点用 docker 型实例）→ `compose up -d` 一把建好，daemon 带
  `mcsmanager-daemon` 服务名别名，面板可直接解析。
- `DAEMON_PORTS` **非空**（进程模式实例需要把进服端口映射到宿主）→ compose 无法按 `.env`
  动态生成端口列表，脚本改为剔除 daemon 后 `docker run --mount` 创建并补别名
  （`lib/common.sh` 的 `win_daemon_run` / `win_daemon_alias`）。
- 切换两种情况后请 `stop && up` 重建（`down` 会先 `docker rm -f` 手动容器）。

## 5. 端口与防火墙

- 宿主发布端口：`LAN_MCS_WEB_PORT`（默认 18090）、`LAN_EASYBOT_PORT`（默认 18091）。
  **daemon 的 24444 不发布**（ADR-026）。
- PaperMC 实例端口（`25565` / `19132` 等）由 MCSManager 按实例配置发布。
- Windows 防火墙需要放行上述入站端口（管理员 PowerShell）：

```powershell
New-NetFirewallRule -DisplayName 'OrzMC MCSM Panel' -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort 23333 -RemoteAddress Any
New-NetFirewallRule -DisplayName 'OrzMC EasyBot' -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort 18091 -RemoteAddress Any
# 查已有规则：Get-NetFirewallRule -DisplayName 'OrzMC*' | Select DisplayName,Enabled,Action
```

- Docker 发布端口在 WSL 网络栈里（`networkingMode=mirrored`），Windows 侧 `netstat` 看不到
  监听属正常；**验证要用手机/另一台设备**访问 `http://<宿主LAN IP>:<端口>`。

## 6. 实例目录属主

Windows 侧由 Docker Desktop 的文件共享承担写入，一般无需 `chown`；若实例报
`Permission denied` / `AccessDenied`，优先检查：

1. `DATA_ROOT` 所在盘是否在 Docker Desktop 的 File sharing 白名单里；
2. 实例配置里的 `cwd`（绝对路径）是否存在；
3. 杀毒软件是否锁定了 `InstanceData` 目录。

## 7. 常见症状

| 症状 | 原因 | 处理 |
|---|---|---|
| `up` 报 `invalid volume specification` | 在 WSL 侧执行了 compose | 改到 Windows 侧执行（§3） |
| 面板能开，终端/文件管理打不开 | 面板未启用中转模式 | 见 `docs/usage.md` §6.3（`dataPlane=proxy`） |
| 本机能访问、手机不能 | 防火墙未放行 / 用错 IP | 补入站规则；确认访问的是宿主 LAN IP |
| 端口被旧容器占用 | 残留容器（改端口/改服务后） | `./orzmc.sh stop`（`down --remove-orphans`）后 `up` |
| 实例容器"消失" | 直接 `docker restart MCSM-<uuid>` 被 daemon 当停止处理 | 实例生命周期一律走面板 |
| 改了实例 JSON 又回退 | 实例运行中改被内存副本覆盖 | 停 daemon → 改 JSON → 启 daemon（`docs/usage.md` §6.5） |
