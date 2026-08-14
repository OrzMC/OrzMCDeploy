#!/usr/bin/env bash
# ===========================================================================
# OrzMC 局域网直连入口（薄封装，固定 lan profile：无 TLS 终止直连模式）
#
# 用法: ./lan.sh init|start|stop|status|backup|validate
#
# 把 DATA_ROOT 固定为仓库下的 .local-data-lan，模板固定为 templates/env.lan，
# PROFILE 固定为 lan（无 Caddy / cloudflared 边缘层，4 个源站直接发布宿主端口，
# 纯 HTTP）。委托给 deploy.sh / backup.sh。
#
# ⚠️ 与 local / prod 同机互斥：共用 compose 项目名 orzmc 与容器名，一次只能跑
# 一个；切换 profile 需先 stop（否则 profile 专属容器会残留、互相顶替）。
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
DATA_ROOT="${SCRIPT_DIR}/.local-data-lan"
TEMPLATE="${SCRIPT_DIR}/templates/env.lan"
BACKUP_DIR="${SCRIPT_DIR}/.local-backups"

case "${1:-}" in
    init)     exec "${SCRIPT_DIR}/deploy.sh" -d "$DATA_ROOT" -t "$TEMPLATE" -p lan init ;;
    start)    exec "${SCRIPT_DIR}/deploy.sh" -d "$DATA_ROOT" -t "$TEMPLATE" -p lan up ;;
    stop)     exec "${SCRIPT_DIR}/deploy.sh" -d "$DATA_ROOT" -p lan stop ;;
    status)   exec "${SCRIPT_DIR}/deploy.sh" -d "$DATA_ROOT" -p lan status ;;
    validate) exec "${SCRIPT_DIR}/deploy.sh" -d "$DATA_ROOT" -p lan validate ;;
    backup)   shift; exec "${SCRIPT_DIR}/backup.sh" -d "$DATA_ROOT" -o "$BACKUP_DIR" -p lan "$@" ;;
    *)
        echo "用法: ./lan.sh init|start|stop|status|backup|validate" >&2
        exit 1
        ;;
esac
