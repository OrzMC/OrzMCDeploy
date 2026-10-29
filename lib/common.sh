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
# Windows 与 macOS/Linux 的主要差异（详见 docs/windows-deployment.md）：
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

# MSYS/原生路径 → Windows 原生正斜杠形式（docker 用）：C:/...、E:/...
win_path() {
    local p="$1"
    case "$p" in
        [A-Za-z]:*) printf '%s\n' "${p//\\//}" ;;   # 已是原生（E:\ 或 E:/），统一正斜杠
        /*) printf '%s\n' "$(cygpath -m "$p" 2>/dev/null || printf '%s' "$p")" ;;
        *) printf '%s\n' "${p//\\//}" ;;
    esac
}

# ---- 可选服务 -------------------------------------------------------------
# 按 ENABLE_* 输出应启用的可选服务 profile 列表（换行分隔；读 .env）
# ENABLE_EASYBOT 缺省为 true（保持历史默认启用）；ADR-025 起只剩 easybot 一个可选服务。
# 注意：判断写成 if（避免 set -e 下 [ false ] 返回非零导致函数退出）。
enabled_profiles() {
    local eb
    eb="$(read_env_value ENABLE_EASYBOT)";  [ -n "$eb" ] || eb="true"
    if [ "$eb" = "true" ]; then printf '%s\n' "easybot"; fi
}

# 读 compose.yaml 中 mcsmanager-daemon 的 image（含 digest）。awk：进入 daemon 服务
# 块后取首个 image: 行，遇到下一个 2 空格缩进的服务名即退出。不依赖 python/yq。
daemon_image() {
    awk '/^  mcsmanager-daemon:/{d=1; next}
         d && /^  [a-zA-Z]/{d=0}
         d && /image:/{sub(/^.*image:[[:space:]]*/,""); gsub(/[[:space:]]/,""); print; exit}' "$COMPOSE_FILE"
}

# ---- DATA_ROOT 解析 ------------------------------------------------------
# 优先级：-d/--data-root 参数（由各脚本解析后赋值）> ORZMC_DATA_ROOT 环境变量 > 平台默认值：
#   Windows E:/orzmc（必须原生路径：WSL 侧 compose 建不了 E:/ 绑定，见 ADR-029）
#   macOS   /Users/Shared/orzmc（Docker Desktop 共享目录）
#   Linux   /srv/orzmc
# 默认值按平台区分是有意为之：文档/AGENTS 一直按平台描述默认值，代码也必须一致
# （否则 Windows 上默认会落到 MSYS 的 /srv/orzmc，与文档不符）。
default_data_root() {
    if is_windows; then
        printf '%s\n' "E:/orzmc"
    elif [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
        printf '%s\n' "/Users/Shared/orzmc"
    else
        printf '%s\n' "/srv/orzmc"
    fi
}

resolve_data_root() {
    if [ -n "${ORZMC_DATA_ROOT:-}" ]; then
        printf '%s\n' "$(norm_path "${ORZMC_DATA_ROOT}")"
    else
        default_data_root
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
        docker network disconnect "$network" "$c" 2>/dev/null || true
        docker network connect --alias mcsmanager-daemon "$network" "$c" 2>/dev/null || true
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
# 输出。详见 docs/windows-deployment.md §4。
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
        docker network create "$network" >/dev/null 2>&1 || true
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
    docker run -d --name "$(daemon_container)" \
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
    docker rm -f "$(daemon_container)" 2>/dev/null || true
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
    # Windows：COMPOSE_FILE / override / env-file 是 MSYS 路径（/c/...），docker compose
    # 无法解析（会转成 C:\c\...）。须转 Windows 原生正斜杠路径（docs/windows-deployment.md §7）。
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
                    if [ -z "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$(daemon_container)" 2>/dev/null)" ]; then
                        printf '  %-24s %s\n' "daemon(docker-run)" \
                            "$(docker inspect -f '{{.State.Status}}' "$(daemon_container)" 2>/dev/null || echo "absent")"
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
    local lan_ip bind cidr eb
    lan_ip="$(read_env_value LAN_HOST_IP)"
    bind="$(read_env_value LAN_BIND_ADDR)"; [ -n "$bind" ] || bind="0.0.0.0"
    cidr="$(read_env_value LAN_CIDR)";     [ -n "$cidr" ] || cidr="（未设置）"
    eb="$(read_env_value ENABLE_EASYBOT)"; [ -n "$eb" ] || eb="true"
    echo "访问地址（局域网）："
    echo "  MCSManager Web: http://${lan_ip}:$(read_env_value LAN_MCS_WEB_PORT)"
    if [ "$eb" = "true" ]; then
        echo "  EasyBot 管理后台: http://${lan_ip}:$(read_env_value LAN_EASYBOT_PORT)"
    else
        echo "  EasyBot: 已禁用（ENABLE_EASYBOT=false）"
    fi
    if [ "$bind" = "127.0.0.1" ]; then
        echo "  暴露面: 仅本机（LAN_BIND_ADDR=127.0.0.1，需经反代/VPN 访问）"
    elif [ "$bind" = "0.0.0.0" ]; then
        echo "  暴露面: 所有网卡（LAN_BIND_ADDR=0.0.0.0）—— 建议用防火墙限源："
        echo "          ./orzmc.sh firewall apply   # 默认只放行 LAN_CIDR=${cidr}"
    else
        echo "  暴露面: 仅绑定 ${bind}"
    fi
    echo "  外部访问: 由站点自备（VPN / TLS 反代 / DDNS+端口映射），见 docs/security.md"
}

