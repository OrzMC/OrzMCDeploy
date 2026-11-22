# Web 客户端托管（可选服务 webmc）

> **状态**：可选服务（默认关闭）。镜像/仓库**不包含客户端本体**；客户端由运维自行下载，
> 放进 `$DATA_ROOT/webmc/versions/<版本>/client.html`。
>
> **定位**：官方 Eaglercraft 站不可用时的自托管入口（深链/外嵌/多版本）；不是 EULA 合规方案。
> 客户端是 ARR 且不符合 Mojang EULA，**仅私有兜底、不公开分发、不商业化**。

---

## 1. 启用

```bash
# 1) 编辑 $DATA_ROOT/.env
ENABLE_WEBMC=true
LAN_WEBMC_PORT=18092
WEBMC_IMAGE=ghcr.io/orzmc/orzmc-webmc:0.1.2
# 可选：限制可嵌入的站点
# WEBMC_FRAME_ANCESTORS=https://orzmc.jokerhub.cn
# 可选：对外域名（只影响 API 返回的绝对 URL）
# WEBMC_PUBLIC_BASE_URL=https://webclient.example.com

# 2) 校验 + 启动
./orzmc.sh -d <数据目录> validate
./orzmc.sh -d <数据目录> up

# 3) 访问
http://<LAN_HOST_IP>:18092/
```

`webmc` 是 **profile 可选服务**：`ENABLE_WEBMC=true` 时 `compose_cmd` 自动追加
`--profile webmc`；`false` 时容器不创建，对现有部署零影响。

## 2. 放客户端（镜像不含）

官方 26.3 单文件 HTML 由部署者自行获取：

```bash
mkdir -p "$DATA_ROOT/webmc/versions/26.3"
# 把官方 HTML 放成：
#   $DATA_ROOT/webmc/versions/26.3/client.html
# 可选元数据：
cp <仓库>/data/versions/meta.example.json \
   "$DATA_ROOT/webmc/versions/26.3/meta.json"
```

多版本：每个子目录一个版本（`1.8.8/`、`1.12.2/`、`26.2/`、`26.3/`），访问
`/play?version=<id>&server=wss://...`。

| id | 官方离线资产 | MC 协议 | 运行时 | `inject` |
|---|---|---:|---|---|
| `1.8.8` | `1.8.8/eaglercraft1-8-62da5f39.zip` | 47 | js | `joinServer` |
| `1.12.2` | `1.12.2/eaglercraft1-12-62da5f39.zip` | 340 | js | `joinServer` |
| `26.2` | `26.2/eaglercraft-26.2-fe8f1237-d6714264.zip` | 776 | wasm-gc | `auto` |
| `26.3` | `26.3/eaglercraft-26.3-590e4bd1-3769e546.zip` | 777 | wasm-gc | `auto` |

> 官方资产在 `https://cdn.eaglercraft.net/objects/dl/...`；解压后把 zip 内唯一 HTML 改名为
> `client.html`。1.5.2 需要 `EaglerXRewind`，EaglerXServer 默认不接，不要放。

- 目录名 = 版本 id（`[A-Za-z0-9._-]`）；`meta.json` 可覆盖 `name/client/protocol/runtime/inject`。
- 官方 26.x 客户端不读 `?server=`；服务首次访问时在**容器内临时缓存**注入
  `eaglercraftXOpts.joinServer`，源文件不改、镜像不存客户端。
- ⚠️ **1.8.8 / 1.12.2 必须 `"inject": "joinServer"`**：这两版代码里本来就有
  `joinServer` 选项名，但不会从 URL 读取；`auto` 会误判为已支持，深链不会自动连服。
- 新增/更新版本后重启 `webmc`：`./orzmc.sh -d <数据目录> up`（或 `docker restart orzmc-webmc`）。

## 3. 深链与外嵌

```text
# 直接进服
http://<LAN_HOST_IP>:18092/play?version=26.3&server=wss%3A%2F%2Fdev.jokerhub.cn%3A18443

# 嵌入 iframe（跨域时配 WEBMC_FRAME_ANCESTORS）
http://<LAN_HOST_IP>:18092/embed?version=26.3&server=wss%3A%2F%2F...
```

- `/play`：返回客户端 HTML（注入 `joinServer`）；`server` / `joinServer` 都接受。
- `/embed`：最小外壳 + `WebMC.join()/setVersion()/reload()` + `postMessage({type:'webmc:ready'})`。
- `/api/versions`、`/api/health`：版本清单 / 健康检查。
- `/client/<version>/<path>`：版本目录静态文件（白名单/防穿越）。
- 可选 `WEBMC_ACCESS_TOKEN`：非空则 `/play`、`/embed`、`/client` 需 `?token=`。

## 4. 对外 TLS（站点自备）

本仓库不管理反代。Caddy 示例：

```caddyfile
webclient.example.com {
    reverse_proxy 127.0.0.1:18092 {
        flush_interval -1
    }
    header {
        X-Content-Type-Options nosniff
        Referrer-Policy no-referrer
        X-Robots-Tag "noindex, nofollow"
    }
}
```

- 建议 `LAN_BIND_ADDR=127.0.0.1` 或防火墙只放行反代；不要直接把 18092 暴露公网。
- 若反代在另一台机器，用 `LAN_BIND_ADDR=<内网IP>` 并限源。
- `WEBMC_PUBLIC_BASE_URL` 填对外域名，`/api/versions` 里的 play/embed URL 才是绝对地址。

## 5. 官网 `site` 接入

官方站正常时：主按钮继续走官方深链。
官方站不可用/想自托管时：

```toml
# OrzMCSite: config/_default/params.toml
web_client_url = "https://webclient.example.com/play?version=26.3"
# 或只作为兜底（默认不显示）
web_client_fallback_url = "https://webclient.example.com/play?version={version}&server={address}"
```

`site` 会自动追加 `joinServer`/`launch=1`；webmc 读 `joinServer`，忽略 `launch`。

## 6. 镜像与升级

- 镜像：`ghcr.io/orzmc/orzmc-webmc:<tag>`（当前 `0.1.2`；`0.1.1` 修复 78MB 客户端在 512M 堆下的 OOM，`0.1.2` 增加播放壳/大小屏/加载反馈）。
- **GHCR 包已设为 public**，宿主机可直接 `docker pull`，无需登录。
  若遇到限流/网络问题，仍可 `docker login ghcr.io` 或本地 `docker build`。
- 升级：改 `.env` 的 `WEBMC_IMAGE` → `./orzmc.sh up`。建议钉 digest（与其它镜像一致）。
  `0.1.2` digest：`sha256:ef0fb1d7dceab28c153f067b01ca3d403bfbd3486123a12410bc2dc822dc4fd7`。
- 数据/客户端在 `$DATA_ROOT/webmc/`，升级镜像不丢。

## 7. 资源与排障

| 项 | 值 |
|---|---|
| 容器内存上限 | 默认 768M（`WEBMC_MEMORY_LIMIT`） |
| JVM 堆 | 默认 `-Xms256m -Xmx512m`（`WEBMC_JAVA_OPTS`） |
| 首次 `/play` | 读取 78MB 客户端生成补丁缓存，几秒（ext4）；之后直接命中缓存 |
| 缓存位置 | 容器内 `/tmp/webmc-cache`（重建无妨） |

| 现象 | 处理 |
|---|---|
| 容器起不来 / `pull access denied` | 包已 public；检查 DNS/网络；私有镜像才需 `docker login ghcr.io` |
| `/api/health` 正常但 `/api/versions` 为空 | 客户端没放对：需 `versions/<id>/client.html`，然后重启 |
| `/play` 404 Unknown version | `version` 与目录名不一致；看 `/api/versions` |
| 页面能开但没自动进服 | 客户端需首次 Edit Profile → Done、Default Username → Continue Anyway；之后自动连接 |
| 外嵌被浏览器拒绝 | 配 `WEBMC_FRAME_ANCESTORS`（CSP frame-ancestors），并确认反代没加 X-Frame-Options |
| 大面积 502 | 反代上游端口写错（18092）或容器未起；`docker logs orzmc-webmc` |

## 8. 合规

- 镜像/仓库**零客户端**；客户端由部署者自行获取，服务只做托管入口。
- 客户端 All Rights Reserved，项目不符合 Mojang EULA；自托管=再分发，风险由运营者承担。
- 仅私有/小范围兜底；不要公开镜像客户端、不要收费、不要做公开镜像站。
- 仅链官方时风险更低；本服务用于官方不可用时的可用性兜底，不宣称合规。
