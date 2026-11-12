#!/usr/bin/env bash
# ===========================================================================
# Eaglercraft Web 接入的可选运行时（EAGLER_MODE≠off 时由 deploy.sh source）
#
# 单一开关（ADR-035）：
#   EAGLER_MODE=off     不启用（缺省；不下载、不起服务、零影响）
#   EAGLER_MODE=direct  实例直挂 EaglerXPaper（同端口兼任 WSS；Java 连接方式不变；
#                       **不支持 Folia**，不能改写玩家 UUID）
#   EAGLER_MODE=proxy   Velocity + EaglerXServer 接管玩家端口（支持 Folia；多后端；
#                       可在代理层改写用户名/UUID）
#
# 本文件只做三件事：下载校验（templates/eagler/versions.env 锁版本）→ 生成代理配置
# → 生成实例侧待办（$DATA_ROOT/eagler/instance-setup.md）。TLS 反代归站点自备
# （ADR-027），片段见 templates/eagler/Caddyfile.snippet。
#
# 约定：
#   - 生成物一律落 $DATA_ROOT/eagler/（随数据备份），密钥 600；
#   - 配置/密钥**绝不覆盖已有文件**（ensure_* 语义），只有生成说明文档会刷新；
#   - bash 3.2：不用 mapfile/关联数组；消息里变量一律 ${VAR}。
# ===========================================================================

# ---- 版本锁 -------------------------------------------------------------

EAGLER_LOCK_FILE="${TEMPLATES_DIR}/eagler/versions.env"

eagler_lock() { # eagler_lock <KEY>
    [ -f "$EAGLER_LOCK_FILE" ] || die "缺少版本锁: ${EAGLER_LOCK_FILE}"
    grep "^$1=" "$EAGLER_LOCK_FILE" 2>/dev/null | head -n1 | cut -d '=' -f 2- | tr -d '\r'
}

# ---- 通用小工具 ---------------------------------------------------------

eagler_dir()        { printf '%s/eagler' "${DATA_ROOT}"; }
eagler_proxy_dir()  { printf '%s/proxy' "$(eagler_dir)"; }
eagler_jars_dir()   { printf '%s/jars' "$(eagler_dir)"; }
eagler_setup_doc()  { printf '%s/instance-setup.md' "$(eagler_dir)"; }
eagler_caddy_doc()  { printf '%s/caddy-eagler.snippet' "$(eagler_dir)"; }

eagler_sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        die "需要 sha256sum 或 shasum 才能校验下载文件"
    fi
}

# macOS(BSD) 与 GNU 的 sed -i 语法不同：先试 GNU，失败再退回 BSD
sed_inplace() { # sed_inplace <sed-expr> <file>
    if sed --version >/dev/null 2>&1; then
        sed -i "$1" "$2"
    else
        sed -i '' "$1" "$2"
    fi
}

# ---- 下载与校验 ---------------------------------------------------------

eagler_fetch() { # eagler_fetch <url> <dest> <sha256> <label>
    local url="$1" dest="$2" want="$3" label="$4" tmp have
    if [ -f "$dest" ]; then
        have="$(eagler_sha256_of "$dest")"
        if [ "$have" = "$want" ]; then
            info "${label} 已就绪（sha256 匹配）"
            return 0
        fi
        warn "${label} 校验不符，重新下载（旧文件将被替换）"
    fi
    mkdir -p "$(dirname -- "$dest")"
    tmp="${dest}.part"
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        die "需要 curl 或 wget 才能下载 ${label}"
    fi
    # 官方源偶发 TLS 中断（实测），重试 3 次再放弃
    local attempt
    attempt=1
    while :; do
        rm -f "$tmp"
        if command -v curl >/dev/null 2>&1; then
            curl -fL --retry 2 --connect-timeout 20 -o "$tmp" "$url" && break
        else
            wget -q -O "$tmp" "$url" && break
        fi
        if [ "$attempt" -ge 3 ]; then
            rm -f "$tmp"
            die "下载失败（已重试 3 次）: ${url}"
        fi
        warn "下载中断，${attempt}/3 后重试: ${url}"
        attempt=$((attempt + 1))
        sleep 3
    done
    have="$(eagler_sha256_of "$tmp")"
    if [ "$have" != "$want" ]; then
        rm -f "$tmp"
        die "${label} sha256 不符（期望 ${want}，实际 ${have}）；版本锁见 ${EAGLER_LOCK_FILE}"
    fi
    mv "$tmp" "$dest"
    info "已下载 ${label}: ${dest}"
}

# ---- 生成物 -------------------------------------------------------------

eagler_ensure_secret() { # eagler_ensure_secret <file>
    local f="$1" s
    if [ -f "$f" ]; then
        return 0
    fi
    if command -v openssl >/dev/null 2>&1; then
        s="$(openssl rand -hex 16)"
    elif [ -r /dev/urandom ]; then
        s="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    else
        die "无法生成 forwarding.secret（缺少 openssl 与 /dev/urandom）"
    fi
    [ -n "$s" ] || die "生成的 forwarding.secret 为空"
    mkdir -p "$(dirname -- "$f")"
    printf '%s' "$s" > "$f"
    chmod 600 "$f"
    info "已生成转发密钥: ${f}"
}

eagler_render_velocity_toml() { # eagler_render_velocity_toml <dest> <backend-host:port>
    local dest="$1" backend="$2"
    if [ -f "$dest" ]; then
        info "velocity.toml 已存在（不覆盖）: ${dest}"
        return 0
    fi
    sed "s#__EAGLER_BACKEND__#${backend}#g" "${TEMPLATES_DIR}/eagler/velocity.toml" > "$dest"
    info "已生成 velocity.toml: ${dest}"
}

# EaglerXServer 首次启动才会生成 listeners.toml；已有则把两个关键项改成面向反代的值。
# 返回 0=有改动（调用方据此重启代理），1=无改动。
eagler_patch_listeners() {
    local f="$1" before after
    [ -f "$f" ] || return 1
    before="$(eagler_sha256_of "$f")"
    # 反代在站点侧：玩家真实 IP 由反代写进 X-Real-IP（与 Caddyfile.snippet 一致）
    if grep -qE '^[[:space:]]*forward_ip[[:space:]]*=' "$f"; then
        sed_inplace 's#^[[:space:]]*forward_ip[[:space:]]*=.*#	forward_ip = true#' "$f"
    fi
    if grep -qE '^[[:space:]]*forward_ip_header[[:space:]]*=' "$f"; then
        sed_inplace 's#^[[:space:]]*forward_ip_header[[:space:]]*=.*#	forward_ip_header = "X-Real-IP"#' "$f"
    fi
    after="$(eagler_sha256_of "$f")"
    [ "$before" != "$after" ]
}

# settings.toml 的帧长下调（1.1.1 安全公告建议；默认 131071 偏高）。
# 返回 0=有改动，1=无改动。
eagler_patch_settings() {
    local f="$1" before after
    [ -f "$f" ] || return 1
    before="$(eagler_sha256_of "$f")"
    if grep -qE '^[[:space:]]*http_websocket_max_frame_length[[:space:]]*=' "$f"; then
        sed_inplace 's#^[[:space:]]*http_websocket_max_frame_length[[:space:]]*=.*#	http_websocket_max_frame_length = 65535#' "$f"
    fi
    after="$(eagler_sha256_of "$f")"
    [ "$before" != "$after" ]
}

eagler_write_caddy_snippet() { # eagler_write_caddy_snippet <upstream-host>
    local up="$1" dest host cert
    dest="$(eagler_caddy_doc)"
    host="$(eagler_public_host)"
    if [ -n "$host" ]; then
        # 取最后两段做通配（dev.jokerhub.cn → *.jokerhub.cn）；不是三段域名则原样
        case "$host" in
            *.*.*) cert="*.$(printf '%s' "$host" | cut -d '.' -f 2-)" ;;
            *)     cert="$host" ;;
        esac
    else
        cert="*.<你的域名>"
    fi
    sed -e "s#__EAGLER_CERT_DOMAIN__#${cert}#g" -e "s#__EAGLER_UPSTREAM__#${up}#g" \
        "${TEMPLATES_DIR}/eagler/Caddyfile.snippet" > "$dest"
    info "已生成反代片段: ${dest}（追加到站点 Caddyfile，站点自己重启 caddy）"
}

eagler_write_setup_doc() { # eagler_write_setup_doc <direct|proxy>
    local mode="$1" dest jp bp wp host secret_line
    dest="$(eagler_setup_doc)"
    jp="$(eagler_java_port)"
    bp="$(eagler_backend_port)"
    wp="$(eagler_ws_port)"
    host="$(eagler_public_host)"
    [ -n "$host" ] || host="<你的域名>"
    if [ "$mode" = "proxy" ] && [ -f "$(eagler_proxy_dir)/forwarding.secret" ]; then
        secret_line="$(cat "$(eagler_proxy_dir)/forwarding.secret")"
    else
        secret_line="（direct 模式不需要）"
    fi
    {
        echo "# Eaglercraft 接入：实例侧待办（EAGLER_MODE=${mode}）"
        echo
        echo "> 本文件由 ./orzmc.sh 自动生成，每次 up 会刷新；实例由 MCSManager 面板管理，"
        echo "> 仓库不能替你改实例——照下面抄即可。原理与验收见 docs/eaglercraft.md /"
        echo "> docs/eaglercraft-deploy.md。"
        echo
        echo "## 1. 后端实例（Paper/Folia）"
        echo
        echo "- 实例目录：\`\$DATA_ROOT/mcsmanager/daemon/data/InstanceData/<实例uuid>/\`"
        echo "- \`server.properties\`：\`online-mode=false\`（桥接层不支持在线模式，ADR-035）"
        if [ "$mode" = "proxy" ]; then
            echo "- \`docker.ports\`（面板 → 实例 → 端口映射）：**删掉** \`25565:25565/tcp\`，"
            echo "  改成 \`${bp}:25565/tcp\`（玩家端口让给代理 \`${jp}\`）"
        else
            echo "- \`docker.ports\`：保持现状（\`${jp}:25565/tcp\`），Java 连接方式不变"
        fi
        echo "- \`plugins/\`：ViaVersion + ViaBackwards（版本见 docs/eaglercraft.md §7）"
        if [ "$mode" = "direct" ]; then
            echo "- \`plugins/\`：再加 **EaglerXPaper**："
            echo "  \`cp $(eagler_jars_dir)/EaglerXPaper.jar \$DATA_ROOT/mcsmanager/daemon/data/InstanceData/<实例uuid>/plugins/\`"
            echo "- 注意：direct 模式**不支持 Folia**，也不能改写玩家 UUID"
        fi
        echo
        if [ "$mode" = "proxy" ]; then
            echo "## 2. Velocity 转发（写进实例 \`config/paper-global.yml\`）"
            echo
            echo '```yaml'
            echo "proxies:"
            echo "  velocity:"
            echo "    enabled: true"
            echo "    online-mode: false"
            echo "    secret: '${secret_line}'"
            echo "    enabled-force-key-authentication: false"
            echo '```'
            echo
            echo "secret 与代理的 \`\$DATA_ROOT/eagler/proxy/forwarding.secret\` 必须一致（600 权限，随备份）。"
            echo
        fi
        echo "## 3. 反代（站点自备，TLS 终结）"
        echo
        echo "- 片段：\`\$DATA_ROOT/eagler/caddy-eagler.snippet\` → 追加到站点 Caddyfile"
        echo "- 给站点 caddy 服务加端口映射：\`\"${wp}:8443\"\`，路由器转发 ${wp}/TCP 到宿主"
        echo "- 防火墙：按站点自建 TLS 规则放行（docs/security.md §4），**不要**写进 MC_PUBLIC_TCP"
        echo
        echo "## 4. 玩家入口"
        echo
        echo "- Java：\`${host}:${jp}\`（proxy 模式经代理；direct 模式直连实例）"
        echo "- Web ：\`wss://${host}:${wp}/\`（浏览器客户端）"
        echo
        echo "## 5. 验收"
        echo
        echo '```bash'
        echo "python3 tests/eaglercraft_probe.py --host ${host} --port ${wp} --tls"
        echo '```'
        echo
        echo "期望：\`eagler_protocol=5 minecraft_protocol=777\`。"
    } > "$dest"
    chmod 600 "$dest"
    info "已生成实例待办: ${dest}"
}

# 端口占用体检：proxy 模式要求「EAGLER_JAVA_PORT 归代理、EAGLER_BACKEND_PORT 归实例」。
# 只在实例正在运行时能看见（面板停实例会移除容器），所以这里是**告警**而不是硬失败——
# 真正兜底的是 compose 起不来时的端口冲突报错。
eagler_check_port_conflicts() {
    command -v docker >/dev/null 2>&1 || return 0
    local p busy
    for p in "$(eagler_java_port)" "$(eagler_backend_port)"; do
        busy="$(docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null \
            | awk -F'|' -v port=":${p}->" '$2 ~ port && $1 != "orzmc-eagler-proxy" {print $1}' \
            | head -n 2 | tr '\n' ' ')"
        if [ -n "$busy" ]; then
            warn "端口 ${p} 已被容器占用：${busy}——proxy 模式需要 EAGLER_JAVA_PORT 归代理、EAGLER_BACKEND_PORT 归实例，请先在面板改实例端口映射"
        fi
    done
    return 0
}

# ---- 主流程 -------------------------------------------------------------

eagler_prepare() {
    local mode
    mode="$(eagler_mode)"
    case "$mode" in
        off) return 0 ;;
        direct)
            mkdir -p "$(eagler_jars_dir)"
            eagler_fetch "$(eagler_lock EAGLERXPAPER_URL)" \
                "$(eagler_jars_dir)/EaglerXPaper-$(eagler_lock EAGLERXPAPER_VERSION).jar" \
                "$(eagler_lock EAGLERXPAPER_SHA256)" "EaglerXPaper $(eagler_lock EAGLERXPAPER_VERSION)"
            eagler_write_setup_doc direct
            eagler_write_caddy_snippet "host.docker.internal"
            ;;
        proxy)
            local pdir backend
            eagler_check_port_conflicts
            pdir="$(eagler_proxy_dir)"
            mkdir -p "${pdir}/plugins"
            eagler_fetch "$(eagler_lock VELOCITY_URL)" "${pdir}/velocity.jar" \
                "$(eagler_lock VELOCITY_SHA256)" "Velocity $(eagler_lock VELOCITY_VERSION)-$(eagler_lock VELOCITY_BUILD)"
            eagler_fetch "$(eagler_lock EAGLERXSERVER_URL)" "${pdir}/plugins/EaglerXServer.jar" \
                "$(eagler_lock EAGLERXSERVER_SHA256)" "EaglerXServer $(eagler_lock EAGLERXSERVER_VERSION)"
            eagler_ensure_secret "${pdir}/forwarding.secret"
            backend="host.docker.internal:$(eagler_backend_port)"
            eagler_render_velocity_toml "${pdir}/velocity.toml" "$backend"
            eagler_write_setup_doc proxy
            eagler_write_caddy_snippet "orzmc-eagler-proxy"
            ;;
    esac
}

# up 之后调用：EaglerXServer 已生成 listeners.toml 则修正为面向反代的配置。
# 返回 0 表示改过（需要重启代理容器才生效）。
eagler_post_up() {
    local mode cfg changed
    mode="$(eagler_mode)"
    [ "$mode" = "proxy" ] || return 1
    cfg="$(eagler_proxy_dir)/plugins/eaglerxserver"
    changed=1
    if eagler_patch_listeners "${cfg}/listeners.toml"; then
        info "已修正 listeners.toml（forward_ip / X-Real-IP）"
        changed=0
    fi
    if eagler_patch_settings "${cfg}/settings.toml"; then
        info "已修正 settings.toml（http_websocket_max_frame_length=65535）"
        changed=0
    fi
    return "$changed"
}

# validate 用：检查运行时是否就绪（只告警，不因缺文件失败——init 后 up 前是常态）
eagler_runtime_check() {
    local mode
    mode="$(eagler_mode)"
    [ "$mode" = "off" ] && return 0
    if [ "$mode" = "proxy" ]; then
        if [ ! -f "$(eagler_proxy_dir)/velocity.jar" ] || [ ! -f "$(eagler_proxy_dir)/plugins/EaglerXServer.jar" ]; then
            warn "代理运行时未就绪（首次 up 会自动下载；离线环境请预置 $(eagler_proxy_dir)）"
        fi
    else
        if ! ls "$(eagler_jars_dir)"/EaglerXPaper-*.jar >/dev/null 2>&1; then
            warn "EaglerXPaper 未下载（首次 up 会自动下载）"
        fi
    fi
    return 0
}
