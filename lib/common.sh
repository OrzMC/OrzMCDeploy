#!/usr/bin/env bash
# ===========================================================================
# OrzMC deploy 共享函数库
#
# 架构原则：仓库只承载"运行时"，全部配置与数据落在 $DATA_ROOT（统一目录）。
# 双 Profile：local=Caddy(.localhost 反代) / prod=cloudflared(Cloudflare Tunnel)。
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

# compose 双 Profile：local=Caddy(.localhost) / prod=cloudflared(Cloudflare Tunnel)
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

# prod profile 专用：由 templates/cloudflared-config.yml 用 .env 的
# CLOUDFLARE_TUNNEL_ID / DOMAIN_MCS_WEB / DOMAIN_EASY_ADMIN / DOMAIN_MCS_NODE
# 替换占位符，生成 $DATA_ROOT/cloudflared/config.yml。仅当 CLOUDFLARE_TUNNEL_ID
# 已填写时生成；与当前 .env 一致时不动（已落盘 config 属运行数据），不一致时
# 覆盖并留备份（config.yml 完全由 .env 派生，.env 为唯一事实源）。
ensure_cloudflared_config() {
    local tid mcs_domain easy_domain node_domain target tmp
    tid="$(read_env_value CLOUDFLARE_TUNNEL_ID)"
    [ -n "$tid" ] || { warn "CLOUDFLARE_TUNNEL_ID 未设置，跳过 cloudflared config 生成"; return 0; }
    mcs_domain="$(read_env_value DOMAIN_MCS_WEB)"
    easy_domain="$(read_env_value DOMAIN_EASY_ADMIN)"
    node_domain="$(read_env_value DOMAIN_MCS_NODE)"
    mkdir -p "$DATA_ROOT/cloudflared"
    target="$DATA_ROOT/cloudflared/config.yml"
    tmp="$(mktemp)"
    sed -e "s#__CLOUDFLARE_TUNNEL_ID__#${tid}#g" \
        -e "s#__DOMAIN_MCS_WEB__#${mcs_domain}#g" \
        -e "s#__DOMAIN_EASY_ADMIN__#${easy_domain}#g" \
        -e "s#__DOMAIN_MCS_NODE__#${node_domain}#g" \
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
}

# ---- compose 统一入口 ----------------------------------------------------
# compose v2：--env-file 是替换而非叠加项目根 .env，必须显式传入且为真实普通文件；
# --profile 按 COMPOSE_PROFILE 选择边缘层（local=caddy / prod=cloudflared）。
compose_cmd() {
    local file profile="${COMPOSE_PROFILE:-prod}"
    file="$(env_file)"
    [ -f "$file" ] || die "缺少 ${file}，请先执行 init"
    case "$profile" in
        local)
            [ -f "$DATA_ROOT/caddy/Caddyfile" ] || die "缺少 Caddyfile，请先执行 init"
            ;;
        prod)
            [ -f "$DATA_ROOT/cloudflared/config.yml" ] || die "缺少 cloudflared/config.yml，请先执行 init 并配置 CLOUDFLARE_TUNNEL_ID"
            ;;
        *) die "未知 profile: ${profile}（可选 prod|local）" ;;
    esac
    docker compose --env-file "$file" -f "$COMPOSE_FILE" --profile "$profile" "$@"
}

# ---- 校验 ---------------------------------------------------------------

# 按 profile 区分的必需变量（QQBOT_APP_ID/CLIENT_SECRET 被 easybot 服务消费）
# prod：cloudflared 入口，无 Caddy；插件 API 仅内网，无 DOMAIN_EASY_API。
# DOMAIN_MCS_NODE：daemon 浏览器直连入口（MCSManager 连接模型，密钥鉴权）。
REQUIRED_ENV_VARS_PROD=(
    TZ
    CLOUDFLARE_TUNNEL_ID
    DOMAIN_MCS_WEB DOMAIN_EASY_ADMIN DOMAIN_MCS_NODE
    EASYBOT_PORT EASYBOT_ADMIN_PASSWORD
    MCS_WEB_PORT MCS_DAEMON_PORT
    QQBOT_APP_ID QQBOT_CLIENT_SECRET
)

# local：Caddy 入口
REQUIRED_ENV_VARS_LOCAL=(
    TZ CADDY_EMAIL
    PROXY_HTTP_PORT PROXY_HTTPS_PORT
    DOMAIN_MCS_WEB DOMAIN_EASY_ADMIN DOMAIN_MCS_NODE
    EASYBOT_PORT EASYBOT_ADMIN_PASSWORD
    MCS_WEB_PORT MCS_DAEMON_PORT
    QQBOT_APP_ID QQBOT_CLIENT_SECRET
)

validate_required_env() {
    local k v list
    case "${COMPOSE_PROFILE:-prod}" in
        local) list=("${REQUIRED_ENV_VARS_LOCAL[@]}") ;;
        prod)  list=("${REQUIRED_ENV_VARS_PROD[@]}") ;;
        *) die "未知 profile: ${COMPOSE_PROFILE}（可选 prod|local）" ;;
    esac
    for k in "${list[@]}"; do
        v="$(read_env_value "$k")"
        [ -n "$v" ] || die "env 缺少必需变量: ${k}（请编辑 $(env_file)）"
    done
}

# ---- 访问地址 -----------------------------------------------------------

print_access_info() {
    local mcs_web easy_admin profile
    mcs_web="$(read_env_value DOMAIN_MCS_WEB)"
    easy_admin="$(read_env_value DOMAIN_EASY_ADMIN)"
    profile="${COMPOSE_PROFILE:-prod}"
    echo "访问地址（profile: ${profile}）:"
    if [ "$profile" = "prod" ]; then
        # prod：Cloudflare 边缘终止 TLS，标准 443，无端口后缀
        echo "  MCSManager Web: https://${mcs_web}"
        echo "  EasyBot 管理后台: https://${easy_admin}"
    else
        echo "  MCSManager Web: https://${mcs_web}:$(read_env_value PROXY_HTTPS_PORT)"
        echo "  EasyBot 管理后台: https://${easy_admin}:$(read_env_value PROXY_HTTPS_PORT)"
    fi
}
