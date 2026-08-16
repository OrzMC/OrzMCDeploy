#!/usr/bin/env bash
# ===========================================================================
# OrzMC 统一部署入口（ADR-017 起唯一入口；三平台一致）
#
# 用法: ./orzmc.sh [-d DATA_ROOT] [-e EDGE] init|up|stop|status|validate|backup|templates
#
# 统一一个入口，EDGE（边缘层）与 ENABLE_*（可选服务）都在 $DATA_ROOT/.env 里配置，
# 无需按 profile 选不同脚本。三平台（macOS/Linux/Windows）命令完全一致；Windows 下
# daemon 自动走脚本生成的 docker run（lib/common.sh detect_os / ADR-016）。
#
# EDGE（边缘层，.env 里 EDGE=...，或 -e 覆盖）:
#   cloudflare  Cloudflare Tunnel（生产；真实 HTTPS）
#   local       Caddy（.localhost 本地 CA；仅本地验证）
#   lan         无边缘层直连（4 源站发宿主端口，纯 HTTP，局域网）
#   none        仅内网 orzmc_default（不对外）
# ENABLE_*（可选服务开关，.env 里，缺省 true）:
#   ENABLE_EASYBOT / ENABLE_MARIADB / ENABLE_STATUS
#   （核心 mcsmanager-web / mcsmanager-daemon 常驻，不随开关变化）
#
# DATA_ROOT 优先级：-d/--data-root 参数 > ORZMC_DATA_ROOT 环境变量 > 平台默认
#   （Windows: E:/orzmc；macOS/Linux: /srv/orzmc）
# 全部 compose 调用统一走 lib/common.sh 的 compose_cmd。
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# 注意：source common.sh 会把 SCRIPT_DIR 覆写为 lib/ 目录，须先保存仓库根
ORZMC_BIN_DIR="$SCRIPT_DIR"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DATA_ROOT="$(resolve_data_root)"
TEMPLATE="$DEFAULT_TEMPLATE"

usage() {
    cat <<'EOF'
用法:
  orzmc.sh [-d DATA_ROOT] [-e EDGE] init          # 建目录树 + 生成 .env + 边缘层配置
  orzmc.sh [-d DATA_ROOT] [-e EDGE] up            # init + compose up -d（启动全平台层）
  orzmc.sh [-d DATA_ROOT] [-e EDGE] stop          # compose down --remove-orphans
  orzmc.sh [-d DATA_ROOT] [-e EDGE] status        # 访问地址 + compose ps
  orzmc.sh [-d DATA_ROOT] [-e EDGE] validate      # 必需变量检查 + compose config -q
  orzmc.sh [-d DATA_ROOT] [-e EDGE] templates [--diff|--force]  # 边缘层配置模板同步
  orzmc.sh print-root                             # 打印解析后的 DATA_ROOT

EDGE（边缘层，默认读 .env 的 EDGE=，否则 cloudflare）: cloudflare|local|lan|none
可选服务开关在 $DATA_ROOT/.env 的 ENABLE_EASYBOT / ENABLE_MARIADB / ENABLE_STATUS。
三平台命令一致；Windows 下 daemon 自动 docker run（ADR-016）。
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -d|--data-root)
            [ "$#" -ge 2 ] || die "$1 需要一个参数"
            DATA_ROOT="$(norm_path "$2")"
            shift 2
            ;;
        -e|--edge)
            [ "$#" -ge 2 ] || die "$1 需要一个参数"
            EDGE="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            die "未知选项: $1"
            ;;
        *)
            break
            ;;
    esac
done

export DATA_ROOT
[ "$#" -ge 1 ] || { usage; exit 1; }
CMD="$1"; shift

# 若 .env 已存在，从其中读取 EDGE / ENABLE_*（未设 -e 时）；-e 已显式给则优先。
if [ -f "$(env_file)" ] && [ -z "${EDGE:-}" ]; then
    v="$(read_env_value EDGE)"
    [ -n "$v" ] && EDGE="$v"
fi
# 校验 EDGE 合法（normalize_edge 对非法值 die；默认 cloudflare）
: "${EDGE:-cloudflare}"
case "$(normalize_edge)" in cloudflare|local|lan|none) ;; esac
# 按 EDGE 选 env 模板（orzmc.sh 不暴露 -t，模板随 EDGE 固定）：
# cloudflare/none→env.prod（含 CLOUDFLARE/DOMAIN 全量；none 只需基础，多填无害）
# local→env.local，lan→env.lan。
case "$(normalize_edge)" in
    local) TEMPLATE="${TEMPLATES_DIR}/env.local" ;;
    lan)   TEMPLATE="${TEMPLATES_DIR}/env.lan" ;;
    *)     TEMPLATE="${TEMPLATES_DIR}/env.prod" ;;
esac

case "$CMD" in
    init)      "${ORZMC_BIN_DIR}/deploy.sh" -d "$DATA_ROOT" -e "$EDGE" -t "$TEMPLATE" init ;;
    up)        "${ORZMC_BIN_DIR}/deploy.sh" -d "$DATA_ROOT" -e "$EDGE" -t "$TEMPLATE" up ;;
    stop)      "${ORZMC_BIN_DIR}/deploy.sh" -d "$DATA_ROOT" -e "$EDGE" stop ;;
    status)    "${ORZMC_BIN_DIR}/deploy.sh" -d "$DATA_ROOT" -e "$EDGE" status ;;
    validate)  "${ORZMC_BIN_DIR}/deploy.sh" -d "$DATA_ROOT" -e "$EDGE" validate ;;
    templates) "${ORZMC_BIN_DIR}/deploy.sh" -d "$DATA_ROOT" -e "$EDGE" templates "$@" ;;
    backup)    "${ORZMC_BIN_DIR}/backup.sh" -d "$DATA_ROOT" -e "$EDGE" "$@" ;;
    print-root) echo "$DATA_ROOT" ;;
    *) usage; exit 1 ;;
esac
