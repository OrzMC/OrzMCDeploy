#!/usr/bin/env bash
# ===========================================================================
# OrzMC 本地验证入口（薄封装，固定 local profile）
#
# 用法: ./local.sh init|start|stop|status|validate|backup
#
# 把 DATA_ROOT 固定为仓库下的 .local-data，模板固定为 templates/env.local，
# PROFILE 固定为 local（Caddy + .localhost），委托给 deploy.sh / backup.sh。
# env 与 Caddyfile 落在 .local-data/ 内，与生产使用同一套"运行时/数据分离"机制。
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
DATA_ROOT="${SCRIPT_DIR}/.local-data"
TEMPLATE="${SCRIPT_DIR}/templates/env.local"
BACKUP_DIR="${SCRIPT_DIR}/.local-backups"

case "${1:-}" in
    init)   exec "${SCRIPT_DIR}/deploy.sh" -d "$DATA_ROOT" -t "$TEMPLATE" -p local init ;;
    start)  exec "${SCRIPT_DIR}/deploy.sh" -d "$DATA_ROOT" -t "$TEMPLATE" -p local up ;;
    stop)   exec "${SCRIPT_DIR}/deploy.sh" -d "$DATA_ROOT" -p local stop ;;
    status) exec "${SCRIPT_DIR}/deploy.sh" -d "$DATA_ROOT" -p local status ;;
    validate) exec "${SCRIPT_DIR}/deploy.sh" -d "$DATA_ROOT" -p local validate ;;
    backup) shift; exec "${SCRIPT_DIR}/backup.sh" -d "$DATA_ROOT" -o "$BACKUP_DIR" -p local "$@" ;;
    *)
        echo "用法: ./local.sh init|start|stop|status|validate|backup" >&2
        exit 1
        ;;
esac
