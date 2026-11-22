#!/usr/bin/env bash
# =============================================================================
# site.sh —— 站点层 TLS 供给（v0.4.0）
#
# 背景：ADR-027 之后项目本体不再提供边缘层，公网入口（Caddy + Let's Encrypt
# DNS-01）落在站点增量 $DATA_ROOT/compose.site.yaml 与 $DATA_ROOT/site/Caddyfile
# 里。此前这两份文件是**手抄**的：新增一个子域要复制整段 block、`flush_interval -1`
# 与 `header_up X-Real-IP {remote_host}` 漏一处就是「WS 连不上 / 玩家被拒」。
#
# 本模块把这两份文件变成**由一条声明生成**：
#   .env: SITE_ROUTES="域=上游|选项;域=上游|选项"
#   选项：ws（flush_interval -1，长连接必须） / xrip（注入 X-Real-IP） / encode（zstd gzip）
#
# 例（本站现网实证）：
#   SITE_ROUTES="mcs.jokerhub.cn=mcsmanager-web:23333|ws,encode;\
#                easybot.jokerhub.cn=easybot:8080|encode;\
#                dev.jokerhub.cn=orzmc-velocity:25565|ws,xrip;\
#                music.jokerhub.cn=host.docker.internal:8080|encode"
#
# 子命令：
#   site init    从**现有** Caddyfile 反推 SITE_ROUTES 写进 .env（幂等，已有则不覆盖），
#                并确认 compose.site.yaml 里有受管的 caddy 区块（标记区）
#   site apply   依 .env 渲染 Caddyfile → caddy adapt 校验 → 备份 → 落盘 → reload
#                （校验失败不落盘；reload 失败自动回滚）
#   site status  列出「声明 vs 落盘」差异、各域证书剩余天数、容器是否在跑
#
# 不变量：
#   - 证书由 Caddy 自己续（ACME 状态在 $DATA_ROOT/caddy/data），本模块**绝不改**
#     caddy/data，也绝不手工续期。
#   - compose.site.yaml 里其它站点增量（velocity dns、easybot 的 FEISHU_*）不受影响：
#     只重写 `# >>> orzmc:site:caddy` 与 `# <<< orzmc:site:caddy` 之间的区块。
# =============================================================================
set -euo pipefail

# 本文件既可独立执行（orzmc.sh site ...）也可被 deploy.sh source（probe 用 site_parse_routes）。
# 用 BASH_SOURCE 定位自身目录，而不是 $0（被 source 时 $0 是调用方）。
SITE_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F info >/dev/null 2>&1; then
    SCRIPT_DIR="${SITE_LIB_DIR}"
    # shellcheck source=lib/common.sh
    source "${SITE_LIB_DIR}/common.sh"
fi

SITE_MARK_BEGIN='# >>> orzmc:site:caddy （本区块由 orzmc.sh site apply 生成，勿手改）'
SITE_MARK_END='# <<< orzmc:site:caddy'
# 带 dns.providers.cloudflare 的官方构建；版本与 digest 在此单点维护
SITE_CADDY_IMAGE="${SITE_CADDY_IMAGE:-ghcr.io/caddybuilds/caddy-cloudflare@sha256:17505a5e55432764957953787b065f400a1f1a0c280c3b4da2c99ce4746708d6}"

site_caddyfile() { printf '%s/site/Caddyfile' "$DATA_ROOT"; }
site_compose()   { printf '%s/compose.site.yaml' "$DATA_ROOT"; }

# ---------------------------------------------------------------- 解析 SITE_ROUTES
# 输出每行：domain<TAB>upstream<TAB>opts
site_parse_routes() {
    local raw entry domain rest upstream opts
    raw="$(read_env_value SITE_ROUTES || true)"
    [ -n "$raw" ] || return 0
    # 支持 ; 空格 换行三种分隔
    # 末尾补换行：while read 会丢掉「没有以换行结尾」的最后一行（最后一个域会静默消失）
    printf '%s\n' "$raw" | tr ';' '\n' | while IFS= read -r entry; do
        entry="$(printf '%s' "$entry" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$entry" ] || continue
        case "$entry" in \#*) continue ;; esac
        domain="${entry%%=*}"
        rest="${entry#*=}"
        upstream="${rest%%|*}"
        opts=""
        [ "$rest" != "$upstream" ] && opts="${rest#*|}"
        [ -n "$domain" ] && [ -n "$upstream" ] || die "SITE_ROUTES 条目格式错：$entry（应为 域=上游|选项）"
        printf '%s\t%s\t%s\n' "$domain" "$upstream" "$opts"
    done
}

site_has_opt() { case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------- 渲染 Caddyfile
site_render() {
    cat <<'EOF'
# =============================================================================
# 本文件由 `./orzmc.sh site apply` 依 .env 的 SITE_ROUTES 生成 —— 不要手改。
# 改路由：编辑 $DATA_ROOT/.env 的 SITE_ROUTES，然后重新 `site apply`。
#
# 拓扑：公网 <高位端口> ──路由器──> 宿主 443 ──> Caddy(容器 :443) ──> 各上游
# 证书：Let's Encrypt **DNS-01**（Cloudflare API 写 _acme-challenge TXT），
#       不依赖入站 80/443，适合家宽端口被封 / CGNAT。Token 取 .env 的
#       CF_DNS_API_TOKEN（权限只需 Zone:DNS:Edit 且限定本 zone）。
# 续期：Caddy 自动完成，ACME 状态在 $DATA_ROOT/caddy/data —— 不要手工续期、
#       不要删该目录。
# =============================================================================
{
	email {$ACME_EMAIL}

	# 只开 h1/h2：家用路由器对 UDP 443 的转发/hairpin 常不可靠，留着 h3 会让浏览器
	# 先试 QUIC 再回退，表现为「偶尔打不开 / 白屏」。确认 UDP 443 真能到达再开。
	servers {
		protocols h1 h2
	}
}
EOF
    local domain upstream opts name
    site_parse_routes | while IFS="$(printf '\t')" read -r domain upstream opts; do
        [ -n "$domain" ] || continue
        name="$(printf '%s' "$domain" | cut -d. -f1)"
        # shellcheck disable=SC2016  # {$CF_DNS_API_TOKEN} 是 Caddyfile 占位符，故意不求值
        printf '\n# %s -> %s\n%s {\n\ttls {\n\t\tdns cloudflare {$CF_DNS_API_TOKEN}\n\t}\n' \
            "$domain" "$upstream" "$domain"
        if site_has_opt "$opts" encode; then
            printf '\tencode zstd gzip\n'
        fi
        if site_has_opt "$opts" ws || site_has_opt "$opts" xrip; then
            printf '\treverse_proxy %s {\n' "$upstream"
        else
            printf '\treverse_proxy %s\n' "$upstream"
        fi
        if site_has_opt "$opts" ws; then
            printf '\t\t# 长连接（WS/终端/游戏）：关掉响应缓冲，否则握手/推送被攒住\n\t\tflush_interval -1\n'
        fi
        if site_has_opt "$opts" xrip; then
            printf '\t\t# EaglerXServer forward_ip=true 时缺此头直接拒连\n\t\theader_up X-Real-IP {remote_host}\n'
        fi
        if site_has_opt "$opts" ws || site_has_opt "$opts" xrip; then
            printf '\t}\n'
        fi
        printf '\tlog {\n\t\toutput file /data/access-%s.log {\n\t\t\troll_size 10mb\n\t\t\troll_keep 3\n\t\t}\n\t}\n}\n' "$name"
    done
}

# ------------------------------------------------- 从现有 Caddyfile 反推 SITE_ROUTES
site_derive_routes() {
    local f domain upstream opts
    f="$(site_caddyfile)"
    [ -f "$f" ] || return 0
    awk '
        /^[A-Za-z0-9][A-Za-z0-9.-]*[ \t]*\{/ {
            gsub(/[ \t]*\{.*/, "", $0)
            if (dom != "" && up != "") printf "%s=%s|%s;", dom, up, opts wsflag(up)
            dom=$0; up=""; opts=""
            next
        }
        dom != "" && /reverse_proxy / {
            line=$0; sub(/^[ \t]*reverse_proxy[ \t]+/, "", line); sub(/[ \t]*\{.*/, "", line)
            up=line
            next
        }
        dom != "" && /flush_interval[ \t]+-1/ { if (index(opts,"ws")==0) opts = (opts=="" ? "ws" : opts ",ws") }
        dom != "" && /header_up[ \t]+X-Real-IP/ { if (index(opts,"xrip")==0) opts = (opts=="" ? "xrip" : opts ",xrip") }
        dom != "" && /^[ \t]*encode[ \t]/ { if (index(opts,"encode")==0) opts = (opts=="" ? "encode" : opts ",encode") }
        END { if (dom != "" && up != "") printf "%s=%s|%s;", dom, up, opts wsflag(up) }
        # Velocity 的 :25565 是真正的 WebSocket 入口（Eaglercraft 浏览器客户端），
        # 反推时补 wscheck，让 status --probe 对它做 Upgrade 探测；
        # 面板的 ws 只是终端长连接，探 / 无意义（上游会 EOF）。
        function wsflag(u) { return (u ~ /velocity/ || u ~ /:25565$/) ? (opts == "" ? "wscheck" : ",wscheck") : "" }
    ' "$f" | sed 's/;$//'
}

# ---------------------------------------------------------------- compose 受管区块
site_compose_block() {
    cat <<EOF
$SITE_MARK_BEGIN
  caddy:
    image: ${SITE_CADDY_IMAGE}
    container_name: orzmc-caddy
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 256M
    environment:
      TZ: "\${TZ}"
      ACME_EMAIL: "\${ACME_EMAIL}"
      # DNS-01 验证用（Cloudflare Token 只在 .env，不入库）
      CF_DNS_API_TOKEN: "\${CF_DNS_API_TOKEN}"
    ports:
      # 运营商封的是**外网** 443；宿主内网 443 正常，公网入口由路由器
      # 外网 <高位端口> → 宿主 443 → 本容器 443。不要改成高位端口:443，
      # 那样宿主 443 无人监听，路由器转发会打到空端口。
      - "443:443"
    volumes:
      - "\${DATA_ROOT}/site/Caddyfile:/etc/caddy/Caddyfile:ro"
      - "\${DATA_ROOT}/caddy/data:/data"
      - "\${DATA_ROOT}/caddy/config:/config"
    depends_on:
      - mcsmanager-web
$SITE_MARK_END
EOF
}

# 在 compose.site.yaml 中就地替换标记区；没有标记就追加
site_write_compose() {
    local f tmp
    f="$(site_compose)"
    tmp="$(mktemp "${TMPDIR:-/tmp}/site-compose.XXXXXX")"
    if [ ! -f "$f" ]; then
        {
            echo "# 站点增量 override（随数据存放，升级换包不丢）。caddy 区块由 site apply 管理。"
            echo "services:"
            site_compose_block
        } > "$tmp"
    elif grep -qF "$SITE_MARK_BEGIN" "$f"; then
        awk -v b="$SITE_MARK_BEGIN" -v e="$SITE_MARK_END" -v blk="$(site_compose_block)" '
            $0 == b { print blk; skip=1; next }
            skip && $0 == e { skip=0; next }
            !skip { print }
        ' "$f" > "$tmp"
    elif grep -qE '^  caddy:[[:space:]]*$' "$f"; then
        # 无标记但已有手写 caddy 服务（v0.3.x 及更早的站点增量）：
        # 就地**替换**该服务块，而不是再插入一个（重复 key 会让 compose 直接报错）。
        # 服务块边界：`^  caddy:` 起，到下一个 `^  <name>:` 或文末。
        awk -v blk="$(site_compose_block)" '
            /^  caddy:[[:space:]]*$/ { print blk; skip=1; next }
            skip && /^  [A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*$/ { skip=0 }
            !skip { print }
        ' "$f" > "$tmp"
    else
        # 无标记也无 caddy：在 services: 之后插入区块
        awk -v blk="$(site_compose_block)" '
            !done && /^services:[[:space:]]*$/ { print; print blk; done=1; next }
            { print }
        ' "$f" > "$tmp"
    fi
    cmp -s "$tmp" "$f" && { rm -f "$tmp"; info "compose.site.yaml 已是目标状态，跳过"; return 0; }
    [ -f "$f" ] && cp -p "$f" "${f}.bak-$(date +%Y%m%d-%H%M%S)"
    mv "$tmp" "$f"
    info "已更新 $(basename "$f")"
}

# ---------------------------------------------------------------- 校验（caddy adapt）
site_validate_file() {
    local file="$1" img
    img="$SITE_CADDY_IMAGE"
    if ! dkr image inspect "$img" >/dev/null 2>&1; then
        warn "本地无 $img，跳过语法校验（首次 apply 时 compose 会拉取）"
        return 0
    fi
    # 校验要带上 .env 里的变量：Caddyfile 里 {$ACME_EMAIL} / {$CF_DNS_API_TOKEN} 为空时
    # caddy 会直接报 "wrong argument count ... after 'email'"，看起来像语法错，其实是空值。
    local email token
    email="$(read_env_value ACME_EMAIL || true)"
    [ -n "$email" ] || email="admin@example.com"
    token="$(read_env_value CF_DNS_API_TOKEN || true)"
    local mount
    if is_wsl_backend; then
        mount="$(wsl_path "$file")"
    else
        mount="$(win_path "$file")"
    fi
    dkr run --rm -e "ACME_EMAIL=${email}" -e "CF_DNS_API_TOKEN=${token:-dummy}" \
        -v "${mount}:/etc/caddy/Caddyfile:ro" \
        --entrypoint caddy "$img" adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
}

# ---------------------------------------------------------------- 子命令
site_cmd_init() {
    local routes derived force="${1:-}"
    routes="$(read_env_value SITE_ROUTES || true)"
    derived="$(site_derive_routes)"
    if [ -z "$routes" ]; then
        [ -n "$derived" ] || die "既无 SITE_ROUTES，也无法从 $(site_caddyfile) 反推；请在 .env 手写 SITE_ROUTES"
        set_env_value SITE_ROUTES "$derived"
        info "已从现有 Caddyfile 反推 SITE_ROUTES 写入 .env（$(printf '%s' "$derived" | tr ';' '\n' | grep -c '=' || true) 条）"
    elif [ "$routes" = "$derived" ]; then
        info "SITE_ROUTES 与落盘一致，保持不变"
    elif [ "$force" = "--force" ]; then
        set_env_value SITE_ROUTES "$derived"
        info "已用反推结果覆盖 SITE_ROUTES（--force）"
    else
        # 声明与落盘不一致时不静默吞掉：这是「改了 Caddyfile 却没改声明」或反之的典型现场
        warn "SITE_ROUTES 与现有 Caddyfile 反推结果不一致（未改动）："
        printf '  声明: %s\n  反推: %s\n' "$routes" "$derived"
        warn "确认以落盘为准就加 --force：./orzmc.sh -d $DATA_ROOT site init --force"
    fi
    site_write_compose
    info "init 完成。下一步：./orzmc.sh -d $DATA_ROOT site status"
}

site_cmd_apply() {
    local f
    [ -n "$(read_env_value CF_DNS_API_TOKEN || true)" ] || die "缺少 CF_DNS_API_TOKEN（DNS-01 必需）"
    [ -n "$(read_env_value ACME_EMAIL || true)" ] || die "缺少 ACME_EMAIL（Let\'s Encrypt 注册邮箱；空值会让 caddy 报看似语法错的错）"
    [ -n "$(read_env_value SITE_ROUTES || true)" ] || die "缺少 SITE_ROUTES，先跑 site init"
    f="$(site_caddyfile)"
    mkdir -p "$(dirname "$f")"
    local tmp="${f}.new"
    site_render > "$tmp"
    if ! site_validate_file "$tmp"; then
        rm -f "$tmp"
        die "生成的 Caddyfile 未通过 caddy adapt 校验，已丢弃（原文件未动）"
    fi
    info "语法校验通过"
    [ -f "$f" ] && cp -p "$f" "${f}.bak-$(date +%Y%m%d-%H%M%S)"
    mv "$tmp" "$f"
    info "已写入 $(site_caddyfile)"

    site_write_compose

    if dkr ps --format '{{.Names}}' | tr -d '\r' | grep -qx 'orzmc-caddy'; then
        if dkr exec orzmc-caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
            info "Caddy 已热重载（未重启容器，连接不中断）"
        else
            warn "热重载失败，回滚到上一个 Caddyfile"
            local bak
            # shellcheck disable=SC2012  # macOS BSD find 无 -printf，按 mtime 排序只能用 ls
            bak="$(ls -1t "${f}".bak-* 2>/dev/null | head -1 || true)"
            [ -n "$bak" ] && cp -p "$bak" "$f"
            dkr exec orzmc-caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
            die "reload 失败，已回滚；请检查 docker logs orzmc-caddy"
        fi
    else
        warn "orzmc-caddy 未运行；文件已就位，下次 up 生效"
    fi
    site_cmd_status
}

site_cmd_status() {
    local f declared ondisk
    f="$(site_caddyfile)"
    declared="$(site_parse_routes | cut -f1 | sort -u | tr '\n' ' ')"
    if [ -f "$f" ]; then
        ondisk="$(site_derive_routes | tr ';' '\n' | cut -d= -f1 | sort -u | tr '\n' ' ')"
    else
        ondisk=""
    fi
    printf '%-28s %s\n' "声明（.env）" "${declared:-<空>}"
    printf '%-28s %s\n' "落盘（Caddyfile）" "${ondisk:-<空>}"
    if [ "$declared" = "$ondisk" ]; then info "一致"; else warn "不一致：先 site apply"; fi

    local container
    container="orzmc-caddy"
    if dkr ps --format '{{.Names}}' | tr -d '\r' | grep -qx "$container"; then
        info "orzmc-caddy 运行中"
    else
        warn "orzmc-caddy 未运行"
    fi
    # 证书天数交给 cert.sh，避免两套实现
    if [ -f "${SITE_LIB_DIR}/cert.sh" ]; then
        bash "${SITE_LIB_DIR}/cert.sh" -d "$DATA_ROOT" || true
    fi
}

site_dispatch() {
    local cmd="${1:-status}"
    [ "$#" -gt 0 ] && shift
    case "$cmd" in
        init)   site_cmd_init "${1:-}" ;;   # shift 后 $1 才是 --force
        apply)  site_cmd_apply ;;
        render) site_render ;;        # 只打印，不落盘（写进 /tmp 对比用）
        status) site_cmd_status ;;
        -h|--help|help)
            cat <<'EOF'
用法: ./orzmc.sh -d <数据目录> site <init|apply|status>

  init [--force]  从现有 Caddyfile 反推 SITE_ROUTES 写入 .env（已存在且不一致时需 --force），并确认 compose 受管区块
  apply   依 SITE_ROUTES 渲染 Caddyfile → caddy adapt 校验 → 备份 → 落盘 → 热重载
  render  只把渲染结果打到 stdout（不落盘、不校验），用于 review / diff
  status  声明与落盘是否一致、容器状态、各域证书剩余天数

路由写法（.env）：
  SITE_ROUTES="域=上游|选项;域=上游|选项"
  选项：ws（长连接必须）/ xrip（注入 X-Real-IP）/ encode（zstd gzip）
        wscheck（该域的 / 是 WebSocket 入口，status --probe 会做 Upgrade 探测）
EOF
            ;;
        *) die "未知 site 子命令：$cmd" ;;
    esac
}

# ---------------------------------------------------------------- 入口
# 被 deploy.sh source 时不要执行（否则会把调用方的参数吃掉）
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
DATA_ROOT="${DATA_ROOT:-}"
while [ "$#" -gt 0 ]; do
    case "$1" in
        -d|--data-root) [ "$#" -ge 2 ] || die "$1 需要一个参数"; DATA_ROOT="$(norm_path "$2")"; shift 2 ;;
        -h|--help) site_dispatch help; exit 0 ;;
        --) shift; break ;;
        -*) die "未知选项: $1" ;;
        *) break ;;
    esac
done
[ -n "$DATA_ROOT" ] || DATA_ROOT="$(resolve_data_root)"
apply_docker_backend
export DATA_ROOT
assert_data_root_matches
site_dispatch "$@"
fi
