#!/usr/bin/env bash
# ===========================================================================
# OrzMC 数据备份
#
# 用法: backup.sh [-d DATA_ROOT] [-o BACKUP_DIR] [--stop] [--keep N]
#
# 打包整个 $DATA_ROOT（含 .env 与 Caddyfile），归档默认放在 DATA_ROOT 之外
# 的 $(dirname $DATA_ROOT)/orzmc-backups，避免自我包含。
#
# 默认在线打包（best-effort，可能产生不一致快照）；
# --stop 会先停 compose 服务再打包再拉起，但 MCSManager 管理的 PaperMC 实例
# 不属于 compose，如需完全一致的快照请先在 MCSManager 面板停止实例。
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DATA_ROOT="$(resolve_data_root)"
BACKUP_DIR=""
STOP=0
KEEP=""

usage() {
    echo "用法: backup.sh [-d DATA_ROOT] [-o BACKUP_DIR] [--stop] [--keep N]" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -d|--data-root) [ "$#" -ge 2 ] || usage; DATA_ROOT="$(norm_path "$2")"; shift 2 ;;
        -o|--output-dir) [ "$#" -ge 2 ] || usage; BACKUP_DIR="$(norm_path "$2")"; shift 2 ;;
        --stop) STOP=1; shift ;;
        --keep) [ "$#" -ge 2 ] || usage; KEEP="$2"; shift 2 ;;
        *) usage ;;
    esac
done

export DATA_ROOT
[ -z "$BACKUP_DIR" ] && BACKUP_DIR="$(norm_path "${DATA_ROOT%/*}/orzmc-backups")"

# 安全断言
[ "$BACKUP_DIR" != "$DATA_ROOT" ] || die "备份目录不能与 DATA_ROOT 相同: $BACKUP_DIR"
[ -d "$DATA_ROOT" ] || die "DATA_ROOT 不存在: ${DATA_ROOT}（请先 init）"

mkdir -p "$BACKUP_DIR"
archive="$BACKUP_DIR/orzmc-backup-$(date +%Y%m%d-%H%M%S).tar.gz"

# 停服快照（仅 compose 服务；PaperMC 实例需面板手动停止）
if [ "$STOP" = 1 ]; then
    if [ -f "$(env_file)" ]; then
        warn "停止 compose 服务以获得更一致快照..."
        compose_cmd down --remove-orphans
    else
        warn "未找到 $(env_file)，跳过停服（仅打包现有数据目录）"
    fi
fi

info "打包 $DATA_ROOT -> $archive"
tar -C "$(dirname "$DATA_ROOT")" -czf "$archive" "$(basename "$DATA_ROOT")"

if [ "$STOP" = 1 ] && [ -f "$(env_file)" ]; then
    info "重新拉起 compose 服务..."
    compose_cmd up -d
fi

# 校验归档可读
if tar tzf "$archive" >/dev/null 2>&1; then
    info "备份完成并校验通过: $archive"
else
    die "备份校验失败: $archive"
fi

# 保留最近 N 份
if [ -n "$KEEP" ]; then
    mapfile -t old < <(ls -1t "$BACKUP_DIR"/orzmc-backup-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)))
    for f in "${old[@]}"; do
        rm -f "$f"
        warn "清理旧备份: $f"
    done
fi
