# Windows 平台部署指南

> 本文件记录 OrzMC 在 **Windows 11 家庭版 + Docker Desktop(WSL2)** 上的完整部署实录，
> 逐条记录遇到的**问题 → 根因 → 解决办法**，以指导项目后续向 Windows 平台扩展。
> 与 `docs/architecture.md`（ADR-015 起）配套：本文件偏「怎么部署」，ADR 偏「为什么这么设计」。

- **部署机器**：Windows 11 家庭版（SKU 101，无 RDP 服务端）、Docker Desktop 4.86 / WSL2
  **（`.wslconfig` 开 `networkingMode=mirrored`，见 §1.3 / ADR-020）**、域 `jokerhub.cn`。
- **版本基线**：本文件面向 **ADR-017 EDGE 模型**——唯一入口 `./orzmc.sh [-d DATA_ROOT]
  [-e EDGE] init|up|stop|status|validate|backup`（`EDGE=cloudflare|local|lan|none`）；
  旧 `deploy.sh -p` / `local.sh` / `lan.sh` / `windows.sh` 兼容保留（deprecated）。
  前 8 节的「问题#N」为 **prod 档历史实录**（旧 profile 模型），§9/§10 为
  **2026-08-18 三档真实验收**（EDGE 模型）的部署/节点/实例/验收全流程与踩坑记录。
- **最终可用状态（2026-08-18 三档验收）**：prod / local / lan 三档分别在
  `E:/orzmc` / `.local-data` / `.local-data-lan` 实测 up→验证→stop 全通过；生产档已按
  用户要求停用（容器清空、数据完好）。三档差异与 Windows 特有限制（mirrored hairpin）
  见 §9 / §10 与 ADR-020。

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
| 网络模式 | NAT（Docker 默认）：发布端口只绑 localhost | **必须 `.wslconfig` 设 `networkingMode=mirrored` + `wsl --shutdown` 冷重启**，发布端口才绑宿主真实网卡（局域网设备/玩家可达）；代价：**容器→宿主自身 LAN IP 的已发布端口不可达**（面板 hairpin，ADR-020） | 局域网进服 + 局域网设备访问面板的前提 |

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
> - **lan（macOS/Linux）**：`ws://<LAN_HOST_IP>:<LAN_MCS_DAEMON_PORT>`（无 TLS，明文）
> - **lan（Windows mirrored）**：**`ws://mcsmanager-daemon:24444`（内网名，ADR-020）**——
>   面板容器经宿主 LAN IP 的已发布端口必然超时（hairpin），节点地址只能用内网名；后果是
>   节点在线、面板管理正常，但浏览器「网页直连」/实时终端不可用（需要终端用 local/prod 档）。

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

- **mirrored 网络双陷阱（ADR-020）**：① 宿主访问**自己的** LAN IP 的发布端口必超时
  （hostAddressLoopback 未开，非故障）；② **容器→宿主 LAN IP 的已发布端口必超时**
  （内核级 hairpin）——导致 lan 档面板无法直连 LAN IP、浏览器实时终端不可用（见 §9.3/
  §10 P6）。局域网可达性一律用**局域网其他设备**验证。
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

---

## 9. 三档部署 → 节点 → 实例 → 验收全流程（Windows，2026-08-18 真实验收）

> EDGE 模型（ADR-017）唯一入口 `./orzmc.sh [-d DATA_ROOT] [-e EDGE] init|up|stop|...`。
> 三档**互斥**（共用 compose 项目名 `orzmc` 与容器名），**切档必须先 `stop` 当前档**。
> 本节为本次 Windows 真实验收总结的最小可用路径；坑点详解见 §10，验收实录见
> `docs/acceptance.md` §7。

### 9.1 前置（每档都依赖）

1. **WSL2 mirrored 网络（关键前置，见 §10 P1）**：`C:\Users\<user>\.wslconfig`：
   ```ini
   [wsl2]
   networkingMode=mirrored
   ```
   改后**必须 `wsl --shutdown` 冷重启**（Docker Desktop 重启不算）。此后发布端口才绑宿主
   真实网卡、局域网设备/玩家可达（NAT 模式只绑 localhost，2026-08-16 已实测不可达）。
2. **Windows 防火墙入站放行（lan 档必需，§10 P2）**：Wi-Fi / Mihomo TUN 多为 **Public
   profile**，入站默认全拦。管理员 PowerShell：
   ```powershell
   netsh advfirewall firewall add rule name="OrzMC Web 18090"   dir=in action=allow protocol=TCP localport=18090
   netsh advfirewall firewall add rule name="OrzMC EasyBot 18091" dir=in action=allow protocol=TCP localport=18091
   netsh advfirewall firewall add rule name="OrzMC Status 18092" dir=in action=allow protocol=TCP localport=18092
   netsh advfirewall firewall add rule name="OrzMC Daemon 24444" dir=in action=allow protocol=TCP localport=24444
   ```
   实例进服端口 `25565/tcp`（Java）与 `19132/udp`（基岩）如需局域网直连同样放行。
3. **真机验证优先（§10 P5）**：宿主访问**自己**的 LAN IP 的发布端口必超时（mirrored
   host-loopback 陷阱，非故障）——局域网可达性一律用**局域网其他设备**验证；验证服务
   本身用 `127.0.0.1`。
4. **daemon key 取法**：`<DATA_ROOT>/mcsmanager/daemon/data/Config/global.json` 的 `key`
   字段（47 位），面板添加节点时填入（写入节点配置 `apiKey`）。

### 9.2 三档部署方法

| 档 | DATA_ROOT | 部署命令 | 入口 |
|---|---|---|---|
| prod（cloudflare） | `E:/orzmc` | `./orzmc.sh -d E:/orzmc -e cloudflare init` → 编辑 `.env` 填 `CLOUDFLARE_TUNNEL_ID`/`DOMAIN_*`/密码 → `./orzmc.sh -d E:/orzmc up` | `https://mcs.<domain>` 等 4 入口 |
| local | `.local-data` | `./orzmc.sh -e local init && ./orzmc.sh -e local up` | `https://mcs.localhost:18443` 等 4 入口 |
| lan | `.local-data-lan` | `./orzmc.sh -e lan init` → 编辑 `.env` 把 `LAN_HOST_IP` 改成**真实局域网 IP**（如 `192.168.0.33`，模板默认 `192.168.1.100` 是死地址）→ `./orzmc.sh -e lan up` | `http://<LAN_HOST_IP>:18090` 等 4 端口 |

> - local/lan 的 DATA_ROOT 是仓库内相对路径 `.local-data`/`.local-data-lan`（gitignored）；
>   prod 用绝对盘符。`-d` 参数优先级最高（>`ORZMC_DATA_ROOT` > 默认值）。
> - 模板差异：`env.prod`（域名/隧道）、`env.local`（Caddy `.localhost` 非特权端口
>   18080/18443）、`env.lan`（`LAN_HOST_IP` + `LAN_*_PORT`，无域名/TLS）。
> - **三档模板均已含 `DAEMON_PORTS=25565:25565/tcp,19132:19132/udp`**（仅 Windows 消费：
>   进程模式实例进服端口由 daemon 容器 `-p` 发布；macOS/Linux 由 MCSManager 按实例配置
>   映射，不消费本变量）。此变量曾漏在 env.local/env.lan，见 §10 P4。

### 9.3 节点创建（面板「节点管理」→ 添加节点）

| 档 | 节点 `ip` | 端口 | Windows 下是否可用 |
|---|---|---|---|
| prod | `wss://mcs-node.<domain>` | `443` | ✅ 面板 + 浏览器全可用（公网域名两端都能解析） |
| local | `wss://mcs-node.localhost` | `18443` | ✅ 面板（web 容器 `extra_hosts: mcs-node.localhost:host-gateway`）+ 宿主浏览器（信任 Caddy 本地 CA 后，§10 P7） |
| lan（macOS/Linux） | `ws://<LAN_HOST_IP>` | `24444` | ✅ 面板 + 局域网设备双向可达（ADR-014） |
| **lan（Windows）** | **`ws://mcsmanager-daemon`** | `24444` | ⚠️ **仅面板侧可用**：节点在线、实例启停/状态/文件管理正常；**浏览器「网页直连」/实时终端不可用**（ADR-020 / §10 P6） |

改节点配置后 `docker restart orzmc-mcsmanager-web` 生效；确认面板日志：
```
远程节点 Name: ... 已连接
远程节点 ... 密钥验证通过
```
若面板日志出现 `Daemon exception detected ... reconnecting...` 即节点地址不可达。

### 9.4 实例创建（面板「实例」→ 创建实例，参数参考 `docs/papermc-template.md`）

Windows 推荐 **Java 版进程模式**（java 直接跑在 daemon 容器内；进服端口经 `DAEMON_PORTS`
发布到宿主，局域网玩家直连 `http://<LAN_HOST_IP>:25565`）：
1. 先备好实例目录文件：`paper.jar`、`eula.txt`（`eula=true`）、`server.properties`
   （离线服 `online-mode=false`）；目录用面板默认 `data/InstanceData/<uuid>/`（经 daemon/data
   落宿主 `$DATA_ROOT/mcsmanager/daemon/data/InstanceData/`，ADR-019）。
2. 面板创建实例：启动命令 `java -Xms2G -Xmx2G -jar paper.jar --nogui`；停止命令 `stop`；
   Ready 关键字 `Done`；控制台编码 UTF-8；内存按需（测试服 2G）。
3. 启动实例 → 等控制台 `Done` → 局域网设备进服测试（Java 25565；基岩 Geyser 19132/udp
   需另加 UDP 防火墙规则）。
4. 面板侧验证实例启停/重启/状态正常（走服务端 daemon 连接，Windows lan 档同样可用）。

> ⚠️ **2026-08-18 本次验收未创建实例**（lan 档实例目录为空）——上述步骤按
> `papermc-template.md` + macOS 验收经验整理，**未在 Windows 实机跑通**，下次验收第一
> 优先补齐实例创建 + 进服闭环。

### 9.5 逐档验收清单（下次直接照做）

**通用**：`./orzmc.sh status` 看容器；`./orzmc.sh validate` 看配置；面板首次登录建管理员；
节点连接后 `docker logs orzmc-mcsmanager-web | grep -E "已连接|密钥验证"`。

**prod（cloudflare）**：
- [ ] 6 容器 Up，mariadb+easybot healthy
- [ ] cloudflared `Registered tunnel connection`（QUIC）
- [ ] 4 公网入口：`curl -s -o /dev/null -w '%{http_code}' https://<sub>.<domain>` 全 200
- [ ] 面板节点在线 + 密钥验证通过
- [ ] 浏览器终端/控制台可用（公网域名两端可解析，Windows 正常）
- [ ] 实例进服（可选，Windows 建议先测 25565 TCP）

**local**：
- [ ] 容器含 caddy、无 cloudflared；`curl -k https://mcs.localhost:18443` 等 4 入口 200
- [ ] 面板节点在线（`wss://mcs-node.localhost:18443`）
- [ ] **宿主浏览器信任 Caddy 本地 CA 后完全退出重启**，网页直连终端可用：
      `certutil -user -addstore -f Root .local-data/caddy/data/caddy/pki/authorities/local/root.crt`
      （`-user` 免管理员；机器级 `-addstore` 报 AccessDenied）
- [ ] 实例端口已发布：`netstat -ano | findstr 25565`

**lan**：
- [ ] 5 容器 Up（无 caddy/cloudflared）
- [ ] **局域网设备**访问 `http://192.168.0.33:18090`（面板）/18091/18092/24444 可达
      （宿主自己访问 LAN IP 必超时，勿以此判故障）
- [ ] `.env` 的 `LAN_HOST_IP` 为真实 IP；删除 `status/config.yaml` 后重新 init 使状态页
      按钮指向正确 IP（`ensure_*` 绝不覆盖已有文件）
- [ ] 面板节点在线（Windows 用 `ws://mcsmanager-daemon:24444`）+ 密钥验证通过
- [ ] 实例启停/状态/文件管理正常（面板侧）
- [ ] ⚠️ **浏览器实时终端在本档不可用**（Windows mirrored 限制）——需要终端用 local 档
      （宿主浏览器）或 prod 档（任意设备）

---

## 10. Windows 三档验收踩坑记录（2026-08-18）

### P1｜mirrored 未冷重启不生效（曾误判「引擎仍是 NAT、需迁移」）
`.wslconfig` 改 `networkingMode=mirrored` 后，**必须 `wsl --shutdown` 冷重启**，Docker
Desktop 重启不算（容器 Up 47min 证明 VM 未冷重启，mirrored 一直没落地）。此前误判
「docker-desktop 仍 NAT、需迁移引擎」正是因此。验证：发布端口 `netstat -ano` 是否绑
`0.0.0.0` 于真实网卡。

### P2｜Windows 防火墙 Public profile 拦局域网入站
Wi-Fi + Mihomo TUN 均在 **Public profile**，入站默认全拦；未加规则前局域网设备连面板
`curl 000`。加 §9.1 的 4 条 netsh 规则（管理员）后恢复。

### P3｜win_daemon_run 相对路径 bug（已修复，lib/common.sh 未提交）
local/lan 档 DATA_ROOT 是相对路径 `.local-data`，`win_path` 只处理 `C:/` 与 MSYS 前缀，
相对路径原样传给 `docker run --mount` → `invalid mount path: 'C:/.../AppData/Local/hermes/
git/opt/mcsmanager/daemon/data'`（exit 125）。修复：先 `cd "$root" && pwd` 绝对化再
`win_path`。**local/lan 档必现**，bash -n + 三档 validate 回归通过。

### P4｜DAEMON_PORTS 模板缺失（已补，提交 5c13047）
ADR-016 只给 `env.prod` 加了 `DAEMON_PORTS`，local/lan 模板漏 → 进程模式实例进服端口
25565/19132 不发布。已补进 `templates/env.local` / `env.lan`（附注释说明仅 Windows 消费）。

### P5｜宿主访问自身 LAN IP 必超时（mirrored host-loopback 陷阱）
宿主 `curl http://192.168.0.33:18090` 超时（000），`curl http://127.0.0.1:18090` 200，
`docker inspect` 显示 `0.0.0.0` 绑定正常——**非故障**。局域网可达性一律用局域网其他设备
验证（手机真机验证 25565 已通过）。

### P6（核心）｜lan 档节点地址在 Windows mirrored 下面板/浏览器不可兼得
- 面板容器 → 宿主 LAN IP 已发布端口 = **内核级 hairpin 超时**。决定性证据：同一路径经
  bridge 网关进入 VM，`dst=172.18.0.1:24444` 通（socket.io HTTP 200）、`dst=192.168.0.33:24444`
  超时——入口一样、只差目标 IP。mirrored 下 VM 对「自身镜像 LAN IP」的本地投递在
  conntrack/NAT 层坏掉。
- 尝试全失败：容器内 `ip route add 192.168.0.33/32 via 172.18.0.1`（改路由不修 conntrack）、
  `/etc/hosts` 注入（字面 IP 不查 hosts）、`docker exec --privileged` 提权 NET_ADMIN（同样
  只改路由）。**Mac 能行是因为 macOS Docker Desktop 正确处理宿主 LAN IP 的 hairpin**。
- MCSManager 面板服务端与浏览器**共用同一节点 `ip:port`**（`connectOpts` 只是 socket.io
  重连选项，无独立服务端地址）→ 单一地址必须两端都可达，而 Windows mirrored 下面板可达
  地址（bridge 内网）与浏览器可达地址（LAN IP）**不相交**。
- **唯一全功能解 = hostname 双解析**：节点地址用自定义主机名（如 `mcs-node.lan`），面板
  容器 `extra_hosts: mcs-node.lan:host-gateway` 指到 docker 网关（面板侧已实测：解析
  host-gateway `192.168.65.254` → daemon socket.io 200），浏览器经**路由器自定义 DNS** 指
  到 LAN IP。依赖路由器支持自定义 DNS 记录，当前环境不具备 → 未启用；路由具备能力时按
  此启用即可恢复浏览器终端（详见 ADR-020）。
- **落地**：Windows lan 档节点 = 内网名 `ws://mcsmanager-daemon:24444`——节点在线、面板
  管理（启停/状态/文件）正常，浏览器实时终端不可用。与 macOS/Linux（ADR-014 LAN-IP 直连）
  不同，见 ADR-020。

### P7｜Caddy 本地 CA 信任（local 档）
Windows 用 `certutil -user -addstore -f Root <root.crt>`（当前用户库，**免管理员**）；
机器级 `certutil -addstore` 报 `AccessDenied (0x80070005)`。信任后必须**完全退出并重启
浏览器**（Chrome 有缓存；「网页直连」异常先怀疑证书 + 浏览器重启）。

### P8｜「网页直连异常」排查顺序（避免走弯路）
先分「服务端侧 vs 浏览器侧」：服务端侧看面板日志「已连接/密钥验证通过」；浏览器侧看
能否从**局域网设备浏览器**直连 `ws://<LAN_IP>:24444`（`socket.io/?EIO=4&transport=polling`
握手）。两侧用的是**同一个**节点地址——服务端通浏览器不通 = 该地址对浏览器不可达
（解析 / 防火墙 / 端口未发布），按 §9.3 节点表核对。
