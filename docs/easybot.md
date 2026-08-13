# EasyBot 网关配置指南

本页说明 OrzMC 部署栈中的 EasyBot 统一 IM 网关如何配置，以及
PaperMC 插件 `easybot.yml` 如何对接。

## 架构位置

```text
公网（Cloudflare 边缘终止 TLS，prod profile）
  https://DOMAIN_EASY_ADMIN  （EasyBot 管理后台）
        ▼
cloudflared（出站隧道）─> easybot:8080（compose 内网，仅 expose 不发布宿主机端口）
        ▼
EasyBot 网关  ——  QQ / Telegram / Discord / 飞书 / 微信

内网（插件 API，不暴露公网）
PaperMC 实例（MCSManager 管理，挂 orzmc_default 网络，插件 easybot.yml）
        │  http://easybot:8080  (REST + WebSocket，服务内网直连)
        ▼
EasyBot 网关
```

- EasyBot 监听器**仅支持 HTTP**，TLS 由边缘层承担：prod=Cloudflare 边缘，
  local=Caddy。故其端口只 `expose`，不发布到宿主机。
- **插件 API 仅内网**：插件跑在 `orzmc_default` 网络内，直连 `http://easybot:8080`
  （REST 与 WS 同端口，内网无需 TLS）。不存在 `easybot-api` 公网域名。
  - 先决条件：MCSManager 创建 PaperMC 实例时，把实例网络挂到 `orzmc_default`，
    否则插件容器解析不到 `easybot` 服务名。
- 管理后台走公网 `DOMAIN_EASY_ADMIN`（prod 即 `easybot.<domain>`）。

## 管理后台（首次配置）

1. 打开 `https://DOMAIN_EASY_ADMIN`（生产模板中的 `DOMAIN_EASY_ADMIN`，即
   `easybot.<domain>`）。
2. 使用 `EASYBOT_ADMIN_PASSWORD` 登录/初始化管理后台。
3. **API 密钥**：后台 → API 密钥 → 创建「客服类」密钥，得到 `sk-xxxxxxxx`，填入插件 `api_key`。
4. **会话**：后台 → 会话管理 → 为各平台创建会话，复制**会话 key**（如 `qq:conv_xxxxxxxx`），
   填入插件对应平台的 `admin_group` / `player_group` / `admin_dm`。
   - 注意：这些不是平台原生 ID（QQ 群号等），而是 EasyBot 后台分配的会话 key。

## QQ 接入模型（重要）

EasyBot 的 QQ 适配器使用 **QQ 开放平台** 的官方 bot 凭据（非个人账号扫码登录）：
- `QQ_APP_ID`（来自 `$DATA_ROOT/.env` 的 `QQBOT_APP_ID`）
- `QQ_CLIENT_SECRET`（来自 `$DATA_ROOT/.env` 的 `QQBOT_CLIENT_SECRET`）

需要先在 QQ 开放平台注册并审核 bot 应用，取得 AppID 与 ClientSecret 后填入。
未设置该平台 token 的适配器会自动跳过。

## 插件配置（easybot.yml）

在 MCSManager 面板进入 PaperMC 实例，编辑 `plugins/OrzMC/easybot.yml`：

```yaml
# EasyBot 连接地址（服务内网直连；实例须挂 orzmc_default 网络）
api_server: 'http://easybot:8080'
ws_server: 'ws://easybot:8080'

# 客服类 API Key（从 EasyBot 管理后台获取）
api_key: 'sk-xxxxxxxxxxxxxxxx'

# 启用需要接入的平台，并填入 EasyBot 后台的会话 key
platforms:
  qq:
    enabled: true
    admin_group: 'qq:conv_xxxxxxxx'   # 管理群会话 key
    player_group: ''                  # 玩家群（留空降级 admin_group）
    admin_dm: 'qq:conv_yyyyyyyy'      # 管理员私聊会话 key
```

`api_server` / `ws_server` 指向 **`http://easybot:8080`**（compose 服务名 `easybot`，
端口 `EASYBOT_PORT`）。`api_key` 与会话 key 均从 EasyBot 管理后台获取，属密钥，不应入库。

## 本地验证注意事项

本地模板 `env.local` 使用 `easybot.localhost`：
- EasyBot 管理后台（`https://easybot.localhost:18443`）经 Caddy 反代可正常访问。
- 插件若跑在 PaperMC 容器内并挂到 `orzmc_default`，同样可直连
  `http://easybot:8080`；否则本地验证可跳过机器人连接验证，只验证平台层可达。

## 可选平台适配器

在 `compose.yaml` 的 `easybot` 服务中按需增加环境变量（启用即加一行，勿注入空串）：
- Telegram：`TELEGRAM_BOT_TOKEN`
- Discord：`DISCORD_BOT_TOKEN`
- 飞书：`FEISHU_APP_ID` + `FEISHU_APP_SECRET`
- 微信：扫码登录，无需环境变量

## 禁用微信适配器

个人微信适配器**无凭据要求，默认自动启用**（启动日志显示 `Auto-enabling adapter 'wechat'`，
并持续刷新扫码二维码）。不需要微信接入时，在 `$DATA_ROOT/easybot/data/gateway.local.yaml`
显式关闭（`deploy.sh init` 已自动生成该文件，属运行数据，入 Git 的仅是模板
`templates/gateway.local.yaml`）：

```yaml
adapters:
  wechat:
    enabled: false
```

改后重启生效：`docker restart orzmc-easybot`，日志应出现
`Skipping adapter 'wechat' ... explicitly disabled in config`，且 `Started adapters` 不再
包含 `wechat`。该覆盖文件由 EasyBot 从 `EASYBOT_HOME`（容器 `/var/lib/easybot`）读取，
仿 Caddyfile 模式由 init 生成、**绝不覆盖已有文件**。

> 注：**无需在覆盖文件里写 `server.host`**（EasyBot ≥0.0.35 已修复 round-trip 默认值
> 注入 bug，本地覆盖只按文件显式写出的键合并，不再注入 `server.host` 默认值
> `127.0.0.1`）。镜像低于 0.0.35 时旧版存在该 bug：只要 `gateway.local.yaml` 存在就会
> 覆盖基础 gateway.yaml 的 `0.0.0.0`，监听退回容器回环、公网 502（2026-08-14 生产
> 故障，当时需临时补 `server.host: "0.0.0.0"` 绕过）。

## 健康检查

EasyBot 提供 `/api/v1/live`，可从管理后台入口验证：

```bash
curl -s https://easybot.example.com/api/v1/live -o /dev/null -w '%{http_code}\n'
```

## 运维注意

- **不要用外部 `sqlite3` CLI 直接读写运行中的 `gateway.db`**（`$DATA_ROOT/easybot/data/data/`）。
  该库由网关进程以 WAL 模式持有，外部访问（尤其与网关并发写、SQLite 版本不一致时）可能
  触发瞬时 `SQLITE_CORRUPT`（"database disk image is malformed"，code 11）。2026-08-13 实测
  教训：停网关正常关库 checkpoint 后 `integrity_check` 可恢复无损。日常查询会话/密钥/授权一律
  走管理后台或网关 API。
- 插件发送报 `403` 时，先查该 API key 的 `permissions`（需含 `messagessend`）与
  `target_grants`（key 的 `subject_id` 对该 `platform+chat_id` 是否授权 `messages:send`）。
