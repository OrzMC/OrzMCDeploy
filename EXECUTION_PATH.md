# OrzMC 执行路径与门禁

> 本文只保留**当前有效**的执行路径、门禁规则与最近状态记录。
> 历史过程记录（三档验收、隧道排障、MariaDB/状态页演进等）已随对应功能移除，
> 需要时用 `git log -p -- EXECUTION_PATH.md` 查阅。

## 1. 当前基线

| 项 | 值 |
|---|---|
| 运行模式 | **只有局域网模式**（ADR-027）：面板 + EasyBot 发布宿主端口，纯 HTTP |
| 服务 | `mcsmanager-web`、`mcsmanager-daemon`、`easybot`（`ENABLE_EASYBOT=false` 时前两个） |
| 入口 | `http://<LAN_HOST_IP>:<LAN_MCS_WEB_PORT>`（缺省 18090）、`http://<LAN_HOST_IP>:<LAN_EASYBOT_PORT>`（缺省 18091） |
| daemon | 不发布端口（ADR-026）；节点地址固定 `ws://mcsmanager-daemon:24444`，浏览器数据面经面板中转 |
| 数据库 / 状态页 | 不内置（ADR-025）；需要时用 `compose.site.yaml` 站点增量加回 |
| 镜像 | `compose.yaml` digest 锁定；升级走 `update-image-digests.sh` + commit，回滚走 `git revert` |
| 数据 | 全部落 `$DATA_ROOT`（`.env` / `mcsmanager/` / `easybot/` / `compose.site.yaml`） |

## 2. 执行原则

1. **仓库只放运行时**：compose、digest、脚本、模板、文档；配置/数据/密钥一律在 `$DATA_ROOT`。
2. **单一路径**：`./orzmc.sh [-d DATA_ROOT] init|up|stop|status|validate|backup`。
3. **不引入边缘层**：不做隧道/Caddy/域名；对外访问由站点自备（ADR-027）。
4. **改配置只改 `.env`**，站点特有增量只改 `$DATA_ROOT/compose.site.yaml`。
5. **不做容器内自助升级**：面板内置自助升级会偏离 digest 锁定，禁止使用。

## 3. 门禁（CI 与本地一致）

```bash
# 静态
for f in *.sh lib/*.sh tests/*.sh; do bash -n "$f"; done
shellcheck -x --shell=bash *.sh lib/*.sh tests/*.sh
python3 -c "import glob,yaml;[yaml.safe_load(open(f)) for f in glob.glob('templates/*.y*ml')+glob.glob('compose*.yaml')]"

# 配置（不拉镜像、不碰真实 DATA_ROOT）
rm -rf /tmp/orzmc-ci && ./orzmc.sh -d /tmp/orzmc-ci init && ./orzmc.sh -d /tmp/orzmc-ci validate
printf 'ENABLE_EASYBOT=false\n' >> /tmp/orzmc-ci/.env && ./orzmc.sh -d /tmp/orzmc-ci validate

# Windows 分支逻辑（mock uname/docker）
bash tests/windows_ci.sh
```

CI（`.github/workflows/ci.yml`）跑同样三组：`lint` / `validate` / `windows-branch`；
打 `v*` tag 时额外产出 Release tarball（ADR-018）。

## 4. 改动时需同步的位置

| 改动类型 | 必同步 |
|---|---|
| 服务增减 / 端口变更 | `compose.yaml`、`templates/env`、`docs/usage.md`、`README.md`、ADR |
| `.env` 必需变量 | `templates/env`、`lib/common.sh` 的 `required_env_list` |
| 卷 / 网络 | `compose.yaml`、`lib/common.sh` 的 `ensure_data_dirs` |
| 站点增量机制 | `templates/compose.site.yaml`、`lib/common.sh` 的 `collect_site_override_files` |
| 镜像升级 | `compose.yaml`(digest)、`CHANGELOG.md` |
| 安全边界 | `docs/architecture.md`(ADR)、`AGENTS.md` |

## 5. 状态记录

### 2026-10-29 收敛为「只有局域网模式」（ADR-027）+ 此前三轮精简

- **本轮**：删除全部边缘层（cloudflared/Caddy/EDGE 四档）、三份 env 模板合并为
  `templates/env`、删除 `local.sh`/`lan.sh`/`windows.sh` 旧入口；端口发布内联进
  `compose.yaml`（`LAN_*_PORT`）；CI 矩阵从 4 档变 1 档并新增 `LAN_*_PORT` 覆盖用例。
- **前置三轮**（同日）：
  1. 移除 `mariadb` / `status`（ADR-025，实测零使用）→ 容器 6→4；
  2. 全部镜像升级到最新（MCSManager 10.22 含安全修复 / easybot 0.0.43 /
     cloudflared 2026.10.5 / caddy 2.11.7），并修 `update-image-digests.sh` 的
     服务→文件定位缺陷；
  3. daemon 不再对外暴露（ADR-026，面板中转 `dataPlane=proxy`）→ 入口 3→2。
- **Windows**：`DAEMON_PORTS` 为空时 daemon 交给 compose（ADR-029）；WSL 侧 compose
  仍不能创建 `E:/` 绑定，`up` 必须在 Windows 侧执行。
- **验证**：`bash -n` 全过 · `shellcheck` 0 告警 · `init && validate` PASS ·
  默认端口 18090/18091 与自定义 19090/19091 均生效 · `ENABLE_EASYBOT=false` 时只剩
  web/daemon · `tests/windows_ci.sh` 40 项全过。
- **本机运行态**：3 容器 Up（web/daemon/easybot）；面板 `http://192.168.0.33:23333` 200、
  EasyBot `:18091` 200；daemon 端口未发布；防火墙仅保留在用端口规则（其余 `Any`）。

## 6. 待办

- 面板/ EasyBot 对外暴露前：加 TLS 反代或改走 VPN（当前是 HTTP + 口令登录）。
- `EDGE`/`CLOUDFLARE_*`/`DNS_*`/`DOMAIN_*` 已无消费者；旧 `.env` 残留行可清理。
- 实例（PaperMC/Folia）按需在面板启动；进服端口 `25565/25566` 由实例自己发布。

### 2026-10-29 默认限源：三层暴露面收敛（ADR-028）

- **背景**：调试期间宿主机防火墙规则的来源被改成 `Any`；面板/EasyBot 是 HTTP + 口令登录，
  `Any` 等于对同网段（乃至公网映射后）开放登录页。
- **设计**：三层收敛 —— L1 daemon 不发布端口（ADR-026）；L2 `LAN_BIND_ADDR` 控制绑定地址；
  L3 `LAN_CIDR` + `ALLOW_EXTRA_CIDRS` 控制防火墙来源。单层误配不足以造成暴露。
- **落地**：`compose.yaml` 端口改用 `${LAN_BIND_ADDR:-0.0.0.0}`；`templates/env` 新增
  `LAN_BIND_ADDR` / `LAN_CIDR` / `ALLOW_EXTRA_CIDRS`（及可选 `MC_TCP_PORTS` /
  `MC_UDP_PORTS` / `RCON_PORTS`）；新增 `lib/firewall.sh` 与 `./orzmc.sh firewall show|apply`；
  `status` 打印暴露面摘要；新增 `docs/security.md`。
- **本机执行**：`.env` 写入 `LAN_BIND_ADDR=0.0.0.0` / `LAN_CIDR=192.168.0.0/24`；
  防火墙规则重建为 5 组 `OrzMC-*`，来源统一 `192.168.0.0/255.255.255.0`
  （Panel 23333 / EasyBot 18091 / MC-TCP 25565,25566 / MC-UDP 19132 / RCON 25575,25576）。
- **验证**：`init + validate` PASS；`compose config` 的 `host_ip` 随 `LAN_BIND_ADDR`
  在 `0.0.0.0` ↔ `127.0.0.1` 间切换；`bash -n`/`shellcheck` 0 告警。
- **对外暴露**：VPN（推荐）→ TLS 反代（后端绑 127.0.0.1）→ 路由器映射+限源，见 security.md。

### 2026-10-29 站点公网入口落地：Caddy + Let's Encrypt DNS-01

- **需求**：站点自备 `https://mcs.jokerhub.cn` / `https://easybot.jokerhub.cn`（ADR-027 后
  项目本体不带边缘层）。
- **落地**（全部在 `$DATA_ROOT`，不进仓库）：
  - `site/Caddyfile`：两站点各加 `tls { dns cloudflare {$CF_DNS_API_TOKEN} }`，
    反代到 `mcsmanager-web:23333` / `easybot:8080`（同网络，不经宿主端口）。
  - `compose.site.yaml`：新增 `caddy` 服务，镜像 `ghcr.io/caddybuilds/caddy-cloudflare`
    （官方镜像无 DNS provider），digest 锁定；发布 `80/443/18443`。
  - `.env`：`CF_DNS_API_TOKEN`（Zone:DNS:Edit，仅本 zone）。
  - 防火墙：`OrzMC-Web-TLS` = TCP 80/443/18443，来源 Any（唯一对外入口）；
    面板 23333 / EasyBot 18091 仍限 `192.168.0.0/24`。
- **过程**：先试 HTTP-01 / TLS-ALPN-01 均超时（路由器映射当时未生效）→ 改 DNS-01 后
  证书即刻签发（`certificate obtained successfully` ×2，issuer `Let's Encrypt YE1`，
  到期 2027-01-27，ARI 自动续期），随后公网 443 也确认可达。
- **验收**：公网 `mcs` / `easybot` 各 8/8 成功，耗时 0.03–0.12 s；证书严格校验通过；
  `http://114.240.151.88:23333` 从公网仍超时（防火墙生效，面板端口未暴露）。
- **注意**：`$DATA_ROOT/caddy/data` 存证书与 ACME 账号，**务必随数据备份**；
  路由器若日后封 443，只需把外部端口换成 18443（已发布到宿主 443）即可，证书不受影响。

### 2026-10-29 EasyBot 公网入口收口

- `easybot.jokerhub.cn` 经同一 Caddy 反代可用（`/` 200、`/admin` 200、`/api/v1/live` 200）。
- **发现并修复**：Caddy 反代把 EasyBot 的 `/docs`、`/swagger`（开发文档）一并暴露到公网
  → 在 Caddyfile 里无条件 404；局域网改走 `http://<LAN_HOST_IP>:<LAN_EASYBOT_PORT>/docs`
  （已实测 200）。
- **踩坑记录**：容器内 `remote_ip` 被 Docker 改写成网桥网关，无法据此区分局域网/公网，
  所以"只对局域网开放某路径"这类规则不能靠 IP 匹配实现。
- **残留风险（已知可接受）**：EasyBot 插件 API 与管理后台同端口，公网可达但需 API key
  （未鉴权返回 401）。若不需要公网管理 EasyBot，建议不配该域名，只留面板一个公网入口。
