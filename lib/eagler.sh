#!/usr/bin/env bash
# ===========================================================================
# 前端拓扑的可选运行时（ENABLE_VELOCITY / ENABLE_EAGLER 任一为 true 时由 deploy.sh source）
#
# 两个正交开关（ADR-036），四种组合，实现方式由 ENABLE_VELOCITY 派生的：
#   V=false E=false  java-only      纯直连基线（缺省；本文件不下载、不生成任何东西）
#   V=false E=true   eagler-direct  实例直挂 EaglerXPaper（同端口兼任 WSS；不支持 Folia，
#                                   不能改写玩家 UUID）
#   V=true  E=false  velocity       仅 Velocity（多服大厅；玩家端口由代理发布）
#   V=true  E=true   eagler-proxy   代理装 EaglerXServer（+ 默认 Geyser-Velocity）
#
# 基岩端口跟着前端走：geyser_target()=velocity 时由代理托管，否则留给实例侧
# Geyser-Spigot。ADR-040 起代理是面板实例，19132 等端口写在该实例的端口映射里。
#
# 本文件只做三件事：下载校验（templates/eagler/versions.env 锁版本）→ 生成代理配置
# → 生成实例侧待办（$DATA_ROOT/eagler/instance-setup.md）。TLS 反代归站点自备
# （ADR-027），片段见 templates/eagler/Caddyfile.snippet。
#
# 约定：
#   - 生成物一律落 $DATA_ROOT/eagler/（随数据备份），密钥 600；
#   - 配置/密钥**绝不覆盖已有文件**（ensure_* 语义），只有生成说明文档会刷新；
#   - 切换拓扑时，当前拓扑不需要的插件会被移到 $DATA_ROOT/eagler/disabled/，
#     避免 ENABLE_EAGLER=false 之后 Web 端点仍然可连；
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
# 代理数据目录（ADR-040）：Velocity 已由 MCSM 面板托管成实例，数据落在面板的实例目录
# （InstanceData/<uuid>/，容器里就是 /server），不再是 $DATA_ROOT/eagler/proxy。
# 解析顺序：.env 的 VELOCITY_DIR → 面板实例目录里已有 velocity-*.jar 的那个 → 旧的 proxy 目录。
eagler_proxy_dir()  {
    local override d inst
    override="$(read_env_value VELOCITY_DIR 2>/dev/null | tr -d '\r')"
    if [ -n "${override}" ]; then printf '%s' "${override}"; return 0; fi
    inst="${DATA_ROOT}/mcsmanager/daemon/data/InstanceData"
    if [ -d "${inst}" ]; then
        for d in "${inst}"/*; do
            [ -d "${d}" ] || continue
            if [ -f "${d}/velocity.toml" ] || ls "${d}"/velocity-*.jar >/dev/null 2>&1; then
                printf '%s' "${d}"; return 0
            fi
        done
    fi
    printf '%s/proxy' "$(eagler_dir)"
}
# 代理 jar：面板实例里带版本号（velocity-4.3.1.jar），旧的固定名 velocity.jar 也认。
eagler_proxy_jar() {
    local pdir
    pdir="$(eagler_proxy_dir)"
    ls "${pdir}"/velocity-*.jar 2>/dev/null | head -n1
}
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

eagler_render_velocity_toml() { # eagler_render_velocity_toml <dest>
    local dest="$1" line srv name addr sname saddr t
    if [ -f "$dest" ]; then
        info "velocity.toml 已存在（不覆盖）: ${dest}"
        return 0
    fi
    : > "${dest}.tmp"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '__VELOCITY_SERVERS__')
                # 多后端：每个实例发布到宿主的端口各占一行
                while IFS= read -r srv; do
                    [ -n "$srv" ] || continue
                    name="${srv%%=*}"
                    addr="${srv##*=}"   # 已是 host:port（容器名或 host.docker.internal）
                    printf '%s = "%s"\n' "$name" "$addr" >> "${dest}.tmp"
                done < <(velocity_servers)
                ;;
            '__VELOCITY_TRY__')
                # 玩家首次落地顺序：try 列表第一个即默认服
                while IFS= read -r t; do
                    [ -n "$t" ] || continue
                    printf '    "%s",\n' "$t" >> "${dest}.tmp"
                done < <(velocity_try)
                ;;
            *)
                printf '%s\n' "$line" >> "${dest}.tmp"
                ;;
        esac
    done < "${TEMPLATES_DIR}/eagler/velocity.toml"
    mv "${dest}.tmp" "$dest"
    info "已生成 velocity.toml（后端 $(velocity_servers | tr '\n' ' ' | sed 's/ $//')）: ${dest}"
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
        # 默认用**显式域名**：实测通配证书在部分家宽/令牌下会卡 DNS-01 传播检查。
        # 想覆盖多个子域名，手工把这里改成 *.your.domain（见模板注释）。
        cert="$host"
    else
        cert="<你的域名>"
    fi
    sed -e "s#__EAGLER_CERT_DOMAIN__#${cert}#g" -e "s#__EAGLER_UPSTREAM__#${up}#g" \
        "${TEMPLATES_DIR}/eagler/Caddyfile.snippet" > "$dest"
    info "已生成反代片段: ${dest}（追加到站点 Caddyfile，站点自己重启 caddy）"
}

eagler_write_setup_doc() { # eagler_write_setup_doc <velocity|eagler-direct|eagler-proxy>
    local topo="$1" dest jp bp wp host secret_line have_vel have_eg uses_host_ports
    dest="$(eagler_setup_doc)"
    jp="$(eagler_java_port)"
    bp="$(eagler_backend_port)"
    wp="$(eagler_ws_port)"
    host="$(eagler_public_host)"
    [ -n "$host" ] || host="<你的域名>"
    case "$topo" in
        velocity|eagler-proxy) have_vel=1 ;;
        *)                     have_vel=0 ;;
    esac
    case "$topo" in
        eagler-direct|eagler-proxy) have_eg=1 ;;
        *)                          have_eg=0 ;;
    esac
    uses_host_ports=0
    if [ "$have_vel" = "1" ]; then
        while IFS= read -r srv; do
            case "$srv" in
                *=host.docker.internal:*) uses_host_ports=1 ;;
            esac
        done < <(velocity_servers)
    fi
    if [ "$have_vel" = "1" ] && [ -f "$(eagler_proxy_dir)/forwarding.secret" ]; then
        secret_line="$(cat "$(eagler_proxy_dir)/forwarding.secret")"
    else
        secret_line="（eaglerxpaper 不需要）"
    fi
    {
        echo "# 前端拓扑：实例侧待办（ENABLE_VELOCITY=$(if [ "$have_vel" = "1" ]; then echo true; else echo false; fi)"
        echo "#               ENABLE_EAGLER=$(if [ "$have_eg" = "1" ]; then echo true; else echo false; fi)）"
        echo
        echo "> 本文件由 ./orzmc.sh 自动生成，每次 up 会刷新；实例由 MCSManager 面板管理，"
        echo "> 仓库不能替你改实例——照下面抄即可。原理见 docs/eaglercraft.md、"
        echo "> 落地步骤见 docs/eaglercraft-deploy.md、拓扑矩阵见 docs/architecture.md ADR-036。"
        echo
        echo "## 1. 后端实例（Paper/Folia）"
        echo
        echo "- 实例目录：\`\$DATA_ROOT/mcsmanager/daemon/data/InstanceData/<实例uuid>/\`"
        echo "- \`server.properties\`：\`online-mode=false\`（玩家认证在代理/桥接层，ADR-035/036）"
        if [ "$have_vel" = "1" ] && [ "$uses_host_ports" = "1" ]; then
            echo "- \`docker.ports\`（面板 → 实例 → 端口映射）：**删掉** \`25565:25565/tcp\`，"
            echo "  改成 \`${bp}:25565/tcp\`（玩家端口让给代理 \`${jp}\`）"
        elif [ "$have_vel" = "1" ]; then
            echo "- \`docker.ports\`（面板 → 实例 → 端口映射）：**删掉** \`25565:25565/tcp\`、"
            echo "  \`19132/udp\`、\`19132/tcp\`、\`19134/udp\`（代理用容器名直连，不需要宿主端口；"
            echo "  只留 RCON/语音等运维端口）"
        else
            echo "- \`docker.ports\`：保持现状（\`${jp}:25565/tcp\`），Java 连接方式不变"
        fi
        echo "- \`plugins/\`：ViaVersion + ViaBackwards（版本见 docs/eaglercraft.md §7）"
        if [ "$have_vel" = "1" ]; then
            echo
            echo "### 1.1 每个后端实例的端口（代理按名字接入）"
            echo
            echo "| 代理里的名字 | 代理连接地址 | 实例侧要做的 |"
            echo "|---|---|---|"
            while IFS= read -r srv; do
                [ -n "$srv" ] || continue
                sname="${srv%%=*}"
                saddr="${srv##*=}"
                case "$saddr" in
                    host.docker.internal:*)
                        echo "| \`${sname}\` | \`${saddr}\` | 发布 \`${saddr##*:}:25565/tcp\` |" ;;
                    *)
                        echo "| \`${sname}\` | \`${saddr}\` | 不用发布端口（容器名直达） |" ;;
                esac
            done < <(velocity_servers)
            echo
            echo "玩家默认落地：\`$(velocity_try | head -n1)\`（改 \`.env\` 的 \`VELOCITY_TRY\` 可换；\`/server <名字>\` 切换）"
        fi
        if [ "$have_eg" = "1" ] && [ "$have_vel" = "0" ]; then
            echo "- \`plugins/\`：再加 **EaglerXPaper**："
            echo "  \`cp $(eagler_jars_dir)/EaglerXPaper.jar \$DATA_ROOT/mcsmanager/daemon/data/InstanceData/<实例uuid>/plugins/\`"
            echo "- 注意：eagler-direct **不支持 Folia**，也不能改写玩家 UUID"
        fi
        echo
        if [ "$have_vel" = "1" ]; then
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
            echo "secret 与代理实例目录里的 \`forwarding.secret\` 必须一致（面板实例 InstanceData/<uuid>/，600 权限，随备份）。"
            echo
        fi
        case "$(geyser_target)" in
            velocity)
                echo "## 2.5 基岩（Geyser）——由代理托管"
                echo
                echo "- **Geyser-Spigot 可以保留**：检测到 Velocity 转发时它会自我禁用（无害）"
                echo "- 代理已自动装 Geyser-Velocity（端口/后端/离线认证由 orzmc.sh 配好）"
                echo "- **只挪端口**：实例端口映射删掉 19132/udp、19132/tcp、19134/udp，"
                echo "  改由代理发布：udp/$(eagler_geyser_port)、tcp/$(eagler_geyser_port)、udp/$(eagler_geyser_webrtc_port)"
                echo "- 路由器不用改（宿主端口号不变）；防火墙 MC_PUBLIC_* 已覆盖则无需改"
                if [ "$have_eg" = "1" ]; then
                    echo "- 后端 RPC 已撤除（Paper 26.3 抛 Player is already registered，见 ADR-035 修正记录）"
                fi
                echo
                ;;
            spigot)
                echo "## 2.5 基岩（Geyser）——实例侧自行托管"
                echo
                echo "- 没有代理，基岩由实例自己装 Geyser-Spigot，端口保持原样"
                echo "- **不要**在 \`advertise-addresses\` 里写公网 IP：家宽 WAN IP 是 DDNS 动态的，"
                echo "  写死会在换 IP 后失效；保持 \`[]\` + \`stun-discovery: false\`，基岩仅局域网可用"
                echo "- 需要外网基岩时改用 \`ENABLE_VELOCITY=true\`（基岩由代理的 Geyser-Velocity 托管）"
                echo
                ;;
        esac
        if [ "$have_eg" = "1" ]; then
            echo "## 3. 反代（站点自备，TLS 终结）"
            echo
            echo "- 片段：\`\$DATA_ROOT/eagler/caddy-eagler.snippet\` → 追加到站点 Caddyfile"
            echo "- 给站点 caddy 服务加端口映射：\`\"${wp}:8443\"\`，路由器转发 ${wp}/TCP 到宿主"
            echo "- 防火墙：按站点自建 TLS 规则放行（docs/security.md §4），**不要**写进 MC_PUBLIC_TCP"
            echo
        fi
        echo "## 4. 玩家入口"
        echo
        if [ "$have_vel" = "1" ]; then
            echo "- Java：\`${host}:${jp}\`（经代理）"
        else
            echo "- Java：\`${host}:${jp}\`（直连实例）"
        fi
        if [ "$have_eg" = "1" ]; then
            echo "- Web ：\`wss://${host}:${wp}/\`（浏览器客户端）"
        fi
        if [ "$(geyser_target)" = "velocity" ]; then
            echo "- 基岩：\`${host}:$(eagler_geyser_port)\`（NetherNet，见 §2.5）"
        elif [ "$(geyser_target)" = "spigot" ]; then
            echo "- 基岩：\`${host}:$(eagler_geyser_port)\`（Geyser-Spigot，实例侧）"
        fi
        echo
        if [ "$have_eg" = "1" ]; then
            echo "## 5. 验收"
            echo
            echo '```bash'
            echo "python3 tests/eaglercraft_probe.py --host ${host} --port ${wp} --tls"
            echo '```'
            echo
            echo "期望：\`eagler_protocol=5 minecraft_protocol=777\`。"
        else
            echo "## 5. 验收"
            echo
            echo '```bash'
            echo "docker exec orzmc-velocity sh -c 'ls /server/plugins'  # velocity-only：不应有 EaglerXServer.jar"
            echo 'docker logs --tail 30 orzmc-velocity                  # 期望 "Listening on /0.0.0.0:25565"'
            echo '```'
        fi
    } > "$dest"
    chmod 600 "$dest"
    info "已生成实例待办: ${dest}"
}

# 端口占用体检：要求「EAGLER_JAVA_PORT 归代理、各后端端口归实例」。
# 只在实例正在运行时能看见（面板停实例会移除容器），所以这里是**告警**而不是硬失败——
# 真正兜底的是 compose 起不来时的端口冲突报错。
eagler_check_port_conflicts() {
    command -v docker >/dev/null 2>&1 || return 0
    local p busy srv
    for p in "$(eagler_java_port)" $(velocity_servers | cut -d= -f2); do
        busy="$(docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null \
            | awk -F'|' -v port=":${p}->" '$2 ~ port && $1 != "orzmc-velocity" {print $1}' \
            | head -n 2 | tr '\n' ' ')"
        if [ -n "$busy" ]; then
            warn "端口 ${p} 已被容器占用：${busy}——velocity 拓扑需要 EAGLER_JAVA_PORT 归代理、每个后端端口归对应实例，请先在面板改实例端口映射"
        fi
    done
    return 0
}

# 按 section 定向改 YAML 键（Geyser 的 bedrock/remote 都有 port，不能用全局 sed）
eagler_cfg_set() { # <file> <section> <key> <value>
    local f="$1" sec="$2" key="$3" val="$4"
    awk -v sec="${sec}" -v key="${key}" -v val="${val}" '
        /^[A-Za-z][A-Za-z0-9_.-]*:/ { cur=$1; sub(/:.*$/, "", cur) }
        cur == sec && $0 ~ ("^[ \t]+" key "[ \t]*:") {
            match($0, /^[ \t]+/); ind = substr($0, 1, RLENGTH)
            print ind key ": " val; next
        }
        { print }
    ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
}

# Geyser-Velocity 首次启动后修正：端口/后端/认证方式。返回 0=有改动。
eagler_patch_geyser() {
    local f="$1" before after gp gw
    [ -f "$f" ] || return 1
    gp="$(eagler_geyser_port)"
    gw="$(eagler_geyser_webrtc_port)"
    before="$(eagler_sha256_of "$f")"
    eagler_cfg_set "$f" bedrock port "$gp"
    eagler_cfg_set "$f" bedrock webrtc-port "$gw"
    # 26.x 起 RakNet-only 已移除；transport 由 .env 派生：
    #   nethernet（webrtc-port=0 → 媒体复用主端口，端口集合最小）
    #   both      （保留 RakNet 兜底，需独立媒体端口）
    eagler_cfg_set "$f" bedrock transport "$(eagler_geyser_transport)"
    # 广播地址：advertise-addresses 为空时 Geyser 用 STUN 探测本机出口 IP；宿主跑着
    # 系统代理/VPN（Mihomo TUN 等）时会探到 VPN 出口 → 外网基岩客户端拿到错地址连不上。
    # 这里按 .env 的 LAN_HOST_IP + EAGLER_PUBLIC_HOST 显式写出，并关掉 STUN。
    local lan adv
    lan="$(read_env_value LAN_HOST_IP)"
    adv=""
    if [ -n "$lan" ]; then adv="\"${lan}\""; fi
    if [ -n "$(eagler_public_host)" ]; then
        if [ -n "$adv" ]; then
            adv="${adv}, \"$(eagler_public_host)\""
        else
            adv="\"$(eagler_public_host)\""
        fi
    fi
    if [ -n "$adv" ]; then
        eagler_cfg_set "$f" bedrock advertise-addresses "[${adv}]"
        eagler_cfg_set "$f" bedrock stun-discovery "false"
    fi
    # Geyser 2.12 的认证段叫 java（不是 remote）：online=要求微软/Java 正版，
    # offline=Bedrock 玩家按离线身份进（与 Java/Eagler 共用名字空间）。
    eagler_cfg_set "$f" java auth-type "offline"
    after="$(eagler_sha256_of "$f")"
    [ "$before" != "$after" ]
}

# ---- 主流程 -------------------------------------------------------------

# 拓扑不需要的插件要真正移走：否则 ENABLE_EAGLER=false 之后 Web 入口（8081）仍然在，
# 玩家还能连进来，开关形同虚设。移到 $DATA_ROOT/eagler/disabled/（可随时移回）。
eagler_stash_plugin() { # eagler_stash_plugin <jar-path>
    local f="$1" d
    if [ -f "$f" ]; then
        d="$(eagler_dir)/disabled"
        mkdir -p "$d"
        mv "$f" "${d}/$(basename -- "$f")"
        info "已移走当前拓扑不需要的插件: $(basename -- "$f") → ${d}"
    fi
}

eagler_prepare() {
    local topo pdir jar_cur
    topo="$(topology)"
    case "$topo" in
        java-only)
            return 0
            ;;
        eagler-direct)
            mkdir -p "$(eagler_jars_dir)"
            eagler_fetch "$(eagler_lock EAGLERXPAPER_URL)" \
                "$(eagler_jars_dir)/EaglerXPaper-$(eagler_lock EAGLERXPAPER_VERSION).jar" \
                "$(eagler_lock EAGLERXPAPER_SHA256)" "EaglerXPaper $(eagler_lock EAGLERXPAPER_VERSION)"
            eagler_write_setup_doc "$topo"
            eagler_write_caddy_snippet "host.docker.internal"
            ;;
        velocity|eagler-proxy)
            eagler_check_port_conflicts
            pdir="$(eagler_proxy_dir)"
            mkdir -p "${pdir}/plugins"
            # jar 名带版本号（velocity-4.3.1.jar）：换版本就是换文件，旧版留着可回滚。
            # 已有任意 velocity*.jar 就不再下载——面板里换过版本也不会被打回。
            jar_cur="$(eagler_proxy_jar)"
            if [ -z "${jar_cur}" ] && [ -f "${pdir}/velocity.jar" ]; then jar_cur="${pdir}/velocity.jar"; fi
            if [ -n "${jar_cur}" ]; then
                info "Velocity jar 已存在（$(basename "${jar_cur}")），跳过下载"
            else
                eagler_fetch "$(eagler_lock VELOCITY_URL)" \
                    "${pdir}/$(basename "$(eagler_lock VELOCITY_URL)")" \
                    "$(eagler_lock VELOCITY_SHA256)" "Velocity $(eagler_lock VELOCITY_VERSION)-$(eagler_lock VELOCITY_BUILD)"
            fi
            if [ "$topo" = "eagler-proxy" ]; then
                eagler_fetch "$(eagler_lock EAGLERXSERVER_URL)" "${pdir}/plugins/EaglerXServer.jar" \
                    "$(eagler_lock EAGLERXSERVER_SHA256)" "EaglerXServer $(eagler_lock EAGLERXSERVER_VERSION)"
            else
                # velocity-only：Web 端点必须关掉，否则"没开 Eaglercraft"也能连进来
                eagler_stash_plugin "${pdir}/plugins/EaglerXServer.jar"
            fi
            # 后端 RPC：给 Web/基岩玩家单独降视野（EAGLER_RPC=false 可关；仅 eagler-proxy 需要）
            if [ "$topo" = "eagler-proxy" ] && [ "$(eagler_port EAGLER_RPC true)" = "true" ]; then
                eagler_fetch "$(eagler_lock EAGLER_RPC_URL)" \
                    "$(eagler_jars_dir)/EaglerXBackendRPC-$(eagler_lock EAGLER_RPC_VERSION).jar" \
                    "$(eagler_lock EAGLER_RPC_SHA256)" "EaglerXBackendRPC $(eagler_lock EAGLER_RPC_VERSION)"
            fi
            if [ "$(geyser_target)" = "velocity" ]; then
                eagler_fetch "$(eagler_lock GEYSER_URL)" "${pdir}/plugins/Geyser-Velocity.jar" \
                    "$(eagler_lock GEYSER_SHA256)" "Geyser-Velocity $(eagler_lock GEYSER_VERSION)-$(eagler_lock GEYSER_BUILD)"
            else
                eagler_stash_plugin "${pdir}/plugins/Geyser-Velocity.jar"
            fi
            eagler_ensure_secret "${pdir}/forwarding.secret"
            eagler_render_velocity_toml "${pdir}/velocity.toml"
            eagler_write_setup_doc "$topo"
            if [ "$topo" = "eagler-proxy" ]; then
                eagler_write_caddy_snippet "orzmc-velocity"
            fi
            ;;
    esac
}

# up 之后调用：插件首次启动才生成配置，随后修正为面向反代/宿主的形态。
# 返回 0 表示改过（需要重启代理容器才生效）。
eagler_post_up() {
    local cfg changed
    changed=1
    if [ "$(eagler_dialect)" = "eaglerxserver" ]; then
        cfg="$(eagler_proxy_dir)/plugins/eaglerxserver"
        if eagler_patch_listeners "${cfg}/listeners.toml"; then
            info "已修正 listeners.toml（forward_ip / X-Real-IP）"
            changed=0
        fi
        if eagler_patch_settings "${cfg}/settings.toml"; then
            info "已修正 settings.toml（http_websocket_max_frame_length=65535）"
            changed=0
        fi
    fi
    if [ "$(geyser_target)" = "velocity" ] \
        && eagler_patch_geyser "$(eagler_proxy_dir)/plugins/Geyser-Velocity/config.yml"; then
        info "已修正 Geyser-Velocity/config.yml（端口/后端/离线认证）"
        changed=0
    fi
    return "$changed"
}

# validate 用：检查运行时是否就绪（只告警，不因缺文件失败——init 后 up 前是常态）
eagler_runtime_check() {
    local dialect
    dialect="$(eagler_dialect)"
    if [ "$dialect" = "eaglerxpaper" ]; then
        if ! ls "$(eagler_jars_dir)"/EaglerXPaper-*.jar >/dev/null 2>&1; then
            warn "EaglerXPaper 未下载（首次 up 会自动下载）"
        fi
    fi
    if velocity_enabled; then
        if [ ! -f "$(eagler_proxy_dir)/velocity.jar" ]; then
            warn "Velocity 运行时未就绪（面板实例目录里还没有 jar；`up` 会下载到 $(eagler_proxy_dir)，离线环境请预置）"
        fi
        if [ "$dialect" = "eaglerxserver" ] \
            && [ ! -f "$(eagler_proxy_dir)/plugins/EaglerXServer.jar" ]; then
            warn "EaglerXServer 插件缺失（ENABLE_EAGLER=true 但代理 plugins 里没有）"
        fi
        if [ "$(geyser_target)" = "velocity" ] \
            && [ ! -f "$(eagler_proxy_dir)/plugins/Geyser-Velocity.jar" ]; then
            warn "Geyser-Velocity 插件缺失（基岩由代理托管时必需）"
        fi
    fi
    return 0
}
