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
   **`proxy` 模式必须移除 Geyser-Spigot（或迁移到代理）**：实测 Geyser-Spigot 检测到
   Velocity 转发后会**自我禁用**（日志：`Remove the Geyser plugin from this server and install
   Geyser only on your proxy`）——不迁就等于基岩版全部掉线。
4. `proxy` 模式：`config/paper-global.yml` 写入（secret 来自 `instance-setup.md`）：

```yaml
proxies:
  velocity:
    enabled: true
    online-mode: false
    secret: '<instance-setup.md 里的 secret>'
    enabled-force-key-authentication: false
```

5. 重启实例，日志应出现 `Done (...)`（Via 会打印 `server version: 26.3 (777)`）。

## 5. 阶段 3：TLS / WSS（站点自备）

把 `<数据目录>/eagler/caddy-eagler.snippet` 追加到站点 Caddyfile，然后：

| 动作 | 内容 |
|---|---|
| Caddy 端口 | 站点 `caddy` 服务加一行 `"<EAGLER_WS_PORT>:8443"`（缺省 `18444:8443`） |
| 路由器 | 转发 `<EAGLER_WS_PORT>/TCP` 到宿主（与现有 18443 同一台机器） |
| 防火墙 | 按站点自建 TLS 规则放行（如 `OrzMC-Web-TLS`），**不要**写进 `MC_PUBLIC_TCP` |
| 域名 | 已解析到本机的名字即可；用通配证书时换子域名**不用改配置** |

片段要点：`flush_interval -1`（WS 长连接）、`header_up X-Real-IP {remote_host}`
（EaglerXServer 的 `forward_ip=true` 缺这个头会直接断开）。

## 6. 阶段 4：加固清单

| 项 | 动作 |
|---|---|
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
**GrimAC**（浏览器端延迟高，重点看移动/攻击是否误判踢人；误判就对该玩家放宽或加 bypass 权限）。

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
