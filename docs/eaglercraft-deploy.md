# Eaglercraft 接入实施与验收

> **定位**：把 `EAGLER_MODE` 开关（ADR-035）落成可执行的启用 / 验收 / 回滚步骤。
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

配置项只有一行是真的要改的，其余都有缺省：

| 变量 | 必填 | 缺省 | 说明 |
|---|---|---|---|
| `EAGLER_MODE` | ✅ | `off` | `off` / `direct` / `proxy` |
| `EAGLER_JAVA_PORT` | | `25565` | 玩家 Java 入口（proxy=代理端口） |
| `EAGLER_BACKEND_PORT` | | `25566` | 仅 proxy：实例内部端口（必须 ≠ 上面那个） |
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
# 改已有那一行（read_env_value 是"首次出现优先"，追加同名行会被忽略）
sed -i 's/^EAGLER_MODE=.*/EAGLER_MODE=proxy/' <数据目录>/.env
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

5. **后端 RPC（Paper 26.3 上实测不可用，默认不要装）**：RPC 1.1.0 监听 `PlayerLoginEvent`
   注册玩家，而 Paper 26.3 的 `HorriblePlayerLoginEventHack` 会**触发两次**该事件 →
   `IllegalStateException: Player is already registered!` → `eagler_players_view_distance` 从未生效。
   替代：直接降全局 `server.properties` 的 `view-distance`（本站 6 → 5）。
6. 重启实例，日志应出现 `Done (...)`（Via 会打印 `server version: 26.3 (777)`）。

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
| T1 | 代理启动 | 日志 `Listener "listener0" injected ... (Velocity method)` + `Done` | `docker logs orzmc-eagler-proxy` |
| T2 | 握手协商 | `eagler_protocol=5`、`minecraft_protocol=777` | 探针（§7.2） |
| T3 | 登录放行 | `ALLOW_LOGIN` 且两次 UUID 一致 | 探针 `--login` |
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

### 7.2 探针（`tests/eaglercraft_probe.py`，手工，不进 CI）

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

1. 测试实例 + `EAGLER_MODE=proxy` → T1–T5 全绿；
2. 接 Geyser 与三端共存 → T6；
3. Folia 实例 → T7/T10；
4. 生产实例：只改实例侧（§4），低峰期开放白名单 3 人；观察 24 h 再放开。

## 9. 回滚

| 步骤 | 命令/动作 |
|---|---|
| 1 | `sed -i 's/^EAGLER_MODE=.*/EAGLER_MODE=off/' <数据目录>/.env` |
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
   **实测对比**（同一客户端包、同一服务端）：
   - 视野 6：**148 s / 18.7 MB（≈127 KB/s）**，客户端侧断开；
   - 视野 4（RPC 生效）：**619 s（10 分 19 秒）/ 9.5 MB（≈15 KB/s）**，全程稳定、无踢出。
   注意：RPC 插件会要求"modernized channel names"，代理侧必须同时设
   `use_modernized_channel_names = true`（1.13+ 后端），否则 RPC 不生效。
   不想装 RPC 的退路：全局 `view-distance` 6 → 5 或 4（影响所有人）。
3. **容错参数**（已在本站生效，仍建议保留）：`velocity.toml` 的 `read-timeout` 120000、`spigot.yml` 的 `settings.timeout-time` 180。
4. 已给 `dev.jokerhub.cn` 开 Caddy 访问日志（`/data/access-eagler.log`），下次可直接对比是反代断还是上游踢。

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
| 7 | 无法用自动化库验证基岩 | Geyser 2.12 起移除 RakNet-only，改 NetherNet | 必须用真实 26.x 基岩客户端验收（信令 TCP 19132 + 媒体 UDP 19134） |

新基岩玩家入场三步：`whitelist add <Xbox代号>` → 客户端首登 `/register <密码>` → `lp user <代号> parent add bedrock`。

## 12. 模式互切（测试服常用：off ⇄ direct ⇄ proxy）

三态的**唯一真相**是 `.env` 的 `EAGLER_MODE`；但实例侧有三处会跟着变，切之前先对照本表：

| 目标 | `.env` | `paper-global.yml` 的 velocity | 实例端口映射 | 代理容器 | Geyser |
|---|---|---|---|---|---|
| `off` | `EAGLER_MODE=off` | `enabled: false` | `25565:25565` + `19132/udp`、`19132/tcp`、`19134/udp` | 不创建 | Geyser-Spigot 生效 |
| `direct` | `EAGLER_MODE=direct` | `enabled: false` | 同 `off`；另把 `EaglerXPaper.jar` 放进 `plugins/` | 不创建 | Geyser-Spigot 生效 |
| `proxy` | `EAGLER_MODE=proxy` | `enabled: true` + `secret` | **`25567:25565`**（去掉 19132/19134） | 创建 | Geyser-Spigot **自禁用**；基岩由代理的 Geyser-Velocity 提供 |

要点：

- **Geyser-Spigot 不用删**——`proxy` 下它检测到 velocity 转发会自禁用，切回 `off/direct`
  且关掉 velocity 转发后自动恢复；只有"端口"必须跟着挪（同端口不能两处发布）。
- 反向切回 `off/direct` 别忘了把 `proxies.velocity.enabled` 改回 `false`，否则 Paper 只接受
  带转发数据的连接（直连会被踢）。
- 站点反代（Caddyfile 的 Eagler 站点块）可以一直留着：代理没起时它只是返回 502，不影响
  面板/EasyBot（同端口按 Host 分流）。
- 切完各跑一次：`./orzmc.sh -d <数据目录> validate` → `status` → §7.2 探针。

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
