#!/usr/bin/env bash
# ===========================================================================
# OrzMC Windows 部署入口（薄封装，三平台统一入口之一）
#
# 用法: ./windows.sh [-d DATA_ROOT] init|start|stop|status|validate|backup
#
# 与 macOS/Linux 完全相同的命令；脚本自动检测平台（lib/common.sh detect_os）：
#   - Windows(Docker Desktop/WSL2)：daemon 走脚本生成的 docker run --mount +
#     自动补网络别名 + 自动转原生路径，其余服务由 compose 管理（ADR-016）。
#   - macOS/Linux：全量 compose 管理（与 deploy.sh 一致）。
# DATA_ROOT 默认取生产盘 E:/orzmc，可用 -d/--data-root 覆盖，或设 ORZMC_DATA_ROOT。
# PROFILE 默认 prod（cloudflared 隧道），用 -p/--profile 覆盖（local/lan）。
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
DATA_ROOT="${ORZMC_DATA_ROOT:-E:/orzmc}"
TEMPLATE="${SCRIPT_DIR}/templates/env.prod"
BACKUP_DIR=""
PROFILE="prod"

# 薄封装只拦截 -d/-p 与子命令，其余（backup 的 --stop/--keep 等）透传
case "${1:-}" in
    -d|--data-root)
        DATA_ROOT="${2:-}"; shift 2 ;;
    -p|--profile)
        PROFILE="${2:-}"; shift 2 ;;
esac

BACKUP_DIR="${DATA_ROOT%/*}/orzmc-backups"

case "${1:-}" in
    init)     exec "${SCRIPT_DIR}/deploy.sh" -d "$DATA_ROOT" -t "$TEMPLATE" -p "$PROFILE" init ;;
    start)    exec "${SCRIPT_DIR}/deploy.sh" -d "$DATA_ROOT" -t "$TEMPLATE" -p "$PROFILE" up ;;
    stop)     exec "${SCRIPT_DIR}/deploy.sh" -d "$DATA_ROOT" -p "$PROFILE" stop ;;
    status)   exec "${SCRIPT_DIR}/deploy.sh" -d "$DATA_ROOT" -p "$PROFILE" status ;;
    validate) exec "${SCRIPT_DIR}/deploy.sh" -d "$DATA_ROOT" -p "$PROFILE" validate ;;
    backup)   shift; exec "${SCRIPT_DIR}/backup.sh" -d "$DATA_ROOT" -o "$BACKUP_DIR" -p "$PROFILE" "$@" ;;
    *)
        echo "用法: ./windows.sh [-d DATA_ROOT] [-p PROFILE] init|start|stop|status|validate|backup" >&2
        echo "  DATA_ROOT 默认 E:/orzmc（可用 -d 或 ORZMC_DATA_ROOT 覆盖）" >&2
        echo "  PROFILE 默认 prod（cloudflared），可选 local/lan" >&2
        exit 1
        ;;
esac
