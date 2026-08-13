#!/usr/bin/env bash
# ===========================================================================
# OrzMC 生产部署入口
#
# 用法:
#   deploy.sh [-d DATA_ROOT] [-t TEMPLATE] init
#   deploy.sh [-d DATA_ROOT] up
#   deploy.sh [-d DATA_ROOT] stop
#   deploy.sh [-d DATA_ROOT] status
#   deploy.sh [-d DATA_ROOT] validate
#   deploy.sh [-d DATA_ROOT] templates [--diff|--force]
#   deploy.sh print-root
#
# DATA_ROOT 优先级：-d/--data-root 参数 > ORZMC_DATA_ROOT 环境变量 > 默认 /srv/orzmc
# 全部 compose 调用统一走 lib/common.sh 的 compose_cmd（显式 --env-file）。
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DATA_ROOT="$(resolve_data_root)"
TEMPLATE="$DEFAULT_TEMPLATE"

usage() {
    cat <<'EOF'
用法:
  deploy.sh [-d DATA_ROOT] [-t TEMPLATE] init          # 建目录树 + 生成 .env + 复制 Caddyfile
  deploy.sh [-d DATA_ROOT] up                          # init + compose up -d
  deploy.sh [-d DATA_ROOT] stop                        # compose down --remove-orphans
  deploy.sh [-d DATA_ROOT] status                      # 访问地址 + compose ps
  deploy.sh [-d DATA_ROOT] validate                    # 必需变量检查 + compose config -q
  deploy.sh [-d DATA_ROOT] templates [--diff|--force]  # Caddyfile 模板同步
  deploy.sh print-root                                 # 打印解析后的 DATA_ROOT
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
        -t|--template)
            [ "$#" -ge 2 ] || die "$1 需要一个参数"
            TEMPLATE="$2"
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

export DATA_ROOT   # 确保 compose 替换使用与脚本一致的值（shell env 优先于 --env-file）
[ "$#" -ge 1 ] || { usage; exit 1; }
CMD="$1"; shift

# ---- 命令实现 -------------------------------------------------------------

cmd_init() {
    ensure_env_file
    ensure_caddyfile
    ensure_data_dirs
    info "初始化完成，DATA_ROOT=$DATA_ROOT"
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

cmd_templates() {
    local src="$TEMPLATES_DIR/Caddyfile" target="$DATA_ROOT/caddy/Caddyfile" mode="diff"
    [ -f "$src" ] || die "模板不存在: $src"
    for a in "$@"; do
        case "$a" in
            --diff) mode="diff" ;;
            --force) mode="force" ;;
            *) die "未知参数: $a" ;;
        esac
    done
    if [ ! -f "$target" ]; then
        warn "目标 $target 不存在，执行: deploy.sh init"
        exit 1
    fi
    if diff -u "$target" "$src" >/dev/null 2>&1; then
        info "模板与已落盘文件一致，无需同步: $target"
        return 0
    fi
    case "$mode" in
        diff)
            echo "以下为模板与已落盘文件的差异（覆盖需加 --force）:"
            diff -u "$target" "$src" || true
            ;;
        force)
            cp "$target" "${target}.bak.$(date +%Y%m%d-%H%M%S)"
            cp "$src" "$target"
            info "已覆盖 ${target}（原文件已备份）"
            warn "Caddy 不会自动热加载 bind 挂载的 Caddyfile，请执行: deploy.sh stop && deploy.sh up"
            ;;
    esac
}

# ---- 分发 ---------------------------------------------------------------

case "$CMD" in
    init)      cmd_init ;;
    up)        cmd_up ;;
    stop|down) cmd_stop ;;
    status|ps) cmd_status ;;
    validate|config) cmd_validate ;;
    templates) cmd_templates "$@" ;;
    print-root) echo "$DATA_ROOT" ;;
    *) usage; exit 1 ;;
esac
