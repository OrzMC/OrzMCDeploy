#!/usr/bin/env bash
# ===========================================================================
# probe.sh —— 真探协议（v0.4.0）
#
# `docker ps` 说 Up 不等于「玩家能连」。本模块按真实协议打一遍：
#   - 面板 / EasyBot：HTTP 状态码
#   - Velocity(Java) / Geyser(TCP)：TCP 连接
#   - 各站点域：TLS 握手 + HTTP 状态码（走 127.0.0.1:443 并 --resolve，绕开 DNS/WAN）
#   - Web 客户端：向 dev 域发 WebSocket Upgrade，期待 101 或服务端明确拒绝（4xx），
#     502/503 说明上游没起
#   - 实例：daemon 内 java 进程数（面板里没起实例时这里立刻能看出来）
#
# 只读：不发任何写请求、不重启容器。
# ===========================================================================

PROBE_FAIL=0
PROBE_OK=0
PROBE_TOTAL=0

# _probe_row <ok|warn|fail> <label> <detail> [soft]
# soft=1 时把 fail 降级为 WARN（用于「本机连自己 LAN IP」这类不确定项）
_probe_row() {
    local st="$1" label="$2" detail="$3" soft="${4:-0}"
    if [ "$soft" = "1" ] && [ "$st" = "fail" ]; then st="warn"; fi
    PROBE_TOTAL=$((PROBE_TOTAL + 1))
    case "$st" in
        ok)   PROBE_OK=$((PROBE_OK + 1));   printf '  [ OK ] %-22s %s\n' "$label" "$detail" ;;
        warn) PROBE_OK=$((PROBE_OK + 1));   printf '  [WARN] %-22s %s\n' "$label" "$detail" ;;
        *)    PROBE_FAIL=$((PROBE_FAIL + 1)); printf '  [FAIL] %-22s %s\n' "$label" "$detail" ;;
    esac
}

probe_tcp() {
    local host="$1" port="$2" label="$3" soft="${4:-0}"
    if timeout 5 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
        _probe_row ok "$label" "tcp ${host}:${port} 可连"
    else
        _probe_row fail "$label" "tcp ${host}:${port} 连不上" "$soft"
    fi
}

# probe_http <url> <label> <允许的码正则>
probe_http() {
    local url="$1" label="$2" okpat="$3" soft="${4:-0}" code
    code="$(curl -s -o /dev/null -m 8 -w '%{http_code}' "$url" 2>/dev/null)" || code=""
    [ -n "$code" ] && [ "$code" != "000" ] || code="000"
    if printf '%s' "$code" | grep -Eq "$okpat"; then
        _probe_row ok "$label" "HTTP ${code}"
    else
        _probe_row fail "$label" "HTTP ${code}（期望 ${okpat}）" "$soft"
    fi
}

# 站点域：TLS + HTTP，直连宿主 443（--resolve 到 127.0.0.1，绕开 DDNS 与运营商）
probe_site() {
    local domain="$1" upstream="$2" code
    code="$(curl -sk -o /dev/null -m 10 -w '%{http_code}' \
        --resolve "${domain}:443:127.0.0.1" "https://${domain}:443/" 2>/dev/null)" || code=""
    [ -n "$code" ] || code="000"
    case "$code" in
        000) _probe_row fail "$domain" "TLS/连接失败（证书或 Caddy 未起）" ;;
        502|503|504) _probe_row fail "$domain" "HTTP ${code} —— Caddy 在，上游 ${upstream} 没起" ;;
        *) _probe_row ok "$domain" "HTTP ${code}（→ ${upstream}）" ;;
    esac
}

# WebSocket Upgrade：101 = 握手成功；4xx = 服务端明确拒绝（可达）；
# 502 = 上游没起；000 = TLS/连接失败
probe_ws() {
    local domain="$1" code
    code="$(curl -sk -o /dev/null -m 10 -w '%{http_code}' \
        --resolve "${domain}:443:127.0.0.1" \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
        -H 'Sec-WebSocket-Version: 13' \
        -H 'Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==' \
        "https://${domain}:443/" 2>/dev/null)" || code=""
    [ -n "$code" ] || code="000"
    case "$code" in
        101) _probe_row ok "ws ${domain}" "101 Switching Protocols（Web 客户端可连）" ;;
        4*)  _probe_row warn "ws ${domain}" "HTTP ${code} —— 反代与上游都通，握手被上游拒绝（视协议实现而定）" ;;
        502|503) _probe_row fail "ws ${domain}" "HTTP ${code} —— 上游没起" ;;
        *)   _probe_row fail "ws ${domain}" "HTTP ${code}" ;;
    esac
}

probe_instances() {
    local n
    if ! docker ps --format '{{.Names}}' | tr -d '\r' | grep -qx 'orzmc-mcsmanager-daemon'; then
        _probe_row fail "实例进程" "orzmc-mcsmanager-daemon 未运行"
        return
    fi
    # daemon 里的 java 进程＝正在跑的 MC 实例（面板未点「启动」时这里为 0）
    n="$(docker exec orzmc-mcsmanager-daemon sh -c 'ps ax 2>/dev/null | grep -c "[j]ava"' 2>/dev/null | tr -d '\r')"
    n="${n:-0}"
    if [ "$n" -gt 0 ]; then
        _probe_row ok "实例进程" "${n} 个 java 进程在跑"
    else
        _probe_row warn "实例进程" "0 个 —— 实例未启动（面板里点「启动」，或 autoStart=true）"
    fi
}

probe_all() {
    local lan port_web port_bot port_java port_bedrock domain upstream opts
    lan="$(read_env_value LAN_HOST_IP || true)"
    [ -n "$lan" ] || lan="127.0.0.1"
    port_web="$(read_env_value LAN_MCS_WEB_PORT || true)"; port_web="${port_web:-23333}"
    port_bot="$(read_env_value LAN_EASYBOT_PORT || true)"; port_bot="${port_bot:-18091}"
    # 端口真源在 lib/eagler.sh 的 eagler_* 函数里（.env 里没有这两项）
    if declare -F eagler_java_port >/dev/null 2>&1; then port_java="$(eagler_java_port)"; else port_java=25565; fi
    if declare -F eagler_geyser_port >/dev/null 2>&1; then port_bedrock="$(eagler_geyser_port)"; else port_bedrock=19132; fi

    echo
    echo "协议探测:"
    # 回环是硬指标；宿主连自己的 LAN IP 在 Windows 上常被防火墙/路由挡（不代表局域网不通），
    # 所以 LAN IP 只降级为 WARN——真正「局域网进不来」要靠外部设备或 firewall 检查发现。
    probe_http "http://127.0.0.1:${port_web}/" "MCSM 面板 http" '^(200|30[0-9])$'
    probe_http "http://127.0.0.1:${port_bot}/" "EasyBot http" '^(200|30[0-9])$'
    probe_tcp 127.0.0.1 "$port_java" "Velocity java"
    probe_tcp 127.0.0.1 "$port_bedrock" "Geyser tcp"
    if [ "$lan" != "127.0.0.1" ]; then
        probe_http "http://${lan}:${port_web}/" "面板(经 LAN IP)" '^(200|30[0-9])$' 1
        probe_tcp "$lan" "$port_java" "Java(经 LAN IP)" 1
    fi
    printf '  [skip] %-22s UDP %s 未探测（RakNet 需构造握手包，交给实例侧验证）\n' "Geyser udp" "$port_bedrock"

    if declare -F site_parse_routes >/dev/null 2>&1 && [ -n "$(read_env_value SITE_ROUTES || true)" ]; then
        while IFS="$(printf '\t')" read -r domain upstream opts; do
            [ -n "$domain" ] || continue
            probe_site "$domain" "$upstream"
            case ",$opts," in
                *",ws,"*) probe_ws "$domain" ;;
            esac
        done <<EOF
$(site_parse_routes)
EOF
    fi

    probe_instances

    echo
    if [ "$PROBE_FAIL" -eq 0 ]; then
        info "探测 ${PROBE_TOTAL} 项：OK/WARN ${PROBE_OK}，FAIL 0"
    else
        warn "探测 ${PROBE_TOTAL} 项：OK/WARN ${PROBE_OK}，FAIL ${PROBE_FAIL}"
        return 1
    fi
}
