#!/usr/bin/env bash
# ===========================================================================
# OrzMC deploy 共享函数库
#
# 架构原则：仓库只承载"运行时"，全部配置与数据落在 $DATA_ROOT（统一目录）。
# 三 Profile：local=Caddy(.localhost 反代) / prod=cloudflared(Cloudflare Tunnel) /
#            lan=无边缘层直连（compose.lan.yaml 发布源站宿主端口，纯 HTTP，局域网）。
# 本库统一处理：
#   - DATA_ROOT 解析与一致性校验
#   - env 文件（$DATA_ROOT/.env）读写
#   - 数据目录树与边缘层配置引导（Caddyfile / cloudflared config）
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
DEFAULT_DATA_ROOT="/srv/orzmc"
# shellcheck disable=SC2034  # 供 deploy.sh 读取（TEMPLATE 默认值），跨文件可见
DEFAULT_TEMPLATE="${TEMPLATES_DIR}/env.prod"

# compose Profile 模型（ADR-017）：单 profile + 可插拔服务 + 可插拔边缘层。
#   - EDGE：边缘层选择（cloudflare|local|lan|none），由 .env 的 EDGE 决定；
#     compose_cmd 按 EDGE 追加对应 override 文件（compose.edge.<edge>.yaml）。
#   - ENABLE_EASYBOT：可选服务开关（true|false），compose_cmd 按启用项追加
#     --profile easybot。核心 web/daemon 常驻。ADR-025 起不再有 mariadb/status。
#   - 兼容：旧的 COMPOSE_PROFILE=prod|local|lan 由 orzmc.sh / deploy.sh 映射到 EDGE
#     （prod→cloudflare，local→local，lan→lan），旧入口脚本不破坏。
EDGE="${EDGE:-cloudflare}"

# ---- 日志 ---------------------------------------------------------------

info() { printf '[info] %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
die()  { printf '[error] %s\n' "$*" >&2; exit 1; }

# 去掉末尾斜杠，便于路径比较
norm_path() { printf '%s\n' "${1%/}"; }

# ---- 平台检测 -------------------------------------------------------------
# Windows 下 daemon 的实例自挂载卷 target 含驱动器冒号，Docker Compose 无法创建
# （见 ADR-016 / docs/windows-deployment.md §3）：compose 只对「target 含冒号」的
# bind 序列化失败，source 含冒号无碍。因此 Windows 下 daemon 须用 docker run --
# mount 手动创建（结构性必然），其余服务（web/easybot/边缘层）的
# 卷 target 均无冒号，本可由 compose 管理。三平台统一：macOS/Linux 全 compose；
# Windows 下脚本自动生成 daemon 的 docker run 命令 + 补网络别名 + 转原生路径，
# 用户命令与 macOS/Linux 完全一致。
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

# ---- 边缘层与可选服务（ADR-017）-------------------------------------------
# EDGE 归一：把兼容的旧 COMPOSE_PROFILE(prod/local/lan) 映射到新 EDGE；EDGE 本身
# 已是 cloudflare|local|lan|none 时原样。优先显式 EDGE（.env 新配置），否则读
# COMPOSE_PROFILE（旧入口脚本仍设置它）。
normalize_edge() {
    local e="${EDGE:-${COMPOSE_PROFILE:-cloudflare}}"
    case "$e" in
        prod) printf '%s\n' "cloudflare" ;;
        local|lan|cloudflare|none) printf '%s\n' "$e" ;;
        *) die "未知 EDGE: ${e}（可选 cloudflare|local|lan|none）" ;;
    esac
}

# 当前 EDGE 对应的边缘层 override 文件（无则空——EDGE=none）
edge_override_file() {
    local e
    e="$(normalize_edge)"
    case "$e" in
        cloudflare) printf '%s\n' "${COMPOSE_FILE%.yaml}.edge.cloudflare.yaml" ;;
        local)      printf '%s\n' "${COMPOSE_FILE%.yaml}.edge.local.yaml" ;;
        lan)        printf '%s\n' "${COMPOSE_FILE%.yaml}.edge.lan.yaml" ;;
        none)       return 0 ;;
    esac
}

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
# 优先级：-d/--data-root 参数（由各脚本解析后赋值）> ORZMC_DATA_ROOT 环境变量 > 默认 /srv/orzmc
resolve_data_root() {
    if [ -n "${ORZMC_DATA_ROOT:-}" ]; then
        printf '%s\n' "$(norm_path "${ORZMC_DATA_ROOT}")"
    else
        printf '%s\n' "$DEFAULT_DATA_ROOT"
    fi
}

env_file() { printf '%s/.env' "$DATA_ROOT"; }

read_env_value() {
    local key="$1" file
    file="$(env_file)"
    [ -f "$file" ] || return 0
    grep "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d '=' -f 2- || true
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

# 防坑：compose 对不存在的宿主机文件路径会以"目录"方式自动创建，
# Caddy 会把目录当 Caddyfile 挂载而失败。这里强制落成普通文件。
ensure_caddyfile() {
    local target="$DATA_ROOT/caddy/Caddyfile"
    if [ -f "$target" ] && [ ! -d "$target" ]; then
        info "Caddyfile 已存在: $target"
        return 0
    fi
    rm -rf "$target"
    mkdir -p "$(dirname "$target")"
    cp "$TEMPLATES_DIR/Caddyfile" "$target"
    info "已生成 Caddyfile: $target"
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

# prod profile 专用：由 templates/cloudflared-config.yml 用 .env 的
# CLOUDFLARE_TUNNEL_ID / DOMAIN_MCS_WEB / DOMAIN_EASY_ADMIN
# 替换占位符，生成 $DATA_ROOT/cloudflared/config.yml。仅当 CLOUDFLARE_TUNNEL_ID
# 已填写时生成；与当前 .env 一致时不动（已落盘 config 属运行数据），不一致时
# 覆盖并留备份（config.yml 完全由 .env 派生，.env 为唯一事实源）。
ensure_cloudflared_config() {
    local tid mcs_domain easy_domain target tmp
    tid="$(read_env_value CLOUDFLARE_TUNNEL_ID)"
    [ -n "$tid" ] || { warn "CLOUDFLARE_TUNNEL_ID 未设置，跳过 cloudflared config 生成"; return 0; }
    mcs_domain="$(read_env_value DOMAIN_MCS_WEB)"
    easy_domain="$(read_env_value DOMAIN_EASY_ADMIN)"
    mkdir -p "$DATA_ROOT/cloudflared"
    target="$DATA_ROOT/cloudflared/config.yml"
    tmp="$(mktemp)"
    sed -e "s#__CLOUDFLARE_TUNNEL_ID__#${tid}#g" \
        -e "s#__DOMAIN_MCS_WEB__#${mcs_domain}#g" \
        -e "s#__DOMAIN_EASY_ADMIN__#${easy_domain}#g" \
        "$TEMPLATES_DIR/cloudflared-config.yml" > "$tmp"
    if [ -f "$target" ] && cmp -s "$target" "$tmp"; then
        info "cloudflared config 已就绪: $target"
        rm -f "$tmp"
        return 0
    fi
    if [ -f "$target" ]; then
        cp "$target" "${target}.bak.$(date +%Y%m%d-%H%M%S)"
        warn "cloudflared config 与 .env 不一致，已备份旧文件并重新生成"
    fi
    mv "$tmp" "$target"
    chmod 600 "$target"   # 含隧道 ID，收紧权限
    info "已生成 cloudflared config: $target"
}

ensure_data_dirs() {
    mkdir -p \
        "$DATA_ROOT/caddy/data" \
        "$DATA_ROOT/caddy/config" \
        "$DATA_ROOT/cloudflared" \
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
# 输出。详见 docs/windows-deployment.md §10 P9。
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
        "${port[@]}" \
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
# Profile 模型（ADR-017）：单 profile + 可插拔服务 + 可插拔边缘层。
#   - -f 集合：compose.yaml（核心+可选服务定义）+ 按 EDGE 追加 compose.edge.<edge>.yaml。
#   - --profile：按 ENABLE_EASYBOT 追加可启用的可选服务（easybot）；核心
#     web/daemon 无 profile 常驻。EDGE 决定边缘层 override，与 --profile 无关。
# Windows 适配（ADR-016）：daemon 实例自挂载 target 含驱动器冒号，compose 无法
# 创建。up 时用 --no-deps + 显式列出非 daemon 服务让 compose 跳过 daemon，再走
# win_daemon_run docker run；down 先 rm daemon 再 compose down；status 补一行
# daemon 状态。macOS/Linux 走原生 compose 全流程。其余命令（config/exec/validate
# 等）在 Windows 下同样透传 compose。
compose_cmd() {
    local file edge
    local -a extra=() profiles_flags=() base=()
    file="$(env_file)"
    [ -f "$file" ] || die "缺少 ${file}，请先执行 init"
    edge="$(normalize_edge)"
    case "$edge" in
        local)
            [ -f "$DATA_ROOT/caddy/Caddyfile" ] || die "缺少 Caddyfile，请先执行 init"
            extra=(-f "$(edge_override_file)")
            ;;
        cloudflare)
            [ -f "$DATA_ROOT/cloudflared/config.yml" ] || die "缺少 cloudflared/config.yml，请先执行 init 并配置 CLOUDFLARE_TUNNEL_ID"
            extra=(-f "$(edge_override_file)")
            ;;
        lan)
            # 无边缘层：追加 compose.edge.lan.yaml 给 4 个源站发布宿主端口（纯 HTTP，局域网）
            extra=(-f "$(edge_override_file)")
            ;;
        none)
            # EDGE=none：仅内网 orzmc_default，不追加边缘层 override
            extra=()
            ;;
    esac
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
    # posix（macOS/Linux）：base 用原生路径 + 边缘层 override + ENABLE_* profile
    base=(docker compose --env-file "$file" -f "$COMPOSE_FILE" "${extra[@]}" "${profiles_flags[@]}")
    # Windows：COMPOSE_FILE / override / env-file 是 MSYS 路径（/c/...），docker compose
    # 无法解析（会转成 C:\c\...）。须转 Windows 原生正斜杠路径（docs/windows-deployment.md §7）。
    if is_windows; then
        file="$(win_path "$file")"
        local -a extra_win=()
        for f in "${extra[@]}"; do
            [ "$f" = "-f" ] && continue
            extra_win+=(-f "$(win_path "$f")")
        done
        base=(docker compose --env-file "$file" -f "$(win_path "$COMPOSE_FILE")" "${extra_win[@]}" "${profiles_flags[@]}")
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
                        # 进程模式实例：剔除 daemon，由 win_daemon_run 注入 -p
                        mapfile -t svcs < <("${base[@]}" config --services 2>/dev/null | grep -v '^mcsmanager-daemon$')
                        "${base[@]}" up -d --no-deps "${svcs[@]}"
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

# 必需变量按 EDGE + ENABLE_* 动态组装：
#   - 基础（所有 EDGE 都要求）：web/daemon 端口 + 可选服务各自的必备项。
#   - 可选服务（easybot）仅当 ENABLE_EASYBOT=true 时要求其变量。
#   - 边缘层变量按 EDGE 追加（cloudflare→CLOUDFLARE_TUNNEL_ID+DOMAIN；local→CADDY+
#     PROXY；lan→LAN_HOST_IP+LAN_*_PORT；none→无）。
# QQ 凭据由 easybot 服务消费，仅 easybot 启用时必填。
required_env_list() {
    local eb edge
    eb="$(read_env_value ENABLE_EASYBOT)"; [ -n "$eb" ] || eb="true"
    edge="$(normalize_edge)"
    printf '%s\n' TZ MCS_WEB_PORT MCS_DAEMON_PORT
    if [ "$eb" = "true" ]; then
        printf '%s\n' EASYBOT_PORT EASYBOT_ADMIN_PASSWORD QQBOT_APP_ID QQBOT_CLIENT_SECRET
    fi
    case "$edge" in
        cloudflare)
            printf '%s\n' CLOUDFLARE_TUNNEL_ID DOMAIN_MCS_WEB DOMAIN_EASY_ADMIN
            ;;
        local)
            printf '%s\n' CADDY_EMAIL PROXY_HTTP_PORT PROXY_HTTPS_PORT \
                DOMAIN_MCS_WEB DOMAIN_EASY_ADMIN
            ;;
        lan)
            printf '%s\n' LAN_HOST_IP LAN_MCS_WEB_PORT LAN_EASYBOT_PORT
            ;;
    esac
}

validate_required_env() {
    local k v list
    mapfile -t list < <(required_env_list)
    for k in "${list[@]}"; do
        v="$(read_env_value "$k")"
        [ -n "$v" ] || die "env 缺少必需变量: ${k}（请编辑 $(env_file)）"
    done
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
    local mcs_web easy_admin edge
    mcs_web="$(read_env_value DOMAIN_MCS_WEB)"
    easy_admin="$(read_env_value DOMAIN_EASY_ADMIN)"
    edge="$(normalize_edge)"
    echo "访问地址（EDGE: ${edge}）:"
    case "$edge" in
        cloudflare)
            # cloudflare：Cloudflare 边缘终止 TLS，标准 443，无端口后缀
            echo "  MCSManager Web: https://${mcs_web}"
            echo "  EasyBot 管理后台: https://${easy_admin}"
            ;;
        lan)
            # lan：无边缘层纯 HTTP，局域网设备用 http://<LAN_HOST_IP>:<LAN_*_PORT>
            echo "  MCSManager Web: http://$(read_env_value LAN_HOST_IP):$(read_env_value LAN_MCS_WEB_PORT)"
            echo "  EasyBot 管理后台: http://$(read_env_value LAN_HOST_IP):$(read_env_value LAN_EASYBOT_PORT)"
            ;;
        local)
            # local：Caddy 本地 CA，.localhost + 非特权端口
            echo "  MCSManager Web: https://${mcs_web}:$(read_env_value PROXY_HTTPS_PORT)"
            echo "  EasyBot 管理后台: https://${easy_admin}:$(read_env_value PROXY_HTTPS_PORT)"
            ;;
        none)
            # none：仅内网 orzmc_default，无对外入口；打印内网地址提示
            echo "  内网访问（orzmc_default，无边缘层）:"
            echo "  MCSManager Web: http://mcsmanager-web:$(read_env_value MCS_WEB_PORT)"
            echo "  EasyBot 管理后台: http://easybot:$(read_env_value EASYBOT_PORT)"
            ;;
    esac
}
