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
# shellcheck disable=SC2034  # 供 deploy.sh 读取（TEMPLATE 默认值），跨文件可见
DEFAULT_TEMPLATE="${TEMPLATES_DIR}/env.prod"

# compose Profile 模型（ADR-017）：单 profile + 可插拔服务 + 可插拔边缘层。
#   - EDGE：边缘层选择（cloudflare|local|lan|none），由 .env 的 EDGE 决定；
#     compose_cmd 按 EDGE 追加对应 override 文件（compose.edge.<edge>.yaml）。
#   - ENABLE_EASYBOT / ENABLE_MARIADB / ENABLE_STATUS：可选服务开关（true|false），
#     compose_cmd 按启用项追加 --profile <name>。核心 web/daemon 常驻。
#   - 兼容：旧的 COMPOSE_PROFILE=prod|local|lan 由 orzmc.sh / deploy.sh 映射到 EDGE
#     （prod→cloudflare，local→local，lan→lan），旧入口脚本不破坏。
EDGE="${EDGE:-cloudflare}"

# ---- 日志 ---------------------------------------------------------------

info() { printf '[info] %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
die()  { printf '[error] %s\n' "$*" >&2; exit 1; }

# 去掉末尾斜杠，便于路径比较
norm_path() { printf '%s\n' "${1%/}"; }

# ---- 平台检测 -------------------------------------------------------------
# Windows 下 daemon 的实例自挂载卷 target 含驱动器冒号，Docker Compose 无法创建
# （见 ADR-016 / docs/windows-deployment.md §3）：compose 只对「target 含冒号」的
# bind 序列化失败，source 含冒号无碍。因此 Windows 下 daemon 须用 docker run --
# mount 手动创建（结构性必然），其余服务（web/easybot/mariadb/status/边缘层）的
# 卷 target 均无冒号，本可由 compose 管理。三平台统一：macOS/Linux 全 compose；
# Windows 下脚本自动生成 daemon 的 docker run 命令 + 补网络别名 + 转原生路径，
# 用户命令与 macOS/Linux 完全一致。
detect_os() {
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) printf '%s\n' "windows" ;;
        *) printf '%s\n' "posix" ;;
    esac
}
is_windows() { [ "$(detect_os)" = "windows" ]; }

# MSYS/原生路径 → Windows 原生正斜杠形式（docker 用）：C:/...、E:/...
win_path() {
    local p="$1"
    case "$p" in
        [A-Za-z]:*) printf '%s\n' "${p//\\//}" ;;   # 已是原生（E:\ 或 E:/），统一正斜杠
        /*) printf '%s\n' "$(cygpath -m "$p" 2>/dev/null || printf '%s' "$p")" ;;
        *) printf '%s\n' "${p//\\//}" ;;
    esac
}

# ---- 边缘层与可选服务（ADR-017）-------------------------------------------
# EDGE 归一：把兼容的旧 COMPOSE_PROFILE(prod/local/lan) 映射到新 EDGE；EDGE 本身
# 已是 cloudflare|local|lan|none 时原样。优先显式 EDGE（.env 新配置），否则读
# COMPOSE_PROFILE（旧入口脚本仍设置它）。
normalize_edge() {
    local e="${EDGE:-${COMPOSE_PROFILE:-cloudflare}}"
    case "$e" in
        prod) printf '%s\n' "cloudflare" ;;
        local|lan|cloudflare|none) printf '%s\n' "$e" ;;
        *) die "未知 EDGE: ${e}（可选 cloudflare|local|lan|none）" ;;
    esac
}

# 当前 EDGE 对应的边缘层 override 文件（无则空——EDGE=none）
edge_override_file() {
    local e
    e="$(normalize_edge)"
    case "$e" in
        cloudflare) printf '%s\n' "${COMPOSE_FILE%.yaml}.edge.cloudflare.yaml" ;;
        local)      printf '%s\n' "${COMPOSE_FILE%.yaml}.edge.local.yaml" ;;
        lan)        printf '%s\n' "${COMPOSE_FILE%.yaml}.edge.lan.yaml" ;;
        none)       return 0 ;;
    esac
}

# 按 ENABLE_* 输出应启用的可选服务 profile 列表（换行分隔；读 .env）
# easybot/mariadb/status 的 ENABLE_* 缺省为 true（保持历史默认全部启用）。
# 注意：各判断独立 if（避免 set -e 下最后的 [ false ] 返回非零导致函数退出）。
enabled_profiles() {
    local eb md st
    eb="$(read_env_value ENABLE_EASYBOT)";  [ -n "$eb" ] || eb="true"
    md="$(read_env_value ENABLE_MARIADB)";  [ -n "$md" ] || md="true"
    st="$(read_env_value ENABLE_STATUS)";   [ -n "$st" ] || st="true"
    if [ "$eb" = "true" ]; then printf '%s\n' "easybot"; fi
    if [ "$md" = "true" ]; then printf '%s\n' "mariadb"; fi
    if [ "$st" = "true" ]; then printf '%s\n' "status"; fi
}

# 读 compose.yaml 中 mcsmanager-daemon 的 image（含 digest）。awk：进入 daemon 服务
# 块后取首个 image: 行，遇到下一个 2 空格缩进的服务名即退出。不依赖 python/yq。
daemon_image() {
    awk '/^  mcsmanager-daemon:/{d=1; next}
         d && /^  [a-zA-Z]/{d=0}
         d && /image:/{sub(/^.*image:[[:space:]]*/,""); gsub(/[[:space:]]/,""); print; exit}' "$COMPOSE_FILE"
}

# ---- 状态页（Gatus）健康检查等平台无关路径 ---------------------------------

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
    local file
    file="$(env_file)"
    if [ -f "$file" ]; then
        info "env 已存在: $file"
        return 0
    fi
    # shellcheck disable=SC2153  # TEMPLATE 为调用方（deploy.sh/local.sh/lan.sh）设置的全局
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
    local target mcs_base easy_base node_link mcs_endpoint="" easy_endpoint="" tls_insecure \
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
    case "$(normalize_edge)" in
        local)
            https_port="$(read_env_value PROXY_HTTPS_PORT)"
            [ -n "$https_port" ] || die "EDGE=local 缺少 PROXY_HTTPS_PORT（status 链接生成需要）"
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
            [ -n "$lan_ip" ] || die "EDGE=lan 缺少 LAN_HOST_IP（status 链接生成需要）"
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

# ---- Windows daemon 生命周期（结构性 docker run）---------------------------
# 仅 Windows 需要：daemon 的实例自挂载卷 target 含驱动器冒号，Docker Compose
# 无法创建（ADR-016）。macOS/Linux 走 compose（compose.yaml 里 daemon 服务定义
# 照旧），Windows 走本组函数手动 docker run。容器名/网络与 compose 定义一致。
daemon_container() { printf '%s\n' "orzmc-mcsmanager-daemon"; }

# 补服务名别名：compose 创建的容器自动有服务名别名，docker run 手动创建的无；
# 面板/状态页按 mcsmanager-daemon 解析失败时需补。仅当别名缺失时才操作，且
# docker network connect --alias 无法在容器已连接时更新别名（报 endpoint already
# exists），须先 disconnect 再 connect --alias（ADR-015 §4 同款做法）。仅作用于
# 别名缺失的容器（如新 docker-run 的 daemon），不影响已就绪的 daemon。
win_daemon_alias() {
    local network="orzmc_default"
    local c
    c="$(daemon_container)"
    # 别名已就绪则无操作
    if docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$v.Aliases}}{{end}}' "$c" 2>/dev/null | grep -q 'mcsmanager-daemon'; then
        return 0
    fi
    if docker inspect "$c" >/dev/null 2>&1; then
        docker network disconnect "$network" "$c" 2>/dev/null || true
        docker network connect --alias mcsmanager-daemon "$network" "$c" 2>/dev/null || true
    fi
}

# 创建 daemon（幂等：已存在则跳过并补别名）。实例自挂载 target 按容器内实际
# 相对路径落点：daemon 工作目录固定 /opt/mcsmanager/daemon，Windows 实例 cwd
# = ${DATA_ROOT}/instances/<uuid>（含 E: 非绝对路径）在容器内解析为
# /opt/mcsmanager/daemon/${DATA_ROOT}/instances（见 docs/windows-deployment.md §3）。
win_daemon_run() {
    local root img tz network port=() extra_ports
    root="$(win_path "$DATA_ROOT")"
    img="$(daemon_image)"
    tz="$(read_env_value TZ)"
    network="orzmc_default"
    [ -n "$img" ] || die "无法从 compose.yaml 解析 daemon 镜像"
    if docker inspect "$(daemon_container)" >/dev/null 2>&1; then
        info "daemon 已存在，跳过创建（补别名）"
        win_daemon_alias
        return 0
    fi
    # 确保网络存在（compose up 会创建；首次单独 run 前手动建）
    if ! docker network inspect "$network" >/dev/null 2>&1; then
        docker network create "$network" >/dev/null 2>&1 || true
    fi
    # 进程模式 PaperMC 实例（cwd 在 daemon 内部）的进服端口须由 daemon 容器 -p 暴露。
    # .env 的 DAEMON_PORTS 追加额外映射（逗号分隔 host:container/proto），供玩家进服
    # （Java 25565/tcp、基岩 19132/udp 等）。lan 模式下 daemon API 端口另发。
    extra_ports="$(read_env_value DAEMON_PORTS)"
    if [ -n "$extra_ports" ]; then
        local oldifs="$IFS"
        IFS=','
        # shellcheck disable=SC2206  # 故意按逗号拆分配置项
        for p in $extra_ports; do
            [ -n "$p" ] && port+=(-p "$p")
        done
        IFS="$oldifs"
    fi
    if [ "$(normalize_edge)" = "lan" ]; then
        port+=(-p "${LAN_MCS_DAEMON_PORT:-24444}:${MCS_DAEMON_PORT:-24444}")
    fi
    docker run -d --name "$(daemon_container)" \
        --restart unless-stopped \
        --env "MCSM_DOCKER_WORKSPACE_PATH=${root}/instances" \
        --env "TZ=${tz}" \
        --mount "type=bind,source=${root}/mcsmanager/daemon/data,target=/opt/mcsmanager/daemon/data" \
        --mount "type=bind,source=${root}/mcsmanager/daemon/logs,target=/opt/mcsmanager/daemon/logs" \
        --mount "type=bind,source=${root}/instances,target=/opt/mcsmanager/daemon/${root}/instances" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        "${port[@]}" \
        --network "$network" \
        "$img" >/dev/null
    info "daemon 已通过 docker run 创建（Windows 专用路径）"
    win_daemon_alias
}

win_daemon_rm() {
    docker rm -f "$(daemon_container)" 2>/dev/null || true
}

# ---- compose 统一入口 ----------------------------------------------------
# compose v2：--env-file 是替换而非叠加项目根 .env，必须显式传入且为真实普通文件。
# Profile 模型（ADR-017）：单 profile + 可插拔服务 + 可插拔边缘层。
#   - -f 集合：compose.yaml（核心+可选服务定义）+ 按 EDGE 追加 compose.edge.<edge>.yaml。
#   - --profile：按 ENABLE_* 追加可启用的可选服务（easybot/mariadb/status）；核心
#     web/daemon 无 profile 常驻。EDGE 决定边缘层 override，与 --profile 无关。
# Windows 适配（ADR-016）：daemon 实例自挂载 target 含驱动器冒号，compose 无法
# 创建。up 时用 --no-deps + 显式列出非 daemon 服务让 compose 跳过 daemon，再走
# win_daemon_run docker run；down 先 rm daemon 再 compose down；status 补一行
# daemon 状态。macOS/Linux 走原生 compose 全流程。其余命令（config/exec/validate
# 等）在 Windows 下同样透传 compose。
compose_cmd() {
    local file edge
    local -a extra=() profiles_flags=() base=()
    file="$(env_file)"
    [ -f "$file" ] || die "缺少 ${file}，请先执行 init"
    edge="$(normalize_edge)"
    case "$edge" in
        local)
            [ -f "$DATA_ROOT/caddy/Caddyfile" ] || die "缺少 Caddyfile，请先执行 init"
            extra=(-f "$(edge_override_file)")
            ;;
        cloudflare)
            [ -f "$DATA_ROOT/cloudflared/config.yml" ] || die "缺少 cloudflared/config.yml，请先执行 init 并配置 CLOUDFLARE_TUNNEL_ID"
            extra=(-f "$(edge_override_file)")
            ;;
        lan)
            # 无边缘层：追加 compose.edge.lan.yaml 给 4 个源站发布宿主端口（纯 HTTP，局域网）
            extra=(-f "$(edge_override_file)")
            ;;
        none)
            # EDGE=none：仅内网 orzmc_default，不追加边缘层 override
            extra=()
            ;;
    esac
    while IFS= read -r p; do
        [ -n "$p" ] && profiles_flags+=("--profile" "$p")
    done < <(enabled_profiles)
    # posix（macOS/Linux）：base 用原生路径 + 边缘层 override + ENABLE_* profile
    base=(docker compose --env-file "$file" -f "$COMPOSE_FILE" "${extra[@]}" "${profiles_flags[@]}")
    # Windows：COMPOSE_FILE / override / env-file 是 MSYS 路径（/c/...），docker compose
    # 无法解析（会转成 C:\c\...）。须转 Windows 原生正斜杠路径（docs/windows-deployment.md §7）。
    if is_windows; then
        file="$(win_path "$file")"
        local -a extra_win=()
        for f in "${extra[@]}"; do
            [ "$f" = "-f" ] && continue
            extra_win+=(-f "$(win_path "$f")")
        done
        base=(docker compose --env-file "$file" -f "$(win_path "$COMPOSE_FILE")" "${extra_win[@]}" "${profiles_flags[@]}")
    fi

    # ---- Windows：daemon 不走 compose（结构性 docker run）----
    if is_windows; then
        case "$1" in
            up)
                # 仅全量 up -d 时接管 daemon；指定服务 up（如 backup 的 up -d
                # mariadb，$#=3）仍交 compose 原样处理。
                if [ "${2:-}" = "-d" ] && [ "$#" -eq 2 ]; then
                    local -a svcs=()
                    # 列出当前 EDGE+ENABLE 下全部 compose 服务，剔除 daemon
                    mapfile -t svcs < <("${base[@]}" config --services 2>/dev/null | grep -v '^mcsmanager-daemon$')
                    "${base[@]}" up -d --no-deps "${svcs[@]}"
                    win_daemon_run
                    return 0
                fi
                ;;
            down)
                win_daemon_rm
                "${base[@]}" down --remove-orphans
                return 0
                ;;
            status|ps)
                # 仅裸 ps/status 时补 daemon 行；ps -q/ps <svc> 等带参数透传
                if [ "$#" -eq 1 ]; then
                    "${base[@]}" "$@"
                    printf '  %-24s %s\n' "daemon(docker-run)" \
                        "$(docker inspect -f '{{.State.Status}}' "$(daemon_container)" 2>/dev/null || echo "absent")"
                    return 0
                fi
                ;;
        esac
    fi

    "${base[@]}" "$@"
}

# ---- 校验 ---------------------------------------------------------------

# 必需变量按 EDGE + ENABLE_* 动态组装：
#   - 基础（所有 EDGE 都要求）：web/daemon 端口 + 可选服务各自的必备项。
#   - 可选服务（easybot/mariadb/status）仅当 ENABLE_*=true 时要求其变量。
#   - 边缘层变量按 EDGE 追加（cloudflare→CLOUDFLARE_TUNNEL_ID+DOMAIN；local→CADDY+
#     PROXY；lan→LAN_HOST_IP+LAN_*_PORT；none→无）。
# QQ 凭据由 easybot 服务消费，仅 easybot 启用时必填。
required_env_list() {
    local eb md st edge
    eb="$(read_env_value ENABLE_EASYBOT)"; [ -n "$eb" ] || eb="true"
    md="$(read_env_value ENABLE_MARIADB)"; [ -n "$md" ] || md="true"
    st="$(read_env_value ENABLE_STATUS)";  [ -n "$st" ] || st="true"
    edge="$(normalize_edge)"
    printf '%s\n' TZ MCS_WEB_PORT MCS_DAEMON_PORT
    [ "$st" = "true" ] && printf '%s\n' STATUS_PORT
    if [ "$eb" = "true" ]; then
        printf '%s\n' EASYBOT_PORT EASYBOT_ADMIN_PASSWORD QQBOT_APP_ID QQBOT_CLIENT_SECRET
    fi
    if [ "$md" = "true" ]; then
        printf '%s\n' MARIADB_ROOT_PASSWORD MARIADB_DATABASE MARIADB_USER MARIADB_PASSWORD
    fi
    case "$edge" in
        cloudflare)
            printf '%s\n' CLOUDFLARE_TUNNEL_ID DOMAIN_MCS_WEB DOMAIN_EASY_ADMIN DOMAIN_MCS_NODE DOMAIN_STATUS
            ;;
        local)
            printf '%s\n' CADDY_EMAIL PROXY_HTTP_PORT PROXY_HTTPS_PORT \
                DOMAIN_MCS_WEB DOMAIN_EASY_ADMIN DOMAIN_MCS_NODE DOMAIN_STATUS
            ;;
        lan)
            printf '%s\n' LAN_HOST_IP LAN_MCS_WEB_PORT LAN_EASYBOT_PORT LAN_STATUS_PORT LAN_MCS_DAEMON_PORT
            ;;
    esac
}

validate_required_env() {
    local k v list
    mapfile -t list < <(required_env_list)
    for k in "${list[@]}"; do
        v="$(read_env_value "$k")"
        [ -n "$v" ] || die "env 缺少必需变量: ${k}（请编辑 $(env_file)）"
    done
}

# ---- 访问地址 -----------------------------------------------------------

print_access_info() {
    local mcs_web easy_admin status_domain edge
    mcs_web="$(read_env_value DOMAIN_MCS_WEB)"
    easy_admin="$(read_env_value DOMAIN_EASY_ADMIN)"
    status_domain="$(read_env_value DOMAIN_STATUS)"
    edge="$(normalize_edge)"
    echo "访问地址（EDGE: ${edge}）:"
    case "$edge" in
        cloudflare)
            # cloudflare：Cloudflare 边缘终止 TLS，标准 443，无端口后缀
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
        local)
            # local：Caddy 本地 CA，.localhost + 非特权端口
            echo "  MCSManager Web: https://${mcs_web}:$(read_env_value PROXY_HTTPS_PORT)"
            echo "  EasyBot 管理后台: https://${easy_admin}:$(read_env_value PROXY_HTTPS_PORT)"
            echo "  统一状态页: https://${status_domain}:$(read_env_value PROXY_HTTPS_PORT)"
            ;;
        none)
            # none：仅内网 orzmc_default，无对外入口；打印内网地址提示
            echo "  内网访问（orzmc_default，无边缘层）:"
            echo "  MCSManager Web: http://mcsmanager-web:$(read_env_value MCS_WEB_PORT)"
            echo "  EasyBot 管理后台: http://easybot:$(read_env_value EASYBOT_PORT)"
            echo "  统一状态页: http://status:$(read_env_value STATUS_PORT)"
            ;;
    esac
}
