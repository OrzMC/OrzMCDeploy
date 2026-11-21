#!/usr/bin/env bash
# ===========================================================================
# OrzMC 备份/恢复演练（v0.4.1）
#
# 用法: drill.sh [-d DATA_ROOT] [-o BACKUP_DIR] [归档] [--keep-restore]
#
# 每日备份之后跑一遍，回答的是「这份归档真的能还原吗」，而不是「tar 有没有报错」：
#   1. 取最新归档（或指定归档）
#   2. 还原到 **数据目录之外** 的演练根（绝不碰生产数据）
#   3. 三项核对：条目数 / 关键文件 md5（直接从归档流取，独立于解压路径）/ DATA_ROOT 改写
#   4. 默认删掉还原出来的临时树，只留结论；`--keep-restore` 保留现场排查
#
# 演练根默认与备份同盘相邻：<备份目录的父目录>/orzmc-drills
# （本站 3.9G 归档 → 还原约 5.9G）。磁盘不足会先拒绝，不会把盘写满。
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/common.sh"

DATA_ROOT="${DATA_ROOT:-}"
BACKUP_DIR=""
KEEP_RESTORE=0
ARCHIVE=""
DRILL_FAIL=0

usage() {
    cat <<'EOF'
用法: ./orzmc.sh -d <数据目录> drill [归档] [--keep-restore]

  归档            不给则取备份目录里最新的一份
  --keep-restore  保留还原现场（默认核对完即删）

演练根：<备份目录的父目录>/orzmc-drills（可用 .env 的 DRILL_ROOT 覆盖）
EOF
}

row() {
    local st="$1" label="$2" detail="$3"
    [ "$st" = "fail" ] && DRILL_FAIL=$((DRILL_FAIL + 1))
    printf '  %-8s %-24s %s\n' "[$st]" "$label" "$detail"
}

# 从归档流取单成员 md5（独立于解压结果，是最硬的一致性证据）
archive_md5() {
    tar_local -xzOf "$1" "$2" 2>/dev/null | md5sum | cut -d' ' -f1
}

file_md5() {
    [ -f "$1" ] || { printf '\n'; return 0; }
    md5sum "$1" 2>/dev/null | cut -d' ' -f1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -d|--data-root) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; DATA_ROOT="$(norm_path "$2")"; shift 2 ;;
        -o|--output-dir) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; BACKUP_DIR="$(norm_path "$2")"; shift 2 ;;
        --keep-restore|--keep) KEEP_RESTORE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) die "未知选项: $1" ;;
        *) ARCHIVE="$1"; shift ;;
    esac
done

[ -n "$DATA_ROOT" ] || DATA_ROOT="$(resolve_data_root)"
apply_docker_backend
export DATA_ROOT
[ -n "$BACKUP_DIR" ] || BACKUP_DIR="$(norm_path "${DATA_ROOT%/*}/orzmc-backups")"

if [ -z "$ARCHIVE" ]; then
    # shellcheck disable=SC2012  # 按 mtime 排序只能用 ls
    ARCHIVE="$(ls -1t "${BACKUP_DIR}"/orzmc-backup-*.tar.gz 2>/dev/null | head -1 || true)"
fi
[ -n "$ARCHIVE" ] || die "找不到归档：先跑 ./orzmc.sh -d $DATA_ROOT backup，或显式给归档路径"
[ -f "$ARCHIVE" ] || die "归档不存在: $ARCHIVE"

size_mb="$(du -m "$ARCHIVE" 2>/dev/null | cut -f1 || true)"
info "演练归档: $(basename "$ARCHIVE")（${size_mb:-?} MB）"

DRILL_ROOT="${DRILL_ROOT:-$(read_env_value DRILL_ROOT || true)}"
[ -n "${DRILL_ROOT:-}" ] || DRILL_ROOT="$(norm_path "${BACKUP_DIR%/*}/orzmc-drills")"
ts="$(date +%Y%m%d-%H%M%S)"
TARGET="${DRILL_ROOT}/drill-${ts}/orzmc"

# 空间预检：解压后约为归档的 1.6 倍，按 2 倍保守估
mkdir -p "$DRILL_ROOT" 2>/dev/null || die "无法创建演练根: $DRILL_ROOT"
need_mb=$(( ${size_mb:-1000} * 2 ))
free_mb="$(df -m "$DRILL_ROOT" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
if [ -n "${free_mb:-}" ] && [ "${free_mb:-0}" -lt "$need_mb" ]; then
    die "演练空间不足：需要约 ${need_mb} MB，剩余 ${free_mb} MB"
fi

mkdir -p "$(dirname "$TARGET")"
info "还原到 $TARGET"

t0="$(date +%s)"
if ! bash "${REPO_ROOT}/restore.sh" -d "$TARGET" "$ARCHIVE" --force >/dev/null 2>&1; then
    rm -rf "$(dirname "$TARGET")" 2>/dev/null || true
    die "还原失败（restore.sh 非零退出）；演练目录已清理"
fi
t1="$(date +%s)"
row ok "还原" "耗时 $((t1 - t0))s"

# ---- 核对 1：条目数 ----
n_archive="$(tar_local -tzf "$ARCHIVE" 2>/dev/null | grep -vc '/$' || true)"
n_restored="$(find "$TARGET" -type f 2>/dev/null | wc -l | tr -d ' ')"
# 还原会额外产生 .env.bak-restore，故允许 +1
if [ "${n_restored:-0}" -eq "${n_archive:-1}" ] || [ "${n_restored:-0}" -eq "$(( ${n_archive:-0} + 1 ))" ]; then
    row ok "条目数" "归档 ${n_archive} / 还原 ${n_restored}"
else
    row fail "条目数" "归档 ${n_archive} / 还原 ${n_restored}"
fi

# ---- 核对 2：关键文件 md5（归档流 vs 还原结果）----
members="$(tar_local -tzf "$ARCHIVE" 2>/dev/null \
    | grep -E '/(server\.properties|velocity\.toml|forwarding\.secret|level\.dat|ops\.json|eula\.txt)$' \
    | head -8 || true)"
if [ -z "$members" ]; then
    row fail "关键文件" "归档里找不到任何关键文件（结构可疑）"
else
    checked=0
    bad=0
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        a="$(archive_md5 "$ARCHIVE" "$m")"
        b="$(file_md5 "$TARGET/${m#*/}")"
        checked=$((checked + 1))
        if [ -z "$a" ] || [ "$a" != "$b" ]; then
            bad=$((bad + 1))
            row fail "md5 ${m##*/}" "归档 ${a:-空} / 还原 ${b:-缺失}"
        fi
    done <<EOF
$members
EOF
    [ "$bad" -eq 0 ] && row ok "关键文件 md5" "${checked} 个逐一相同"
fi

# ---- 核对 3：DATA_ROOT 已改写到演练路径 ----
env_dr="$(grep -m1 '^DATA_ROOT=' "$TARGET/.env" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)"
if [ -z "$env_dr" ]; then
    row fail "DATA_ROOT 改写" "还原后的 .env 里没有 DATA_ROOT"
elif [ "$(norm_path "$env_dr")" = "$(norm_path "$TARGET")" ]; then
    row ok "DATA_ROOT 改写" "$env_dr"
else
    row fail "DATA_ROOT 改写" "期望 $TARGET，实际 $env_dr"
fi

if [ "$KEEP_RESTORE" = "1" ]; then
    info "保留演练现场：$TARGET"
else
    rm -rf "$(dirname "$TARGET")" 2>/dev/null || true
    info "演练现场已清理"
fi

echo
if [ "$DRILL_FAIL" -eq 0 ]; then
    info "演练通过：这份归档可以还原，且内容与归档一致"
else
    warn "演练失败：${DRILL_FAIL} 项不符 —— 该归档不可信"
    exit 1
fi
