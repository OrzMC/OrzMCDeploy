#!/usr/bin/env bash
# ===========================================================================
# OrzMC 站点层证书检查（只读）
#
# 用法: cert.sh [check] [-d DATA_ROOT] [--min-days N]
#
# 读 $DATA_ROOT/caddy/data 里 Caddy 自己续期下来的证书（JSON 存储旁的 .crt），
# 打印每个域名的到期日与剩余天数；任一证书剩余天数 < --min-days（缺省 21）则以
# 退出码 1 结束，方便直接挂到 cron / 监控 / 告警里。
#
# 约束（ADR / 运维口径）：
#   - **只读**：不触发续期、不写 caddy/data。手工续期会打乱 Caddy 的 ACME 状态。
#   - 站点层是站点自备（ADR-027）：没有 caddy 目录时就报「未启用」并正常退出。
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/common.sh"

MIN_DAYS=21
DATA_ROOT="${DATA_ROOT:-}"

usage() {
    cat <<'EOF'
用法: ./orzmc.sh -d <数据目录> cert [--min-days N]

  --min-days N   任一证书剩余天数小于 N 即视为异常并 exit 1（缺省 21）

只读检查 Caddy 落盘的证书；不做续期。无 caddy/data 时提示站点层未启用。
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -d|--data-root) [ "$#" -ge 2 ] || die "$1 需要一个参数"; DATA_ROOT="$(norm_path "$2")"; shift 2 ;;
        --min-days)     [ "$#" -ge 2 ] || die "$1 需要一个参数"; MIN_DAYS="$2"; shift 2 ;;
        check)          shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage; exit 1 ;;
    esac
done

[ -n "$DATA_ROOT" ] || DATA_ROOT="$(resolve_data_root)"
export DATA_ROOT
is_uint "$MIN_DAYS" || die "--min-days 需要非负整数: $MIN_DAYS"

command -v openssl >/dev/null 2>&1 || die "缺少 openssl，无法读取证书"

CERT_ROOT="${DATA_ROOT}/caddy/data/caddy/certificates"

# openssl 是原生程序：MSYS 风格路径（/e/...）它读不了，Windows 下统一转成 E:/...
_localize() { if is_windows; then win_path "$1"; else printf '%s\n' "$1"; fi; }

# notAfter（如 "Feb 10 06:02:33 2027 GMT"）→ epoch；GNU date 与 BSD date 都试一遍
_epoch_of() {
    local when="$1"
    date -u -d "$when" +%s 2>/dev/null && return 0
    date -u -j -f "%b %d %H:%M:%S %Y %Z" "$when" +%s 2>/dev/null && return 0
    return 1
}

if [ ! -d "$CERT_ROOT" ]; then
    info "未发现站点层证书目录: ${CERT_ROOT}"
    info "（站点层属站点自备，未启用 Caddy 时属正常）"
    exit 0
fi

now="$(date -u +%s)"
bad=0
count=0
printf '%-28s %-12s %-6s %s\n' "域名" "到期(UTC)" "剩余" "状态"
printf '%s\n' "---------------------------------------------------------------"

while IFS= read -r crt; do
    [ -n "$crt" ] || continue
    count=$((count + 1))
    domain="$(basename "$crt" .crt)"
    loc="$(_localize "$crt")"
    not_after="$(openssl x509 -in "$loc" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')" || true
    if [ -z "$not_after" ]; then
        printf '%-28s %-12s %-6s %s\n' "$domain" "-" "-" "无法解析"
        bad=$((bad + 1)); continue
    fi
    epoch="$(_epoch_of "$not_after")" || epoch=""
    if [ -z "$epoch" ]; then
        printf '%-28s %-12s %-6s %s\n' "$domain" "$not_after" "?" "无法换算（date 不支持 -d/-j）"
        continue
    fi
    days=$(( (epoch - now) / 86400 ))
    expiry="$(date -u -d "@$epoch" +%Y-%m-%d 2>/dev/null || date -u -r "$epoch" +%Y-%m-%d 2>/dev/null || printf '%s' "$not_after")"
    if [ "$days" -lt 0 ]; then status="已过期"
    elif [ "$days" -lt "$MIN_DAYS" ]; then status="将过期"
    else status="正常"; fi
    [ "$status" = "正常" ] || bad=$((bad + 1))
    printf '%-28s %-12s %-6s %s\n' "$domain" "$expiry" "${days}天" "$status"
done < <(find "$CERT_ROOT" -name '*.crt' -type f 2>/dev/null | sort)

echo
if [ "$count" -eq 0 ]; then
    warn "证书目录存在但没找到 .crt：$CERT_ROOT"
    exit 0
fi
if [ "$bad" -gt 0 ]; then
    warn "${bad}/${count} 张证书剩余不足 ${MIN_DAYS} 天或无法解析"
    info "排查：docker logs orzmc-caddy 看 ACME 续期是否失败；**不要手工续期**、不要删 caddy/data"
    exit 1
fi
info "${count} 张证书均在 ${MIN_DAYS} 天以上"
