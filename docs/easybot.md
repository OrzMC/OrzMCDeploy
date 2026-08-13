# EasyBot 网关配置指南

本页说明 OrzMC 部署栈中的 EasyBot 统一 IM 网关（取代 NapCat）如何配置，以及
PaperMC 插件 `easybot.yml` 如何对接。

## 架构位置

```text
PaperMC 实例（MCSManager 管理，插件 easybot.yml）
        │  https://DOMAIN_EASY_API   (REST + WebSocket，经公网域名)
        ▼
Caddy（TLS 终止）
        │  easybot:8080（compose 内网，仅 expose 不发布宿主机端口）
        ▼
EasyBot 网关  ——  QQ / Telegram / Discord / 飞书 / 微信
```

- EasyBot 监听器**仅支持 HTTP**，必须由 Caddy 承担 TLS；故其端口只 `expose`，
  不发布到宿主机。
- 插件与 EasyBot 之间走公网域名 `DOMAIN_EASY_API`，Caddy `reverse_proxy`
  原生支持 WebSocket upgrade，REST 与 WS 共用同一域名。

## 管理后台（首次配置）

1. 打开 `https://DOMAIN_EASY_ADMIN`（生产模板中的 `DOMAIN_EASY_ADMIN`）。
2. 使用 `EASYBOT_ADMIN_PASSWORD` 登录/初始化管理后台。
3. **API 密钥**：后台 → API 密钥 → 创建「客服类」密钥，得到 `sk-xxxxxxxx`，填入插件 `api_key`。
4. **会话**：后台 → 会话管理 → 为各平台创建会话，复制**会话 key**（如 `qq:conv_xxxxxxxx`），
   填入插件对应平台的 `admin_group` / `player_group` / `admin_dm`。
   - 注意：这些不是平台原生 ID（QQ 群号等），而是 EasyBot 后台分配的会话 key。

## QQ 接入模型（重要）

EasyBot 的 QQ 适配器使用 **QQ 开放平台** 的官方 bot 凭据：
- `QQ_APP_ID`（来自 `$DATA_ROOT/.env` 的 `QQBOT_APP_ID`）
- `QQ_CLIENT_SECRET`（来自 `$DATA_ROOT/.env` 的 `QQBOT_CLIENT_SECRET`）

这与旧 NapCat 的「个人 QQ 账号扫码登录」是**不同**的接入模型。需要先在
QQ 开放平台注册并审核 bot 应用，取得 AppID 与 ClientSecret 后填入。
未设置该平台 token 的适配器会自动跳过。

## 插件配置（easybot.yml）

在 MCSManager 面板进入 PaperMC 实例，编辑 `plugins/OrzMC/easybot.yml`：

```yaml
# EasyBot 连接地址（DOMAIN_EASY_API 对应生产模板变量）
api_server: 'https://easyapi.example.com'
ws_server: 'wss://easyapi.example.com'

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

`api_server` / `ws_server` 的值应替换为实际的 `DOMAIN_EASY_API` 域名。
`api_key` 与会话 key 均从 EasyBot 管理后台获取，属密钥，不应入库。

## 本地验证注意事项

本地模板 `env.local` 使用 `easyapi.localhost:18443`：
- EasyBot 管理后台（`easyadmin.localhost`）经 Caddy 反代可正常访问。
- 插件（运行在 PaperMC 容器内）通过 `.localhost` 域名访问 EasyBot 在容器内指向
  自身，本地验证时建议改用宿主网关地址（如 `http://host.docker.internal:8080`）
  或跳过机器人连接验证，只验证平台层可达。

## 可选平台适配器

在 `compose.yaml` 的 `easybot` 服务中按需增加环境变量（启用即加一行，勿注入空串）：
- Telegram：`TELEGRAM_BOT_TOKEN`
- Discord：`DISCORD_BOT_TOKEN`
- 飞书：`FEISHU_APP_ID` + `FEISHU_APP_SECRET`
- 微信：仅支持扫码登录，无需环境变量

## 健康检查

EasyBot 提供 `/api/v1/live`，可通过 Caddy 入口验证：

```bash
curl -k -s https://easyapi.example.com/api/v1/live -o /dev/null -w '%{http_code}\n'
```
