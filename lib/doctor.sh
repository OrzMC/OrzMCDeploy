#!/usr/bin/env bash
# ===========================================================================
# OrzMC 部署自检（doctor）—— 把部署后手工清单里可判定的项做成一条命令
#
# 用法: doctor.sh [-d DATA_ROOT]
#
# 只读为主（唯一写操作是在 DATA_ROOT 与备份根各写一个探针文件后立即删除）。
# 有 FAIL 时 exit 1，可直接挂 CI / cron。覆盖的坑：
#   - 环境缺件（docker CLI / daemon / compose 插件 / openssl）
#   - DATA_ROOT 不可写、.env 缺变量、.env 里的 DATA_ROOT 与实际不一致
#   - 磁盘水位（备份单次 ~4G，留不够空间会把 tar 打断）
#   - 容器 config_files 指向另一棵程序树（两棵树各管一半容器的经典故障）
#   - 期望端口没真正发布到宿主
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/common.sh"

DATA_ROOT="${DATA_ROOT:-}"
[[ "${1:-}" == "-d" || "${1:-}" == "--data-root" ]] && { [ "$#" -ge 2 ] || die "-d 需要一个参数"; DATA_ROOT="$(norm_path "$2")"; shift 2; }
case "${1:-}" in -h|--help)
    cat <<'EOF'
用法: ./orzmc.sh -d <数据目录> doctor

逐项检查环境 / 数据目录 / 备份 / 运行时 / 工具链，输出 [ OK ] [WARN] [FAIL]；
存在 FAIL 时 exit 1。
EOF
    exit 0 ;;
esac

[ -n "$DATA_ROOT" ] || DATA_ROOT="$(resolve_data_root)"
export DATA_ROOT

PASS=0; WARNED=0; FAILED=0
ok()   { PASS=$((PASS + 1));    printf '  [ OK ] %s\n' "$*"; }
warn() { WARNED=$((WARNED + 1)); printf '  [WARN] %s\n' "$*"; }
bad()  { FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$*"; }
section() { printf '\n%s\n' "== $* =="; }

# ---------------------------------------------------------------- 环境
section "环境"
if command -v docker >/dev/null 2>&1; then
    ok "docker CLI: $(docker --version 2>/dev/null | head -1)"
    if docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
        ok "docker daemon: $(docker info --format '{{.ServerVersion}}' 2>/dev/null)"
    else
        bad "docker daemon 不可达（Windows 上确认 Docker Desktop 已启动；它在会话 0 里会起不来）"
    fi
    if docker compose version >/dev/null 2>&1; then
        ok "compose 插件: $(docker compose version --short 2>/dev/null)"
    else
        bad "缺少 docker compose 插件（docker-compose v1 不被支持）"
    fi
else
    bad "找不到 docker CLI"
fi
if command -v openssl >/dev/null 2>&1; then ok "openssl: $(openssl version | cut -d' ' -f1-2)"; else warn "缺少 openssl（cert 子命令不可用）"; fi

# ---------------------------------------------------------------- 数据目录
section "数据目录 $DATA_ROOT"
if [ -d "$DATA_ROOT" ]; then
    ok "目录存在"
    if : >"$DATA_ROOT/.orzmc-doctor-probe" 2>/dev/null; then
        rm -f "$DATA_ROOT/.orzmc-doctor-probe"
        ok "可写"
    else
        bad "不可写（权限 / 只读挂载 / Windows Docker 文件共享白名单）"
    fi
else
    bad "目录不存在：先跑 ./orzmc.sh -d $DATA_ROOT init"
fi

if [ -f "$(env_file)" ]; then
    ok ".env 存在"
    if ( validate_required_env ) >/dev/null 2>&1; then
        ok "必需变量齐全"
    else
        bad "必需变量缺失：$( ( validate_required_env ) 2>&1 | head -3 | tr '\n' ' ')"
    fi
    env_root="$(read_env_value DATA_ROOT || true)"
    if [ -z "$env_root" ]; then
        warn ".env 未写 DATA_ROOT（迁移后建议写成当前路径）"
    elif [ "$(norm_path "$env_root")" = "$DATA_ROOT" ]; then
        ok ".env 内 DATA_ROOT 与实际一致"
    else
        bad ".env 内 DATA_ROOT=${env_root} 与实际 $DATA_ROOT 不一致（迁移后残留，restore 会自动改写）"
    fi
else
    bad "缺少 $DATA_ROOT/.env：先 init"
fi

# ---------------------------------------------------------------- 备份
section "备份"
BK_ROOT="$(dirname -- "$DATA_ROOT")/orzmc-backups"
if [ -d "$BK_ROOT" ]; then
    if : >"$BK_ROOT/.orzmc-doctor-probe" 2>/dev/null; then
        rm -f "$BK_ROOT/.orzmc-doctor-probe"
        ok "备份根可写: $BK_ROOT"
    else
        bad "备份根不可写: $BK_ROOT"
    fi
    # ls -1t 而不是 find -printf：BSD find（macOS）没有 -printf
    # shellcheck disable=SC2012
    latest="$(ls -1t "$BK_ROOT"/orzmc-backup-*.tar.gz 2>/dev/null | head -1 || true)"
    if [ -n "$latest" ]; then
        ok "最近归档: $(basename "$latest") ($(du -h "$latest" 2>/dev/null | cut -f1))"
    else
        warn "备份根里没有任何 orzmc-backup-*.tar.gz：还没跑过 backup"
    fi
else
    warn "备份根不存在（首次 backup 会自动创建）: $BK_ROOT"
fi

avail_kb="$(df -Pk "$DATA_ROOT" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
if [ -n "${avail_kb:-}" ]; then
    avail_gb=$((avail_kb / 1024 / 1024))
    if [ "$avail_gb" -ge 20 ]; then ok "剩余空间 ${avail_gb}G"
    elif [ "$avail_gb" -ge 5 ]; then warn "剩余空间 ${avail_gb}G，单次备份约 4G，建议先清理"
    else bad "剩余空间仅 ${avail_gb}G，备份会写坏"; fi
else
    warn "无法读取磁盘剩余空间（df 不可用）"
fi

# ---------------------------------------------------------------- 运行时
section "运行时"
containers="$(docker ps -a --format '{{.Names}}' 2>/dev/null | tr -d '\r' | grep -E '^orzmc-' || true)"
if [ -z "$containers" ]; then
    warn "没有 orzmc-* 容器：平台层从未启动过，或已 stop"
else
    running="$(docker ps --format '{{.Names}}' 2>/dev/null | tr -d '\r' | grep -cE '^orzmc-' || true)"
    total="$(printf '%s\n' "$containers" | wc -l | tr -d ' ')"
    ok "容器 ${running}/${total} 在运行"

    # 关键：容器可能是从另一棵程序树里的 compose 文件起的（改了 A 树、容器跑的是 B 树）
    roots=""
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        cf="$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null || true)"
        case "$cf" in ""|"<no value>") continue ;; esac
        first="${cf%%,*}"                 # 只看主 compose 文件（其余是 -f 追加的）
        first="${first//\\//}"            # 反斜杠统一成正斜杠再比
        root="${first%/*}"
        case "|$roots|" in
            *"|$root|"*) ;;
            *) roots="${roots:+$roots|}${root}" ;;
        esac
    done <<<"$containers"
    n_roots="$(printf '%s' "$roots" | awk -F'|' '{print NF}')"
    repo_norm="${REPO_ROOT//\\//}"
    if [ -z "$roots" ]; then
        warn "容器没有 compose 标签（可能是手工 docker run 起的）"
    elif [ "$n_roots" -gt 1 ]; then
        bad "容器分散在多棵程序树下（改了其中一棵不会全生效）：${roots//|/, }"
    elif [ "$roots" = "$repo_norm" ]; then
        ok "容器 compose 文件均指向当前程序目录 $REPO_ROOT"
    else
        warn "容器由另一棵程序树启动：${roots}（当前 $REPO_ROOT 的改动不会生效；发布部署时属正常）"
    fi

    # 端口是否真的发布到宿主
    ports="$(docker ps --format '{{.Ports}}' 2>/dev/null | tr -d '\r')"
    for p in 25565 19132; do
        case "$ports" in
            *":${p}->"*) ok "宿主端口 ${p} 已发布" ;;
            *) warn "宿主端口 ${p} 未见发布（只跑代理/面板拓扑时正常）" ;;
        esac
    done
    for p in "$(read_env_value LAN_MCS_WEB_PORT || true)" "$(read_env_value LAN_EASYBOT_PORT || true)"; do
        [ -n "${p:-}" ] || continue
        case "$ports" in
            *":${p}->"*) ok "宿主端口 ${p} 已发布" ;;
            *) warn "宿主端口 ${p} 未见发布（面板 / EasyBot 未起？）" ;;
        esac
    done
fi

# ---------------------------------------------------------------- 工具链
section "工具链"
if [ -n "${JAVA_HOME:-}" ]; then
    if [ -d "$JAVA_HOME" ]; then ok "JAVA_HOME=$JAVA_HOME"
    else bad "JAVA_HOME 指向不存在的目录: $JAVA_HOME（Eagler 转译/构建需要）"; fi
else
    warn "未设置 JAVA_HOME（只跑代理拓扑时不影响）"
fi

# ---------------------------------------------------------------- 结论
printf '\n'
if [ "$FAILED" -gt 0 ]; then
    printf '[doctor] FAIL %d / WARN %d / OK %d\n' "$FAILED" "$WARNED" "$PASS" >&2
    exit 1
fi
printf '[doctor] WARN %d / OK %d —— 无阻断项\n' "$WARNED" "$PASS"
