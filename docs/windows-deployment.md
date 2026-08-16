# Windows 平台部署指南

> 本文件记录 OrzMC 在 **Windows 11 家庭版 + Docker Desktop(WSL2)** 上的完整部署实录，
> 逐条记录遇到的**问题 → 根因 → 解决办法**，以指导项目后续向 Windows 平台扩展。
> 与 `docs/architecture.md`（ADR-015 起）配套：本文件偏「怎么部署」，ADR 偏「为什么这么设计」。

- **部署机器**：Windows 11 家庭版（SKU 101，无 RDP 服务端）、Docker Desktop 4.86 / WSL2、
  数据目录 `E:\orzmc`、域 `jokerhub.cn`、profile=prod（cloudflared 隧道）。
- **最终可用状态**：平台层 6 容器（web/daemon/easybot/mariadb/status/cloudflared）全部运行，
  4 个公网入口经 Cloudflare 隧道 HTTP 200，Gatus 状态页健康检查全绿，面板↔daemon 节点已连接并通过密钥验证。

---

## 0. 平台差异总览（Windows vs macOS/Linux）

本项目默认按 macOS/Linux 设计（见 `AGENTS.md`、ADR-006/007）。Windows 移植的核心差异：

| 维度 | macOS/Linux 假设 | Windows(Docker Desktop/WSL2) 实际 | 影响 |
|---|---|---|---|
| 卷挂载路径 | `${DATA_ROOT}/mcsmanager/daemon/{data,logs}`（target 无驱动器冒号） | 无驱动器冒号问题（ADR-019 已移除 instances 自挂载）；daemon 仍按 ADR-016 走 `docker run` | daemon 生命周期不归 compose，`win_daemon_run` 自动生成（**ADR-016 起由脚本生成**） |
| 容器服务名别名 | compose 自动注入 `服务名` 网络别名 | **手动创建**（`docker run`）的容器无服务名别名 | 面板/状态页解析失败，须补 alias（**ADR-016 起 `win_daemon_alias` 自动补**） |
| cert.pem 落盘 | 容器 HOME 可写 | 默认 HOME=`/home/nonroot` 写容器层，`--rm` 即丢 | cloudflared 须 `-e HOME=/home/cloudflared` 指向挂载目录 |
| 脚本路径 | `/c/...` 直接可用 | MSYS 生成 `/c/...`，Windows 原生 docker 拼成 `C:\c\...` 出错 | compose 一律用 Windows 原生路径（**ADR-016 起 `compose_cmd` 自动过 `win_path`**） |
| 面板节点地址 | `wss://域名` 按文档填 | 协议前缀/端口写错即连不上 | 严格 `wss://<domain>:443`（prod） |
| Docker 数据 | 默认路径够用 | WSL 数据占 C 盘 | 需迁移到 E 盘（见 §1.2） |

> **ADR-016（三平台统一命令）+ ADR-017（单入口）**：从本版本起，macOS/Linux/Windows 使用
> **同一套命令**（`./orzmc.sh init|up|stop|status|validate|backup`，或 `deploy.sh`）。Windows 下
> 脚本自动完成：daemon 的 `docker run --mount` 创建（`win_daemon_run`）、服务名别名补丁
> （`win_daemon_alias`）、MSYS→原生路径转换（`win_path`，`compose_cmd` 内置）。
> **status/web/easybot/mariadb/cloudflared 已回归 compose 管理**（它们的卷 target 均无
> 驱动器冒号，Windows 可直接 `docker compose up`）；**仅 daemon 一个容器**脱离 compose，
> 由脚本全自动处理。用户无需任何手工 `docker run` / `docker network connect` / 路径转换。

---

## 1. 环境准备

### 1.1 安装 Docker Desktop + WSL2

Docker Desktop 安装后需完成 WSL2 后端：
- Windows 功能：勾选「适用于 Linux 的 Windows 子系统」「虚拟机平台」，重启。
- WSL 内核更新（`wsl --update`）。
- Docker Desktop → Settings → Resources → WSL Integration 启用发行版。

### 1.2 迁移 Docker WSL 数据到数据盘（避免占满 C 盘）

生产数据根在 E 盘，Docker 的 WSL 数据（vhdx）默认也在 C 盘会越涨越大。迁移方法：

```bash
# 1) 完全停止 Docker（Docker Desktop + 后台服务 + WSL）
#    PowerShell：
#      Stop-Process -Name "Docker Desktop","com.docker.backend","com.docker.service"
#      Stop-Service com.docker.service
#      wsl --shutdown

# 2) 导出已存在发行版（如有），并注册新位置；对 docker-desktop 数据发行版（非用户发行版）
#    直接改注册表 BasePath 更稳：
#      reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss" /s /f docker-desktop
#      → 找到 BasePath，改为 E:\Docker\wsl\main
#    用户发行版（如 Ubuntu）用 wsl --export / --import 迁到目标盘。

# 3) 重启 Docker Desktop，验证
docker version        # Engine 正常
# 确认 E:\Docker\wsl\main\ext4.vhdx + disk\docker_data.vhdx 在位
# 迁移成功后删除 C 盘旧 wsl.bak 释放空间
```

- **验证**：`docker version` 引擎就绪、`docker run hello-world` 通过。
- **结果**：C 盘释放约 1.7 GB（删除 `wsl.bak`）。

---

## 2. Cloudflare 隧道（prod 边缘层）

### 2.1 首次授权：cloudflared 的 HOME 坑（问题 #1）

**问题**：`docker run --rm cloudflare/cloudflared tunnel login` 报成功，但 `cert.pem`
没有落到 E 盘挂载目录，容器退出后消失。

**根因**：镜像默认 HOME=`/home/nonroot`，`cert.pem` 写到容器可写层；`--rm` 容器退出即丢，
并未写入挂载的 E 盘目录。

**解法**：显式设 HOME 指向挂载目录，容器内才会把 cert.pem 写到 E 盘：

```bash
docker run --rm \
  -e "HOME=/home/cloudflared" \
  -v "E:/orzmc/cloudflared:/home/cloudflared" \
  cloudflare/cloudflared tunnel login
# 授权成功后确认 E:\orzmc\cloudflared\.cloudflared\cert.pem 存在
```

> ⚠️ 这次教训已两次踩坑（第一次因 `--rm` 丢 cert）。**所有 cloudflared 管理命令一律加
> `-e HOME=/home/cloudflared` + 挂载**。

### 2.2 隧道凭据 `<uuid>.json` 丢失恢复（问题 #2，核心）

**问题**：`orzmc` 隧道已在 2026-08-13 创建（`.env` 里 `CLOUDFLARE_TUNNEL_ID`），但凭据
`E:\orzmc\cloudflared\<uuid>.json` 丢失，cloudflared 无法启动。全盘搜不到任何 `*.json` 凭据。

**关键事实**：隧道凭据 JSON **仅隧道创建时本地生成一次**，Cloudflare 控制台**无下载按钮**。
但可以**用账号级 cert.pem 经 Cloudflare API 重新取回**：

1. **cert.pem 是 ARGO TUNNEL TOKEN JWT**，解码 payload 可得账号信息：
   ```bash
   # cert.pem 内容形如（多个 base64 段）：
   # -----BEGIN ARGO TUNNEL TOKEN-----
   # <accountID.base64>.<zoneID.base64>.<apiToken.base64>  （各段独立）
   # -----END ARGO TUNNEL TOKEN-----
   # 逐段 base64 解码（urlsafe，补 padding）即得 accountID / zoneID / apiToken
   ```

2. **用 apiToken 调 Cloudflare API 取隧道运行 token**（token 是单段 base64）：
   ```bash
   curl -H "Authorization: Bearer <apiToken>" \
     "https://api.cloudflare.com/client/v4/accounts/<accountID>/cfd_tunnel/<tunnelID>/token"
   # 返回 result = 一段 base64，解码后形如：
   # {"a":"<accountID>","t":"<tunnelID>","s":"<TunnelSecret base64>"}
   ```

3. **重建凭据 JSON**（格式固定，与隧道创建时一致）：
   ```json
   { "AccountTag": "<accountID>", "TunnelID": "<tunnelID>", "TunnelSecret": "<s 值>" }
   ```
   落盘为 `E:\orzmc\cloudflared\<tunnelID>.json`，与 config.yml 的 `credentials-file` 匹配。

4. **验证**：`docker compose up` 启动 cloudflared 后，日志出现
   `Registered tunnel connection ... location=xxx protocol=quic` 即隧道连接成功。

> ⚠️ **凭据纪律**：`<uuid>.json` 含 `TunnelSecret`，可完全控制该账号下隧道，与 `cert.pem`
> 同级按密钥对待——只存 `$DATA_ROOT/cloudflared/`，随数据备份，`chmod 600`，永不入库。

### 2.3 config.yml 生成：占位符坑（问题 #3）

**问题**：`deploy.sh templates --force` 生成 config.yml 时输出的是**原始占位符**
（`__CLOUDFLARE_TUNNEL_ID__`、`__DOMAIN_*__`），不是真实值。

**根因**：`templates --force` 只复制模板、不做占位符替换；占位符替换是 `init` 的
`ensure_cloudflared_config` 职责，且需 `.env` 里 `CLOUDFLARE_TUNNEL_ID` 已填真实值。

**解法**：先确保 `.env` 的 `CLOUDFLARE_TUNNEL_ID` 正确，再 `deploy.sh -p prod init` 生成
config.yml；验证含真实隧道 ID 和 4 个域名。

---

## 3. compose 无法启动 daemon（问题 #4，Windows 最大坑）

### 问题现象

`docker compose up -d` 启动到 daemon 时报：
```
service:mcsmanager-daemon:1 Error response from daemon: mount denied:
the source path "/orzmc/instances:E:/orzmc/instances:rw" too many colons
```

> **ADR-016 自动化**：以下根因与解法是**必须理解的历史/排障知识**，但从当前版本起，
> 用户**无需手工执行** §3 的 `docker run` 命令——`windows.sh start`（即 `deploy.sh up`）
> 的 `compose_cmd` Windows 分支会自动 `win_daemon_run` 生成并执行等价的 `docker run
> --mount`，并自动补别名（§4）。本节保留完整命令作参考与手动排障用。

### 根因（深度分析）

daemon 的实例自挂载卷（ADR-007）在 compose.yaml 里是：
```yaml
- "${DATA_ROOT}/instances:${DATA_ROOT}/instances"   # 同路径自挂载
```
当 `DATA_ROOT=E:/orzmc` 时展开为 `E:/orzmc/instances:E:/orzmc/instances`。

Docker Compose（v5.x，Linux/WSL2 后端）在**把 bind mount 序列化为 `source:target:mode`
传给 Docker API** 时，把 Windows 驱动器号 `E:` 误当作路径分隔符剥离，source 变成
`/orzmc/instances`，最终拼出非法的 `/orzmc/instances:E:/orzmc/instances:rw`。

**这本质是 Compose 在 Windows 下解析含驱动器冒号 bind source 的缺陷**，`docker run`
命令行（`--mount`）与 `docker compose config` 输出都正常，唯独 compose 创建容器时出错。

> **ADR-019（2026-08-16）**：已移除 `instances/` 自挂载（该卷 target 含 `E:` 冒号正是
> 本错误的根源）。当前 daemon 只挂 `daemon/data` 与 `daemon/logs`（target 均无驱动器冒号），
> 但 daemon 仍按 ADR-016 走 `docker run`（见上注），保持三平台一致，且 Windows 下
> `win_daemon_run` 自动生成等价命令。下表保留历史排障记录。

### 排查结论（已验证）

| 方式 | source=`E:/orzmc/instances` | target 含 `E:` 冒号 | 结果 |
|---|---|---|---|
| `docker run -v "E:/..."` 短语法 | ✅ 可挂载到无冒号 target | ❌ target 含冒号失败 | 短语法 target 不能含冒号 |
| `docker run --mount type=bind` | ✅ | ✅ **可挂载到 `/E:/...`** | **可行** |
| `docker compose up` | ❌ 序列化剥离 `E:` | — | 失败（`too many colons`） |

**结论**：ADR-019 移除 instances 自挂载后，此 `too many colons` 诱因已不存在；daemon 的
`daemon/data`、`daemon/logs` target 无驱动器冒号，Compose 本可创建。但为保持三平台一致
（macOS/Linux 走 compose、Windows 走 docker run），Windows 仍按 ADR-016 用 `docker run`
手动创建，由 `win_daemon_run` 自动生成命令。

### daemon 容器内路径模型的适配

> **ADR-019（2026-08-16）起**：不再设独立的 `instances/` 自挂载与
> `MCSM_DOCKER_WORKSPACE_PATH`。MCSManager 面板创建的实例默认把 `cwd` 写入 daemon 的
> `data/InstanceData/<uuid>/`（容器内 `/opt/mcsmanager/daemon/data/InstanceData/<uuid>`），
> 经 `daemon/data` 的 bind 挂载天然落到宿主 `E:/orzmc/mcsmanager/daemon/data/InstanceData/`，
> 文件管理器与备份均直接可见。以下为历史遗留说明（曾为把实例 cwd 指到 `instances/` 而设，
> 已无用，保留供追溯）。

MCSManager daemon 源码逻辑（`app.js`）：
```js
const hostRealPath = process.env.MCSM_DOCKER_WORKSPACE_PATH;   // （历史）曾 = E:/orzmc/instances
if (hostRealPath && cwd.includes(defaultInstanceDir)) {
    cwd = normalize(join(hostRealPath, instance.instanceUuid)); // （历史）曾 = E:/orzmc/instances/<uuid>
}
// 宿主 bind Source = cwd；daemon 容器内文件管理器也读 absoluteCwdPath() = cwd
```

**当前（ADR-019）**：不设 `MCSM_DOCKER_WORKSPACE_PATH`，实例 cwd 保持 MCSManager 默认的
`data/InstanceData/<uuid>/`，无需任何自挂载适配。

### 最终可用命令（daemon 手动启动，ADR-019 后）

```bash
docker run -d --name orzmc-mcsmanager-daemon \
  --restart unless-stopped \
  --env "TZ=Asia/Shanghai" \
  --mount type=bind,source="E:/orzmc/mcsmanager/daemon/data",target="/opt/mcsmanager/daemon/data" \
  --mount type=bind,source="E:/orzmc/mcsmanager/daemon/logs",target="/opt/mcsmanager/daemon/logs" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --network orzmc_default \
  githubyumao/mcsmanager-daemon@<digest>
```

启动后验证：
```bash
docker logs orzmc-mcsmanager-daemon | grep -iE "Daemon process has been successfully started|Access Key"
docker exec orzmc-mcsmanager-daemon ls "/opt/mcsmanager/daemon/data/InstanceData"   # 面板实例数据
```

> ⚠️ **daemon 不受 compose 管理**：重启后靠 `--restart unless-stopped` 自动恢复；升级/回滚
> 需手动 `docker rm -f` 后重新 `docker run`。`docker compose up/down` 不会影响它（compose
> 不认识这个容器）。
>
> **ADR-016 后**：上述命令已封装进 `lib/common.sh` 的 `win_daemon_run`（从 compose.yaml
> 自动读 digest、`win_path` 转路径、lan 下自动补 `-p`），升级/回滚/重建统一用
> `windows.sh stop && windows.sh start`，无需再手敲 `docker run`。daemon 数据/logs 卷由
> `win_daemon_run` 按同样参数生成（ADR-019 起不再挂载 instances）。

---

## 4. 手动创建容器的服务名别名（问题 #5）

### 问题现象

面板日志持续：
```
正在尝试连接远程节点 URL: wss://mcs-node.jokerhub.cn:24444
Daemon exception detected ... reconnecting...
```
Gatus 状态页 `MCSManager Daemon` 节点 `success=false`。

> **ADR-016 自动化**：`win_daemon_run` 创建 daemon 后会自动调 `win_daemon_alias` 补
> `mcsmanager-daemon` 别名。**注意**：`docker network connect --alias` 无法在容器
> **已连接**时更新别名（报 `endpoint ... already exists in network`），因此
> `win_daemon_alias` 须先 `disconnect` 再 `connect --alias`（本 ADR 在 2026-08-16 生产
> 迁移实测修复此点）。本节为历史/排障知识；且 **status 容器自 ADR-016 起回归 compose
> 管理**（其卷 target 无冒号），不再需要手动 docker-run，别名由 compose 自动注入，
> 本节的 status 别名补丁不再适用。

### 根因

compose 创建的容器（web/easybot/mariadb/cloudflared）会自动获得**服务名网络别名**
（`mcsmanager-daemon`、`status` 等）。但 daemon/status 是 `docker run` 手动创建的，**没有
服务名别名**，导致面板/状态页按服务名解析失败。

### 解法

给手动创建的容器补服务名别名（断开重连，容器进程不受影响）：
```bash
docker network disconnect orzmc_default orzmc-mcsmanager-daemon
docker network connect --alias mcsmanager-daemon orzmc_default orzmc-mcsmanager-daemon

docker network disconnect orzmc_default orzmc-status
docker network connect --alias status orzmc_default orzmc-status
```

验证：
```bash
docker exec orzmc-mcsmanager-web getent hosts mcsmanager-daemon   # → 172.18.0.x
docker exec orzmc-mcsmanager-web getent hosts status              # → 172.18.0.x
```

---

## 5. status（Gatus）配置占位符未替换（问题 #6）

**问题**：`orzmcs.jokerhub.cn` 返回 502，status 容器监控 URL 还是 `*.example.com` 占位符。

**根因**：首次 `init` 时 `.env` 的 `CLOUDFLARE_TUNNEL_ID` 为空，`ensure_status_config`
生成的 config.yaml 用了模板占位符；且 `ensure_*` **绝不覆盖已有文件**，之后 init 不会
重写。

**解法**：
```bash
# 备份占位符 config，删除后重新 init 生成真实域名 config
cp E:/orzmc/status/config.yaml E:/orzmc/status/config.yaml.placeholder.bak
rm  E:/orzmc/status/config.yaml
bash deploy.sh -d "E:/orzmc" -p prod init     # 重新生成真实 *.jokerhub.cn
docker restart orzmc-status                    # 重新加载 config
```

---

## 6. 面板新增节点连接失败（问题 #7）

### 问题现象

新增节点后状态「离线」，`网页直连` 异常；面板日志：
```
正在尝试连接远程节点 URL: wss://mcs-node.jokerhub.cn:24444
Daemon exception detected ... reconnecting...
```

### 根因

节点地址填了 `mcs-node.jokerhub.cn` + 端口 `24444`。但 prod 下 daemon 的 24444 **只在容器
内监听、不暴露公网**；公网只有 cloudflared 隧道把 `mcs-node.jokerhub.cn:443` 转发到
daemon 容器 24444。**公网 24444 端口根本不存在** → 连不上。

此外协议前缀也会错：填 `https://域名` 时面板拼出非法 `ws://https://...`；正确应填
`wss://域名`（带 wss:// 前缀，面板据此用 `wss://` + 自动拼 `/socket.io` 路径）。

### 排查确认

- `curl https://mcs-node.jokerhub.cn` → HTTP 200（隧道 HTTP 转发正常，返回 daemon 页面）。
- 内网 `ws://mcsmanager-daemon:24444/socket.io/?EIO=4&transport=websocket` → OPEN OK。
- 经隧道 `wss://mcs-node.jokerhub.cn/socket.io/?EIO=4&transport=websocket` → OPEN OK。
- 明文 `ws://` 经隧道 → 400（隧道要求 WebSocket 走 TLS）。

### 解法（正确节点配置）

直接编辑面板节点配置文件 `E:\orzmc\mcsmanager\web\data\RemoteServiceConfig\<uuid>.json`，
或面板 UI 填写：

```json
{
  "ip": "wss://mcs-node.jokerhub.cn",
  "port": "443",
  "apiKey": "<daemon key>",
  "connectOpts": { "rejectUnauthorized": false }
}
```

改后重启 web 容器加载：
```bash
docker restart orzmc-mcsmanager-web
```

验证：面板日志出现
```
远程节点 Name: Minecraft ... 已连接
设置节点语言 ... language: zh_cn
远程节点 ... 密钥验证通过
```
节点即在线，网页直连（终端/控制台/文件管理器）恢复。

> ⚠️ 三种 profile 的节点地址格式（对照 ADR-013/014）：
> - **prod**：`wss://<domain>:443`（经 cloudflared 隧道）
> - **local**：`wss://mcs-node.localhost:18443`（Caddy 非特权 TLS）
> - **lan**：`ws://<LAN_HOST_IP>:<LAN_MCS_DAEMON_PORT>`（无 TLS，明文）

---

## 7. Windows 运行维护速查

| 操作 | 命令 |
|---|---|
| 统一入口（macOS/Linux/Windows 同） | `./orzmc.sh init\|up\|stop\|status\|validate\|backup`（或 `deploy.sh ...`） |
| 查看全部容器 | `docker ps -a` |
| daemon 日志（含 Access Key） | `docker logs orzmc-mcsmanager-daemon` |
| 节点连接结果 | `docker logs orzmc-mcsmanager-web \| grep -iE "节点\|daemon"` |
| daemon 实例数据自检 | `docker exec orzmc-mcsmanager-daemon ls "/opt/mcsmanager/daemon/data/InstanceData"` |
| 面板/状态页服务名解析 | `docker exec orzmc-mcsmanager-web getent hosts <service>` |
| 公网入口自检 | `curl -s -o /dev/null -w "%{http_code}" https://<sub>.jokerhub.cn` |
| daemon 重建（compose 无法管理，脚本自动） | `./orzmc.sh stop && ./orzmc.sh up`（内部 `win_daemon_rm` + `win_daemon_run`） |
| 隧道凭据备份 | 备份 `E:\orzmc\cloudflared\*.json` + `cert.pem` |

### 已知限制（Windows 特有）

- **仅 daemon 不由 compose 管理**：`docker compose up/down` 不作用于 daemon；`windows.sh
  stop/start`（内部 `win_daemon_rm`/`win_daemon_run`）统一管理其生命周期，靠
  `--restart unless-stopped` 自动恢复。status 自 ADR-016 起回归 compose 管理。
- **无 RDP 服务端**：Windows 11 家庭版（SKU 101）无远程桌面服务端，远程控制须第三方
  （RustDesk/ToDesk）。
- **脚本路径坑已根治**：`compose_cmd` 内置 `win_path`，MSYS `/c/...` 路径自动转
  Windows 原生路径；仅当绕过脚本直接手敲 `docker compose` 时仍需原生路径。

---

## 8. 待上游改进建议（建议整理成 patch/issue）

1. **compose 对 Windows 驱动器号 bind 卷的缺陷**：`docker compose up` 曾无法创建含
   `E:/` target 的 bind mount（报 `too many colons`）。**ADR-019 已移除该 instances 卷**
   （target 含驱动器冒号是诱因），问题消失；daemon 现仍按 ADR-016 走 `docker run` 仅为
   三平台一致性。可保留此建议供上游了解历史缺陷。
2. **隧道凭据恢复**：Cloudflare 控制台无凭据下载入口，仅 create 时本地生成。建议文档
   说明「凭据丢失可从 cert.pem + API `/cfd_tunnel/{id}/token` 重建」（见 §2.2）。
3. **status config 占位符**：`ensure_status_config` 遇 `.env` 隧道 ID 为空时静默生成
   占位符且不再覆盖，易留隐患。建议加「占位符残留告警」。
