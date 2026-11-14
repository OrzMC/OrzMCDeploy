# Eaglercraft 接入实施与验收

> **定位**：把前端拓扑开关（`ENABLE_VELOCITY` / `ENABLE_EAGLER`，ADR-036）落成可执行的
> 启用 / 验收 / 回滚步骤。
> 仓库只负责**运行时**（代理容器、jar 校验、配置生成、防火墙口径）；TLS 反代与实例
> 归站点与面板。
> **读者**：在测试服验证通过后负责灰度的运维。
> **相关文档**：原理与证据见 [eaglercraft](eaglercraft.md)；暴露面见 [security](security.md)；
> 实例字段见 [papermc-template](papermc-template.md)。

**前置**：先在测试服；生产执行前按 §2 备份。占位符：`<数据目录>`、`<域名>`
（填已解析到本机的名字，如 `dev.jokerhub.cn`）、`<EAGLER_WS_PORT>`。

## 1. 两种启用方式（一个开关）

| 值 | 形态 | Java 玩家连接方式 | Folia | 改写 UUID |
|---|---|---|---|---|
| `off`（缺省） | 不启用，零影响 | 不变 | — | — |
| `direct` | 实例直挂 EaglerXPaper | **不变**（实例端口同端口兼任 WSS） | ❌ | ❌ |
| `proxy` | Velocity + EaglerXServer 接管玩家端口 | 变成"连代理"（端口可沿用） | ✅ | ✅ |

真正要决定的只有两个开关，其余都有缺省（ADR-036）：

| 变量 | 必填 | 缺省 | 说明 |
|---|---|---|---|
| `ENABLE_VELOCITY` | ✅ | `false` | 是否用 Velocity 当前端（多服大厅；玩家 Java 端口由代理发布） |
| `ENABLE_EAGLER` | ✅ | `false` | 是否接 Web 客户端。实现由上一行派生：`true` → 代理装 EaglerXServer；`false` → 实例挂 EaglerXPaper（不支持 Folia） |
| `EAGLER_MODE` | 已废弃 | — | 旧三态；两个新开关都没写时才生效，`validate` 提示迁移 |
| `EAGLER_JAVA_PORT` | | `25565` | 玩家 Java 入口（`ENABLE_VELOCITY=true` 时是代理端口） |
| `EAGLER_BACKEND_PORT` | | `25566` | 仅 `ENABLE_VELOCITY=true`：实例内部端口（必须 ≠ 上面那个） |
| `EAGLER_WS_PORT` | | `18444` | 站点反代对外端口（只用于提示/片段） |
| `EAGLER_PUBLIC_HOST` | | 空 | 只影响提示文案（如 `dev.jokerhub.cn`） |
| `EAGLER_PROXY_MEMORY_LIMIT` / `EAGLER_PROXY_HEAP_MB` | | `1024M` / `768` | proxy 容器/堆上限 |
| `EAGLER_GEYSER` | | `true` | proxy 模式下是否在代理装 Geyser-Velocity（`false` 则自理） |
| `EAGLER_GEYSER_PORT` / `EAGLER_GEYSER_WEBRTC_PORT` | | `19132` / `19134` | 基岩端口（RakNet/NetherNet 信令 UDP+TCP、WebRTC 媒体 UDP） |

## 2. 阶段 0：隔离与备份

```bash
# 1) 全量备份（含 InstanceData 与 .env）
./orzmc.sh -d <数据目录> backup

# 2) 测试服：面板 → 实例列表 → 新建/选用测试实例（Paper 26.3 / Folia 26.3）
#    禁止直接改生产实例做验证
```

## 3. 阶段 1：打开开关并生成运行时

```bash
# 改已有那两行（read_env_value 是"首次出现优先"，追加同名行会被忽略）
# 例：多服大厅 + Web 客户端（旧 EAGLER_MODE=proxy 等价写法）
sed -i 's/^ENABLE_VELOCITY=.*/ENABLE_VELOCITY=true/' <数据目录>/.env
sed -i 's/^ENABLE_EAGLER=.*/ENABLE_EAGLER=true/' <数据目录>/.env
# 只要 Velocity 大厅（不接 Web 客户端）：ENABLE_EAGLER 保持 false 即可
# 可选：只影响提示文案
printf 'EAGLER_PUBLIC_HOST=dev.jokerhub.cn\n' >> <数据目录>/.env

./orzmc.sh -d <数据目录> validate   # 值域/端口一致性检查
./orzmc.sh -d <数据目录> up         # 下载并校验 jar，生成配置，启动代理
```

`up` 会做（`lib/eagler.sh`，版本锁在 `templates/eagler/versions.env`）：

| 产物 | 路径 | 说明 |
|---|---|---|
| Velocity jar + EaglerXServer jar | `<数据目录>/eagler/proxy/` | sha256 校验；版本锁不一致会重新下载 |
| `velocity.toml` | 同上 | 首次生成后**不再覆盖**（改端口/多后端直接改它） |
| `forwarding.secret` | 同上（600） | 与实例 `paper-global.yml` 的 `secret` 一致 |
| `instance-setup.md` | `<数据目录>/eagler/` | 实例侧待办（含 secret、端口改动、验收命令） |
| `caddy-eagler.snippet` | 同上 | 站点反代片段（通配证书 + `X-Real-IP`） |

首次启动后会把 `plugins/eaglerxserver/listeners.toml` 的 `forward_ip` 改成 `true`、
`forward_ip_header` 固定 `X-Real-IP`、`settings.toml` 的 `http_websocket_max_frame_length`
降到 `65535`，并自动重启代理一次（之后幂等）。

## 4. 阶段 2：实例侧（照 `instance-setup.md` 抄）

实例目录：`$DATA_ROOT/mcsmanager/daemon/data/InstanceData/<实例uuid>/`

1. `server.properties`：`online-mode=false`（**必须**，桥接层不支持在线模式）。
2. `proxy` 模式：面板 → 实例 → 端口映射，删掉 `25565:25565/tcp`，改成
   `<EAGLER_BACKEND_PORT>:25565/tcp`（让出玩家端口）；`direct` 模式不动。
   **每个后端一个独立宿主端口**，且不能与别的实例撞（例：Folia 已占 `25566` → Paper 用 `25567`，
   Folia 若也接代理再用 `25568` 并在 `velocity.toml` 的 `[servers]` 登记）。`up` 时会检查并告警。
3. `plugins/`：ViaVersion + ViaBackwards（老 Eagler 客户端兜底）。
   `direct` 模式再放 **EaglerXPaper**（`<数据目录>/eagler/jars/` 里那份）。
   **`proxy` 模式下 Geyser-Spigot 可保留**：实测它检测到 Velocity 转发会**自我禁用**
   （日志：`Remove the Geyser plugin from this server and install Geyser only on your proxy`）。
   对需要在 off/direct 与 proxy 之间来回切的测试服，**留着 jar** 更方便：切回非代理模式并关闭
   velocity 转发后它会自动恢复；proxy 模式下只需把基岩端口从实例挪到代理。
   代理侧由 `up` 自动装 `Geyser-Velocity`（`EAGLER_GEYSER=true` 缺省），并自动改：
   `bedrock.port` / `bedrock.webrtc-port` / `bedrock.transport: both` /
   `bedrock.port` / `bedrock.webrtc-port` / `bedrock.transport: both` / **`java.auth-type: offline`**
   （Geyser 2.12 的认证段叫 `java`，不是 `remote`；`online` 会要求 Bedrock 玩家绑定微软/Java 正版，表现为客户端提示「需要使用微软帐号登录」）。
4. `proxy` 模式：`config/paper-global.yml` 写入（secret 来自 `instance-setup.md`）：

```yaml
proxies:
  velocity:
    enabled: true
    online-mode: false
    secret: '<instance-setup.md 里的 secret>'
    enabled-force-key-authentication: false
```

5. **后端 RPC（Paper 26.3 上已实测出现故障，默认不要装）**：装好后日志出现
   `IllegalStateException: Player is already registered!`（栈在 RPC 的 `PlayerLoginEvent` 处理里）。
   **注意**：该异常在观察窗口内只出现 1 次（同期 5 次登录），因此**不能**推断为"每次登录都双触发"；
   更像快速重连时旧的注册未清理。是否影响 `eagler_players_view_distance` **尚未验证**。
   稳妥做法：先不装 RPC，用全局 `server.properties` 的 `view-distance` 控制负载（本站 6 → 5）。
6. 重启实例，日志应出现 `Done (...)`（Via 会打印 `server version: 26.3 (777)`）。

## 4.5 多后端大厅（可选：一个代理带多个实例）

面板里每个实例 = 代理的一个后端。代理只认"名字 + 宿主端口"，所以配置仍然只有一行：

```ini
# <数据目录>/.env —— 示例：大厅 + 生存，端口是各实例发布到宿主的端口
VELOCITY_SERVERS=lobby=25567,survival=25566
VELOCITY_TRY=lobby
```

| 要点 | 说明 |
|---|---|
| 端口来源 | 两种写法：① `<名字>=<宿主端口>`（面板里该实例的 docker 端口映射）；② `<名字>=<主机>:<端口>`——实例与代理同在 `orzmc_default` 网络时直接写实例容器名（`docker ps` 里的 `MCSM-xxxxxxxx`），**不用挪宿主端口**，也不会和代理入口抢 `25565` |
| 不能撞 | 每个后端一个独立端口，且都不等于 `EAGLER_JAVA_PORT`（代理入口）；`validate` 会拦 |
| 名字 | 只允许字母/数字/下划线/连字符，大小写敏感；`/server <名字>` 用它切换 |
| 落地顺序 | `VELOCITY_TRY` 逗号分隔，须全部在 `VELOCITY_SERVERS` 里；留空 = 第一个 |
| 每个后端都要做 | §4 的 1–4 步（`online-mode=false` + `proxies.velocity` + 同一条 `secret`） |
| 生成物 | `up` 渲染 `$DATA_ROOT/eagler/proxy/velocity.toml` 的 `[servers]`/`try`；**已存在不覆盖** |
| 视图/限制 | 后端之间不做视图隔离，一个后端的插件只对其玩家生效（大厅与生存请分开装插件） |

改了`.env`里的服务器列表后要重建 `velocity.toml` 才生效——按 `ensure_*` 语义它不会被覆盖：

```bash
mv <数据目录>/eagler/proxy/velocity.toml <数据目录>/eagler/proxy/velocity.toml.old
./orzmc.sh -d <数据目录> up        # 重新渲染并重启代理
```

> Folia 后端同样可以挂在代理后面（Velocity 转发与 region 线程无关）；Eaglercraft 只有在
`ENABLE_VELOCITY=true` 下才支持 Folia（`eagler-direct` 用 EaglerXPaper，不支持 Folia）。

## 5. 阶段 3：TLS / WSS（站点自备）

把 `<数据目录>/eagler/caddy-eagler.snippet` 追加到站点 Caddyfile，然后：

| 动作 | 内容 |
|---|---|
| 端口（两条路） | ① **复用已有反代入口**：站点块写 `play.example.com { ... }`（不写端口=443），宿主沿用 `18443`——**不需要新端口/路由器/防火墙改动**；② 独立端口：`"<EAGLER_WS_PORT>:8443"` + 路由器转发 + 防火墙放行 |
| 路由器 | 只有选②才需要转发 `<EAGLER_WS_PORT>/TCP`（与 18443 同一台）；选①不动 |
| 防火墙 | 选①沿用现有 `OrzMC-Web-TLS`（端口已含）；选②把新端口加进去，**不要**写进 `MC_PUBLIC_TCP` |
| 域名 | 已解析到本机的名字即可。**建议给 Eagler 单独一个子域**（`dev.`/`play.`），与面板/EasyBot 按 Host 分流；显式证书下换子域=改一行 |
| 基岩 | 无需额外反代：Geyser 走 UDP/TCP 直连（不经 Caddy）；公网放行仍靠 `MC_PUBLIC_*` |

> 复用同一入口时，`mcs.` / `easybot.` / Eagler 共用 443（宿主 18443），Caddy 按 SNI/Host 分流，
> 互不影响（已实测：面板 200、EasyBot 200、Eagler 握手 5/777）。

片段要点：`flush_interval -1`（WS 长连接）、`header_up X-Real-IP {remote_host}`
（EaglerXServer 的 `forward_ip=true` 缺这个头会直接断开）、
**`resolvers 1.1.1.1 8.8.8.8` + `propagation_timeout 180s`**：家宽/ISP 常屏蔽权威 NS 的
53 直查，Caddy 的 DNS-01 传播检查会超时（日志 `timed out waiting for record to fully propagate`，
但 DoH 能查到 TXT）。**默认用显式域名**；通配证书在部分网络下会卡同一检查，需先单域名跑通。

## 6. 阶段 4：加固清单

| 项 | 动作 |
|---|---|
| 基岩端口 | 迁移后 `19132/udp+tcp`、`19134/udp` 由**代理**发布（端口号不变，路由器不用动）；对应 `MC_PUBLIC_UDP` / `MC_PUBLIC_TCP` 已覆盖时无需改 |
| 端口 | 后端实例端口**不发布公网**（也不写进 `MC_PUBLIC_*`）；proxy 模式只发布 `<EAGLER_JAVA_PORT>`。代理经 `host.docker.internal:<EAGLER_BACKEND_PORT>` 访问后端——已实测宿主防火墙不会拦容器到已发布端口，无需为此加规则 |
| 防火墙 | 代理端口按游戏端口口径（`MC_TCP_PORTS`/`MC_PUBLIC_TCP`）；WSS 端口按站点 TLS 规则 |
| 密钥 | `eagler/proxy/forwarding.secret` + `instance-setup.md` 均 600，随 `$DATA_ROOT` 备份 |
| 身份 | **共用名字空间（已定）**：同名 = 同 UUID = 同账号，门 = 白名单 + LoginSecurity 口令。上线前：① `white-list=true` + `enforce-whitelist=true`（名字集合收敛，真正的门）② `join.hide-inventory: true`（内置方法，不依赖 ProtocolLib）③ `registration.enabled` **保持 true**——`/lac` 没有建号命令，关注册会挡住新玩家；用「加名单即须立即首登注册」收敛窗口，被抢注时 `/lac rmpass <名字>` 兜底 ④ **上线前核对：所有 op/权限名字必须已注册**——ops.json 按 UUID 授权，而 UUID 由名字派生，未注册的 op 名字等于「谁先注册谁拿权」 |
| 直连 | WS 直连代理端口（不带 `X-Real-IP`）会被拒，属预期：唯一入口应是反代 |
| 升级 | 改 `templates/eagler/versions.env`（版本 + sha256）/镜像 digest → commit → `stop && up`；**不用**面板自助升级 |

## 7. 验收测试

### 7.1 分层验收表

| 编号 | 验收项 | 通过标准 | 手段 |
|---|---|---|---|
| T1 | 代理启动 | 日志 `Listener "listener0" injected ... (Velocity method)` + `Done` | `docker logs orzmc-velocity`；或用验收脚本（见 §7.3） |
| T2 | 握手协商 | `eagler_protocol=5`、`minecraft_protocol=777` | 探针（§7.2）；或验收脚本 |
| T3 | 登录放行 | `ALLOW_LOGIN` 且两次 UUID 一致 | 探针 `--login`；或验收脚本 |
| T4 | 浏览器进服 | 游戏内出现 HUD；后端日志 `joined the game` | 浏览器 + 后端日志 |
| T5 | 插件矩阵 | 下表逐项 PASS | 手工 |
| T6 | 三端共存 | Java + 基岩 + Web 同时在线、互相可见、聊天互通 | 三种客户端各一个（Web/Java 已实测，基岩**必须真机 26.x**：Geyser 2.12 起走 NetherNet，RakNet 库不可用） |
| T7 | 方块/交互 | 放置/破坏、开箱子、`/tp` 生效 | 手工 |
| T8 | 身份不可伪造 | 同名必须过 LoginSecurity 口令；白名单外的名字根本进不来 | 双开浏览器（Java + Web 同名） |
| T9 | 断线重连 | 断网 30 s 后重连成功、背包/位置合理 | 手工 |
| T10 | Folia 线程安全 | 跨区域跑动 10 分钟无 Folia 调度异常 | 后端日志 |
| T11 | 弱网 | DevTools 3G 限速可进服（可卡但不断连） | 手工 |
| T12 | 回滚演练 | 按 §9 回滚后 Java 入口恢复正常 | 演练一次 |

T5 逐项（记录"版本 / 结果 / 日志"）：LuckPerms（权限生效）、GriefPrevention（领地）、
EzShops（GUI 商店）、Geyser（基岩可进）、ViaVersion（1.8 Eagler 客户端可进）、
Simple Voice Chat（**Java 端**正常，Web 端预期不可用）、
**GrimAC**（浏览器/基岩端延迟高、且 Geyser 会转包）：实测**基岩经 Geyser 会被
`BadPackets`/`PacketOrder` 误判**，`punishments.yml` 里 30 次就踢（提示「检测到数据包滥用」）。
测试服做法：把该组的 kick 行注释掉、保留 `[log]`/`[alert]`，`/grim reload`；要严格时再放开。
被踢后立刻重连还会撞上代理的连接节流（`You must wait N seconds before logging-in again`），等十几秒即可。
**「能登录但完全不能移动」**（实测）：GrimAC 的 `BadPacketsN` = *Ignored or failed to accept a
required server teleport*——服务端要求传送、Bedrock/Geyser 没确认，GrimAC 会把人按住。
处置：给基岩玩家免掉该检查（它支持 bypass 权限 `grim.badpackets.invalid_teleport`）：
`lp creategroup bedrock` → `lp group bedrock permission set grim.badpackets.invalid_teleport true`
→ `lp user <名字> parent add bedrock`（顺带给该组加 `[基岩]` 前缀便于识别）。
**紧接着还会撞上 `Simulation`（移动预测）**：Bedrock 的移动语义与 Java 不同，GrimAC 的
`Simulation/GroundSpoof/Timer/NoFall` 组会在十几秒内累计到 100 → 踢（提示「检测到移动作弊」）。
根因是**架构性的**：Geyser 装在代理上，Paper 侧的 GrimAC 拿不到 Geyser/Floodgate 的"这是基岩玩家"
信号（GrimAC 内置了 Geyser/Floodgate 识别，但需要插件在**后端**可见）。处置（**项目已决定不使用 Floodgate**，见 §11）：
① 把该组踢人注释掉（只留 `[log]`/`[alert]`）——测试服已做；
② **推荐做法（实测有效）**：给 LuckPerms 的 `bedrock` 组加 **`grim.exempt`**——GrimAC 会把这些
   玩家整体跳过（不再判定、不再 setback），Java 端反作弊完全不受影响；
   比逐条加 `grim.prediction.simulation` 之类的 bypass 更干净（那些是检查级豁免，容易漏）。
   命令：`lp creategroup bedrock` → `lp group bedrock permission set grim.exempt true`
   → `lp user <基岩名字> parent add bedrock`。
③ 不要试图靠「看名字像基岩」来豁免——基岩玩家的名字就是 Xbox 代号，与 Java 名字混在同一空间。

**LoginSecurity 是共用名字空间的唯一门槛，必须单独跑完（缺一不可）**：

| 用例 | 期望 |
|---|---|
| Web 首次进服 | 被要求 `/register`（实测：能正常收到提示）；**实测未登录仍可打开背包**，若要更强限制需改开局物品发放时机 |
| 同名双开（Java + Web） | 后进者要求口令；密码正确=同一账号（背包/位置一致），错误=拒绝 |
| 密码错误 N 次 | 触发锁定/踢出（看配置） |
| 抢注窗口 | 已加白名单但未注册的名字被他人先注册：本人进不来 → `/lac rmpass <名字>` 清密码后本人立即注册 |
| 会话超时（`session-timeout`） | 重连需重新登录；Web 断线重连不复用会话 |
| 26.3 兼容 | `api-version: 26.2` 的 3.3.2-SNAPSHOT 在 Paper 26.3 上工作正常：`/register` 提示与注册成功均实测通过 |
| 同名双开 | 实测：同时在线时第二个连接在代理层被拒（`You are already connected to this proxy!`），原会话保留；口令分支只在原会话掉线后出现 |
| 会话超时 | 实测：浏览器客户端启动约 40 s，重连基本都会被要求 `/login`（重登后同一 UUID/存档接续） |
| 站点自研白名单 | 若装了自带 `force_whitelist` 的自研插件：Web 玩家要**同时**进它的名单与 vanilla whitelist |

### 7.3 一键验收（`tests/acceptance_eagler.sh`，手工，不进 CI gate）

机器可判定的项（T1–T3 + 拓扑/端口/暴露面）已经脚本化，一条命令出结论：

```bash
bash tests/acceptance_eagler.sh -d <数据目录>
# 或 ORZMC_DATA_ROOT=<数据目录> bash tests/acceptance_eagler.sh
```

它做五件事：① 按 `.env` 打印派生拓扑（`topology`/`dialect`/`geyser_target`）；
② T1 查代理与信令启动、Geyser 广播地址；③ **三端连通性**（见下表）；④ T2/T3 经**反代**
（玩家真实链路）跑握手与同名两次登录比对 UUID；⑤ 核对端口归属（玩家端口必须归代理、
实例不得抢占）。末尾会打印仍需真人跑的 T4–T12 清单。

三端连通性的自动判定口径（都不需要真人，但都只是"链路层"证据）：

| 端 | 自动检查 | 通过标准 | 局限 |
|---|---|---|---|
| **Java** | 状态查询 + 登录流程（`tests/mc_status.py`） | `version=Velocity …`（代理拓扑）/`Paper`/`Folia`；登录返回 `LOGIN SUCCESS` 或**带原因**的 `DISCONNECT` | 不做玩法验证；被白名单/登录插件拦下也算通（能看到原因就说明链路通） |
| **基岩** | 信令 `TCP/<EAGLER_GEYSER_PORT>` 可连 + Geyser 日志 | `Built-in signaling started` + `Advertised address <域名> resolves to <WAN IP>` | **媒体是 UDP，脚本探不了**；真正"能进服"必须真机（手机流量实测见 §13） |
| **Eagler** | 握手探针（`tests/eaglercraft_probe.py`） | `eagler_protocol=5 minecraft_protocol=777`；同名两次 UUID 一致 | 同上，进服后的玩法要真人 |

三端**同时在线互见**属于 T6，必须真人（三种客户端各一个）。

### 7.2 探针（`tests/eaglercraft_probe.py` / `tests/mc_status.py`，手工，不进 CI）

> `mc_status.py` 用于 **Java 端**：`--host --port` 做状态查询，加 `--login <名字>` 走登录流程。
> 例：`python3 tests/mc_status.py --host 127.0.0.1 --port 25565 --login AcceptJava`

```bash
# 经反代（推荐：等价玩家真实链路，Caddy 会带 X-Real-IP）
python3 tests/eaglercraft_probe.py --host <域名> --port <EAGLER_WS_PORT> --tls

# 直连代理端口调试：必须自己带 X-Real-IP（forward_ip=true 时缺头即断）
python3 tests/eaglercraft_probe.py --host <代理> --port <EAGLER_JAVA_PORT> --real-ip <任意IP>

# 登录放行 + UUID
python3 tests/eaglercraft_probe.py --host <域名> --port <EAGLER_WS_PORT> --tls --login <测试名>

# 抓真客户端首帧（假 WS 服务器；浏览器连它）
python3 tests/eaglercraft_probe.py --sniff --port 9500
```

期望：`-> SERVER_VERSION: eagler_protocol=5 minecraft_protocol=777 ...`。

### 7.3 浏览器进服（可选，无头验证）

`file://` 打开 26.3 单文件 HTML：编辑档案 → Done → Multiplayer → Proceed →
Direct Connection → `<域名>:<EAGLER_WS_PORT>` → Join。判定：出现 HUD，后端日志
`joined the game`。客户端**只认 `wss://`**，本地自签证书需给浏览器
`--ignore-certificate-errors`。

## 8. 灰度顺序

1. 测试实例 + `ENABLE_VELOCITY=true`/`ENABLE_EAGLER=true` → T1–T5 全绿；
2. 接 Geyser 与三端共存 → T6；
3. Folia 实例 → T7/T10；
4. 生产实例：只改实例侧（§4），低峰期开放白名单 3 人；观察 24 h 再放开。

## 9. 回滚

| 步骤 | 命令/动作 |
|---|---|
| 1 | `sed -i 's/^ENABLE_VELOCITY=.*/ENABLE_VELOCITY=false/;s/^ENABLE_EAGLER=.*/ENABLE_EAGLER=false/' <数据目录>/.env`（旧写法：`EAGLER_MODE=off`） |
| 2 | `./orzmc.sh -d <数据目录> up`（代理容器不再创建；数据保留） |
| 3 | 实例侧还原：端口映射改回 `25565:25565/tcp`；`proxies.velocity.enabled=false` |
| 4 | 移除实例 `plugins/` 里的 EaglerXPaper（仅 direct 模式需要） |
| 5 | 站点 Caddy：删掉 Eagler 站点块与端口映射；路由器撤掉该端口转发 |
| 6 | 复核 `./orzmc.sh -d <数据目录> validate`、`status`、`firewall show` |

Web 玩家的离线 UUID 数据仍留在世界里，不影响 Java 玩家。

## 11. 身份与基岩：不使用 Floodgate（已定）

项目决定**不引入 Floodgate**：基岩玩家用 Geyser 的 `java.auth-type: offline` 直接进入
**与 Java/Web 共用**的名字空间。

| 结果 | 说明 |
|---|---|
| 身份 | 名字 = Xbox 玩家代号（如 `joker84179`）；同名 = 同 UUID = 同一份存档/权限（与 Java/Web 一致） |
| 认证 | 仍需 LoginSecurity 口令（首次 `/register`，之后 `/login`；`session-timeout` 已调 600 s） |
| 入场 | 必须先加白名单（`whitelist add <代号>`），否则被 OrzMC 的自建白名单拦下 |
| 反作弊 | 后端拿不到「这是基岩」的信号（Geyser 在代理侧）→ **必须给 `bedrock` 组 `grim.exempt`**：实测加之前 `Simulation` 会持续 setback（能登录、完全走不动），加之后不再判定也不回弹；Java 端不受影响 |
| 皮肤 | 只有 Geyser 默认皮肤；Floodgate 的皮肤修复不可用 |

## 13. Web 端掉线（1006）排查——先看客户端渲染

**现象**：浏览器玩几分钟后弹出 `Eagler WebSocket disconnected: connection dropped without a WebSocket close frame (code 1006)`。

**实测因果链（2026-11-12，同一服务端同一客户端包，只改渲染后端）**：

| 渲染方式 | 结果 |
|---|---|
| 纯 CPU 软渲染（SwiftShader） | 连上后 **3–6 分钟**必掉；服务端日志：`kicked from lobby: disconnect.timeout` / `keepalive timeout` / `lost connection: Timed out` |
| 硬件渲染（D3D11） | **连续 10 分 20 秒不掉**（12 次心跳全过） |

即：**1006 是结果**——浏览器端渲染/GC 卡顿 ≥30 s → 漏回服务端 keepalive → Paper 判超时踢人 → 反代关闭 WS → 客户端显示 1006。

**处置优先级**：
1. **客户端**：确认在用硬件加速（`chrome://gpu` 看 Hardware accelerated）、关掉其他重标签页、**游戏标签保持前台**（后台会被节流）、别让机器休眠/锁屏、优先有线或 5 GHz。
2. **服务端减负**：RPC 在 Paper 26.3 上不可用（见 §4 第 5 条），因此直接降全局
   `view-distance`（本节实测为 6 → 5）。原来的“只降 Eagler 视野”方案在 26.x 上不成立。
   **实测数据（注意：视野差异的结论未成立）**：
   - 148 s / 18.7 MB、187 s / 18.9 MB、23–37 s / 5–7.5 MB：均为**客户端侧断开**（服务端无 kick）；
   - 707 s / 7.9 MB、706 s / 7.9 MB：**挂机 11–12 分钟不掉**（无头 Chromium 151 与真实 Chrome 157 各一次）。
   - 上述会话**不能**用来证明"降视野有效"——RPC 是否真正下发视野未验证；
     能确定的是：**同版本 Chrome、同一客户端文件、同一服务端可以稳定 11+ 分钟**，
     掉线集中在特定客户端环境（例如从 ZIP 临时目录打开、多实例/多标签并存）。
   注意：RPC 插件会要求"modernized channel names"，代理侧必须同时设
   `use_modernized_channel_names = true`（1.13+ 后端），否则 RPC 不生效。
   不想装 RPC 的退路：全局 `view-distance` 6 → 5 或 4（影响所有人）。
3. **容错参数**（已在本站生效，仍建议保留）：`velocity.toml` 的 `read-timeout` 120000、`spigot.yml` 的 `settings.timeout-time` 180。
4. 已给 `dev.jokerhub.cn` 开 Caddy 访问日志（`/data/access-eagler.log`），下次可直接对比是反代断还是上游踢。

### 13.0 实测结论：客户端侧 TUN/代理是「域名连上就断、IP 直连正常」的头号原因

2026-11-14 在真实站点上按变量逐层剥离，链路为
`客户端 → Mihomo TUN（fake-ip）→ 海外节点 → 家宽 WAN → 路由器回环 → 宿主 → 容器`：

| 步骤 | 结果 |
|---|---|
| 局域网 IP 直连 | 稳定（60 s+，可反复 `/server` 切换） |
| 域名（TUN + 海外中继 + 回环） | 1–30 s 内被 RST（Java `-54 Connection reset by peer`；Web `1006`） |
| 域名 + `DOMAIN-SUFFIX,DIRECT`（不出国，但仍过 TUN 数据面） | 仍然断 |
| 域名 + `fake-ip-filter` + 把 WAN IP 加入 `tun.route-exclude-address`（完全绕开 TUN） | **稳定** |

结论：只要流量经过客户端代理的用户态数据面，长连接在高吞吐（进服/切服/传送的区块与背包同步）时会被重置；
服务端三侧日志始终只有 `Disconnected`。处置见 `docs/usage.md` §9 表格最后一行。

## 13. 基岩（Geyser）上线实测清单

按踩坑顺序排列，全部来自 2026-11-12 的真实上线：

| # | 现象 | 根因 | 处置 |
|---|---|---|---|
| 1 | `Geyser-Spigot` 启用后立刻自我禁用 | 检测到上层是 Velocity 转发 | 基岩改由**代理侧的 Geyser-Velocity** 提供；测试服可保留 Geyser-Spigot（切回 off/direct 自动恢复），只需把端口从实例挪到代理 |
| 2 | 手机提示「需要使用微软帐号登录」 | Geyser 的认证段是 **`java.auth-type`**（不是 `remote`），默认 `online` | 改 `java.auth-type: offline`（`up` 会自动改；手动改后重启代理） |
| 3 | 被踢后立刻重连报「无法连接至 lobby：You must wait N seconds」 | 代理的连接节流（被踢后的冷却） | 等 20 秒再连，属正常 |
| 4 | 能登录但完全走不动（位置恒不变） | LoginSecurity 未认证会把人拽回原点 | 在手机聊天里执行 `/login <密码>`；`session-timeout` 已调 600 s，10 分钟内重连免输 |
| 5 | 能走两步就被踢「检测到数据包滥用」 | GrimAC `BadPackets/PacketOrder` 对 Geyser 转包误判 | `punishments.yml` 该组只留 `[log]`/`[alert]`（去掉 kick），`/grim reload` |
| 6 | 登录成功后仍走不动 + `Simulation` 刷屏 | GrimAC 移动预测对 Bedrock 误判并 **setback** | **给 `bedrock` 组 `grim.exempt`**（整体豁免）：`lp group bedrock permission set grim.exempt true`；Java 端不受影响 |
| 8 | 闲置/离开一会儿后掉线，客户端 1006，**服务端没有任何 kick 记录** | macOS App Nap / 显示器休眠 / Chrome 后台节流把页面冻住，TCP 被系统掐断 | 客户端侧：`caffeinate -dimsu`（或关显示器休眠）、游戏窗口保持前台、对本站点关掉 Chrome「内存节省」；服务端无法挽救系统级休眠 |
| 7 | 无法用自动化库验证基岩 | Geyser 2.12 起移除 RakNet-only，改 NetherNet | 必须用真实 26.x 基岩客户端验收（信令 TCP 19132 + 媒体端口见 §13.2） |
| 9 | 手机流量连不上、同一服务器 Wi-Fi 能连 | ① 媒体端口 19134 在路由器上没有静态转发（NAT 给了临时端口）；② Geyser 用 STUN 探到的是**宿主代理/VPN 出口**（实测 `64.176.82.52`），把错地址广播给外网客户端 | 切 `nethernet` + `webrtc-port: 0` 收敛到单端口；显式 `advertise-addresses` 并关 STUN；路由器只转发 `19132`(TCP+UDP)。**实测手机流量进服成功** |
| 10 | 手机**流量**下基岩反复 `no network path`（Wi-Fi 正常） | 移动网络普遍 CGNAT：UDP 映射保活短、易静默失效。实测同一配置 20:37 流量进服成功，22:31:52 会话中 `juice: Lost connectivity` 后，客户端一直用失效 ICE 候选重试。排查结论：路由器转发（`ALL 19132`）与 Windows/Hyper-V 两层防火墙（`OrzMC-MC-Public-UDP` Any）均正确，问题在运营商侧 | **项目决定：不引入 RakNet 回退**（会让端口结构从 1 个变 3 个、维护成本上升）。基岩玩家统一走 **Wi-Fi 局域网直连**（`192.168.0.33:19132`，最稳）；外出场景不承诺支持 |

新基岩玩家入场三步：`whitelist add <Xbox代号>` → 客户端首登 `/register <密码>` → `lp user <代号> parent add bedrock`。

## 12. 拓扑互切（测试服常用：四种组合来回切）

四态的**唯一真相**是 `.env` 的两个开关；但实例侧有三处会跟着变，切之前先对照本表：

| 目标 | `.env` | `paper-global.yml` 的 velocity | 实例端口映射 | 代理容器 | Geyser |
|---|---|---|---|---|---|
| `java-only` | `ENABLE_VELOCITY=false`<br>`ENABLE_EAGLER=false` | `enabled: false` | `25565:25565` + `19132/udp`、`19132/tcp`、`19134/udp` | 不创建 | 实例侧 Geyser-Spigot |
| `velocity` | `ENABLE_VELOCITY=true`<br>`ENABLE_EAGLER=false` | `enabled: true` + `secret` | **`25567:25565`**（去掉 19132/19134） | 创建（无 EaglerXServer） | 代理 Geyser-Velocity |
| `eagler-direct` | `ENABLE_VELOCITY=false`<br>`ENABLE_EAGLER=true` | `enabled: false` | 同 `java-only`；另把 `EaglerXPaper.jar` 放进 `plugins/` | 不创建 | 实例侧 Geyser-Spigot |
| `eagler-proxy` | `ENABLE_VELOCITY=true`<br>`ENABLE_EAGLER=true` | `enabled: true` + `secret` | **`25567:25565`**（去掉 19132/19134） | 创建（含 EaglerXServer） | 代理 Geyser-Velocity |

> 切换时 `up` 会把当前拓扑不需要的插件移到 `$DATA_ROOT/eagler/disabled/`：
> 例如 `eagler-proxy` → `velocity` 后代理不再监听 Web 端点（8081）。移回同理。

要点：

- **Geyser-Spigot 不用删**——`proxy` 下它检测到 velocity 转发会自禁用，切回 `off/direct`
  且关掉 velocity 转发后自动恢复；只有"端口"必须跟着挪（同端口不能两处发布）。
- 反向切回 `off/direct` 别忘了把 `proxies.velocity.enabled` 改回 `false`，否则 Paper 只接受
  带转发数据的连接（直连会被踢）。
- 站点反代（Caddyfile 的 Eagler 站点块）可以一直留着：代理没起时它只是返回 502，不影响
  面板/EasyBot（同端口按 Host 分流）。
- 切完各跑一次：`./orzmc.sh -d <数据目录> validate` → `status` → §7.2 探针。

## 12.1 四象限实跑结果（2026-11-14，测试服）

两个开关 × 四种拓扑，全部**实跑**（不是只跑 validate/渲染）：

| 拓扑 | `.env` | 实例侧 | 实测证据 |
|---|---|---|---|
| `java-only` | `V=false E=false` | 关 `proxies.velocity`；实例发布 `25565`/`25566` + `19132/19133`（Geyser-Spigot 自恢复） | 状态查询 `Paper 26.3` / `Folia 26.2`；原始协议登录 `LOGIN SUCCESS`；无代理容器 |
| `velocity` | `V=true E=false` | 开转发；实例只留 RCON/语音；基岩由代理 Geyser 托管 | `/server` lobby↔survival 往返；手机流量基岩进服（`Player connected with username …`） |
| `eagler-direct` | `V=false E=true` | 关转发；实例发布 `25565`；`EaglerXPaper` 放实例 `plugins/`；反代指向实例容器 | WSS 握手 `brand='EaglercraftXServer' version='1.1.1 Stable 2'`；无头 Chrome 进服 + 移动 + 聊天 **3 分钟**稳定 |
| `eagler-proxy` | `V=true E=true` | 开转发；`EaglerXServer` 在代理；反代指向 `orzmc-velocity:25565` | WSS 握手 `version='1.1.1'`；无头 Chrome 进服 **2 分钟**稳定；基岩单端口 19132 |

切换时**必然要动的三处**（容易漏）：

1. 实例 `config/paper-global.yml` 的 `proxies.velocity.enabled`（开/关都行，但必须与拓扑一致，否则直接连会被拒）
2. 实例 `docker.ports`（代理拓扑只留 RCON/语音；直连拓扑要把 `25565`/基岩端口还给实例）
3. 站点 Caddy 里 Eaglercraft 站点的上游（`orzmc-velocity:25565` ⇄ 实例容器 `MCSM-<uuid8>:25565`），改完必须 `caddy reload`

> 注：`eagler-direct` 只对 Paper 有效（EaglerXPaper 不支持 Folia），Folia 在该拓扑下只能给 Java 玩家直连。
> 另外 `EaglerXPaper` 与 `EaglerXServer` 在**同一实例**上不能同时启用（换拓扑时要把对方的 jar 移出 `plugins/`）。

## 13.2 基岩端口最小化（NetherNet-only）

Geyser 2.12 起 `transport` 只有 `both` / `nethernet`（RakNet-only 已移除）。要少占端口：

```ini
EAGLER_GEYSER_TRANSPORT=nethernet
EAGLER_GEYSER_WEBRTC_PORT=0            # 媒体复用 EAGLER_GEYSER_PORT
```

| 配置 | 需要的端口 | 说明 |
|---|---|---|
| `both` + `19134`（缺省） | TCP `19132`、UDP `19132`、UDP `19134` | 兼容 RakNet 老客户端 |
| `nethernet` + `19134` | TCP `19132`、UDP `19134` | 不要 RakNet，但媒体仍独立 |
| **`nethernet` + `0`** | **TCP `19132`、UDP `19132`** | 一个端口号搞定；需客户端走 NetherNet（26.x 均可） |

取舍：`nethernet`-only 放弃 RakNet 兜底，老版本基岩客户端无法进服；换来的好处是
路由器只需一条 TCP + 一条 UDP（同号），且不会出现「STUN 学到的外部端口与内部端口不一致」
那类问题（静态转发同号即可）。

**广播地址必须显式给出**：`up` 会按 `.env` 的 `LAN_HOST_IP` + `EAGLER_PUBLIC_HOST` 写
`signaling.advertise-addresses: ["<LAN_IP>", "<域名>"]` 并关闭 `stun-discovery`——
因为宿主若跑着系统代理/VPN（Mihomo TUN 等），Geyser 通过 STUN 探到的是**代理出口 IP**，
外网基岩客户端会拿到错误地址。同时容器必须能解析该域名：宿主的 fake-ip 会被容器继承，
所以在 `$DATA_ROOT/compose.site.yaml` 里给代理容器指定内网 DNS：

```yaml
services:
  velocity:
    dns:
      - <路由器 LAN IP>
```

验证：`docker exec orzmc-velocity getent hosts <域名>` 应返回真实 WAN IP，日志出现
`Advertised address <域名> resolves to <WAN IP>`。

## 10. 排障速查

| 现象 | 定位 |
|---|---|
| `Connected without a "X-Real-IP" header, disconnecting` | 直连代理端口了；必须经反代（或探针加 `--real-ip`） |
| 浏览器 `1006 / Could not connect to direct EaglerX WebSocket` | 用 `wss://` 连了明文端口；或反代没透传 `Upgrade` |
| `Connection closed during Eagler server version` | 反代连到非 Eagler 端口，或握手超时（`eagler_login_timeout`） |
| 握手成功但 `Invalid Username` | v5 用户名取自握手包 `auth_username`，不是登录包 |
| `Your client does not support online mode` | 代理或后端 `online-mode=true`，必须改 false |
| `You are not whitelisted` | 实例 `white-list` 与实际名单不一致 |
| `Handshake timed out`（上游 issue #183） | 先降 `view-distance` 与 `http_websocket_max_frame_length`，再回退代理版本 |
| 玩家 IP 全是反代地址 | `listeners.toml` 的 `forward_ip`/`forward_ip_header` 与反代头不一致 |
| 代理起不来（jar 校验失败） | 对照 `templates/eagler/versions.env` 与工具输出的期望/实际 sha256；修好版本锁后重跑 `up` 会自动重下 |
