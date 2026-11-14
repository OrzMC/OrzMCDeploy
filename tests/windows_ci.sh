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
# mock uname：MODE=windows|darwin|posix 控制 detect_os / default_data_root
uname() {
    case "${MODE:-posix}" in
        windows) printf '%s\n' "MINGW64_NT-10.0-22631" ;;
        darwin)  printf '%s\n' "Darwin" ;;
        *)       printf '%s\n' "Linux" ;;
    esac
}
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
COMPOSE_FILE="${COMPOSE_FILE:-$REPO_ROOT/compose.yaml}"

# ===========================================================================
section "detect_os / is_windows"
MODE=windows
check "detect_os=MINGW 返回 windows" "windows" "$(detect_os)"
MODE=posix
check "detect_os=Linux 返回 posix" "posix" "$(detect_os)"
MODE=darwin
check "detect_os=Darwin 仍为 posix（不区分平台默认值）" "posix" "$(detect_os)"

# ===========================================================================
section "DATA_ROOT 必须显式指定（无默认路径，ADR-033）"
check "ORZMC_DATA_ROOT 生效" "/tmp/explicit" "$(ORZMC_DATA_ROOT=/tmp/explicit/ resolve_data_root)"
if ( unset ORZMC_DATA_ROOT; MODE=posix; DATA_ROOT=""; resolve_data_root ) >/dev/null 2>&1; then
    fail "未指定 DATA_ROOT 时 resolve_data_root 应报错退出"
else
    ok "未指定 DATA_ROOT 时报错（不回落到任何平台默认路径）"
fi
# 子进程里跑（die 会 exit，当前 shell 直接捕获会触发 set -e）
err="$( bash -c 'source "$1"; resolve_data_root' _ "$LIB" 2>&1 || true )"
case "$err" in
    *"-d/--data-root"*) ok "报错信息给出显式指定方式" ;;
    *) fail "报错信息缺少指引: $err" ;;
esac

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
# LAN_MCS_DAEMON_PORT 自 ADR-026 起已无消费者，保留在样本里验证"多余变量不炸"
LAN_MCS_DAEMON_PORT=24444
MCS_DAEMON_PORT=24444
EOF
env_file() { printf '%s/.env' "$TMP"; }
# 强制走创建分支：mock docker 让 inspect(容器) 失败（不存在）
MODE=windows
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
check "不含 instances 自挂载（ADR-019）" "0" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -c 'instances')"
check "docker 实例 cwd 路径翻译 env（#4，对齐 compose.yaml）" "1" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -c 'MCSM_DOCKER_WORKSPACE_PATH=E:/orzmc/mcsmanager/daemon/data/InstanceData')"
check "docker.sock 挂载" "1" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -c '/var/run/docker.sock:/var/run/docker.sock')"
check "network orzmc_default" "1" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -c '\-\-network orzmc_default')"
check "DAEMON_PORTS 25565 展开" "1" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -c '\-p 25565:25565/tcp')"
check "DAEMON_PORTS 19132 展开" "1" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -c '\-p 19132:19132/udp')"
check "issue #10 --memory 缺省 512M" "1" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -c -- '--memory 512M')"
check "issue #10 覆盖 CMD 降堆（384）" "1" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -c 'node --max-old-space-size=384 app.js')"
check "issue #10 healthcheck 探活端口" "1" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -c -- '--health-cmd')"
check "镜像 digest" "1" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -c 'githubyumao/mcsmanager-daemon@sha256:')"

# ===========================================================================
section "issue #9 —— docker 型实例存在时自动忽略 DAEMON_PORTS"
INST_ROOT="$TMP/inst-root"
mkdir -p "$INST_ROOT/mcsmanager/daemon/data/InstanceConfig"
cat > "$INST_ROOT/mcsmanager/daemon/data/InstanceConfig/AAAA.json" <<'EOF'
{"processType":"docker"}
EOF
check "find_docker_instance 命中 docker 型实例" "AAAA.json" "$(find_docker_instance "$INST_ROOT")"
check "win_effective_daemon_ports 自动忽略" "" "$(win_effective_daemon_ports "$INST_ROOT" 2>/dev/null)"
mkdir -p "$TMP/inst-empty/mcsmanager/daemon/data/InstanceConfig"
check "无 docker 型实例时原样输出" "25565:25565/tcp,19132:19132/udp" "$(win_effective_daemon_ports "$TMP/inst-empty" 2>/dev/null)"

# ===========================================================================
section "win_daemon_run —— 不再发布 daemon 端口（ADR-026）"
DOCKER_RUN_LOGLINE=""
win_daemon_run >/dev/null 2>&1
echo "  docker run 捕获: $DOCKER_RUN_LOGLINE"
check "不再补 -p 24444" "0" "$(printf '%s' "$DOCKER_RUN_LOGLINE" | grep -c '\-p 24444')"

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
                printf '%s\n' "mcsmanager-daemon" "mcsmanager-web" "easybot"
                return 0
            fi
            return 0 ;;
        *) return 0 ;;
    esac
}
DOCKER_CALLS=()
MODE=windows
# compose_cmd 只需 env_file 存在（ADR-027 起无边缘层配置）
DATA_ROOT="$TMP/orzmc"
mkdir -p "$DATA_ROOT"
# issue #11：站点增量 override（存在即自动 -f 追加）
printf 'services: {}\n' > "$DATA_ROOT/compose.site.yaml"
# env_file 指向 DATA_ROOT/.env（已有）
COMPOSE_FILE="$REPO_ROOT/compose.yaml"
compose_cmd up -d >/dev/null 2>&1
calls="$(printf '%s\n' "${DOCKER_CALLS[@]}")"
echo "  docker 调用: $calls"
check "up 用 --no-deps 显式服务列表" "1" "$(printf '%s' "$calls" | grep -c 'up -d --no-deps')"
check "服务列表不含 daemon" "0" "$(printf '%s' "$calls" | grep 'up -d --no-deps' | grep -c 'mcsmanager-daemon')"
check "服务列表含 web" "1" "$(printf '%s' "$calls" | grep 'up -d --no-deps' | grep -c 'mcsmanager-web')"
check "COMPOSE_FILE 转 Windows 原生路径" "1" "$(printf '%s' "$calls" | grep -c '\-f C:/')"
check "issue #11 自动追加 site override" "1" "$(printf '%s' "$calls" | grep -c 'compose.site.yaml')"

# ADR-029：DAEMON_PORTS 为空时 daemon 交给 compose（不再 --no-deps 剔除）
sed -i.bak 's/^DAEMON_PORTS=.*/DAEMON_PORTS=/' "$TMP/.env" 2>/dev/null || true
DOCKER_CALLS=()
compose_cmd up -d >/dev/null 2>&1
calls2="$(printf '%s\n' "${DOCKER_CALLS[@]}")"
echo "  docker 调用(无 DAEMON_PORTS): $calls2"
check "DAEMON_PORTS 为空时走 compose up -d（无 --no-deps）" "0" "$(printf '%s' "$calls2" | grep -c -- '--no-deps')"
check "DAEMON_PORTS 为空时不由 docker run 创建 daemon" "0" "$(printf '%s\n' "${DOCKER_CALLS[@]}" | grep -c '^run ')"

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
section "issue #11 —— COMPOSE_FILE_EXTRA 追加任意路径 compose 文件"
EXTRA_FILE="$TMP/extra-override.yaml"
printf 'services: {}\n' > "$EXTRA_FILE"
printf 'COMPOSE_FILE_EXTRA=%s\n' "$EXTRA_FILE" >> "$TMP/.env"
DOCKER_CALLS=()
compose_cmd ps >/dev/null 2>&1
calls="$(printf '%s\n' "${DOCKER_CALLS[@]}")"
check "COMPOSE_FILE_EXTRA 文件被 -f 追加" "1" "$(printf '%s' "$calls" | grep -c 'extra-override.yaml')"

# ===========================================================================
section "read_env_value —— 首次出现优先 + CRLF 容错"
printf 'ENABLE_EASYBOT=true\nENABLE_EASYBOT=false\n' > "$TMP/dup.env"
env_file() { printf '%s' "$TMP/dup.env"; }
check "同名键首次出现优先（后者被忽略）" "true" "$(read_env_value ENABLE_EASYBOT)"
check "enabled_profiles 跟随首个值" "easybot" "$(enabled_profiles)"
printf 'ENABLE_EASYBOT=false\r\nLAN_BIND_ADDR=127.0.0.1\r\n' > "$TMP/crlf.env"
env_file() { printf '%s' "$TMP/crlf.env"; }
check "CRLF 文件读到 false" "false" "$(read_env_value ENABLE_EASYBOT)"
check "CRLF 下 profile 为空（开关生效）" "" "$(enabled_profiles)"
check "CRLF 值不带 \\r" "127.0.0.1" "$(read_env_value LAN_BIND_ADDR)"

# ===========================================================================
section "前端拓扑：ENABLE_VELOCITY × ENABLE_EAGLER（ADR-036）"
EG_DIR="$TMP/eg"; mkdir -p "$EG_DIR"
eg_env() { printf '%s\n' "$1" > "$EG_DIR/.env"; env_file() { printf '%s' "$EG_DIR/.env"; }; }
eg_env 'TZ=Asia/Shanghai'
check "缺省 java-only（零影响）" "java-only" "$(topology)"
check "缺省不追加 velocity profile" "" "$(enabled_profiles | grep -x velocity || true)"
check "缺省无 Eaglercraft 实现" "none" "$(eagler_dialect)"
if ( validate_topology ) >/dev/null 2>&1; then ok "缺省 validate_topology 通过"; else fail "缺省应通过校验"; fi
check "三个端口缺省值" "25565 25566 18444"     "$(eagler_java_port) $(eagler_backend_port) $(eagler_ws_port)"

# 象限 3（本次新增能力）：只上 Velocity 多服大厅，不接 Web 客户端
eg_env 'ENABLE_VELOCITY=true
ENABLE_EAGLER=false'
check "V=on/E=off → velocity" "velocity" "$(topology)"
check "velocity 追加 velocity profile" "velocity" "$(enabled_profiles | grep -x velocity || true)"
check "velocity 不启用 Eaglercraft（dialect=none）" "none" "$(eagler_dialect)"
check "velocity 拓扑基岩托管在代理" "velocity" "$(geyser_target)"
if ( validate_topology ) >/dev/null 2>&1; then ok "velocity 缺省端口校验通过"; else fail "velocity 应通过校验"; fi

# 象限 4：Velocity + Eaglercraft
eg_env 'ENABLE_VELOCITY=true
ENABLE_EAGLER=true'
check "V=on/E=on → eagler-proxy" "eagler-proxy" "$(topology)"
check "eagler-proxy 用 EaglerXServer（可改 UUID / 支持 Folia）" "eaglerxserver" "$(eagler_dialect)"

# 象限 2：无代理，实例直挂 EaglerXPaper
eg_env 'ENABLE_VELOCITY=false
ENABLE_EAGLER=true'
check "V=off/E=on → eagler-direct" "eagler-direct" "$(topology)"
check "eagler-direct 用 EaglerXPaper" "eaglerxpaper" "$(eagler_dialect)"
check "eagler-direct 不启用 velocity 服务" "" "$(enabled_profiles | grep -x velocity || true)"
check "eagler-direct 基岩留给实例 Geyser-Spigot" "spigot" "$(geyser_target)"

# 基岩派生：显式关掉
eg_env 'ENABLE_VELOCITY=true
EAGLER_GEYSER=false'
check "EAGLER_GEYSER=false → 代理不托管基岩" "none" "$(geyser_target)"

# 向后兼容：旧 EAGLER_MODE
eg_env 'EAGLER_MODE=direct'
check "旧值 direct 推导为 eagler-direct" "eagler-direct" "$(topology)"
eg_env 'EAGLER_MODE=proxy'
check "旧值 proxy 推导为 eagler-proxy" "eagler-proxy" "$(topology)"
check "旧值 proxy 仍追加 velocity profile（服务名已改）" "velocity" \
    "$(enabled_profiles | grep -x velocity || true)"
eg_env 'EAGLER_MODE=bogus'
if ( validate_topology ) >/dev/null 2>&1; then fail "非法 EAGLER_MODE 应报错"; else ok "非法 EAGLER_MODE 报错"; fi
# 新旧并存：新开关优先（旧值不得偷偷生效）
eg_env 'ENABLE_VELOCITY=false
ENABLE_EAGLER=false
EAGLER_MODE=proxy'
check "新键在时旧 EAGLER_MODE 被忽略" "java-only" "$(topology)"
if ( validate_topology ) 2>&1 >/dev/null | grep -q "已被忽略"; then
    ok "新旧并存时提示 EAGLER_MODE 被忽略"
else
    fail "新旧并存应提示旧键被忽略"
fi

# 值域与端口一致性
eg_env 'ENABLE_VELOCITY=yes'
if ( validate_topology ) >/dev/null 2>&1; then fail "非布尔 ENABLE_VELOCITY 应报错"; else ok "非布尔 ENABLE_VELOCITY 报错"; fi
eg_env 'ENABLE_VELOCITY=true
EAGLER_BACKEND_PORT=25565'
if ( validate_topology ) >/dev/null 2>&1; then fail "velocity 同端口应报错"; else ok "velocity 端口相同被拦下"; fi
eg_env 'ENABLE_EAGLER=true
EAGLER_WS_PORT=25565'
if ( validate_topology ) >/dev/null 2>&1; then fail "WS 撞游戏端口应报错"; else ok "WS 端口撞游戏端口被拦下"; fi
eg_env 'ENABLE_EAGLER=true
EAGLER_PUBLIC_HOST=https://dev.jokerhub.cn/'
if ( validate_topology ) >/dev/null 2>&1; then fail "EAGLER_PUBLIC_HOST 带协议应报错"; else ok "EAGLER_PUBLIC_HOST 只接受域名"; fi
eg_env 'ENABLE_VELOCITY=true
EAGLER_GEYSER_PORT=abc'
if ( validate_topology ) >/dev/null 2>&1; then fail "非法 Geyser 端口应报错"; else ok "非法 Geyser 端口被拦下"; fi
eg_env 'ENABLE_EAGLER=true
EAGLER_JAVA_PORT=25570'
check "自定义端口生效" "25570 25566 18444"     "$(eagler_java_port) $(eagler_backend_port) $(eagler_ws_port)"

# ===========================================================================
section "多后端大厅（VELOCITY_SERVERS / VELOCITY_TRY）"
eg_env 'ENABLE_VELOCITY=true'
check "缺省后端 = lobby 的宿主端口（归一化）" "lobby=host.docker.internal:25566" "$(velocity_servers)"
check "缺省 try = 第一个后端" "lobby" "$(velocity_try)"
eg_env 'ENABLE_VELOCITY=true
VELOCITY_SERVERS=lobby=25567,survival=25566
VELOCITY_TRY=lobby'
check "多后端解析（纯端口→宿主，归一化）" "lobby=host.docker.internal:25567 survival=host.docker.internal:25566" "$(velocity_servers | tr '\n' ' ' | sed 's/ $//')"
check "try 显式指定生效" "lobby" "$(velocity_try | head -n1)"
# shellcheck disable=SC1091  # 仓库内相对路径，函数定义无副作用
source "$REPO_ROOT/lib/eagler.sh"
rm -f "$EG_DIR/velocity.toml"
eagler_render_velocity_toml "$EG_DIR/velocity.toml" >/dev/null 2>&1
rendered="$(sed -n '/^\[servers\]/,/^\[forced-hosts\]/p' "$EG_DIR/velocity.toml")"
check "渲染出第二个后端" "yes" \
    "$(printf '%s' "$rendered" | grep -q 'survival = "host.docker.internal:25566"' && echo yes || echo no)"
check "渲染 try 指向 lobby" "yes" \
    "$(printf '%s' "$rendered" | grep -q '^    "lobby",$' && echo yes || echo no)"
eg_env 'ENABLE_VELOCITY=true
VELOCITY_SERVERS=lobby=MCSM-716c2f:25565,survival=25566'
mkdir -p "$EG_DIR/eagler"
saved_root="$DATA_ROOT"; DATA_ROOT="$EG_DIR"
eagler_write_setup_doc eagler-proxy >/dev/null 2>&1
doc="$(cat "$EG_DIR/eagler/instance-setup.md")"
DATA_ROOT="$saved_root"
check "容器名后端：待办里不要求发布宿主端口" "yes" \
    "$(printf '%s' "$doc" | grep -q '不用发布端口（容器名直达）' && echo yes || echo no)"
check "容器名后端：待办里不再出现 x:25565:25565" "0" \
    "$(printf '%s' "$doc" | grep -cE '25565:25565\|')"
eg_env 'ENABLE_VELOCITY=true
VELOCITY_SERVERS=lobby=25567,bad name=25566'
if ( validate_topology ) >/dev/null 2>&1; then fail "名字含空格应报错"; else ok "服务器名含空格被拦下"; fi
eg_env 'ENABLE_VELOCITY=true
VELOCITY_SERVERS=lobby=25567
VELOCITY_TRY=nether'
if ( validate_topology ) >/dev/null 2>&1; then fail "try 不在列表应报错"; else ok "try 不在列表被拦下"; fi
eg_env 'ENABLE_VELOCITY=true
VELOCITY_SERVERS=lobby=25567,lobby=25566'
if ( validate_topology ) >/dev/null 2>&1; then fail "重复名字应报错"; else ok "重复服务器名被拦下"; fi
eg_env 'ENABLE_VELOCITY=true
VELOCITY_SERVERS=lobby=25565'
if ( validate_topology ) >/dev/null 2>&1; then fail "后端端口撞代理入口应报错"; else ok "后端端口撞代理入口被拦下"; fi
# 容器名写法：实例与代理同一 docker 网络时直接用容器名（不挪宿主端口）
eg_env 'ENABLE_VELOCITY=true
VELOCITY_SERVERS=lobby=MCSM-716c2f:25565,survival=25566'
check "容器名写法原样保留" "lobby=MCSM-716c2f:25565 survival=host.docker.internal:25566" \
    "$(velocity_servers | tr '\n' ' ' | sed 's/ $//')"
if ( validate_topology ) >/dev/null 2>&1; then ok "容器名写法不做宿主端口冲突检查"; else fail "容器名写法该校验通过"; fi
eg_env 'ENABLE_VELOCITY=true
VELOCITY_SERVERS=lobby=bad host!:25565'
if ( validate_topology ) >/dev/null 2>&1; then fail "非法主机名应报错"; else ok "非法主机名被拦下"; fi

# ===========================================================================
section "firewall apply —— 只重建受管规则，不碰站点自建（OrzMC-Web-TLS）"
FW_DIR="$TMP/fw"; mkdir -p "$FW_DIR"
cp "$REPO_ROOT/templates/env" "$FW_DIR/.env"
printf 'MC_PUBLIC_TCP=25565,19132\nMC_PUBLIC_UDP=19132,24454\n' >> "$FW_DIR/.env"
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\necho MINGW64_NT-10.0-22631\n' > "$FAKEBIN/uname"; chmod +x "$FAKEBIN/uname"
fwout="$(PATH="$FAKEBIN:$PATH" DATA_ROOT="$FW_DIR" bash "$REPO_ROOT/lib/firewall.sh" apply --dry-run 2>&1)"
check "删除按规则名精确匹配（无 -like 通配删除）" "0" "$(printf '%s' "$fwout" | grep -c 'DisplayName -like')"
check "公网规则按 MC_PUBLIC_* 生成（RemoteAddress Any）" "1" \
    "$(printf '%s' "$fwout" | grep -c "OrzMC-MC-Public-TCP.*RemoteAddress Any")"
check "站点自建 Web-TLS 规则不在删除列表" "0" \
    "$(printf '%s' "$fwout" | grep -c "Remove-NetFirewallRule.*OrzMC-Web-TLS")"
check "LAN 规则仍限 LAN_CIDR" "1" \
    "$(printf '%s' "$fwout" | grep -c "OrzMC-Panel.*RemoteAddress 192.168.0.0/24")"

# ===========================================================================
section "firewall：velocity 拓扑的玩家端口并入 MC-TCP（不新增规则名）"
FW2="$TMP/fw2"; mkdir -p "$FW2"
cp "$REPO_ROOT/templates/env" "$FW2/.env"
# 模板里已有 ENABLE_VELOCITY=false（同名键首次出现优先），必须改原行而不是追加
sed -i 's/^ENABLE_VELOCITY=.*/ENABLE_VELOCITY=true/' "$FW2/.env"
printf 'EAGLER_JAVA_PORT=25570\n' >> "$FW2/.env"
fw2out="$(PATH="$FAKEBIN:$PATH" DATA_ROOT="$FW2" bash "$REPO_ROOT/lib/firewall.sh" apply --dry-run 2>&1)"
check "EAGLER_JAVA_PORT 并入 OrzMC-MC-TCP" "yes" \
    "$(printf '%s' "$fw2out" | grep -q "OrzMC-MC-TCP.*25570" && echo yes || echo no)"
check "不新增 Eagler 专用规则" "0" \
    "$(printf '%s' "$fw2out" | grep -c "OrzMC-Eagler")"
check "Geyser 端口并入 OrzMC-MC-UDP（19134 媒体）" "yes" \
    "$(printf '%s' "$fw2out" | grep -q "OrzMC-MC-UDP.*19134" && echo yes || echo no)"

# ===========================================================================
echo ""
echo "=============================================="
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: Windows 分支 CI 覆盖全部通过"
