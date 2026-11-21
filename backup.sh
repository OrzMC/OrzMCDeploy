#!/usr/bin/env bash
# ===========================================================================
# OrzMC 数据备份
#
# 用法: backup.sh [-d DATA_ROOT] [-o BACKUP_DIR] [--stop] [--keep N]
#
# 打包整个 $DATA_ROOT（含 .env 等密钥），归档默认放在
# DATA_ROOT 之外的 $(dirname $DATA_ROOT)/orzmc-backups，避免自我包含。
#
# 默认在线打包（best-effort，可能产生不一致快照）；
# --stop 会先停 compose 服务再打包再拉起，但 MCSManager 管理的 PaperMC 实例
# 不属于 compose，如需完全一致的快照请先在 MCSManager 面板停止实例。
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DATA_ROOT=""
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

[ -n "$DATA_ROOT" ] || DATA_ROOT="$(resolve_data_root)"   # 无默认路径，ADR-033
apply_docker_backend
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
# 盘符路径交给 tar 有两个坑（详见 lib/common.sh 的 tar_local / tar_parent_of）：
#   1) `E:/orzmc` 的父目录用 dirname 是 "E:"，tar 当远程主机 → 必须保留斜杠；
#   2) 归档路径 "E:/..." 同样被当 host:path → Windows 下要 --force-local。
TAR_NAME="${DATA_ROOT##*/}"
TAR_PARENT="$(tar_parent_of "$DATA_ROOT")"
# 在线（热）打包时服务端仍在写 world，GNU tar 必然报
#   "file changed as we read it" 并以 exit 1 结束。
# 这不是打包失败，而是「归档里某个文件可能不是最新字节」。历史实现让它撞上
# set -e 直接中止，于是后面的 -tzf 校验与 --keep 清理永不执行（备份目录无限膨胀）。
# 因此：0 = 干净；1 = 容忍（下面用 -tzf 校验兜底，校验不过仍判失败）；
#       >1 = 真失败（文件打不开/磁盘写满等），直接退出。
# 一致性另说：world 撕裂快照是热备份的固有代价；要严格一致请用 --stop，
# 并在面板先停 PaperMC 实例。
tar_rc=0
tar_local -C "$TAR_PARENT" -czf "$archive" "$TAR_NAME" || tar_rc=$?
case "$tar_rc" in
    0) ;;
    1) warn "tar 返回 1：打包期间有文件被改写（运行中的实例目录），继续校验归档" ;;
    *) die "打包失败（tar exit ${tar_rc}）: $archive" ;;
esac

if [ "$STOP" = 1 ] && [ -f "$(env_file)" ]; then
    info "重新拉起 compose 服务..."
    compose_cmd up -d
fi

# 校验归档可读：同样要 --force-local，且必须写 -tzf（带短横线）——
# --force-local 在前面时 GNU tar 不再把裸 "tzf" 当选项束解析。
if tar_local -tzf "$archive" >/dev/null 2>&1; then
    if [ "$tar_rc" = 1 ]; then
        warn "备份完成（热备份：打包期间有文件被改写，校验通过）: $archive"
    else
        info "备份完成并校验通过: $archive"
    fi
else
    die "备份校验失败: $archive"
fi

# 保留最近 N 份
if [ -n "$KEEP" ]; then
    # shellcheck disable=SC2012  # 文件名均为脚本自生成（无空格）；ls -1t 按 mtime 排序
    # 找最近 N 份是有意为之，且跨 GNU/BSD find 可移植（find -printf 仅 GNU 可用）。
    # 不用 mapfile：macOS 自带 bash 3.2 没有该内建。
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        rm -f "$f"
        warn "清理旧备份: $f"
    done < <(ls -1t "$BACKUP_DIR"/orzmc-backup-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) || true)
fi
