# Eaglercraft Web 接入调研（26.3 · Paper 26.3 · Folia）

> **定位**：把「浏览器客户端（Eaglercraft Web Edition）」作为 Java / 基岩之后的第三种入口，
> 接进同一套 Paper / Folia 世界。本文是 P0 调研 + 方案论证 + 实测证据，**不含生产变更**。
> **读者**：决定要不要上、上哪种架构的维护者。
> **相关文档**：实施与验收见 [eaglercraft-deploy](eaglercraft-deploy.md)；
> 暴露面与反代见 [security](security.md)；实例字段见 [papermc-template](papermc-template.md)。

**决策状态**：已落 **ADR-035**，并实现为**可选单开关** `EAGLER_MODE=off|direct|proxy`
（缺省 `off`，对现有部署零影响）。启用步骤见 [eaglercraft-deploy](eaglercraft-deploy.md)；
生产启用前先在测试服跑完 T1–T12。

## 1. 结论摘要

| 结论 | 证据等级 |
|---|---|
| Eaglercraft 26.3 是**真 Minecraft 26.3**（协议 **777**）经 TeaVM/Wasm-GC 编译的浏览器客户端，不是"仿制版" | **实测**（抓到客户端首帧：`minecraft_protocols=[777]`） |
| 26.3 客户端使用 **Eaglercraft 握手协议 v5**（同时声明 3/4/5），EaglerXServer 1.1.1 支持 | **实测**（`eagler_protocols=[3,4,5]`；服务端协商 `eagler=5 / mc=777`） |
| 浏览器 → `wss` → **EaglerXPaper**（Paper 26.3 插件）→ 进服可玩 | **实测**（进服、HUD、被僵尸村民击杀） |
| 浏览器 → `wss` → **Velocity 4.3.1 + EaglerXServer 1.1.1** → Paper 26.3 后端 | **实测**（进服可玩） |
| 同上，后端换 **Folia 26.3** | **实测**（进服可玩，无需 Folia 专用插件） |
| 桥接层**不支持 online-mode 后端**，Eagler 玩家一律是**离线 UUID** | **代码证据**（`VanillaInitializer`、`HandshakerInstance`） |
| 只有 Velocity/BungeeCord 能改 Eagler 玩家的 UUID；Bukkit 平台不能 | **代码证据**（`setProfileUUID` 标注 `@UnsupportedOn(BUKKIT)`） |
| 26.3 客户端**必须走 TLS**（默认尝试 `wss://`，明文 `ws://` 直接失败） | **实测** |
| **代理** `online-mode=true` 时 Eagler 玩家被拒（与后端在线模式同一条限制） | **实测**（`SERVER_ERROR "Your client does not support online mode"`） |
| 客户端自带"微软账号 + AES 加密 + Direct Sockets 直连 TCP"能力，但**经 EaglerX 桥接时用不上** | 见 §2.4（未做端到端验证） |
| **整链必须 offline-mode**：代理 `online-mode=true` 时 Eagler 一样被拒 | **实测**（`Your client does not support online mode`） |
| WS 入口可收紧到"只允许反代"：`forward_ip=true` 时缺 `X-Real-IP` 直接断开 | **实测**（`Connected without a "X-Real-IP" header, disconnecting`） |

**推荐**：方案 B（Velocity 4.3.1 + EaglerXServer 1.1.1），TLS 由站点自备反代终结；
理由见 §6，与方案 A 的关键差异是 **Folia 可用** 与 **UUID 可设置**。

## 2. 客户端：Eaglercraft 26.3 是什么

### 2.1 版本号与协议号

官方下载地址（无需登录）：`https://cdn.eaglercraft.net/objects/dl/26.3/eaglercraft-26.3-fe8f1237-815f7813.zip`
（58,885,242 字节，内含单文件 `eaglercraft-26.3-fe8f1237.html`，78,124,802 字节）。

| 项 | 值 | 来源 |
|---|---|---|
| 客户端自称版本 | `26.3 (zeus/master)`，brand `o_xer + Eaglercraft.com` | wasm 内字符串 |
| 内嵌 version manifest | `"id":"26.3"` `"protocol_version":777` `"world_version":5023` `"java_version":25` `"build_time":"2026-09-15"` | wasm 内 version.json |
| 握手时上报的 brand/version | `Eaglercraft 26.2` / `26.2`（**品牌字符串滞后，勿用来判版本**） | 实测首帧 |
| Java Edition 协议 | **26.3 = 777** | ViaVersion `ProtocolVersion.java`、Paper/Velocity API、客户端 manifest 三处一致 |
| 代码命名空间 | 仍是 `net.lax1dude.eaglercraft.v1_8.*` + 真实 `net.minecraft.*` 26.3 类名 | wasm 类名字符串 |

**结论**：`26.x` 是 Minecraft 新版本号体系下的真实版本，不是 Eaglercraft 自定义编号；
Eaglercraft 只在其上替换了渲染/平台层与网络传输层。

### 2.2 运行形态

- 单文件 HTML，内联 5 个 Brotli 压缩块：主 wasm 108 MB、内置服务端 wasm 43 MB、地形 wasm、
  资源 EPK 7 MB、音效 26 MB —— **首次加载流量大**，必须开 br/gzip 与缓存（见 §9）。
- 使用 **Wasm-GC** + WebGL2 渲染；实测在 **headless Chromium 151** 中正常启动：
  `eagler: web boot OK (26287 assets)`、`Using graphics backend WebGL2`。
- 无 Java 客户端、无微软登录也能进离线服；用户名来自「编辑档案」（默认 `Guest_<随机数>`）。

### 2.3 三条连接通道

| 通道 | 形态 | 需要服务端组件 | 实测 |
|---|---|---|---|
| **EaglerX WebSocket** | `wss://<host>:<port>/`，私有握手 + MC 数据包按帧封装 | EaglerXServer / EaglerXPaper | ✅ 本文 |
| **中继 relay** | `wss://relay.eaglercraft.net` 等公共中继（客户端内置多个） | 不适用（NAT 穿透/社区服列表） | ❌ 未测 |
| **Direct Sockets 直连 TCP** | Chrome 桌面版 151+ 直接连 Java 服（可加密、可正版登录） | 不需要桥接插件 | ❌ 未测 |

> 客户端 wasm 内含微软账号（`wispcraft`）、`AES/CFB8/NoPadding`、`setEncryptionKey`、
> `sessionserver.mojang.com/session/minecraft/join` 等实现，说明 26.x 客户端**具备**正版登录能力；
> 但**经 EaglerX 桥接时不生效**：桥接层向后端发的是离线 `Login Start`（§4.1）。

### 2.4 客户端侧握手的真实字节（实测）

用假 WS 服务器抓 26.3 客户端首帧（脚本：`tests/eaglercraft_probe.py --sniff`）：

```text
eagler_protocols=[3, 4, 5]
minecraft_protocols=[777]
brand='Eaglercraft 26.2' version='26.2'
auth_flag=false  auth_username='EaglerWeb26'
```

要点：

1. 客户端**同时声明 v3/v4/v5**，服务端按"最高可用"选择，所以老服务端不会立刻拒连；
2. 声明的 MC 协议只有 **777**——后端不在 777（且没装 Via）时无法自适应；
3. 升级请求**不带 `Sec-WebSocket-Protocol`**；本地文件场景 `Origin: null`；
4. **最终用户名来自握手包的 `auth_username`**（v5 忽略登录包里的用户名）。

## 3. 握手与登录时序（协议 v5）

| 步 | 方向 | 包 | 内容 |
|---|---|---|---|
| 1 | C→S | `0x01 CLIENT_VERSION` | 前导 `01 02`、eagler 版本表、MC 版本表、brand/version、`auth` 标志、`auth_username` |
| 2 | S→C | `0x02 SERVER_VERSION` | 选中的 eagler/MC 协议、服务端 brand/version、认证方式、盐、是否需要昵称选择 |
| 3 | C→S | `0x04 REQUEST_LOGIN` | 用户名、目标服、口令、cookie、能力位（v5 另有扩展能力 UUID 表） |
| 4 | S→C | `0x05 ALLOW_LOGIN` | 最终用户名 + **离线 UUID** + 能力位 |
| 5 | 双向 | 原生 MC 数据包 | 登录（离线）→ 配置阶段 → 进服 |

服务端在这一层的行为（`core/.../handshake/`、`pipeline/`）：

- 认证事件**默认关闭**（`enable_authentication_events=false`），默认**不校验任何口令**；
- UUID = `UUID.nameUUIDFromBytes("OfflinePlayer:" + name)`，与离线 Java 服一致；
- 向后端发 `Login Start`（协议 ≥764 带 UUID），后端回 `Encryption Request` 即判定在线模式并踢人
  （`VanillaInitializer` 的 `"Your client does not support online mode"`）；
- 建连后 `Vanilla compression codecs stripped` —— 压缩交给 WebSocket 层（默认 zlib 级别 6）。

## 4. 服务端桥接组件

### 4.1 EaglerXServer 1.1.1（2026-08-01，上游 lax1dude）

- **单个 jar 可装 Spigot / BungeeCord / Velocity**；对代理是"注入已有 listener"，不另开端口。
- README 明确支持的客户端是 **1.5.2 / 1.8 / 1.12.2**；v5（26.x）来自 1.1.0 的
  `Fixed support for eagler clients using modern protocol versions` 与代码里的 `HandshakerV5`。
- 关键默认值（`plugins/eaglerxserver/settings.toml` / `listeners.toml`）：

| 项 | 默认 | 说明 |
|---|---|---|
| `protocols.max_minecraft_protocol` | `340`（1.12.2） | v3/v4 老客户端能声明的上限 |
| `protocols.max_minecraft_protocol_v5` | `-1`（任意） | v5 客户端不受限：客户端协议须与后端对齐 |
| `protocols.protocol_v5_allowed` | `true` | 可单独关闭 v5 |
| `eagler_login_timeout` | `10000` ms | 握手超时 |
| `http_websocket_max_frame_length` | `131071` | 1.1.1 安全公告建议**下调一个量级** |
| `enable_authentication_events` | `false` | 关：不校验口令；开：需插件实现认证事件 |
| `enable_is_eagler_player_property` | `true` | 给玩家打 `eagler` 属性，便于其他插件按端区分 |

- **Bukkit 平台**：README 明说 >1.17 不维护、**不支持 Folia**；Velocity 侧通过 `VelocityUnsafe`
  （反射 `AuthSessionHandler`、代理 `MinecraftConnection`）深度 hook 代理内部，属**已知脆弱点**
  （4.2.1 曾因构造器变更崩过，上游 issue #188）。

### 4.2 EaglerXPaper v1.1.1-S2（2026-10-19，第三方 fork）

- 定位：把上游 Bukkit 分支**前移到 Paper 1.17 ~ 26.x**。做法是把 NMS 反射的硬编码类名换成
  名字表（`NmsNames.java`，如 `ServerGamePacketListenerImpl|PlayerConnection`）；文件头可见
  `Decompiled with CFR` —— 它是**反编译再改**的产物，不是上游源码分支。
- `plugin.yml`：`api-version: 1.13`、`main: ...bukkit.PlatformPluginBukkit`、`softdepend: [SkinsRestorer]`。
- README 声明需要 **ViaVersion + ViaBackwards**（1.8 客户端再加 ViaRewind）；**不支持 Folia**。
- 作者自述测试范围：`1.12.2–1.17.1` 与 `1.21.11–26.2`，**没有 26.3**（issue #7 里仍建议别人用 1.21.11）。
- 与上游差异：皮肤预热、包批处理（burst 时 2 ms 合并 flush、上限 200 ms），配置结构完全兼容上游。
- 许可：仓库 license 为 `All Rights Reserved`（GitHub 标 NOASSERTION）——二进制可用，二次分发/改源码需谨慎。

### 4.3 维护状态台账（2026-11-12 核对）

| 项目 | 最新版本 / 时间 | 活跃度信号 | 风险 |
|---|---|---|---|
| Eaglercraft 客户端 26.3 | 构建 2026-09-15 | 官方站持续发布 | 客户端代码**未开源**；品牌字符串滞后 |
| EaglerXServer | v1.1.1（2026-08-01） | 作者自述精力有限、发版慢 | v5 相关 issue 仍开放（#183 进服握手超时、#201 问 26.3 无人答） |
| EaglerXPaper | v1.1.1-S2（2026-10-19） | 单人维护、反编译派生 | 26.3 未声明；上游升级需人工跟 |
| Velocity | 4.3.1（2026-10-27） | 官方活跃 | 4.x 与 3.x 插件 API 有断裂史 |
| Paper / Folia | 26.3 build 249 / build 6 | 官方活跃 | — |

## 5. 方案对比

### 5.1 九维对比

| 维度 | A. EaglerXPaper | B. Velocity + EaglerXServer | C. BungeeCord + EaglerXServer | D. 自研 Gateway |
|---|---|---|---|---|
| 26.3 兼容 | ✅ 实测（作者未声明） | ✅ 实测 | ⚠️ 未测（同内核，理论可行） | ❌ 需自实现 v5 |
| Paper 26.3 | ✅ 实测 | ✅ 实测 | ⚠️ 未测 | 理论可行 |
| **Folia** | ❌ 明确不支持 | ✅ **实测进服** | ⚠️ 未测 | 可行但工作量大 |
| Geyser 共存 | ⚠️ 同实例可，但需分端口 | ✅ 推荐把 Geyser 也放代理 | 同上 | 同 A |
| 插件兼容 | 与普通 Paper 插件相同 | 代理层多一跳，后端插件照旧 | 同 B | 全靠自研 |
| 性能 | 少一跳，延迟最低 | 多一跳（本地回环，实测无感） | 同 B | 取决于实现 |
| 安全性 | 需防护直连 WS 端口 | **可只暴露代理 + 反代**，后端不出网 | 同 B | 需自研限流 |
| 部署复杂度 | 低（丢一个 jar） | 中（新容器 + 转发密钥 + 反代） | 中 | 高 |
| **UUID 可设置** | ❌ Bukkit 平台不可 | ✅ `setProfileUUID` 可用 | ✅ 可用 | 自定 |
| 维护成本 | 依赖单人反编译 fork 跟 26.x NMS | 依赖上游 + Velocity 大版本 hook | BungeeCord 生态在衰退 | 极高 |

### 5.2 各方案结论

**A（EaglerXPaper 直插 Paper）**：实测可用、最省事；适合"单 Paper 实例、近期不上 Folia"。
致命项是**不能用 Folia**、**不能改写 UUID**（账号合并只能靠名字）、依赖反编译 fork 跟 NMS。

**B（Velocity + EaglerXServer）**：实测可用，**Folia 同样可用**（桥接在代理层，无 Bukkit 主线程语义依赖）；
`setProfileUUID` 让"Web 玩家绑定已有 Java 账号"成为可能；多后端/多实例天然支持。
代价是多一个容器与一层配置，且 EaglerXServer 对 Velocity 内部有反射依赖（升级需回归）。

**C（BungeeCord）**：没有优于 B 的点（Folia 支持、维护度、现代转发都弱于 Velocity），不推荐。

**D（自研 Gateway）**：v5 握手 + 离线登录 + 配置阶段 + 压缩剥离 + 能力位协商全部要自己跟协议演进，
客户端每次发版都要重测。**结论：不自研**；只在桥接层做不到的需求（如把 Web 玩家映射到真实账号）
上写**小插件**（走 EaglerXServer API），而不是重写网关。

## 6. 推荐架构（方案 B）

```text
浏览器（Eaglercraft 26.3）
   │ wss://<WEB_HOST>（443，站点自备 TLS）
   ▼
宿主机反代（Caddy/nginx：仅 TLS + WS 透传 + X-Real-IP）   ← 站点增量，不进包内 compose
   ▼ ws（仅容器网络/回环）
Velocity 4.3.1 + EaglerXServer 1.1.1（listener 注入，双栈同端口）
   ├── 原生 Java 客户端（TCP，同端口）
   ├── Geyser（可选，Velocity 版，UDP 19132）
   ▼ MODERN 转发（velocity.secret）
Paper 26.3 / Folia 26.3 实例（MCSManager 管理，online-mode=false，后端端口不发布）
```

关键点：

1. **同一代理端口同时承载 Java TCP 与 Eagler WSS**（双栈按首包自动识别）：
   玩家只记一个地址，Java 用 TCP、浏览器用 `wss://`。
2. 后端**不发布端口**，只信代理；`online-mode=false` 是桥接层的前提，不是图省事。
3. TLS 归站点（ADR-027「对外由站点自备」），仓库只给反代片段与防火墙口径。
4. 与 MCSManager 的关系不变：实例仍由面板管理，插件丢实例 `plugins/`；代理是**额外**一段运行时。

## 7. 兼容性矩阵

| 组件 | 实测/核对版本 | 26.3 支持依据 |
|---|---|---|
| Eaglercraft 客户端 | 26.3（`fe8f1237`） | 实测协议 777 + 进服 |
| Java 协议 | 777 | ViaVersion / Velocity API / 客户端 manifest |
| EaglerXServer | 1.1.1 | 实测（Velocity 4.3.1 加载 + 注入 + 进服） |
| EaglerXPaper | 1.1.1-S2 | 实测（Paper 26.3 build 249 加载 + 进服） |
| Velocity | 4.3.1（build 45） | 官方 `MAXIMUM_VERSION = MINECRAFT_26_3` |
| Paper | 26.3 build 249 | 官方 fill API |
| Folia | 26.3 build 6 | 实测（经代理进服） |
| ViaVersion / ViaBackwards | 5.12.3-SNAPSHOT | 支持 26.3；为老 Eagler 客户端（1.8/1.12.2）兜底 |
| ViaRewind | 4.2.0 | 需支持 1.8 客户端时才装 |
| Geyser | 2.12.1-b1300 | 声明支持 Paper 26.3（**未做基岩端实机验证**） |
| LuckPerms | 5.5.71-bukkit | 声明 26.3 |
| GriefPrevention | 16.18.8 | 声明 26.3 |
| Simple Voice Chat | 2.6.27 | 声明 26.3（**只服务 Java 客户端**，浏览器端用不了） |
| EzShops | 2.5.9 | 只声明到 26.2 ⚠️ |
| LoginSecurity | 3.3.1（2025-11） | **未声明 26.3**；`softdepend: ProtocolLib`，而 ProtocolLib 正式版 5.4.0（2025-08）⚠️ |

## 8. 身份、权限与数据

- **UUID 规则**：实测两次分别进入 Paper / Folia，同一用户名拿到同一 UUID（`OfflinePlayer:<name>`），
  身份在代理与后端之间稳定。
- **名字可伪造**：客户端「编辑档案」里用户名随便填，默认 `Guest_<随机数>`，**没有** Mojang 校验。
  风险模型与离线 Java 服相同，但门槛更低（改个名零成本）。
- **身份策略（已定，2026-11-12）：Web 与 Java 共用同一个名字空间**。
  UUID 是名字派生，因此同名 = 同 UUID = **跨端同一个账号**：同一份 `playerdata`/经济/领地/
  LuckPerms 权限。这是**有意选择**——玩家用同一个名字在浏览器与 Java 之间无缝接续。
  含义与代价：
  - **不装**改名插件（原先考虑的 `w_` 前缀方案未采用）：代码层面无需任何改动，
    `EAGLER_MODE` 已足够；`IEaglercraftLoginEvent` 的 `setProfileUsername`/`setProfileUUID`
    仍留给将来"账号映射"类需求。
  - **唯一门槛是口令登录**（LoginSecurity）：同名玩家必须知道该账号密码，否则进不去。
    真正的门是**白名单**：只有名单里的名字能进（本机实测 95 个名字），所以「随便取名」
    不成立；剩下的抢注窗口只有一种——**已加白名单、但还没首次注册**的名字。
  - **不能靠「关闭注册」堵窗口**：LoginSecurity 3.3.2 的 `/lac` 只有
    `rmpass` / `reload` / `session` / `info` / `import`（实测 jar 内子命令），**没有建号命令**；
    关注册会直接挡住新玩家。正确做法：加白名单与首次登录同时进行；若名字被误抢注，
    管理员 `/lac rmpass <名字>` 清掉密码后让本人立刻注册。
    同理，**任何 op/权限名字都必须已注册**——`ops.json` 按 UUID 授权、UUID 由名字派生，未注册的 op 名字等于「谁先注册谁拿权」。
  - **拿不到**的东西：无法给 Web 端单独权限组（LuckPerms 只认 UUID/名字，读不到 `eagler`
    属性）；Web 玩家之间仍可互相仿冒（靠口令拦）；改名即换 UUID，封禁需配合白名单/IP。
    若将来确实要"Web 单独权限"，干净做法是 Web 走独立后端并用 LuckPerms 的 server 上下文，
    代价是拆世界，与"三端同世界"目标冲突。
- **口令登录**：LoginSecurity 走普通 Bukkit 事件，Eagler 玩家在服务端看来就是离线玩家，**理论一致**；
  但它依赖 ProtocolLib（未适配 26.x）做"登录前屏蔽背包/移动"，必须先实测再上生产（§11）。
- **权限**：LuckPerms 按 UUID 存，同名同 UUID 会让"假玩家"继承真玩家权限——与名字政策强绑定。
- **按端区分**：`enable_is_eagler_player_property=true` 后其他插件可判断 `eagler` 属性，
  用来关掉 Java 专属能力（Simple Voice Chat、需要客户端 mod 的资源包等）。

## 9. 安全与网络

| 面 | 要求 | 依据 |
|---|---|---|
| 传输 | **必须 TLS**（客户端默认 `wss://`，明文直接 1006 失败） | 实测 |
| Origin | **不能当门禁**：客户端可发 `Origin: null`，EaglerXServer 无 Origin 白名单 | 实测 + 代码（仅 `debug_log_origin_headers`） |
| 真实 IP | `forward_ip=true` + `forward_ip_header`（默认 `X-Real-IP`） | `listeners.toml` |
| 防绕过反代伪造 IP | `forward_secret=true` + `X-Eagler-Secret`（文件 `eagler_forwarding.secret`，600） | `listeners.toml` |
| 限流 | 每 listener 独立 `ratelimit.http/ip/login/motd/query`（默认 localhost 豁免） | `listeners.toml` |
| 帧长 | `http_websocket_max_frame_length` 从 131071 下调（1.1.1 修了 Netty WS 栈 OOM） | 上游 release note |
| 端口暴露 | 只暴露反代 443 与代理端口；**后端不进公网** | [security](security.md) §4 的"站点自备 TLS 端口"类别 |
| 资源 | 首屏 78 MB HTML + 108 MB wasm：反代必须开 br/gzip 与长缓存 | 实测包体 |

反代必须**整站透传 WS**（`Upgrade`/`Connection` 头 + 长 `proxy_read_timeout`），不要做路径级拦截。

## 10. 本轮实测记录（可复现）

环境：Docker Desktop（WSL2）+ `eclipse-temurin:25-jre`；客户端由 **headless Chromium 151** 驱动，
页面为官方 26.3 单文件 HTML；TLS 由 nginx 自签证书终结（浏览器加 `--ignore-certificate-errors`）。

| # | 场景 | 结果 |
|---|---|---|
| 1 | EaglerXPaper 1.1.1-S2 + Paper 26.3 build 249 + Via* | 插件加载、`Default listener injected into server channel successfully (PaperMC method)` |
| 2 | `tests/eaglercraft_probe.py` 手写 v5 握手打 Paper | `SERVER_VERSION eagler=5 mc=777`，随后 `ALLOW_LOGIN` 给出离线 UUID |
| 3 | 真 26.3 客户端 → `wss`（nginx → Paper 25566） | `EaglerWeb26 joined the game`，实机画面有 HUD/世界/怪物 |
| 4 | Velocity 4.3.1 + EaglerXServer 1.1.1 → Paper 26.3（MODERN 转发） | `Listener "listener0" injected ... (Velocity method)`；进服成功 |
| 5 | 同上，后端换 **Folia 26.3 build 6** | 进服成功（`logged in with entity id 1`） |
| 6 | `--sniff` 抓真客户端首帧 | `eagler_protocols=[3,4,5]`、`minecraft_protocols=[777]`、`brand=Eaglercraft 26.2` |
| 7 | `EAGLER_MODE=proxy` 生成的 velocity.toml + forwarding.secret → Paper 26.3（MODERN 转发） | 代理 `Done`、`Listener "listener0" injected`；浏览器进服、后端 1 秒内登录（`logged in with entity id 1`） |
| 8 | `eagler_post_up` 自动修正 `listeners.toml`（`forward_ip=true` / `X-Real-IP` / 帧长 65535） | 二次执行幂等（`NOCHANGE`）；修正后经反代进服正常，直连 `ws://` 被拒 |
| 9 | **真实插件栈**（复制某站的 20+ 插件：LuckPerms/LoginSecurity/GrimAC/GriefPrevention/EzShops/Geyser/Via*/SVC/自研插件，全新平原地形） | 浏览器进服成功；`/register` 在聊天框可用，注册后自动登录；LuckPerms 命中默认组；GrimAC 持续移动 3 s 无踢人/误判 |
| 10 | 同名双开（两个浏览器会话同名） | 第二个连接在**代理层**被拒：`You are already connected to this proxy!`；**原会话不受影响**（未被顶号），也没走到口令提示 |
| 11 | 断线重连（关闭会话后重连两次） | 两次都要求 `/login`（浏览器启动约 40 s，实际间隔已超 `session-timeout`）；重登后同一 UUID / 同一存档接续 |
| 12 | 口令分支（原会话已断开后同名再登） | 错：`登录失败: 密码错误`；对：`登录成功`；期间反复提示「请输入 /login <密码> 来登录」 |
| 13 | 老版本 Java 客户端（node `minecraft-protocol` 1.20.4）经代理进 26.3 后端 | 成功：后端日志 `joined the game`、`logged in with entity id`、LuckPerms 默认组；证明 ViaVersion 在代理链路里生效 |
| 14 | Folia 26.3 后端（经同一代理） | 进服成功；持续 W/D 移动 8 s，Folia 日志无区域/线程检查异常 |
| 15 | **Geyser（基岩）与代理共存**（仓库已自动化：`proxy` 模式下载 Geyser-Velocity 并改端口/后端） | **Geyser-Spigot 检测到上层是 Velocity 后自我禁用**（日志要求把 Geyser 装到代理）；Geyser 2.12.1 已移除 RakNet-only 传输，强制 NetherNet → 自动化 RakNet 客户端无法再用于验证，**基岩端必须用真实 26.x 客户端** |

实测中观察到的**非致命异常**（备查）：

- `[HorriblePlayerLoginEventHack] You have plugins listening to the PlayerLoginEvent …`
  —— EaglerXPaper 注册了 `PlayerLoginEvent`，让 Paper 的"重新配置 API"不可用；
- `Player … was initialized, but never fired PlayerJoinEvent, dropping...`（方案 A 首次进服偶发一次）；
- `Services public key unavailable; remote chat sessions will remain unsigned`（无正版密钥，聊天不签名）。

## 11. 未验证项与下一步

| 项 | 现状 | 建议验证 |
|---|---|---|
| 基岩 + Web + Java **三端同服** | Web 与 Java（老版本经 Via）均已验证进服；基岩端受限于 NetherNet，需真实客户端 | `proxy` 模式必须先把 Geyser 迁到 Velocity（否则 Geyser-Spigot 自禁用），再用手机/主机各进一次 |
| 插件逐项（LoginSecurity / EzShops / GriefPrevention / LuckPerms / Geyser / SVC） | 仅核对"是否声明 26.3" | 按 [eaglercraft-deploy](eaglercraft-deploy.md) §7 的 T5 表逐项过 |
| Folia 线程安全 | 已验证能进服，未做高负载 | 两玩家跨区域跑动 + 观察 Folia 异常日志 |
| 断线重连 / 长时间挂机 / 弱网 | 未测 | 挂机 30 min + 切网重连 |
| Direct Sockets 直连 TCP（Chrome 151+） | 仅从 wasm 字符串确认存在 | 若要替代桥接层需单独评估（公网暴露原版端口、DDoS） |
| 账号映射（Web 玩家 = 已有 Java 账号） | 机制已知（`setProfileUUID`，仅代理平台） | 自写 auth 事件插件，测试服用同名账号验证经济/领地数据 |
| `enable_authentication_events=true` 但无插件实现事件 | 客户端报 `Rejected: Internal Error`，服务端日志 `Auth required check event was not handled`（**实测**） | 实现 `IEaglercraftAuthCheckRequiredEvent`/`AuthPasswordEvent` 后再测客户端是否弹口令框 |
| 上游 v5 已知问题（#183 握手超时） | 未复现（本环境正常） | 生产出现时按 [eaglercraft-deploy](eaglercraft-deploy.md) §9 处理 |
| 真实外网入口（家宽 DDNS + 端口转发） | 只在局域网链路实测（沙箱出口有透明代理，无法代表外网） | 落地后从手机 4G 跑 §7.2 的探针与浏览器进服 |
| 同名双开中的**口令分支** | 代理层会先拒绝同时在线（见 §10 #10），口令分支只在原会话掉线后出现 | 用两个 Java 客户端验证口令对/错两条分支 |
| 登录前限制强度 | 实测：`hide-inventory: true` 下预登录**仍能看到/打开背包**（开局赠送物品）；blindness 未见明显画面变暗 | 把开局物品改成「登录后发放」，或评估 `hide-inventory-safe`（需 ProtocolLib，26.3 未知） |
| 站点自研插件的**独立白名单** | 实测：自研插件有自己的 `force_whitelist`，不在其名单里的人会被踢（消息指向加群），与 vanilla whitelist 无关 | 加 Web 玩家要同时加到两处白名单 + 让其注册 |
