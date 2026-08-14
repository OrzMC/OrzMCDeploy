#!/usr/bin/env bash
# ===========================================================================
# OrzMC deploy 共享函数库
#
# 架构原则：仓库只承载"运行时"，全部配置与数据落在 $DATA_ROOT（统一目录）。
# 三 Profile：local=Caddy(.localhost 反代) / prod=cloudflared(Cloudflare Tunnel) /
#            lan=无边缘层直连（compose.lan.yaml 发布源站宿主端口，纯 HTTP，局域网）。
# 本库统一处理：
#   - DATA_ROOT 解析与一致性校验
#   - env 文件（$DATA_ROOT/.env）读写
#   - 数据目录树与边缘层配置引导（Caddyfile / cloudflared config）
#   - docker compose 统一入口（显式 --env-file + --profile）
#
# ⚠️ 本仓库脚本在 macOS 自带 bash 3.2（及 /usr/bin/env bash 解析到 3.2）下运行。
#   bash 3.2 + `set -u` 会把双引号内紧跟全角字符（（ ） ， 。 等）的 `$VAR` 误判为
#   未定义变量并报 `VAR�: unbound variable`。消息字符串里的变量一律写 `${VAR}`，
#   不要用 `$VAR` 直接后接全角标点。此为可移植性约定，勿回退。
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/compose.yaml"
TEMPLATES_DIR="${REPO_ROOT}/templates"
DEFAULT_DATA_ROOT="/srv/orzmc"
DEFAULT_TEMPLATE="${TEMPLATES_DIR}/env.prod"

# compose 三 Profile：local=Caddy(.localhost) / prod=cloudflared(Cloudflare Tunnel) /
# lan=无边缘层直连（compose.lan.yaml 发布宿主端口，纯 HTTP，局域网）
# 可由 deploy.sh / backup.sh / restore.sh 的 -p/--profile 覆盖
COMPOSE_PROFILE="${COMPOSE_PROFILE:-prod}"

# ---- 日志 ---------------------------------------------------------------

info() { printf '[info] %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
die()  { printf '[error] %s\n' "$*" >&2; exit 1; }

# 去掉末尾斜杠，便于路径比较
norm_path() { printf '%s\n' "${1%/}"; }

# ---- DATA_ROOT 解析 ------------------------------------------------------
# 优先级：-d/--data-root 参数（由各脚本解析后赋值）> ORZMC_DATA_ROOT 环境变量 > 默认 /srv/orzmc
resolve_data_root() {
    if [ -n "${ORZMC_DATA_ROOT:-}" ]; then
        printf '%s\n' "$(norm_path "${ORZMC_DATA_ROOT}")"
    else
        printf '%s\n' "$DEFAULT_DATA_ROOT"
    fi
}

env_file() { printf '%s/.env' "$DATA_ROOT"; }

read_env_value() {
    local key="$1" file
    file="$(env_file)"
    [ -f "$file" ] || return 0
    grep "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d '=' -f 2- || true
}

# 校验 env 文件内 DATA_ROOT 与生效值一致（防静默不一致导致卷挂到旧路径）
assert_data_root_matches() {
    local file in_file
    file="$(env_file)"
    [ -f "$file" ] || return 0
    in_file="$(read_env_value DATA_ROOT)"
    [ -z "$in_file" ] && return 0
    if [ "$(norm_path "$in_file")" != "$DATA_ROOT" ]; then
        die "env 内 DATA_ROOT($in_file) 与生效值($DATA_ROOT) 不一致：请修正 $file 或重新 init"
    fi
}

# ---- 目录与文件引导 ------------------------------------------------------

# init 专用：生成 $DATA_ROOT/.env，绝不覆盖已有文件
ensure_env_file() {
    local file template
    file="$(env_file)"
    if [ -f "$file" ]; then
        info "env 已存在: $file"
        return 0
    fi
    [ -f "$TEMPLATE" ] || die "env 模板不存在: $TEMPLATE"
    mkdir -p "$DATA_ROOT"
    if grep -q '^DATA_ROOT=' "$TEMPLATE"; then
        sed "s#^DATA_ROOT=.*#DATA_ROOT=${DATA_ROOT}#" "$TEMPLATE" > "$file"
    else
        cp "$TEMPLATE" "$file"
        printf 'DATA_ROOT=%s\n' "$DATA_ROOT" >> "$file"
    fi
    chmod 600 "$file"   # 含密钥，收紧权限
    info "已生成 env: $file"
}

# 防坑：compose 对不存在的宿主机文件路径会以"目录"方式自动创建，
# Caddy 会把目录当 Caddyfile 挂载而失败。这里强制落成普通文件。
ensure_caddyfile() {
    local target="$DATA_ROOT/caddy/Caddyfile"
    if [ -f "$target" ] && [ ! -d "$target" ]; then
        info "Caddyfile 已存在: $target"
        return 0
    fi
    rm -rf "$target"
    mkdir -p "$(dirname "$target")"
    cp "$TEMPLATES_DIR/Caddyfile" "$target"
    info "已生成 Caddyfile: $target"
}

# EasyBot 本地覆盖（gateway.local.yaml）：由模板生成，绝不覆盖已有文件。
# EasyBot 从 EASYBOT_HOME（容器 /var/lib/easybot = $DATA_ROOT/easybot/data）解析；
# 当前用途为显式禁用微信适配器（个人微信扫码登录无凭据，默认自动启用）。
ensure_easybot_local_config() {
    local target="$DATA_ROOT/easybot/data/gateway.local.yaml"
    if [ -f "$target" ]; then
        info "gateway.local.yaml 已存在: $target"
        return 0
    fi
    mkdir -p "$(dirname "$target")"
    cp "$TEMPLATES_DIR/gateway.local.yaml" "$target"
    info "已生成 gateway.local.yaml: $target"
}

# 统一状态页（Gatus）配置：由 templates/gatus-config.yml 按 profile 替换占位符
# 生成 $DATA_ROOT/status/config.yaml。与 Caddyfile/gateway.local.yaml 一样**绝不
# 覆盖**已有文件（用户可能自行扩展 endpoints/buttons）；改域名后需删除已落盘
# 文件再 init 重新生成。
#   - prod ：__*_BASE__/__MCS_NODE_LINK__ = https://<真实域名>；TLS 校验开启
#   - local：追加 :<PROXY_HTTPS_PORT>（.localhost）；TLS 为 Caddy 本地 CA，
#            status 服务 extra_hosts 把 *.localhost 解析到宿主，校验关闭
#   - lan  ：按钮 base = http://<LAN_HOST_IP>:<LAN_*_PORT>（无边缘层，纯 HTTP，局域网）；
#            健康检查端点 __*_ENDPOINT__ 改用内网 URL——gatus 容器经宿主真实 LAN IP
#            访问发布端口会超时（macOS Docker Desktop 实测，见 ADR-012），内网探测
#            只验证进程存活；__TLS_INSECURE__=false
ensure_status_config() {
    local target mcs_base easy_base node_link mcs_endpoint easy_endpoint tls_insecure \
          status_port https_port lan_ip lan_web lan_eb lan_daemon
    target="$DATA_ROOT/status/config.yaml"
    if [ -f "$target" ]; then
        info "status config 已存在: $target"
        return 0
    fi
    [ -f "$TEMPLATES_DIR/gatus-config.yml" ] || die "模板不存在: $TEMPLATES_DIR/gatus-config.yml"
    mkdir -p "$DATA_ROOT/status"
    mcs_base="https://$(read_env_value DOMAIN_MCS_WEB)"
    easy_base="https://$(read_env_value DOMAIN_EASY_ADMIN)"
    node_link="https://$(read_env_value DOMAIN_MCS_NODE)"
    tls_insecure="false"
    case "${COMPOSE_PROFILE:-prod}" in
        local)
            https_port="$(read_env_value PROXY_HTTPS_PORT)"
            [ -n "$https_port" ] || die "local profile 缺少 PROXY_HTTPS_PORT（status 链接生成需要）"
            mcs_base="${mcs_base}:${https_port}"
            easy_base="${easy_base}:${https_port}"
            node_link="${node_link}:${https_port}"
            tls_insecure="true"
            ;;
        lan)
            # 无边缘层纯 HTTP：按钮链接用宿主发布端口（LAN_*_PORT），面向局域网真机
            # 浏览器；健康检查端点走内网 URL（gatus 容器经 LAN_HOST_IP 访问发布端口
            # 会超时——macOS Docker Desktop 实测容器不可达宿主真实 LAN IP，ADR-012）。
            # daemon 直连入口仅作 daemon API（key 鉴权），浏览器「网页直连」终端不可用（ADR-011）。
            lan_ip="$(read_env_value LAN_HOST_IP)"
            [ -n "$lan_ip" ] || die "lan profile 缺少 LAN_HOST_IP（status 链接生成需要）"
            lan_web="$(read_env_value LAN_MCS_WEB_PORT)";  [ -n "$lan_web" ]  || lan_web="18090"
            lan_eb="$(read_env_value LAN_EASYBOT_PORT)";   [ -n "$lan_eb" ]   || lan_eb="18091"
            lan_daemon="$(read_env_value LAN_MCS_DAEMON_PORT)"; [ -n "$lan_daemon" ] || lan_daemon="24444"
            mcs_base="http://${lan_ip}:${lan_web}"
            easy_base="http://${lan_ip}:${lan_eb}"
            node_link="http://${lan_ip}:${lan_daemon}"
            mcs_endpoint="http://mcsmanager-web:$(read_env_value MCS_WEB_PORT)"
            easy_endpoint="http://easybot:$(read_env_value EASYBOT_PORT)"
            tls_insecure="false"
            ;;
    esac
    # 非 lan 下端点与按钮同源（真实入口，可测可达性）
    [ -n "$mcs_endpoint" ] || mcs_endpoint="$mcs_base"
    [ -n "$easy_endpoint" ] || easy_endpoint="$easy_base"
    status_port="$(read_env_value STATUS_PORT)"
    [ -n "$status_port" ] || status_port="8080"
    sed -e "s#__MCS_WEB_BASE__#${mcs_base}#g" \
        -e "s#__EASY_ADMIN_BASE__#${easy_base}#g" \
        -e "s#__MCS_NODE_LINK__#${node_link}#g" \
        -e "s#__MCS_WEB_ENDPOINT__#${mcs_endpoint}#g" \
        -e "s#__EASY_ADMIN_ENDPOINT__#${easy_endpoint}#g" \
        -e "s#__TLS_INSECURE__#${tls_insecure}#g" \
        -e "s#__STATUS_PORT__#${status_port}#g" \
        "$TEMPLATES_DIR/gatus-config.yml" > "$target"
    info "已生成 status config: $target"
}

# prod profile 专用：由 templates/cloudflared-config.yml 用 .env 的
# CLOUDFLARE_TUNNEL_ID / DOMAIN_MCS_WEB / DOMAIN_EASY_ADMIN / DOMAIN_MCS_NODE
# 替换占位符，生成 $DATA_ROOT/cloudflared/config.yml。仅当 CLOUDFLARE_TUNNEL_ID
# 已填写时生成；与当前 .env 一致时不动（已落盘 config 属运行数据），不一致时
# 覆盖并留备份（config.yml 完全由 .env 派生，.env 为唯一事实源）。
ensure_cloudflared_config() {
    local tid mcs_domain easy_domain node_domain status_domain status_port target tmp
    tid="$(read_env_value CLOUDFLARE_TUNNEL_ID)"
    [ -n "$tid" ] || { warn "CLOUDFLARE_TUNNEL_ID 未设置，跳过 cloudflared config 生成"; return 0; }
    mcs_domain="$(read_env_value DOMAIN_MCS_WEB)"
    easy_domain="$(read_env_value DOMAIN_EASY_ADMIN)"
    node_domain="$(read_env_value DOMAIN_MCS_NODE)"
    status_domain="$(read_env_value DOMAIN_STATUS)"
    status_port="$(read_env_value STATUS_PORT)"
    [ -n "$status_port" ] || status_port="8080"
    mkdir -p "$DATA_ROOT/cloudflared"
    target="$DATA_ROOT/cloudflared/config.yml"
    tmp="$(mktemp)"
    sed -e "s#__CLOUDFLARE_TUNNEL_ID__#${tid}#g" \
        -e "s#__DOMAIN_MCS_WEB__#${mcs_domain}#g" \
        -e "s#__DOMAIN_EASY_ADMIN__#${easy_domain}#g" \
        -e "s#__DOMAIN_MCS_NODE__#${node_domain}#g" \
        -e "s#__DOMAIN_STATUS__#${status_domain}#g" \
        -e "s#__STATUS_PORT__#${status_port}#g" \
        "$TEMPLATES_DIR/cloudflared-config.yml" > "$tmp"
    if [ -f "$target" ] && cmp -s "$target" "$tmp"; then
        info "cloudflared config 已就绪: $target"
        rm -f "$tmp"
        return 0
    fi
    if [ -f "$target" ]; then
        cp "$target" "${target}.bak.$(date +%Y%m%d-%H%M%S)"
        warn "cloudflared config 与 .env 不一致，已备份旧文件并重新生成"
    fi
    mv "$tmp" "$target"
    chmod 600 "$target"   # 含隧道 ID，收紧权限
    info "已生成 cloudflared config: $target"
}

# ---- 应用数据库 MariaDB 支持 ----------------------------------------------
# 平台层常驻服务；数据落 $DATA_ROOT/database/mariadb，backup.sh 用逻辑 dump 保证一致快照。

# .env 里 mariadb root 密码（dump / ping 需要；不输出值）。设置 MARIADB_ROOT_PASSWORD
# 后 root 需密码登录，连接统一走 MYSQL_PWD 环境变量（避免 -p 出现在进程列表）。
db_root_pw() { read_env_value MARIADB_ROOT_PASSWORD; }

# 轮询 mariadb 容器可连接（最多 ~60s）；供 backup.sh --stop 模式拉起后等待
wait_for_mariadb() {
    local i=0 root_pw
    root_pw="$(db_root_pw)"
    while [ "$i" -lt 60 ]; do
        if compose_cmd exec -T -e "MYSQL_PWD=${root_pw}" mariadb mariadb-admin ping >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# 逻辑备份：向 $DATA_ROOT/database/dumps/ 产出 --all-databases 一致快照
# （随整机 tar 归档）。必须在 compose down 之前执行（--stop 模式下容器仍 UP）。
# dump 失败返回非零由调用方（backup.sh）用 || warn 兜底，不中断整机备份。
dump_db_logical() {
    local running dump_file root_pw
    [ -f "$(env_file)" ] || return 0
    mkdir -p "$DATA_ROOT/database/dumps"
    root_pw="$(db_root_pw)"
    running="$(compose_cmd ps -q mariadb 2>/dev/null | head -n1 || true)"
    if [ -z "$running" ]; then
        if [ "${STOP:-0}" = 1 ]; then
            info "mariadb 未运行，先拉起以生成逻辑备份..."
            compose_cmd up -d mariadb || return 1
            wait_for_mariadb || { warn "mariadb 启动超时，跳过逻辑备份"; return 1; }
        else
            warn "mariadb 容器未运行，跳过逻辑备份（归档仅含数据目录）"
            return 0
        fi
    fi
    dump_file="$DATA_ROOT/database/dumps/mariadb-all-$(date +%Y%m%d-%H%M%S).sql"
    if compose_cmd exec -T -e "MYSQL_PWD=${root_pw}" mariadb \
            mariadb-dump --all-databases --single-transaction --routines --triggers \
            > "$dump_file" 2>/dev/null; then
        chmod 600 "$dump_file"   # 含 mysql 系统库（用户/授权），按密钥收紧
        info "已生成 MariaDB 逻辑备份: ${dump_file}"
    else
        rm -f "$dump_file"
        warn "mariadb-dump 失败，归档仅含数据库数据目录"
        return 1
    fi
}

ensure_data_dirs() {
    mkdir -p \
        "$DATA_ROOT/caddy/data" \
        "$DATA_ROOT/caddy/config" \
        "$DATA_ROOT/cloudflared" \
        "$DATA_ROOT/mcsmanager/web/data" \
        "$DATA_ROOT/mcsmanager/web/logs" \
        "$DATA_ROOT/mcsmanager/daemon/data" \
        "$DATA_ROOT/mcsmanager/daemon/logs" \
        "$DATA_ROOT/easybot/data" \
        "$DATA_ROOT/status" \
        "$DATA_ROOT/instances/papermc-main/server" \
        "$DATA_ROOT/instances/papermc-main/backups" \
        "$DATA_ROOT/instances/papermc-test/server" \
        "$DATA_ROOT/instances/papermc-test/backups"
    # easybot 镜像默认以 uid/gid=10001 运行，宿主机数据目录需对其可写。
    # 以 root 执行时 chown（Linux 生产常态）；非 root（如 macOS 本地）降级为告警，
    # 此时依赖 Docker Desktop 文件共享即可正常读写。
    if ! chown 10001:10001 "$DATA_ROOT/easybot/data" 2>/dev/null; then
        warn "非 root 无法 chown easybot 数据目录（10001:10001）；Linux 生产部署请以 root 执行 init"
    fi
    # 应用数据库 MariaDB 数据目录：mariadb 镜像以 uid/gid=999(mysql) 运行；
    # root 下 chown（Linux 生产常态），非 root（如 macOS 本地）降级为告警（依赖 Docker
    # Desktop 文件共享，见 ADR-006）。
    mkdir -p "$DATA_ROOT/database/mariadb"
    if ! chown 999:999 "$DATA_ROOT/database/mariadb" 2>/dev/null; then
        warn "非 root 无法 chown mariadb 数据目录（999:999）；Linux 生产部署请以 root 执行 init"
    fi
}

# ---- compose 统一入口 ----------------------------------------------------
# compose v2：--env-file 是替换而非叠加项目根 .env，必须显式传入且为真实普通文件；
# --profile 按 COMPOSE_PROFILE 选择边缘层（local=caddy / prod=cloudflared /
# lan=无边缘层，追加 compose.lan.yaml 发布源站宿主端口）。
compose_cmd() {
    local file profile="${COMPOSE_PROFILE:-prod}"
    local -a extra=()
    file="$(env_file)"
    [ -f "$file" ] || die "缺少 ${file}，请先执行 init"
    case "$profile" in
        local)
            [ -f "$DATA_ROOT/caddy/Caddyfile" ] || die "缺少 Caddyfile，请先执行 init"
            ;;
        prod)
            [ -f "$DATA_ROOT/cloudflared/config.yml" ] || die "缺少 cloudflared/config.yml，请先执行 init 并配置 CLOUDFLARE_TUNNEL_ID"
            ;;
        lan)
            # 无边缘层：--profile lan 下 reverse-proxy/cloudflared 均不匹配不运行；
            # 追加 compose.lan.yaml 给 4 个源站发布宿主端口（纯 HTTP，局域网）
            extra=(-f "${COMPOSE_FILE%.yaml}.lan.yaml")
            ;;
        *) die "未知 profile: ${profile}（可选 prod|local|lan）" ;;
    esac
    docker compose --env-file "$file" -f "$COMPOSE_FILE" "${extra[@]}" --profile "$profile" "$@"
}

# ---- 校验 ---------------------------------------------------------------

# 按 profile 区分的必需变量（QQBOT_APP_ID/CLIENT_SECRET 被 easybot 服务消费）
# prod：cloudflared 入口，无 Caddy；插件 API 仅内网，无 DOMAIN_EASY_API。
# DOMAIN_MCS_NODE：daemon 浏览器直连入口（MCSManager 连接模型，密钥鉴权）。
# MARIADB_*：应用数据库常驻服务（默认启用），四项均为必需变量。
REQUIRED_ENV_VARS_PROD=(
    TZ
    CLOUDFLARE_TUNNEL_ID
    DOMAIN_MCS_WEB DOMAIN_EASY_ADMIN DOMAIN_MCS_NODE DOMAIN_STATUS
    EASYBOT_PORT EASYBOT_ADMIN_PASSWORD
    MCS_WEB_PORT MCS_DAEMON_PORT
    STATUS_PORT
    QQBOT_APP_ID QQBOT_CLIENT_SECRET
    MARIADB_ROOT_PASSWORD MARIADB_DATABASE MARIADB_USER MARIADB_PASSWORD
)

# local：Caddy 入口
REQUIRED_ENV_VARS_LOCAL=(
    TZ CADDY_EMAIL
    PROXY_HTTP_PORT PROXY_HTTPS_PORT
    DOMAIN_MCS_WEB DOMAIN_EASY_ADMIN DOMAIN_MCS_NODE DOMAIN_STATUS
    EASYBOT_PORT EASYBOT_ADMIN_PASSWORD
    MCS_WEB_PORT MCS_DAEMON_PORT
    STATUS_PORT
    QQBOT_APP_ID QQBOT_CLIENT_SECRET
    MARIADB_ROOT_PASSWORD MARIADB_DATABASE MARIADB_USER MARIADB_PASSWORD
)

# lan：无边缘层直连（compose.lan.yaml 发布宿主端口）。无 DOMAIN_*/CLOUDFLARE_TUNNEL_ID/
# CADDY_EMAIL；LAN_HOST_IP 为局域网访问入口（Gatus 按钮与 init 打印用），LAN_*_PORT
# 为宿主发布端口（避开 local Caddy 的 18080/18443 与实例端口 25565/25566）。
REQUIRED_ENV_VARS_LAN=(
    TZ LAN_HOST_IP
    LAN_MCS_WEB_PORT LAN_EASYBOT_PORT LAN_STATUS_PORT LAN_MCS_DAEMON_PORT
    EASYBOT_PORT EASYBOT_ADMIN_PASSWORD
    MCS_WEB_PORT MCS_DAEMON_PORT
    STATUS_PORT
    QQBOT_APP_ID QQBOT_CLIENT_SECRET
    MARIADB_ROOT_PASSWORD MARIADB_DATABASE MARIADB_USER MARIADB_PASSWORD
)

validate_required_env() {
    local k v list
    case "${COMPOSE_PROFILE:-prod}" in
        local) list=("${REQUIRED_ENV_VARS_LOCAL[@]}") ;;
        prod)  list=("${REQUIRED_ENV_VARS_PROD[@]}") ;;
        lan)   list=("${REQUIRED_ENV_VARS_LAN[@]}") ;;
        *) die "未知 profile: ${COMPOSE_PROFILE}（可选 prod|local|lan）" ;;
    esac
    for k in "${list[@]}"; do
        v="$(read_env_value "$k")"
        [ -n "$v" ] || die "env 缺少必需变量: ${k}（请编辑 $(env_file)）"
    done
}

# ---- 访问地址 -----------------------------------------------------------

print_access_info() {
    local mcs_web easy_admin status_domain profile
    mcs_web="$(read_env_value DOMAIN_MCS_WEB)"
    easy_admin="$(read_env_value DOMAIN_EASY_ADMIN)"
    status_domain="$(read_env_value DOMAIN_STATUS)"
    profile="${COMPOSE_PROFILE:-prod}"
    echo "访问地址（profile: ${profile}）:"
    case "$profile" in
        prod)
            # prod：Cloudflare 边缘终止 TLS，标准 443，无端口后缀
            echo "  MCSManager Web: https://${mcs_web}"
            echo "  EasyBot 管理后台: https://${easy_admin}"
            echo "  统一状态页: https://${status_domain}"
            ;;
        lan)
            # lan：无边缘层纯 HTTP，局域网设备用 http://<LAN_HOST_IP>:<LAN_*_PORT>
            echo "  MCSManager Web: http://$(read_env_value LAN_HOST_IP):$(read_env_value LAN_MCS_WEB_PORT)"
            echo "  EasyBot 管理后台: http://$(read_env_value LAN_HOST_IP):$(read_env_value LAN_EASYBOT_PORT)"
            echo "  统一状态页: http://$(read_env_value LAN_HOST_IP):$(read_env_value LAN_STATUS_PORT)"
            echo "  MCSManager Daemon: http://$(read_env_value LAN_HOST_IP):$(read_env_value LAN_MCS_DAEMON_PORT)"
            ;;
        *)
            # local：Caddy 本地 CA，.localhost + 非特权端口
            echo "  MCSManager Web: https://${mcs_web}:$(read_env_value PROXY_HTTPS_PORT)"
            echo "  EasyBot 管理后台: https://${easy_admin}:$(read_env_value PROXY_HTTPS_PORT)"
            echo "  统一状态页: https://${status_domain}:$(read_env_value PROXY_HTTPS_PORT)"
            ;;
    esac
}
