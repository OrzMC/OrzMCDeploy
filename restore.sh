#!/usr/bin/env bash
# ===========================================================================
# OrzMC 数据还原 / 迁移
#
# 用法: restore.sh [-d DATA_ROOT] [-p PROFILE] <archive.tar.gz> [--force] [--start]
#
# 安全规则:
#   - 目标目录非空时默认拒绝，--force 会把旧目录移为 .old-<时间>（不删除）
#   - 归档顶层目录名与目标名不一致时默认拒绝，--force 解压后改名
#   - 还原到新路径时自动改写 .env 内的 DATA_ROOT（迁移核心），留 .env.bak-restore
#   - PROFILE（默认 prod）：--start 拉起时按 profile 选择边缘层
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DATA_ROOT="$(resolve_data_root)"
FORCE=0
START=0
ARCHIVE=""

usage() {
    echo "用法: restore.sh [-d DATA_ROOT] [-p PROFILE] <archive.tar.gz> [--force] [--start]" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -d|--data-root) [ "$#" -ge 2 ] || usage; DATA_ROOT="$(norm_path "$2")"; shift 2 ;;
        -p|--profile) [ "$#" -ge 2 ] || usage; COMPOSE_PROFILE="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --start) START=1; shift ;;
        -h|--help) usage ;;
        -*) usage ;;
        *)
            if [ -z "$ARCHIVE" ]; then ARCHIVE="$1"; else usage; fi
            shift
            ;;
    esac
done

export DATA_ROOT
case "$COMPOSE_PROFILE" in
    prod|local|lan) ;;
    *) die "未知 profile: ${COMPOSE_PROFILE}（可选 prod|local|lan）" ;;
esac
[ -f "$ARCHIVE" ] || die "备份文件不存在: $ARCHIVE"

# 顶层目录名
top="$(tar tzf "$ARCHIVE" | head -n1)"; top="${top%/}"
[ -n "$top" ] || die "备份为空或不可读: $ARCHIVE"
[ "$top" = "$(basename "$DATA_ROOT")" ] || [ "$FORCE" = 1 ] \
    || die "归档顶层目录($top)与目标目录名($(basename "$DATA_ROOT"))不一致；确认后用 --force"

# 防坑：--force 改名还原到"同父目录下的新路径"时，若父目录中已存在与归档顶层同名的
# 旧目录（如把 .local-data 的归档还原成 ./.local-data-2），tar 会把旧目录当作解压目标
# 覆盖/合并进去，随后 mv 把合并结果整目录改名——等于把仍在用的旧数据目录一起改走。
# 此风险与 --force 意图（覆盖目标路径）无关，属另一目录，一律拒绝。
if [ "$top" != "$(basename "$DATA_ROOT")" ] && [ -e "$(dirname "$DATA_ROOT")/$top" ]; then
    die "目标父目录已存在与归档顶层同名目录($(dirname "$DATA_ROOT")/$top)，可能是仍在使用的数据目录；请改用独立父目录还原（如 /tmp/<root>/）"
fi

# 非空目标
if [ -d "$DATA_ROOT" ] && [ -n "$(ls -A "$DATA_ROOT" 2>/dev/null)" ]; then
    if [ "$FORCE" = 1 ]; then
        mv "$DATA_ROOT" "$DATA_ROOT.old-$(date +%Y%m%d-%H%M%S)"
        warn "目标非空，原目录已移走: $DATA_ROOT.old-*"
    else
        die "目标 $DATA_ROOT 非空。确认覆盖请加 --force"
    fi
fi

mkdir -p "$(dirname "$DATA_ROOT")"
info "解压 $ARCHIVE -> $(dirname "$DATA_ROOT")/"
tar -xzf "$ARCHIVE" -C "$(dirname "$DATA_ROOT")"
if [ "$top" != "$(basename "$DATA_ROOT")" ]; then
    mv "$(dirname "$DATA_ROOT")/$top" "$DATA_ROOT"
fi

# 关键：迁移到新宿主机/新路径时，env 内 DATA_ROOT 需改写为当前目标
if [ -f "$(env_file)" ]; then
    in_file="$(read_env_value DATA_ROOT)"
    if [ -n "$in_file" ] && [ "$(norm_path "$in_file")" != "$DATA_ROOT" ]; then
        warn "env 内 DATA_ROOT($in_file) 与目标($DATA_ROOT) 不一致，正在改写（原文件备份）"
        cp "$(env_file)" "$(env_file).bak-restore"
        sed "s#^DATA_ROOT=.*#DATA_ROOT=${DATA_ROOT}#" "$(env_file).bak-restore" > "$(env_file)"
    fi
fi

# 完整性检查按 profile 选择边缘层配置：local 需 Caddyfile，prod 需 cloudflared config
case "$COMPOSE_PROFILE" in
    local)
        [ -f "$DATA_ROOT/caddy/Caddyfile" ] || die "还原内容缺少 caddy/Caddyfile，备份可能不完整"
        ;;
    prod)
        [ -f "$DATA_ROOT/cloudflared/config.yml" ] || die "还原内容缺少 cloudflared/config.yml，备份可能不完整"
        ;;
    lan)
        :  # lan 无边缘层，无 Caddyfile / cloudflared config 可校验；.env 已在上方校验
        ;;
esac

# 应用数据库校验：还原内容应含 database/mariadb 冷数据目录（权威）；
# 仅有逻辑备份则提示手动导入（mariadb 是平台层常驻服务）
if [ ! -d "$DATA_ROOT/database/mariadb" ]; then
    warn "还原内容缺少 database/mariadb 数据目录；若归档含 database/dumps/*.sql，请解压后手动导入再启动"
fi

info "还原完成。验证: deploy.sh -d ${DATA_ROOT} -p ${COMPOSE_PROFILE} validate"
if [ "$START" = 1 ]; then
    # 注意：不能用 ${SCRIPT_DIR} —— source lib/common.sh 会把 SCRIPT_DIR 覆写为
    # lib/ 目录；REPO_ROOT 是 common.sh 按仓库根算出的正确路径。
    "${REPO_ROOT}/deploy.sh" -d "$DATA_ROOT" -p "$COMPOSE_PROFILE" up
fi
