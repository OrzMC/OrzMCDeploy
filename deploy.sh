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
# shellcheck source=lib/eagler.sh
source "${REPO_ROOT}/lib/eagler.sh"   # common.sh 已把 SCRIPT_DIR 改为 lib/，这里用 REPO_ROOT
source "${REPO_ROOT}/lib/site.sh"     # site_parse_routes：probe 依 SITE_ROUTES 逐域探测
# shellcheck source=lib/probe.sh
source "${REPO_ROOT}/lib/probe.sh"

DATA_ROOT=""
TEMPLATE="$DEFAULT_TEMPLATE"

usage() {
    cat <<'EOF'
用法: deploy.sh [-d DATA_ROOT] init|up|stop|status [--probe]|validate|print-root
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
apply_docker_backend
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
    # 前端拓扑（可选，ADR-036）：只建目录，下载/生成放到 up（init 保持离线可用）
    local topo
    topo="$(topology)"
    if [ "$topo" != "java-only" ]; then
        mkdir -p "${DATA_ROOT}/eagler"
        info "前端拓扑=${topo}（Velocity=$(if velocity_enabled; then echo on; else echo off; fi)，Eaglercraft=$(if eagler_enabled; then echo on; else echo off; fi)）：up 时下载运行时并生成配置"
    fi
    info "初始化完成，DATA_ROOT=${DATA_ROOT}"
    print_access_info
}

cmd_up() {
    cmd_init
    eagler_prepare
    compose_cmd up -d
    # EaglerXServer 首次启动才生成 listeners.toml：随后修正为面向反代的配置，
    # 有改动才重启一次代理（首启一次，之后幂等）。
    if eagler_post_up; then
        # ADR-041：velocity 归面板托管后就不再是 compose 服务，直接 restart 会报
        # "no such service: velocity" 并且**配置静默不生效**。这里先探测，探不到就
        # 明确告诉人去面板重启实例。
        if compose_cmd config --services 2>/dev/null | grep -qx 'velocity'; then
            info "重启 velocity 代理以应用配置"
            compose_cmd restart velocity
        else
            warn "Eagler/Geyser 配置已更新：velocity 由面板托管，需要在面板里重启 velocity 实例才生效"
        fi
    fi
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
    case "${1:-}" in
        --probe) probe_all ;;
    esac
}

cmd_validate() {
    assert_data_root_matches
    validate_required_env
    validate_topology
    eagler_runtime_check
    compose_cmd config -q
    info "校验通过: env 必需变量齐全，compose config 解析正常"
}

# ---- 分发 ---------------------------------------------------------------

case "$CMD" in
    init)       cmd_init ;;
    up)         cmd_up ;;
    stop)       cmd_stop ;;
    status)     cmd_status "$@" ;;
    validate)   cmd_validate ;;
    print-root) echo "$DATA_ROOT" ;;
    *) usage; exit 1 ;;
esac
