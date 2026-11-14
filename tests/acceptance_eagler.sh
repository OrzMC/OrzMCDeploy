#!/usr/bin/env bash
# ===========================================================================
# 自动验收（手工工具，不进 CI gate）：Eagler/Velocity 侧的机器可判定项
#
# 覆盖 docs/eaglercraft-deploy.md §7.1 的 T1–T3 + 拓扑/端口/防火墙口径，
# 其余（三端共存、玩法、身份、弱网、回滚）必须真人 + 真客户端，见脚本末尾清单。
#
# 用法：
#   bash tests/acceptance_eagler.sh -d <数据目录>
#   ORZMC_DATA_ROOT=<数据目录> bash tests/acceptance_eagler.sh
# ===========================================================================
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

DATA_ROOT_ARG=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -d|--data-root) DATA_ROOT_ARG="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done
[ -n "$DATA_ROOT_ARG" ] || DATA_ROOT_ARG="${ORZMC_DATA_ROOT:-}"
[ -n "$DATA_ROOT_ARG" ] || { echo "需要 -d <数据目录> 或 ORZMC_DATA_ROOT" >&2; exit 2; }
export ORZMC_DATA_ROOT="$DATA_ROOT_ARG"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ✓ %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$*"; }
skip() { SKIP=$((SKIP+1)); printf '  - %s（跳过：%s）\n' "$1" "$2"; }
check() { # check <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (期望 [$2] 实际 [$3])"; fi
}

# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/common.sh"
DATA_ROOT="$(resolve_data_root)"

topo="$(topology)"
dialect="$(eagler_dialect)"
gysr="$(geyser_target)"
echo "数据目录: ${DATA_ROOT}"
echo "拓扑: ${topo}（dialect=${dialect} geyser=${gysr}）"
[ "$dialect" = "none" ] && { echo "当前未启用 Eaglercraft，T1–T3 不适用"; }

if [ "$dialect" != "none" ] || velocity_enabled; then
    echo ""
    echo "== T1 代理/信令启动 =="
    if docker ps --format '{{.Names}}' | grep -qx orzmc-velocity; then
        ok "orzmc-velocity 容器在运行"
    else
        bad "orzmc-velocity 容器未运行"
    fi
    logs="$(docker logs orzmc-velocity 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -200)"
    case "$logs" in
        *injected*) ok "EaglerXServer listener 已注入" ;;
        *)
            if [ "$dialect" = "eaglerxserver" ]; then
                bad "未见 listener 注入日志"
            else
                skip "listener 注入" "当前 dialect=${dialect}"
            fi
            ;;
    esac
    case "$logs" in
        *"Done ("*) ok "Velocity 启动完成（Done）" ;;
        *) bad "未见到 Velocity Done" ;;
    esac
    if [ "$gysr" = "velocity" ]; then
        case "$logs" in
            *"Built-in signaling started"*) ok "Geyser 内置信令已启动" ;;
            *) bad "未见 Geyser 信令启动" ;;
        esac
        case "$logs" in
            *"Advertised address"*) ok "Geyser 广播地址已解析（非 STUN）" ;;
            *) skip "广播地址" "日志窗口内无 AdvertisedAddresses 行，可 docker logs 复查" ;;
        esac
    fi
fi

echo ""
echo "== 三端连通性（Java / 基岩 / Eagler）=="

# ---- Java：状态查询 + 登录链路（经玩家入口，含代理）----
JP="$(eagler_java_port)"
if python3 "${REPO_ROOT}/tests/mc_status.py" --host 127.0.0.1 --port "$JP" >/tmp/mc_status.out 2>&1; then
    ok "Java 状态查询: $(sed 's/^-> STATUS //' /tmp/mc_status.out | cut -c1-70)"
else
    bad "Java 状态查询失败: $(tail -1 /tmp/mc_status.out)"
fi
if python3 "${REPO_ROOT}/tests/mc_status.py" --host 127.0.0.1 --port "$JP" --login AcceptJava >/tmp/mc_login.out 2>&1; then
    ok "Java 登录链路: $(sed 's/^-> //' /tmp/mc_login.out | cut -c1-70)"
else
    bad "Java 登录链路失败: $(tail -1 /tmp/mc_login.out)"
fi

# ---- 基岩：信令端口 + Geyser 广播地址（媒体是 UDP，无法脚本探测）----
if [ "$(geyser_target)" = "velocity" ] || [ "$(geyser_target)" = "spigot" ]; then
    GP="$(eagler_geyser_port)"
    if timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/${GP}" 2>/dev/null; then
        ok "基岩信令 TCP/${GP} 可连"
    else
        bad "基岩信令 TCP/${GP} 不可连"
    fi
    if docker logs orzmc-velocity 2>&1 | tail -200 | grep -q "Built-in signaling started"; then
        ok "Geyser 内置信令已启动（代理侧）"
    elif grep -rqs "Built-in signaling started" "${DATA_ROOT}/mcsmanager/daemon/logs" 2>/dev/null; then
        ok "Geyser 内置信令已启动（实例侧）"
    else
        skip "Geyser 信令日志" "日志窗口内未见，可 docker logs / 实例日志复查"
    fi
    if docker logs orzmc-velocity 2>&1 | tail -200 | grep -q "Advertised address"; then
        ok "Geyser 广播地址已解析（$(docker logs orzmc-velocity 2>&1 | grep -o "Advertised address.*resolve[s]* to .*" | tail -1 | cut -c1-60)）"
    fi
else
    skip "基岩" "EAGLER_GEYSER=false"
fi

if [ "$dialect" != "none" ]; then
    HOST="$(eagler_public_host)"; WSP="$(eagler_ws_port)"
    if [ -z "$HOST" ]; then
        skip "T2/T3 探针" "EAGLER_PUBLIC_HOST 为空"
    else
        echo ""
        echo "== T2 握手协商（经反代 ${HOST}:${WSP}）=="
        out="$(timeout 60 python3 "${REPO_ROOT}/tests/eaglercraft_probe.py" \
                --host "$HOST" --port "$WSP" --tls --address 127.0.0.1 2>&1 | tail -2)"
        case "$out" in
            *"eagler_protocol=5 minecraft_protocol=777"*) ok "eagler=5 / mc=777 协商成功" ;;
            *) bad "握手失败: ${out}" ;;
        esac
        echo ""
        echo "== T3 登录放行 + UUID 稳定（同名两次）=="
        u1="$(timeout 60 python3 "${REPO_ROOT}/tests/eaglercraft_probe.py" \
                --host "$HOST" --port "$WSP" --tls --address 127.0.0.1 --login AcceptTest 2>&1 \
                | grep -o "uuid=[0-9a-f-]*" | head -n1)"
        sleep 10
        u2="$(timeout 60 python3 "${REPO_ROOT}/tests/eaglercraft_probe.py" \
                --host "$HOST" --port "$WSP" --tls --address 127.0.0.1 --login AcceptTest 2>&1 \
                | grep -o "uuid=[0-9a-f-]*" | head -n1)"
        if [ -n "$u1" ] && [ "$u1" = "$u2" ]; then
            ok "ALLOW_LOGIN 两次 UUID 一致 ($u1)"
        else
            bad "UUID 不稳定或登录被拒 (第一次 [${u1:-空}] 第二次 [${u2:-空}])"
        fi
    fi
fi

echo ""
echo "== 端口与暴露面 =="
ports="$(docker ps --format '{{.Names}}\t{{.Ports}}')"
case "$ports" in
    *"orzmc-velocity"*"25565"*) ok "代理发布 25565/tcp（Java + WSS）" ;;
    *) skip "25565/tcp" "当前拓扑可能不经过代理" ;;
esac
case "$ports" in
    *"orzmc-velocity"*"19132/udp"*) ok "代理发布 19132/udp（基岩媒体）" ;;
    *) skip "19132/udp" "geyser_target=${gysr}" ;;
esac
case "$ports" in
    *"MCSM-"*"25565/tcp"*) bad "实例仍在发布 25565（代理拓扑应让出该端口）" ;;
    *) ok "实例未抢占 25565（玩家端口归代理）" ;;
esac

echo ""
echo "结果: ${PASS} 通过, ${FAIL} 失败, ${SKIP} 跳过"
cat <<'EOF'

仍需真人 + 真客户端（§7.1 T4–T12）：
  T4 浏览器进服      浏览器打开客户端 → 进服出现 HUD → 后端日志 <名字> joined the game
  T6 三端共存        Java + 基岩(真机 26.x) + Web 同时在线、互相可见、聊天互通
  T7 方块/交互       放置/破坏/开箱//tp
  T8 身份不可伪造    同名双开（Java+Web）→ 后进者要求口令；密码错=拒绝
  T9 断线重连        断网 30s 重连，位置/背包合理
  T10 Folia 稳定性   跨区域跑 10 分钟，后端无 Folia 调度异常
  T11 弱网           DevTools 3G 限速可进服
  T12 回滚演练       按 docs/eaglercraft-deploy.md §9 回滚后 Java 入口恢复
EOF
[ "$FAIL" -eq 0 ] || exit 1
