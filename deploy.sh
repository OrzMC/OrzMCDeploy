#!/usr/bin/env bash
# ===========================================================================
# OrzMC 内部命令实现（对外入口是 orzmc.sh，三平台一致）
#
# 用法（一般直接调 orzmc.sh）:
#   deploy.sh [-d DATA_ROOT] init
#   deploy.sh [-d DATA_ROOT] up
#   deploy.sh [-d DATA_ROOT] stop
#   deploy.sh [-d DATA_ROOT] status
#   deploy.sh [-d DATA_ROOT] validate
#   deploy.sh print-root
#
# DATA_ROOT 无默认路径：-d/--data-root 参数 > ORZMC_DATA_ROOT 环境变量，都没有则报错（ADR-033）
# 运行模型见 ADR-027（只有局域网模式）；compose 调用统一走 compose_cmd。
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DATA_ROOT=""
TEMPLATE="$DEFAULT_TEMPLATE"

usage() {
    cat <<'EOF'
用法: deploy.sh [-d DATA_ROOT] init|up|stop|status|validate|print-root
（对外请用 ./orzmc.sh，本脚本是其内部实现）
EOF
}

# ---- 参数解析 -------------------------------------------------------------

while [ "$#" -gt 0 ]; do
    case "$1" in
        -d|--data-root)
            [ "$#" -ge 2 ] || die "$1 需要一个参数"
            DATA_ROOT="$(norm_path "$2")"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            die "未知选项: $1（-e/-p/-t 已随 ADR-027 移除，现只有 -d/--data-root）"
            ;;
        *)
            break
            ;;
    esac
done

[ -n "$DATA_ROOT" ] || DATA_ROOT="$(resolve_data_root)"   # 无默认路径，ADR-033
export DATA_ROOT   # 确保 compose 替换使用与脚本一致的值（shell env 优先于 --env-file）
[ "$#" -ge 1 ] || { usage; exit 1; }
CMD="$1"; shift

# ---- 命令实现 -------------------------------------------------------------

cmd_init() {
    ensure_env_file
    ensure_data_dirs
    ensure_easybot_local_config
    ensure_site_override
    warn_legacy_data_plane
    info "初始化完成，DATA_ROOT=${DATA_ROOT}"
    print_access_info
}

cmd_up() {
    cmd_init
    compose_cmd up -d
    echo "服务已启动"
    print_access_info
}

cmd_stop() {
    compose_cmd down --remove-orphans
    echo "服务已停止并清理容器与网络（数据保留在 ${DATA_ROOT}）"
}

cmd_status() {
    print_access_info
    echo
    echo "容器状态:"
    compose_cmd ps
}

cmd_validate() {
    assert_data_root_matches
    validate_required_env
    compose_cmd config -q
    info "校验通过: env 必需变量齐全，compose config 解析正常"
}

# ---- 分发 ---------------------------------------------------------------

case "$CMD" in
    init)       cmd_init ;;
    up)         cmd_up ;;
    stop)       cmd_stop ;;
    status)     cmd_status ;;
    validate)   cmd_validate ;;
    print-root) echo "$DATA_ROOT" ;;
    *) usage; exit 1 ;;
esac
