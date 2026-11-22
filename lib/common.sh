#!/usr/bin/env bash
# ===========================================================================
# OrzMC deploy 共享函数库
#
# 架构原则：仓库只承载"运行时"，全部配置与数据落在 $DATA_ROOT（统一目录）。
# 运行模型（ADR-027）：只有局域网模式——面板/EasyBot 发布宿主端口，纯 HTTP；
# 本库统一处理：
#   - DATA_ROOT 解析与一致性校验
#   - env 文件（$DATA_ROOT/.env）读写
#   - 数据目录树与站点增量引导（compose.site.yaml / EasyBot 本地覆盖）
#   - docker compose 统一入口（显式 --env-file + --profile）
#
# ⚠️ 本仓库脚本在 macOS 自带 bash 3.2（及 /usr/bin/env bash 解析到 3.2）下运行。
#   bash 3.2 + `set -u` 会把双引号内紧跟全角字符（（ ） ， 。 等）的 `$VAR` 误判为
#   未定义变量并报 `VAR�: unbound variable`。消息字符串里的变量一律写 `${VAR}`，
#   不要用 `$VAR` 直接后接全角标点。此为可移植性约定，勿回退。
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/compose.yaml"
TEMPLATES_DIR="${REPO_ROOT}/templates"
# shellcheck disable=SC2034  # 供 deploy.sh 读取（TEMPLATE 默认值），跨文件可见
DEFAULT_TEMPLATE="${TEMPLATES_DIR}/env"

# 运行模型（ADR-027）：**只有局域网模式**。
#   - 平台层把面板与 EasyBot 发布到宿主端口（LAN_*_PORT），纯 HTTP，局域网直连。
#   - 对外访问由站点自备（DDNS + 端口映射 / 反向代理 / VPN），不在本仓库范围内。
#   - ENABLE_EASYBOT：可选服务开关（true|false），compose_cmd 按启用项追加
#     --profile easybot。核心 web/daemon 常驻。ADR-025 起不再有 mariadb/status。
#   - daemon 不对宿主发布端口（ADR-026：面板中转浏览器↔daemon 数据流）。

# ---- 日志 ---------------------------------------------------------------

info() { printf '[info] %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
die()  { printf '[error] %s\n' "$*" >&2; exit 1; }

# 去掉末尾斜杠，便于路径比较
norm_path() { printf '%s\n' "${1%/}"; }

# ---- 平台检测 -------------------------------------------------------------
# Windows 与 macOS/Linux 的主要差异（详见 docs/usage.md 附录 F）：
#   1) 路径：MSYS 路径（/c/...）必须转 Windows 原生正斜杠（win_path）；
#   2) WSL 侧 compose 无法创建 `E:/...` 绑定（短语法盘符冒号），`up` 须在 Windows 侧执行；
#   3) 仅**进程模式实例**需要给 daemon 注入 `DAEMON_PORTS` 的 `-p` 时才退回
#      `docker run`（compose 无法按 .env 动态生成端口列表）；否则交 compose（ADR-029）。
# 用户命令三平台完全一致。
detect_os() {
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) printf '%s\n' "windows" ;;
        *) printf '%s\n' "posix" ;;
    esac
}
is_windows() { [ "$(detect_os)" = "windows" ]; }

# ---- 容器引擎后端（Windows 专用）------------------------------------------
# 为什么需要：Docker Desktop 的端口转发会把 LAN 访问的源地址统一改写成网关
# （172.18.0.1），站点日志与游戏内看到的都不是真实玩家 IP。WSL 原生 dockerd
# （networkingMode=mirrored + userland-proxy=false）走内核 DNAT，源 IP 原样保留。
# 开关：$DATA_ROOT/.env 里 DOCKER_BACKEND=wsl；不写 = desktop（缺省，向后兼容）。
# 切到 wsl 后有两处必须跟着变：
#   1) 宿主机路径要换成 /mnt/<盘符>/...（dockerd 在 WSL 里解析挂载源）；
#   2) docker CLI 要经 tcp://127.0.0.1:2375 连 WSL dockerd（不是 Desktop 的 socket）。
docker_backend() {
    local v
    v="$(read_env_value DOCKER_BACKEND)"
    [ -n "$v" ] || v="desktop"
    case "$v" in
        desktop|wsl) printf '%s' "$v" ;;
        *) die "DOCKER_BACKEND=${v} 无效：只允许 desktop / wsl" ;;
    esac
}

is_wsl_backend() { is_windows && [ "$(docker_backend)" = "wsl" ]; }

# 目标发行版：`.env` 里 `WSL_DISTRO` 指定（多发行版机器必填）；不写 = `wsl.exe` 的默认发行版。
wsl_distro() { read_env_value WSL_DISTRO || true; }

# 在 WSL 里执行一段命令：backend=wsl 时 compose / docker 调用统一经这里。
wsl_run() {
    local d
    d="$(wsl_distro)"
    if [ -n "$d" ]; then
        wsl.exe -d "$d" -e bash -lc "$*"
    else
        wsl.exe -e bash -lc "$*"
    fi
}

# docker CLI 直调：wsl 后端下 Windows 侧**没有 docker 可执行文件**，所有非 compose
# 的调用（network / run / rm / inspect / ps / exec / pull）都必须转进 WSL，否则
# 这些代码路径会静默失败或误判「没有容器」。返回值保持子命令的退出码。
dkr() {
    if is_wsl_backend; then
        local cmd a out rc
        cmd="docker"
        for a in "$@"; do cmd="$cmd $(printf '%q' "$a")"; done
        out="$(wsl_run "$cmd")"
        rc=$?
        printf '%s\n' "$out" | tr -d '\015'
        return $rc
    fi
    docker "$@"
}

# Windows 盘符路径 → WSL 视角路径（E:/orzmc → /mnt/e/orzmc）。
# MSYS 形式（/e/orzmc）先用 cygpath 归一成 E:/orzmc 再转 —— 脚本变量多来自
# bash 的 pwd，在 Windows 上是 MSYS 路径，直接当 WSL 路径用会找不到文件。
wsl_path() {
    local p="$1" drive rest
    case "$p" in
        /*) p="$(cygpath -m "$p" 2>/dev/null || printf '%s' "$p")" ;;
    esac
    case "$p" in
        [A-Za-z]:*)
            drive="$(printf '%s' "${p%%:*}" | tr '[:upper:]' '[:lower:]')"
            rest="${p#*:}"
            rest="${rest//\\//}"
            printf '/mnt/%s%s\n' "$drive" "$rest" ;;
        *) printf '%s\n' "$p" ;;
    esac
}

# 生成 WSL 视角的派生 env 文件（DATA_ROOT 换成 /mnt/...），返回其 WSL 路径。
# 不直接改 .env：宿主机侧脚本（备份/restore/doctor）仍需要 Windows 形式路径。
wsl_env_file() {
    local src dst wroot abs
    src="$(env_file)"
    dst="${DATA_ROOT}/.env.wsl"
    abs="$(norm_path "$DATA_ROOT")"
    case "$abs" in
        /*|[A-Za-z]:*) ;;                       # 已是绝对路径
        *) abs="$(cd "$abs" 2>/dev/null && pwd)" ;;
    esac
    wroot="$(wsl_path "$abs")"
    sed "s#^DATA_ROOT=.*#DATA_ROOT=${wroot}#" "$src" > "$dst"
    chmod 600 "$dst" 2>/dev/null || true
    printf '%s\n' "$(wsl_path "$dst")"
}

# 各子脚本解析完 DATA_ROOT 后调用一次：把 docker CLI 指到 WSL dockerd。
apply_docker_backend() {
    is_wsl_backend || return 0
    export DOCKER_HOST="tcp://127.0.0.1:2375"
    unset DOCKER_CONTEXT 2>/dev/null || true
}

# MSYS/原生路径 → Windows 原生正斜杠形式（docker 用）：C:/...、E:/...
win_path() {
    local p="$1"
    case "$p" in
        [A-Za-z]:*) printf '%s\n' "${p//\\//}" ;;   # 已是原生（E:\ 或 E:/），统一正斜杠
        /*) printf '%s\n' "$(cygpath -m "$p" 2>/dev/null || printf '%s' "$p")" ;;
        *) printf '%s\n' "${p//\\//}" ;;
    esac
}

# tar 的 Windows 适配选项：GNU tar 会把 "E:/..." 形式的路由参数当作远程主机
# （host:path 语法）→ "Cannot connect to E: resolve failed"。凡把**盘符路径**传给
# tar（归档文件、-C 目录）都必须带 --force-local；BSD tar（macOS）无此选项，故仅 Windows。
# 用法：tar_local -tzf "$archive"（Windows 下自动补 --force-local）
tar_local() { if is_windows; then tar --force-local "$@"; else tar "$@"; fi; }

# 归档目标/解包目录的父目录：Windows 盘符根（E:/orzmc → E:/）必须保留斜杠，
# 因为 dirname 给出的是 "E:"，GNU tar 会把它当远程主机（host:path）。
# 注意只有父目录**恰为** "X:" 时才补斜杠：C:/Users/x/data 的父目录是 C:/Users/x。
tar_parent_of() {
    local target="${1%/}" parent
    parent="${target%/*}"
    case "$parent" in
        [A-Za-z]:) parent="$parent/" ;;
        "")        parent="/" ;;
    esac
    [ "$parent" = "$target" ] && parent="."
    printf '%s\n' "$parent"
}

# 按 ENABLE_* / 前端拓扑输出应启用的可选服务 profile 列表（换行分隔；读 .env）
# ENABLE_EASYBOT 缺省为 true（保持历史默认启用）；ADR-025 起只剩 easybot 一个可选服务。
# 注意：判断写成 if（避免 set -e 下 [ false ] 返回非零导致函数退出）。
enabled_profiles() {
    local eb ew
    eb="$(read_env_value ENABLE_EASYBOT)";  [ -n "$eb" ] || eb="true"
    if [ "$eb" = "true" ]; then printf '%s\n' "easybot"; fi
    ew="$(read_env_value ENABLE_WEBMC)";  [ -n "$ew" ] || ew="false"
    if [ "$ew" = "true" ]; then printf '%s\n' "webmc"; fi
    # Velocity 前端（ADR-040 起）由 MCSM 面板托管成实例，不再是 compose 服务，
    # 所以这里不再输出 velocity profile。
}

# ---- 前端拓扑：两个正交开关（ADR-036）------------------------------------
#   ENABLE_VELOCITY=true|false   是否用 Velocity 当前端（多服大厅 / 玩家端口由代理发布）
#   ENABLE_EAGLER =true|false    是否接 Eaglercraft Web 客户端
#
# 四种组合，实现方式由 ENABLE_VELOCITY **派生**（不设第三个开关）：
#   V=false E=false  java-only      纯直连基线（缺省）
#   V=false E=true   eagler-direct  实例直挂 EaglerXPaper（不支持 Folia、不能改写 UUID）
#   V=true  E=false  velocity       仅 Velocity（多服大厅；Java/基岩玩家）
#   V=true  E=true   eagler-proxy   代理装 EaglerXServer + Geyser-Velocity（支持 Folia）
#
# 向后兼容：两个开关都未写时按旧 EAGLER_MODE 推导（off/direct/proxy），validate 提示迁移。
legacy_eagler_mode() { read_env_value EAGLER_MODE; }

velocity_enabled() {
    local v
    v="$(read_env_value ENABLE_VELOCITY)"
    if [ -n "$v" ]; then
        if [ "$v" = "true" ]; then return 0; else return 1; fi
    fi
    if [ "$(legacy_eagler_mode)" = "proxy" ]; then return 0; fi
    return 1
}

eagler_enabled() {
    local v
    v="$(read_env_value ENABLE_EAGLER)"
    if [ -n "$v" ]; then
        if [ "$v" = "true" ]; then return 0; else return 1; fi
    fi
    case "$(legacy_eagler_mode)" in
        direct|proxy) return 0 ;;
        *)            return 1 ;;
    esac
}

topology() { # java-only | velocity | eagler-direct | eagler-proxy
    local v e
    if velocity_enabled; then v=1; else v=0; fi
    if eagler_enabled;  then e=1; else e=0; fi
    if [ "$v" = "1" ] && [ "$e" = "1" ]; then printf 'eagler-proxy';  return 0; fi
    if [ "$v" = "1" ]; then                    printf 'velocity';      return 0; fi
    if [ "$e" = "1" ]; then                    printf 'eagler-direct'; return 0; fi
    printf 'java-only'
}

eagler_dialect() { # none | eaglerxpaper | eaglerxserver
    case "$(topology)" in
        eagler-direct) printf 'eaglerxpaper' ;;
        eagler-proxy)  printf 'eaglerxserver' ;;
        *)             printf 'none' ;;
    esac
}

# 基岩（Geyser）装在谁身上：有代理 → Geyser-Velocity（Geyser-Spigot 会自我禁用）；
# 无代理 → 留给实例侧自己装 Geyser-Spigot；EAGLER_GEYSER=false 一律不装。
geyser_target() { # none | spigot | velocity
    local v
    v="$(read_env_value EAGLER_GEYSER)"; [ -n "$v" ] || v="true"
    if [ "$v" != "true" ]; then printf 'none'; return 0; fi
    if velocity_enabled; then printf 'velocity'; else printf 'spigot'; fi
}

eagler_port() { # eagler_port <KEY> <default>
    local v
    v="$(read_env_value "$1")"; [ -n "$v" ] || v="$2"
    printf '%s' "$v"
}

# 端口语义（键名保留 EAGLER_*，避免老 .env 失效）：
#   EAGLER_JAVA_PORT     玩家 Java 入口端口（velocity 拓扑下由代理发布）
#   EAGLER_BACKEND_PORT  仅 velocity：实例发布到宿主的内部端口
#   EAGLER_WS_PORT       反代对外暴露的 WSS 端口（TLS 由站点提供，ADR-027）
eagler_java_port()    { eagler_port EAGLER_JAVA_PORT 25565; }
eagler_backend_port() { eagler_port EAGLER_BACKEND_PORT 25566; }
eagler_ws_port()      { eagler_port EAGLER_WS_PORT 18444; }
eagler_public_host()  { read_env_value EAGLER_PUBLIC_HOST; }

eagler_geyser_enabled() {
    local v
    v="$(read_env_value EAGLER_GEYSER)"; [ -n "$v" ] || v="true"
    printf '%s' "$v"
}
# 多后端（Velocity）：.env 的 VELOCITY_SERVERS=lobby=25567,survival=25566
# 值的两种写法（都能混用）：
#   <端口>            实例发布到宿主的端口 → 归一化为 host.docker.internal:<端口>
#   <主机>:<端口>      任意可解析地址 → 直接用（实例与代理由同一 docker 网络时，
#                     写实例容器名最省事：MCSM-xxxxxx:25565，不用挪宿主端口）
# 留空则退化为单个 lobby = EAGLER_BACKEND_PORT（旧行为，老 .env 不用改）。
velocity_servers() { # 输出 "name=host:port"，每行一个
    local v srv name addr
    v="$(read_env_value VELOCITY_SERVERS)"
    if [ -z "$v" ]; then
        printf 'lobby=host.docker.internal:%s\n' "$(eagler_backend_port)"
        return 0
    fi
    printf '%s\n' "$v" | tr ',' '\n' | while IFS= read -r srv; do
        [ -n "$srv" ] || continue
        case "$srv" in
            *=*) ;;
            *) printf '%s\n' "$srv"; continue ;;
        esac
        name="${srv%%=*}"
        addr="${srv##*=}"
        case "$addr" in
            *:*) printf '%s=%s\n' "$name" "$addr" ;;                       # 已是 host:port
            *)   printf '%s=host.docker.internal:%s\n' "$name" "$addr" ;;  # 只有端口
        esac
    done
}

velocity_try() { # 输出 try 列表里的服务器名（每行一个；缺省取第一个后端）
    local v first
    v="$(read_env_value VELOCITY_TRY)"
    if [ -n "$v" ]; then
        printf '%s\n' "$v" | tr ',' '\n'
        return 0
    fi
    first="$(velocity_servers | head -n1)"
    printf '%s\n' "${first%%=*}"
}

eagler_geyser_port()        { eagler_port EAGLER_GEYSER_PORT 19132; }
# 基岩媒体端口：0 = 复用 EAGLER_GEYSER_PORT（NetherNet-only 的最小端口集合）
eagler_geyser_webrtc_port() { eagler_port EAGLER_GEYSER_WEBRTC_PORT 19134; }

# 基岩传输方式（Geyser 2.12 起 raknet-only 已移除）：
#   both      信令 TCP + RakNet UDP + NetherNet UDP（媒体端口独立）
#   nethernet 只有 NetherNet：媒体可复用主端口（EAGLER_GEYSER_WEBRTC_PORT=0）
# 派生规则：媒体端口为 0 时必然是 nethernet（RakNet 需要独立 UDP 端口）。
eagler_geyser_transport() {
    local v wp
    v="$(read_env_value EAGLER_GEYSER_TRANSPORT)"; [ -n "$v" ] || v="both"
    wp="$(eagler_geyser_webrtc_port)"
    if [ "$wp" = "0" ]; then
        printf 'nethernet'
        return 0
    fi
    printf '%s' "$v"
}

# 是否需要单独发布媒体端口（独立且不同于主端口）
geyser_needs_webrtc_port() {
    local gp wp
    gp="$(eagler_geyser_port)"; wp="$(eagler_geyser_webrtc_port)"
    [ "$wp" != "0" ] && [ "$wp" != "$gp" ]
}

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac }

_check_bool() { # _check_bool <KEY>：允许留空（用缺省）
    local v
    v="$(read_env_value "$1")"
    case "$v" in
        ''|true|false) return 0 ;;
        *) die "${1}=${v} 无效：只允许 true / false" ;;
    esac
}

# 多后端校验：名字合法/端口是数字/不与代理入口撞/名字不重复/try 必须是已定义的名字
validate_velocity_servers() { # <java-port>
    local jp="$1" srv name addr host port t names
    names=""
    while IFS= read -r srv; do
        # 只裁首尾空白：名字中间有空格要报错，不能悄悄改成别的名字
        srv="${srv#"${srv%%[![:space:]]*}"}"
        srv="${srv%"${srv##*[![:space:]]}"}"
        [ -n "$srv" ] || continue
        case "$srv" in
            *=*) ;;
            *) die "VELOCITY_SERVERS 格式应为 <名字>=<宿主端口>，当前项 '${srv}'" ;;
        esac
        name="${srv%%=*}"
        addr="${srv##*=}"
        case "$name" in
            ''|*[!A-Za-z0-9_-]*)
                die "VELOCITY_SERVERS 里的服务器名 '${name}' 非法：只允许字母/数字/下划线/连字符" ;;
        esac
        case "$addr" in
            *:*) host="${addr%:*}"; port="${addr##*:}" ;;
            *)   host="";            port="$addr" ;;
        esac
        case "$host" in
            ''|*[!A-Za-z0-9_.-]*) die "VELOCITY_SERVERS 里 ${name} 的地址 '${host}' 非法（只允许主机名/容器名/IP）" ;;
        esac
        if ! is_uint "$port"; then
            die "VELOCITY_SERVERS 里 ${name} 的端口 '${port}' 不是数字"
        fi
        # 只有走宿主端口（host.docker.internal）时才可能和代理入口抢同一宿主端口；
        # 容器名/内网地址是另一套命名空间，不参与该检查。
        if [ -z "$host" ] || [ "$host" = "host.docker.internal" ]; then
            if [ "$port" = "$jp" ]; then
                die "后端 ${name} 的宿主端口 ${port} 与代理入口端口 EAGLER_JAVA_PORT 相同：实例要让出玩家端口"
            fi
        fi
        case " ${names} " in
            *" ${name} "*) die "VELOCITY_SERVERS 里服务器名 '${name}' 重复" ;;
        esac
        names="${names} ${name}"
    done < <(velocity_servers)
    if [ -z "$names" ]; then
        die "VELOCITY_SERVERS 为空：velocity 拓扑至少需要一个后端"
    fi
    while IFS= read -r t; do
        t="${t#"${t%%[![:space:]]*}"}"
        t="${t%"${t##*[![:space:]]}"}"
        [ -n "$t" ] || continue
        case " ${names} " in
            *" ${t} "*) ;;
            *) die "VELOCITY_TRY 里的 '${t}' 不在 VELOCITY_SERVERS 中（可选：${names# }）" ;;
        esac
    done < <(velocity_try)
}

# 值域/端口一致性校验（validate 调用；不碰网络，不要求运行时就绪）
validate_topology() {
    local topo dialect leg leg_topo jp bp wp ph gp gw gtr
    topo="$(topology)"
    dialect="$(eagler_dialect)"
    leg="$(legacy_eagler_mode)"
    case "$leg" in
        ''|off|direct|proxy) ;;
        *) die "EAGLER_MODE=${leg} 无效：只允许 off / direct / proxy（已废弃，改用 ENABLE_VELOCITY / ENABLE_EAGLER）" ;;
    esac
    _check_bool ENABLE_VELOCITY
    _check_bool ENABLE_EAGLER
    _check_bool EAGLER_GEYSER
    if [ -n "$leg" ] && [ -z "$(read_env_value ENABLE_VELOCITY)" ] \
        && [ -z "$(read_env_value ENABLE_EAGLER)" ] && [ "$leg" != "off" ]; then
        warn "EAGLER_MODE=${leg} 已废弃：建议改成 ENABLE_VELOCITY / ENABLE_EAGLER（当前按 ${topo} 运行）"
    fi
    # 新键在、旧键也在：新键说了算，但必须说出来，避免"改了 EAGLER_MODE 却没反应"
    if [ -n "$leg" ] && [ -n "$(read_env_value ENABLE_VELOCITY)$(read_env_value ENABLE_EAGLER)" ]; then
        case "$leg" in
            off)    leg_topo="java-only" ;;
            direct) leg_topo="eagler-direct" ;;
            proxy)  leg_topo="eagler-proxy" ;;
            *)      leg_topo="" ;;
        esac
        if [ -n "$leg_topo" ] && [ "$topo" != "$leg_topo" ]; then
            warn "EAGLER_MODE=${leg} 已被忽略（新开关优先，当前 ${topo}）：建议删掉 EAGLER_MODE 这一行"
        fi
    fi
    if [ "$topo" = "java-only" ]; then return 0; fi
    jp="$(eagler_java_port)"; bp="$(eagler_backend_port)"; wp="$(eagler_ws_port)"
    if ! is_uint "$jp"; then die "EAGLER_JAVA_PORT 必须是数字（当前 ${jp}）"; fi
    if ! is_uint "$bp"; then die "EAGLER_BACKEND_PORT 必须是数字（当前 ${bp}）"; fi
    if ! is_uint "$wp"; then die "EAGLER_WS_PORT 必须是数字（当前 ${wp}）"; fi
    if [ "$(geyser_target)" != "none" ]; then
        if ! is_uint "$(eagler_geyser_port)"; then die "EAGLER_GEYSER_PORT 必须是数字"; fi
        gp="$(eagler_geyser_port)"; gw="$(eagler_geyser_webrtc_port)"
        if ! is_uint "$gw"; then die "EAGLER_GEYSER_WEBRTC_PORT 必须是数字（0 = 复用 EAGLER_GEYSER_PORT）"; fi
        gtr="$(read_env_value EAGLER_GEYSER_TRANSPORT)"
        case "$gtr" in
            ''|both|nethernet) ;;
            *) die "EAGLER_GEYSER_TRANSPORT=${gtr} 无效：只允许 both / nethernet" ;;
        esac
        if [ "$gw" != "0" ] && [ "$gw" = "$gp" ]; then
            die "EAGLER_GEYSER_WEBRTC_PORT 与 EAGLER_GEYSER_PORT 相同（都是 ${gp}）：复用请写 0，否则换一个端口"
        fi
        if [ "$gtr" = "both" ] && [ "$gw" = "0" ]; then
            die "both 传输需要独立媒体端口：EAGLER_GEYSER_WEBRTC_PORT 不能为 0（或改用 EAGLER_GEYSER_TRANSPORT=nethernet）"
        fi
    fi
    if velocity_enabled; then
        validate_velocity_servers "$jp"
    fi
    if [ "$dialect" != "none" ] && [ "$wp" = "$jp" ]; then
        die "EAGLER_WS_PORT 与 EAGLER_JAVA_PORT 不能相同（当前都是 ${jp}）：反代端口与游戏端口必须分开"
    fi
    if [ "$dialect" != "none" ]; then
        ph="$(eagler_public_host)"
        case "$ph" in
            *'://'*|*/*) die "EAGLER_PUBLIC_HOST 只写域名（不要带协议/路径），当前 ${ph}" ;;
        esac
    fi
    if [ "$dialect" = "eaglerxpaper" ]; then
        warn "eaglerxpaper（ENABLE_VELOCITY=false + ENABLE_EAGLER=true）：不支持 Folia，也不能改写玩家 UUID（无法与 Java 同名共用账号）"
    fi
    return 0
}

# 读 compose.yaml 中 mcsmanager-daemon 的 image（含 digest）。awk：进入 daemon 服务
# 块后取首个 image: 行，遇到下一个 2 空格缩进的服务名即退出。不依赖 python/yq。
daemon_image() {
    awk '/^  mcsmanager-daemon:/{d=1; next}
         d && /^  [a-zA-Z]/{d=0}
         d && /image:/{sub(/^.*image:[[:space:]]*/,""); gsub(/[[:space:]]/,""); print; exit}' "$COMPOSE_FILE"
}

# ---- DATA_ROOT 解析 ------------------------------------------------------
# **没有默认路径**：数据、密钥、备份源全落该目录，默认值只会让人"不知道数据在哪"。
# 必须由调用方显式给出其一（ADR-033）：
#   1) -d/--data-root <路径>（入口脚本解析后直接赋值，不经过本函数）
#   2) export ORZMC_DATA_ROOT=<路径>
# 都没给时直接报错并说明怎么给，不做任何猜测。
resolve_data_root() {
    if [ -n "${ORZMC_DATA_ROOT:-}" ]; then
        printf '%s\n' "$(norm_path "${ORZMC_DATA_ROOT}")"
    else
        die "未指定 DATA_ROOT（数据/密钥/备份都落在这里）：请用 -d/--data-root <路径>，或 export ORZMC_DATA_ROOT=<路径>"
    fi
}

env_file() { printf '%s/.env' "$DATA_ROOT"; }

read_env_value() {
    local key="$1" file
    file="$(env_file)"
    [ -f "$file" ] || return 0
    # 同名键**首次出现优先**（后追加的同名行被忽略——要改值请改原有那一行）。
    # tr -d '\r'：Windows 编辑器会给 .env 加 CRLF，值带 \r 会让 ENABLE_EASYBOT
    # 判定失败、LAN_BIND_ADDR 进 compose 端口时报错（静默降级）。
    grep "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d '=' -f 2- | tr -d '\r' || true
}

# 写回单个键：已存在则替换**第一处**（与 read_env_value 的「首个同名键优先」一致），
# 否则追加。值里允许含空格与 =（用 awk 传参，不走 sed 替换串）。
set_env_value() {
    local key="$1" val="$2" file tmp
    file="$(env_file)"
    case "$key" in ''|*[!A-Za-z0-9_]*) die "非法 env 键：$key" ;; esac
    mkdir -p "$(dirname "$file")"
    [ -f "$file" ] || : > "$file"
    tmp="$(mktemp "${TMPDIR:-/tmp}/env.XXXXXX")"
    awk -v k="$key" -v v="$val" '
        BEGIN { done=0 }
        $0 ~ "^" k "=" && !done { print k "=" v; done=1; next }
        { print }
        END { if (!done) print k "=" v }
    ' "$file" > "$tmp"
    # 若替换后与原文逐字节相同则不动（幂等，避免 mtime 变化触发无谓 rebuild）
    if cmp -s "$tmp" "$file"; then rm -f "$tmp"; return 0; fi
    cp -p "$file" "${file}.bak-$(date +%Y%m%d-%H%M%S)"
    mv "$tmp" "$file"
}

# 校验 env 文件内 DATA_ROOT 与生效值一致（防静默不一致导致卷挂到旧路径）
assert_data_root_matches() {
    local file in_file
    file="$(env_file)"
    [ -f "$file" ] || return 0
    in_file="$(read_env_value DATA_ROOT)"
    [ -z "$in_file" ] && return 0
    if [ "$(norm_path "$in_file")" != "$DATA_ROOT" ]; then
        die "env 内 DATA_ROOT($in_file) 与生效值($DATA_ROOT) 不一致：请修正 $file 或重新 init"
    fi
}

# ---- 目录与文件引导 ------------------------------------------------------

# init 专用：生成 $DATA_ROOT/.env，绝不覆盖已有文件
ensure_env_file() {
    local file
    file="$(env_file)"
    if [ -f "$file" ]; then
        info "env 已存在: $file"
        return 0
    fi
    # shellcheck disable=SC2153  # TEMPLATE 为调用方（deploy.sh/local.sh/lan.sh）设置的全局
    [ -f "$TEMPLATE" ] || die "env 模板不存在: $TEMPLATE"
    mkdir -p "$DATA_ROOT"
    if grep -q '^DATA_ROOT=' "$TEMPLATE"; then
        sed "s#^DATA_ROOT=.*#DATA_ROOT=${DATA_ROOT}#" "$TEMPLATE" > "$file"
    else
        cp "$TEMPLATE" "$file"
        printf 'DATA_ROOT=%s\n' "$DATA_ROOT" >> "$file"
    fi
    chmod 600 "$file"   # 含密钥，收紧权限
    info "已生成 env: $file"
}

# EasyBot 本地覆盖（gateway.local.yaml）：由模板生成，绝不覆盖已有文件。
# EasyBot 从 EASYBOT_HOME（容器 /var/lib/easybot = $DATA_ROOT/easybot/data）解析；
# 当前用途为显式禁用微信适配器（个人微信扫码登录无凭据，默认自动启用）。
ensure_easybot_local_config() {
    local target="$DATA_ROOT/easybot/data/gateway.local.yaml"
    if [ -f "$target" ]; then
        info "gateway.local.yaml 已存在: $target"
        return 0
    fi
    mkdir -p "$(dirname "$target")"
    cp "$TEMPLATES_DIR/gateway.local.yaml" "$target"
    info "已生成 gateway.local.yaml: $target"
}

# 站点增量 override 引导（issue #11）：生成 $DATA_ROOT/compose.site.yaml（绝不覆盖
# 已有文件）。该文件是官方提供的「站点增量挂载点」，与包内 compose.yaml 解耦（升级/换包
# 不丢），compose_cmd 检测到即自动 -f 追加；站点特有增量（飞书凭据、额外 env/挂载）写这里。
ensure_site_override() {
    local target="$DATA_ROOT/compose.site.yaml"
    if [ -f "$target" ]; then
        info "站点 override 已存在: $target"
        return 0
    fi
    [ -f "$TEMPLATES_DIR/compose.site.yaml" ] || die "模板不存在: $TEMPLATES_DIR/compose.site.yaml"
    mkdir -p "$DATA_ROOT"
    cp "$TEMPLATES_DIR/compose.site.yaml" "$target"
    info "已生成站点 override 模板: ${target}（站点增量写这里，升级换包不丢）"
}

ensure_data_dirs() {
    # 只建平台层真正需要的目录（ADR-027 后无边缘层，不再建 caddy/）。
    mkdir -p \
        "$DATA_ROOT/mcsmanager/web/data" \
        "$DATA_ROOT/mcsmanager/web/logs" \
        "$DATA_ROOT/mcsmanager/daemon/data" \
        "$DATA_ROOT/mcsmanager/daemon/logs" \
        "$DATA_ROOT/easybot/data"
    # easybot 镜像默认以 uid/gid=10001 运行，宿主机数据目录需对其可写。
    # 以 root 执行时 chown（Linux 生产常态）；非 root（如 macOS 本地）降级为告警，
    # 此时依赖 Docker Desktop 文件共享即可正常读写。
    if ! chown 10001:10001 "$DATA_ROOT/easybot/data" 2>/dev/null; then
        warn "非 root 无法 chown easybot 数据目录（10001:10001）；Linux 生产部署请以 root 执行 init"
    fi
}

# ---- Windows daemon 生命周期（结构性 docker run）---------------------------
# 仅 Windows 需要：daemon 的实例自挂载卷 target 含驱动器冒号，Docker Compose
# 无法创建（ADR-016）。macOS/Linux 走 compose（compose.yaml 里 daemon 服务定义
# 照旧），Windows 走本组函数手动 docker run。容器名/网络与 compose 定义一致。
daemon_container() { printf '%s\n' "orzmc-mcsmanager-daemon"; }

# 补服务名别名：compose 创建的容器自动有服务名别名，docker run 手动创建的无；
# 面板按 mcsmanager-daemon 解析失败时需补。仅当别名缺失时才操作，且
# docker network connect --alias 无法在容器已连接时更新别名（报 endpoint already
# exists），须先 disconnect 再 connect --alias（ADR-015 §4 同款做法）。仅作用于
# 别名缺失的容器（如新 docker-run 的 daemon），不影响已就绪的 daemon。
win_daemon_alias() {
    local network="orzmc_default"
    local c
    c="$(daemon_container)"
    # 别名已就绪则无操作
    if docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$v.Aliases}}{{end}}' "$c" 2>/dev/null | grep -q 'mcsmanager-daemon'; then
        return 0
    fi
    if docker inspect "$c" >/dev/null 2>&1; then
        dkr network disconnect "$network" "$c" 2>/dev/null || true
        dkr network connect --alias mcsmanager-daemon "$network" "$c" 2>/dev/null || true
    fi
}

# 扫描面板实例配置，输出首个 docker 型实例名（无则无输出）。实例配置由面板写在
# daemon/data/InstanceConfig/<uuid>.json，bind 已落宿主。
find_docker_instance() {
    local root="$1" icfg
    for icfg in "$root"/mcsmanager/daemon/data/InstanceConfig/*.json; do
        [ -f "$icfg" ] || continue
        if grep -qE '"processType"[[:space:]]*:[[:space:]]*"docker"' "$icfg" 2>/dev/null; then
            printf '%s\n' "${icfg##*/}"
            return 0
        fi
    done
    return 0
}

# issue #6/#9：DAEMON_PORTS 只服务**进程模式**实例（java 直接跑在 daemon 容器内）。
# 若同时存在 docker 型实例（实例各自起容器、再发布同宿主端口），daemon 按 DAEMON_PORTS
# 先占 25565/19132，实例启动即报 `port is already allocated`——表现为「实例起不来」而非
# 「端口冲突」，排查易被带偏。故检测到 docker 型实例时**自动忽略** DAEMON_PORTS（幂等且
# 安全：进程模式与 docker 型实例互斥），仅留一条 info 让行为可见；无 docker 型实例时原样
# 输出。详见 docs/usage.md 附录 F。
win_effective_daemon_ports() {
    local root="$1" ports docker_inst
    ports="$(read_env_value DAEMON_PORTS)"
    [ -n "$ports" ] || return 0
    docker_inst="$(find_docker_instance "$root")"
    if [ -n "$docker_inst" ]; then
        info "检测到 docker 型实例（${docker_inst}），已自动忽略 DAEMON_PORTS=${ports}（该变量仅服务进程模式实例，issue #9）" >&2
        if docker inspect "$(daemon_container)" >/dev/null 2>&1; then
            warn "现有 daemon 容器可能已按旧 DAEMON_PORTS 占用宿主端口：请在 .env 置空 DAEMON_PORTS 后 stop && up 重建 daemon"
        fi
        return 0
    fi
    printf '%s\n' "$ports"
}

# 创建 daemon（幂等：已存在则跳过并补别名）。实例数据由 MCSManager 面板默认
# 写入 daemon 容器内 /opt/mcsmanager/daemon/data/InstanceData/<uuid>，经下方
# daemon/data 的 bind 挂载落到宿主机 $DATA_ROOT/mcsmanager/daemon/data/InstanceData。
# docker 型实例还依赖下方 MCSM_DOCKER_WORKSPACE_PATH 做 cwd 宿主路径翻译（issue #4）。
win_daemon_run() {
    local root img tz network port=() extra_ports abs mem heap dport
    # DATA_ROOT 可能是相对路径（local/lan 档的 .local-data）：docker run --mount 要求
    # 绝对源路径，win_path 只处理 C:/ 与 MSYS 前缀，相对路径须先解析为绝对。
    root="$DATA_ROOT"
    if [[ "$root" != /* && "$root" != [A-Za-z]:* ]]; then
        abs="$(cd "$root" 2>/dev/null && pwd)"
        [ -n "$abs" ] && root="$abs"
    fi
    root="$(win_path "$root")"
    img="$(daemon_image)"
    tz="$(read_env_value TZ)"
    network="orzmc_default"
    [ -n "$img" ] || die "无法从 compose.yaml 解析 daemon 镜像"
    # issue #10：容器内存上限与 Node 堆上限收敛到 .env，避免两处漂移（默认 512M/384，
    # 384 留出堆外内存余量）。镜像默认 CMD 带 --max-old-space-size=8192，必须覆盖 CMD
    # 才能真正生效（命令行 flag 优先级高于 NODE_OPTIONS）。
    mem="$(read_env_value DAEMON_MEMORY_LIMIT)"; [ -n "$mem" ] || mem="512M"
    heap="$(read_env_value DAEMON_NODE_HEAP_MB)"; [ -n "$heap" ] || heap="384"
    dport="$(read_env_value MCS_DAEMON_PORT)"; [ -n "$dport" ] || dport="24444"
    # 计算生效的 DAEMON_PORTS（docker 型实例存在时自动忽略，issue #9）；
    # 需在"已存在则跳过"之前求值，存量 daemon 也能给出提示。
    extra_ports="$(win_effective_daemon_ports "$root")"
    if docker inspect "$(daemon_container)" >/dev/null 2>&1; then
        info "daemon 已存在，跳过创建（补别名）"
        win_daemon_alias
        return 0
    fi
    # 确保网络存在（compose up 会创建；首次单独 run 前手动建）
    if ! docker network inspect "$network" >/dev/null 2>&1; then
        dkr network create "$network" >/dev/null 2>&1 || true
    fi
    # 进程模式 PaperMC 实例（cwd 在 daemon 内部）的进服端口须由 daemon 容器 -p 暴露。
    # 生效值由上方 win_effective_daemon_ports 计算（逗号分隔 host:container/proto，供
    # 玩家进服：Java 25565/tcp、基岩 19132/udp 等；存在 docker 型实例时已自动忽略）。
    # lan 模式下 daemon API 端口另发。
    if [ -n "$extra_ports" ]; then
        local oldifs="$IFS"
        IFS=','
        # shellcheck disable=SC2206  # 故意按逗号拆分配置项
        for p in $extra_ports; do
            [ -n "$p" ] && port+=(-p "$p")
        done
        IFS="$oldifs"
    fi
    dkr run -d --name "$(daemon_container)" \
        --restart unless-stopped \
        --memory "$mem" \
        --env "TZ=${tz}" \
        --env "MCSM_DOCKER_WORKSPACE_PATH=${root}/mcsmanager/daemon/data/InstanceData" \
        --mount "type=bind,source=${root}/mcsmanager/daemon/data,target=/opt/mcsmanager/daemon/data" \
        --mount "type=bind,source=${root}/mcsmanager/daemon/logs,target=/opt/mcsmanager/daemon/logs" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        --health-cmd "node -e 'const s=require(\"net\").connect(${dport},\"127.0.0.1\");s.on(\"connect\",()=>{s.destroy();process.exit(0)});s.on(\"error\",()=>process.exit(1));s.setTimeout(3000,()=>process.exit(1));'" \
        --health-interval 30s \
        --health-timeout 5s \
        --health-retries 3 \
        --health-start-period 20s \
        ${port[@]+"${port[@]}"} \
        --network "$network" \
        "$img" node --max-old-space-size="$heap" app.js >/dev/null
    info "daemon 已通过 docker run 创建（Windows 专用路径）"
    win_daemon_alias
}

win_daemon_rm() {
    dkr rm -f "$(daemon_container)" 2>/dev/null || true
}

# 站点增量 override 文件列表（供 compose -f 追加，issue #11）：填充全局数组
# SITE_OVERRIDE_FILES（不用命令替换，以免 die 在子 shell 里静默失效）：
#   1) $DATA_ROOT/compose.site.yaml：init 生成的模板，存在即追加。站点特有增量
#      （飞书凭据、额外 env/挂载）写这里，升级/换包不丢。
#   2) .env 的 COMPOSE_FILE_EXTRA：空格/逗号分隔的额外 compose 文件，路径任意（可放
#      仓库/数据目录之外）。显式配置但不存在的文件给出清晰报错。
SITE_OVERRIDE_FILES=()
collect_site_override_files() {
    local site="$DATA_ROOT/compose.site.yaml" extra f
    SITE_OVERRIDE_FILES=()
    if [ -f "$site" ]; then
        SITE_OVERRIDE_FILES+=("$site")
    fi
    extra="$(read_env_value COMPOSE_FILE_EXTRA)"
    [ -n "$extra" ] || return 0
    for f in ${extra//,/ }; do
        [ -n "$f" ] || continue
        [ -f "$f" ] || die "COMPOSE_FILE_EXTRA 指定的 compose 文件不存在: ${f}"
        SITE_OVERRIDE_FILES+=("$f")
    done
}

# ---- compose 统一入口 ----------------------------------------------------
# compose v2：--env-file 是替换而非叠加项目根 .env，必须显式传入且为真实普通文件。
#   - -f 集合：compose.yaml（含局域网端口发布）+ 站点 override（compose.site.yaml /
#     COMPOSE_FILE_EXTRA）。ADR-027 起没有边缘层 override 文件。
#   - --profile：按 ENABLE_EASYBOT 追加 easybot；核心 web/daemon 无 profile 常驻。
# Windows 适配（ADR-029）：默认交 compose；仅当 .env 设了 DAEMON_PORTS（进程模式实例
# 需要 -p 注入）才用 --no-deps 跳过 daemon 并走 win_daemon_run。down 先 rm 手动容器
# 再 compose down；status 补一行手动 daemon。其余命令（config/exec/validate 等）透传。
compose_cmd() {
    local file
    local -a extra=() profiles_flags=() base=()
    file="$(env_file)"
    [ -f "$file" ] || die "缺少 ${file}，请先执行 init"

    while IFS= read -r p; do
        [ -n "$p" ] && profiles_flags+=("--profile" "$p")
    done < <(enabled_profiles)
    # 基岩端口（Geyser-Velocity）自 ADR-040 起由面板实例的端口映射发布，
    # compose 不再追加 Geyser 端口片段（代理容器已不是 compose 服务）。
    # 站点增量 override（issue #11）：$DATA_ROOT/compose.site.yaml + .env 的
    # COMPOSE_FILE_EXTRA，存在即追加；与包内文件解耦，升级/换包不丢。
    # （判空再用：bash 3.2 + set -u 下空数组 "${arr[@]}" 会被当成未定义变量。）
    collect_site_override_files
    if [ "${#SITE_OVERRIDE_FILES[@]}" -gt 0 ]; then
        for f in "${SITE_OVERRIDE_FILES[@]}"; do
            extra+=(-f "$f")
        done
    fi
    # posix（macOS/Linux）：base 用原生路径 + 站点 override + ENABLE_* profile
    # 数组展开一律用 ${arr[@]+"${arr[@]}"}：bash 3.2/4.3 + set -u 下空数组直接展开
    # 会报 unbound variable（ENABLE_EASYBOT=false 时 profiles_flags 必空）。
    base=(docker compose --env-file "$file" -f "$COMPOSE_FILE" \
        ${extra[@]+"${extra[@]}"} ${profiles_flags[@]+"${profiles_flags[@]}"})

    # ---- Windows + WSL 引擎：compose 必须在 WSL 内执行 --------------------
    # 宿主机路径（E:/...）WSL 侧 dockerd 解析不了，且 DATA_ROOT 是 Windows 形式。
    # 做法：派生一份 DATA_ROOT=/mnt/<盘符>/... 的 env 文件，路径一并换成 WSL 视角，
    # 整条 compose 命令交给 wsl.exe 跑（容器与 dockerd 都在 WSL 里，路径自洽）。
    if is_wsl_backend; then
        local wf wenv wcmd _f _p
        wf="$(wsl_path "$COMPOSE_FILE")"
        wenv="$(wsl_env_file)"
        wcmd="docker compose --env-file $(printf '%q' "$wenv") -f $(printf '%q' "$wf")"
        for _f in ${SITE_OVERRIDE_FILES[@]+"${SITE_OVERRIDE_FILES[@]}"}; do
            wcmd="${wcmd} -f $(printf '%q' "$(wsl_path "$_f")")"
        done
        for _p in ${profiles_flags[@]+"${profiles_flags[@]}"}; do
            wcmd="${wcmd} $(printf '%q' "$_p")"
        done
        for _p in "$@"; do
            wcmd="${wcmd} $(printf '%q' "$_p")"
        done
        # 进程模式实例靠 DAEMON_PORTS 给 daemon 注入 -p；WSL 后端下 daemon 由
        # compose 直接管理，该变量不生效 —— 说出来，别让人以为设了就管用。
        if [ -n "$(read_env_value DAEMON_PORTS)" ]; then
            warn "DOCKER_BACKEND=wsl 下 DAEMON_PORTS 不生效（daemon 由 compose 管理）；进程模式实例请改用 docker 型实例"
        fi
        wsl_run "$wcmd"
        return $?
    fi
    # Windows：COMPOSE_FILE / override / env-file 是 MSYS 路径（/c/...），docker compose
    # 无法解析（会转成 C:\c\...）。须转 Windows 原生正斜杠路径（docs/usage.md 附录 F）。
    if is_windows; then
        file="$(win_path "$file")"
        local -a extra_win=()
        for f in "${extra[@]}"; do
            [ "$f" = "-f" ] && continue
            extra_win+=(-f "$(win_path "$f")")
        done
        base=(docker compose --env-file "$file" -f "$(win_path "$COMPOSE_FILE")" \
            ${extra_win[@]+"${extra_win[@]}"} ${profiles_flags[@]+"${profiles_flags[@]}"})
    fi

    # ---- Windows：daemon 默认交给 compose，仅在需要注入端口时走 docker run ----
    # ADR-029：ADR-019 去掉实例自挂载后，Windows 原生 compose 已能创建 daemon
    # （Docker Desktop 4.95 / compose 29.8 实测）。只有 **进程模式实例** 需要给
    # daemon 注入 `DAEMON_PORTS` 的 `-p`（compose 无法按 .env 动态生成端口列表），
    # 此时才退回 win_daemon_run 的 docker run。
    if is_windows; then
        case "$1" in
            up)
                # 仅全量 up -d 时接管 daemon；指定服务 up（如 backup.sh 拉起的
                # 单服务 up，$#=3）仍交 compose 原样处理。
                if [ "${2:-}" = "-d" ] && [ "$#" -eq 2 ]; then
                    if [ -n "$(read_env_value DAEMON_PORTS)" ]; then
                        local -a svcs=()
                        local s
                        # 进程模式实例：剔除 daemon，由 win_daemon_run 注入 -p
                        # （不用 mapfile：macOS bash 3.2 没有）
                        while IFS= read -r s; do
                            [ -n "$s" ] && svcs+=("$s")
                        done < <("${base[@]}" config --services 2>/dev/null | grep -v '^mcsmanager-daemon$' || true)
                        "${base[@]}" up -d --no-deps ${svcs[@]+"${svcs[@]}"}
                        win_daemon_run
                    else
                        # 常规场景：compose 直接管理 daemon（含服务名别名）
                        "${base[@]}" up -d
                    fi
                    return 0
                fi
                ;;
            down)
                # 手动创建的 daemon 无 compose 标签，compose down 不管它
                win_daemon_rm
                "${base[@]}" down --remove-orphans
                return 0
                ;;
            status|ps)
                # 仅裸 ps/status 时补 daemon 行；ps -q/ps <svc> 等带参数透传
                if [ "$#" -eq 1 ]; then
                    "${base[@]}" "$@"
                    # compose 管理的 daemon 已在上表；只有手动 docker run 的才补齐
                    if [ -z "$(dkr inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$(daemon_container)" 2>/dev/null)" ]; then
                        printf '  %-24s %s\n' "daemon(docker-run)" \
                            "$(dkr inspect -f '{{.State.Status}}' "$(daemon_container)" 2>/dev/null || echo "absent")"
                    fi
                    return 0
                fi
                ;;
        esac
    fi

    "${base[@]}" "$@"
}

# ---- 校验 ---------------------------------------------------------------

# 必需变量（ADR-027 单一边缘：局域网）。
#   - 基础：时区 + 容器内端口 + 局域网入口（宿主 IP / 发布端口）
#   - 可选服务（easybot）仅当 ENABLE_EASYBOT=true 时要求其变量（含 QQ 凭据）
required_env_list() {
    local eb
    eb="$(read_env_value ENABLE_EASYBOT)"; [ -n "$eb" ] || eb="true"
    printf '%s\n' TZ MCS_WEB_PORT MCS_DAEMON_PORT \
        LAN_HOST_IP LAN_MCS_WEB_PORT LAN_EASYBOT_PORT
    if [ "$eb" = "true" ]; then
        printf '%s\n' EASYBOT_PORT EASYBOT_ADMIN_PASSWORD QQBOT_APP_ID QQBOT_CLIENT_SECRET
    fi
}

validate_required_env() {
    local k v
    # while-read 而非 mapfile：macOS 自带 bash 3.2 没有 mapfile/readarray。
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        v="$(read_env_value "$k")"
        [ -n "$v" ] || die "env 缺少必需变量: ${k}（请编辑 $(env_file)）"
    done < <(required_env_list)
}

# ---- 面板中转数据模式（ADR-026）------------------------------------------
# MCSManager 10.22 起浏览器↔daemon 的数据面可由面板中转（SystemConfig.dataPlane
# = proxy，**新装默认**；升级的旧装保留 direct）。中转模式下节点地址固定为内网名
# ws://mcsmanager-daemon:24444，daemon 无需对浏览器/公网暴露任何端口。
# 面板配置属运行数据（面板退出时会回写），故这里**只检查并提示**，不自动改写。
warn_legacy_data_plane() {
    local cfg
    cfg="$DATA_ROOT/mcsmanager/web/data/SystemConfig/config.json"
    [ -f "$cfg" ] || return 0          # 尚未首次启动：面板会按新装默认写 proxy
    grep -q '"dataPlane"[[:space:]]*:[[:space:]]*"proxy"' "$cfg" && return 0
    warn "MCSManager 面板未启用中转数据模式（SystemConfig.dataPlane != proxy）"
    warn "  影响：浏览器需能直连 daemon 地址，节点地址不能填内网名"
    warn "  修复（面板运行时会回写配置，必须停机改）："
    warn "    docker stop orzmc-mcsmanager-web"
    warn "    # 在 ${cfg} 中把 \"dataPlane\" 设为 \"proxy\"（无该键则新增）"
    warn "    docker start orzmc-mcsmanager-web"
    warn "  详见 docs/usage.md §6.3"
}

# ---- 访问地址 -----------------------------------------------------------

print_access_info() {
    local lan_ip bind cidr eb ew wport host wp jp
    lan_ip="$(read_env_value LAN_HOST_IP)"
    bind="$(read_env_value LAN_BIND_ADDR)"; [ -n "$bind" ] || bind="0.0.0.0"
    cidr="$(read_env_value LAN_CIDR)";     [ -n "$cidr" ] || cidr="（未设置）"
    eb="$(read_env_value ENABLE_EASYBOT)"; [ -n "$eb" ] || eb="true"
    ew="$(read_env_value ENABLE_WEBMC)";   [ -n "$ew" ] || ew="false"
    echo "访问地址（局域网）："
    echo "  MCSManager Web: http://${lan_ip}:$(read_env_value LAN_MCS_WEB_PORT)"
    if [ "$eb" = "true" ]; then
        echo "  EasyBot 管理后台: http://${lan_ip}:$(read_env_value LAN_EASYBOT_PORT)"
    else
        echo "  EasyBot: 已禁用（ENABLE_EASYBOT=false）"
    fi
    if [ "$ew" = "true" ]; then
        wport="$(read_env_value LAN_WEBMC_PORT)"; [ -n "$wport" ] || wport="18092"
        echo "  Web 客户端托管: http://${lan_ip}:${wport}"
    else
        echo "  Web 客户端托管: 已禁用（ENABLE_WEBMC=false）"
    fi
    if [ "$bind" = "127.0.0.1" ]; then
        echo "  暴露面: 仅本机（LAN_BIND_ADDR=127.0.0.1，需经反代/VPN 访问）"
    elif [ "$bind" = "0.0.0.0" ]; then
        echo "  暴露面: 所有网卡（LAN_BIND_ADDR=0.0.0.0）—— 建议用防火墙限源："
        echo "          ./orzmc.sh firewall apply   # 默认只放行 LAN_CIDR=${cidr}"
    else
        echo "  暴露面: 仅绑定 ${bind}"
    fi
    # 前端拓扑（ADR-036）：两个开关的派生结果，一行说清楚玩家入口归谁
    case "$(topology)" in
        java-only)
            echo "  前端代理: 未启用（ENABLE_VELOCITY=false，玩家直连实例）"
            ;;
        velocity|eagler-proxy)
            jp="$(eagler_java_port)"
            echo "  Velocity: Java 入口 ${jp} → 后端 $(velocity_servers | tr '\n' ' ' | sed 's/ $//')（EAGLERCRAFT=$(if eagler_enabled; then echo on; else echo off; fi)）"
            if [ "$(geyser_target)" = "velocity" ]; then
                if [ "$(eagler_geyser_webrtc_port)" = "0" ]; then
                    echo "  Geyser（基岩）: tcp/$(eagler_geyser_port)（信令） + udp/$(eagler_geyser_port)（媒体，transport=$(eagler_geyser_transport)）"
                else
                    echo "  Geyser（基岩）: tcp/$(eagler_geyser_port)（信令） + udp/$(eagler_geyser_port) + udp/$(eagler_geyser_webrtc_port)（媒体）"
                fi
            fi
            echo "  实例侧待办: ${DATA_ROOT}/eagler/instance-setup.md"
            ;;
        eagler-direct)
            jp="$(eagler_java_port)"
            echo "  Eagler 直挂: 实例 ${jp} 同端口兼任 WSS（无代理；不支持 Folia / 不能改 UUID）"
            echo "  实例侧待办: ${DATA_ROOT}/eagler/instance-setup.md"
            ;;
    esac
    if [ "$(eagler_dialect)" != "none" ]; then
        wp="$(eagler_ws_port)"
        host="$(eagler_public_host)"; [ -n "$host" ] || host="<你的域名>"
        echo "  Eaglercraft Web: wss://${host}:${wp}/  （浏览器客户端；TLS 由站点反代提供）"
    fi
    echo "  外部访问: 由站点自备（VPN / TLS 反代 / DDNS+端口映射），见 docs/security.md"
}

