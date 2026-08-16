#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2317,SC2329,SC2124,SC2295
# 本文件为单元测试：SC2329(mock 函数"未直接调用"，经 source 间接调)、
# SC2317(新版 shellcheck 对重复定义/间接调用的 mock 判"不可达")、
# SC1090/1091(动态 source $LIB)、SC2124/2295(mock cygpath 取末参)——均测试特有。
# ===========================================================================
# Windows 分支单元测试（在 CI linux runner 上跑，无需 Docker daemon）
#
# 背景：CI 的主 job（lint/validate）在 ubuntu 上跑，detect_os 返回 posix，
# 永远走不到 common.sh 的 Windows 分支（win_path / win_daemon_* /
# compose_cmd 的 Windows 路径）。ADR-016 的 Windows 逻辑靠真实 Windows 才暴露
# bug（2026-08-16 生产迁移实测发现 2 个）。本测试通过 mock uname 强制 MINGW，
# 真实执行 Windows 分支；mock docker/cygpath 为"记录参数"的函数，只验证命令
# 构造，不真连 Docker。
#
# 用法：bash tests/windows_ci.sh
# 退出码：0=全通过，1=有失败。
# ===========================================================================
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/lib/common.sh"
[ -f "$LIB" ] || { echo "FAIL: 找不到 $LIB"; exit 1; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✓ $*"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ FAIL: $*"; }
check() { # check <desc> <expected> <actual>
    local desc="$1" exp="$2" act="$3"
    if [ "$exp" = "$act" ]; then ok "$desc"; else fail "$desc (期望 [$exp] 实际 [$act])"; fi
}
section() { echo ""; echo "== $* =="; }

# ---- 注入 mock：必须在 source common.sh 之前 ----
# mock uname：MODE=windows|posix 控制 detect_os
uname() { [ "${MODE:-posix}" = "windows" ] && printf '%s\n' "MINGW64_NT-10.0-22631" || printf '%s\n' "Linux"; }
# mock cygpath：`cygpath -m <abs路径>` → 稳定转 C:/...（MSYS 的 /c/x→C:/x，
# 其它绝对路径统一转 C:/<strip-first-slash>，使断言不依赖 checkout 位置——
# CI 在 /home/runner 而本地在 /c/Users）
cygpath() {
    local p
    p="${@: -1}"   # 最后一个参数是路径
    case "$p" in
        /c/*) printf '%s\n' "C:/${p#/c/}" ;;
        /*) printf '%s\n' "C:/${p#/}" ;;
        *) printf '%s\n' "$p" ;;
    esac
}

# mock docker：记录每次调用参数，可编程返回状态/输出
DOCKER_CALLS=()
DOCKER_RUN_LOGLINE=""   # 捕获 win_daemon_run 的 docker run 参数
docker() {
    DOCKER_CALLS+=("$*")
    case "$1" in
        inspect)
            # 让 win_daemon_alias 走"别名缺失→补"路径：返回不含 mcsmanager-daemon
            # 的别名 + 容器存在
            printf '%s\n' "orzmc_default [other-alias]"
            return 0 ;;
        network)
            # network inspect → 存在（跳过 create）；connect → 成功
            if [ "${2:-}" = "inspect" ]; then return 0; fi
            return 0 ;;
        rm)   return 0 ;;
        run)
            DOCKER_RUN_LOGLINE="$*"
            return 0 ;;
        ps|compose)
            return 0 ;;
        *) return 0 ;;
    esac
}

# source 生产库（测试只读校验，不产生副作用）
# shellcheck disable=SC1091  # LIB 为运行期路径，ShellCheck 无法静态跟随
source "$LIB"

echo "Windows 分支 CI 覆盖（ADR-016 逻辑）"
echo "来源: $LIB"

# 需在 source 后确保这些导出有值（common.sh 可能定义默认）
DATA_ROOT="${DATA_ROOT:-E:/orzmc}"
COMPOSE_PROFILE="${COMPOSE_PROFILE:-prod}"
EDGE="${EDGE:-cloudflare}"
COMPOSE_FILE="${COMPOSE_FILE:-$REPO_ROOT/compose.yaml}"

# ===========================================================================
section "detect_os / is_windows"
MODE=windows
check "detect_os=MINGW 返回 windows" "windows" "$(detect_os)"
MODE=posix
check "detect_os=Linux 返回 posix" "posix" "$(detect_os)"

# ===========================================================================
section "win_path（MSYS/原生路径 → Windows 原生正斜杠）"
check "MSYS /c/Users/x → C:/Users/x" "C:/Users/x" "$(win_path /c/Users/x)"
check "原生 E:/orzmc 保持不变" "E:/orzmc" "$(win_path E:/orzmc)"
check "原生 E:\\orzmc 转正斜杠" "E:/orzmc" "$(win_path 'E:\orzmc')"
check "相对路径原样" "foo/bar" "$(win_path foo/bar)"

# ===========================================================================
section "daemon_container / daemon_image"
check "daemon 容器名" "orzmc-mcsmanager-daemon" "$(daemon_container)"
# daemon_image 从 compose.yaml 读 digest（纯 awk，不依赖 docker）
img="$(daemon_image)"
case "$img" in
    githubyumao/mcsmanager-daemon@sha256:*) ok "daemon_image 解析出 digest 锁镜像: $img" ;;
    *) fail "daemon_image 意外输出: [$img]" ;;
esac

# ===========================================================================
section "win_daemon_run —— docker run 命令构造（prod，含 DAEMON_PORTS）"
# 造一个临时 .env 供 read_env_value
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# DATA_ROOT 用生产真实形态（E:/orzmc，Windows 原生驱动器路径），这样 win_path
# 原样返回、断言准确。.env 放临时目录，并 mock env_file() 指向它，使 read_env_value
# 能读到 TZ/DAEMON_PORTS 等（DATA_ROOT 本身保持 E:/orzmc 供 win_path 断言）。
DATA_ROOT="E:/orzmc"
cat > "$TMP/.env" <<EOF
TZ=Asia/Shanghai
DAEMON_PORTS=25565:25565/tcp,19132:19132/udp
LAN_MCS_DAEMON_PORT=24444
MCS_DAEMON_PORT=24444
EOF
env_file() { printf '%s/.env' "$TMP"; }
# 强制走创建分支：mock docker 让 inspect(容器) 失败（不存在）
MODE=windows
EDGE=cloudflare
# 需要让 docker inspect $(daemon_container) 返回"不存在"——用包装：
# win_daemon_run 里 docker inspect 容器 -> 我们 mock 返回 0（存在）会走"跳过创建"。
# 这里直接调用 win_daemon_run 并断言走的是跳过分支（幂等），再单独测 run 构造。
win_daemon_run >/dev/null 2>&1
check "win_daemon_run 对已存在容器幂等（跳过创建）" "" "$DOCKER_RUN_LOGLINE"

# 强制创建分支：mock docker 让 inspect(容器) 失败（不存在）
docker() {
    DOCKER_CALLS+=("$*")
    case "$1" in
        inspect)
            if [ "${2:-}" = "orzmc-mcsmanager-daemon" ]; then
                return 1  # 容器不存在 → 进入创建
            fi
            printf '%s\n' "orzmc_default [other-alias]"
            return 0 ;;
        network)
            [ "${2:-}" = "inspect" ] && return 0
            return 0 ;;
        rm) return 0 ;;
        run)
            DOCKER_RUN_LOGLINE="$*"
            return 0 ;;
        *) return 0 ;;
    esac
}
DOCKER_RUN_LOGLINE=""
win_daemon_run >/dev/null 2>&1
echo "  docker run 捕获: $DOCKER_RUN_LOGLINE"
check "docker run -d 后台创建" "1" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -o 'run -d' | head -1 | grep -c 'run -d')"
check "容器名 orzmc-mcsmanager-daemon" "1" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -c '\-\-name orzmc-mcsmanager-daemon')"
check "restart unless-stopped" "1" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -c 'unless-stopped')"
check "自挂载 data 卷 target" "1" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -c 'target=/opt/mcsmanager/daemon/data')"
check "不含 instances 自挂载/工作区 env（已移除 ADR）" "0" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -cE 'instances|MCSM_DOCKER_WORKSPACE_PATH')"
check "docker.sock 挂载" "1" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -c '/var/run/docker.sock:/var/run/docker.sock')"
check "network orzmc_default" "1" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -c '\-\-network orzmc_default')"
check "DAEMON_PORTS 25565 展开" "1" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -c '\-p 25565:25565/tcp')"
check "DAEMON_PORTS 19132 展开" "1" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -c '\-p 19132:19132/udp')"
check "镜像 digest" "1" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -c 'githubyumao/mcsmanager-daemon@sha256:')"

# ===========================================================================
section "win_daemon_run —— lan 模式补 daemon API 端口"
EDGE=lan
DOCKER_RUN_LOGLINE=""
win_daemon_run >/dev/null 2>&1
echo "  docker run 捕获: $DOCKER_RUN_LOGLINE"
check "lan 下补 -p 24444:24444" "1" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -c '\-p 24444:24444')"

# ===========================================================================
section "win_daemon_alias —— 别名缺失时 disconnect+connect --alias"
# 恢复"别名缺失"的 inspect mock（容器存在、别名无 mcsmanager-daemon）
docker() {
    DOCKER_CALLS+=("$*")
    case "$1" in
        inspect)
            if [ "${2:-}" = "orzmc-mcsmanager-daemon" ]; then
                printf '%s\n' "orzmc_default [other-alias]"
                return 0
            fi
            return 0 ;;
        network)
            [ "${2:-}" = "inspect" ] && return 0
            return 0 ;;
        *) return 0 ;;
    esac
}
DOCKER_CALLS=()
win_daemon_alias
calls="$(printf '%s\n' "${DOCKER_CALLS[@]}")"
echo "  docker 调用: $calls"
check "别名缺失时先 disconnect" "1" "$(printf '%s' "$calls" | grep -c 'network disconnect')"
check "别名缺失时再 connect --alias" "1" "$(printf '%s' "$calls" | grep -c 'connect --alias mcsmanager-daemon')"

# 别名已存在 → 无操作
docker() {
    case "$1" in
        inspect)
            if [ "${2:-}" = "orzmc-mcsmanager-daemon" ]; then
                printf '%s\n' "orzmc_default [mcsmanager-daemon]"
                return 0
            fi
            return 0 ;;
        *) return 0 ;;
    esac
}
DOCKER_CALLS=()
win_daemon_alias
check "别名已存在时不执行 connect" "0" "$(printf '%s\n' "${DOCKER_CALLS[@]}" | grep -c 'connect')"

# ===========================================================================
section "compose_cmd —— Windows 分支 up 排除 daemon + 路径转原生"
# 需 mock docker compose config --services 输出服务列表
docker() {
    DOCKER_CALLS+=("$*")
    case "$1" in
        compose)
            # 模拟 `config --services`
            if printf '%s' "$*" | grep -q 'config --services'; then
                printf '%s\n' "mcsmanager-daemon" "mcsmanager-web" "easybot" "mariadb" "status" "cloudflared"
                return 0
            fi
            return 0 ;;
        *) return 0 ;;
    esac
}
DOCKER_CALLS=()
MODE=windows
EDGE=cloudflare
# compose_cmd 需要 env_file 存在 + cloudflared/config.yml 存在
DATA_ROOT="$TMP/orzmc"
mkdir -p "$DATA_ROOT/cloudflared"
touch "$DATA_ROOT/cloudflared/config.yml"
# env_file 指向 DATA_ROOT/.env（已有）
COMPOSE_FILE="$REPO_ROOT/compose.yaml"
compose_cmd up -d >/dev/null 2>&1
calls="$(printf '%s\n' "${DOCKER_CALLS[@]}")"
echo "  docker 调用: $calls"
check "up 用 --no-deps 显式服务列表" "1" "$(printf '%s' "$calls" | grep -c 'up -d --no-deps')"
check "服务列表不含 daemon" "0" "$(printf '%s' "$calls" | grep 'up -d --no-deps' | grep -c 'mcsmanager-daemon')"
check "服务列表含 web" "1" "$(printf '%s' "$calls" | grep 'up -d --no-deps' | grep -c 'mcsmanager-web')"
check "COMPOSE_FILE 转 Windows 原生路径" "1" "$(printf '%s' "$calls" | grep -c '\-f C:/')"

# ===========================================================================
section "posix 分支不受影响（回归）—— compose_cmd 透传"
docker() {
    DOCKER_CALLS+=("$*")
    return 0
}
DOCKER_CALLS=()
MODE=posix
compose_cmd ps >/dev/null 2>&1
calls="$(printf '%s\n' "${DOCKER_CALLS[@]}")"
echo "  docker 调用: $calls"
check "posix 下 compose_cmd ps 原样透传（无 --no-deps、无 daemon 接管）" "0" "$(printf '%s' "$calls" | grep -c -- '--no-deps')"
check "posix 下路径不转原生（保留 MSYS 相对形式）" "0" "$(printf '%s' "$calls" | grep -c '\-f C:/')"

# ===========================================================================
echo ""
echo "=============================================="
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: Windows 分支 CI 覆盖全部通过"
