#!/usr/bin/env bash
# shellcheck disable=SC1091  # source ./common.sh（同目录运行时文件）
# shellcheck disable=SC2016  # 单引号内的 $ 为 PowerShell 变量，不需要 bash 展开
# ===========================================================================
# 宿主防火墙收敛（ADR-028）——把「项目端口」限制为只允许指定来源
#
# 目标：默认只信任局域网（LAN_CIDR），VPN 等额外来源用 ALLOW_EXTRA_CIDRS 显式追加；
#       公网暴露必须由站点显式决定（改用 VPN / 反代 / 路由器映射），不由本脚本默认放开。
#
# 用法（一般通过 ./orzmc.sh firewall <动作> 调用）：
#   firewall.sh show            # 列出当前与项目端口相关的规则
#   firewall.sh apply           # 幂等应用：删掉旧的 OrzMC-* 规则后按 LAN_CIDR 重建
#   firewall.sh apply --dry-run # 只打印将要执行的命令
#
# 规则命名：OrzMC-<用途>（Panel / EasyBot / MC-TCP / MC-UDP / RCON / MC-Public-TCP|UDP）
# 端口来源：.env 的 LAN_MCS_WEB_PORT / LAN_EASYBOT_PORT / MC_TCP_PORTS / MC_UDP_PORTS /
#           RCON_PORTS（后三者可选，缺省按本仓库常用值：25565,25566 / 19132 / 25575,25576）
#
# 公网游戏端口（第二类有意 Any，见 docs/security.md §4）：.env 的
#   MC_PUBLIC_TCP / MC_PUBLIC_UDP（逗号分隔，缺省空 = 不开放）
# 仅这两个清单会生成 OrzMC-MC-Public-*（RemoteAddress Any）；RCON 永不进该清单。
#
# apply 只删除/重建下面 MANAGED_RULES 里的规则，**不碰**站点自建规则（如 OrzMC-Web-TLS）。
#
# 平台：
#   Windows（Git Bash / MSYS）→ 通过 powershell.exe 调 New-NetFirewallRule（**需要管理员**）
#   Linux  → 优先 ufw，其次打印 iptables 命令
#   macOS  → 只打印等价 pf 规则（不自动改，避免误伤系统 pf 配置）
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# DATA_ROOT 无默认值（ADR-033）：直接用本脚本时也要能解析出来。
[ -n "${DATA_ROOT:-}" ] || DATA_ROOT="$(resolve_data_root)"
export DATA_ROOT
# 端口/来源全取自 .env，缺文件会静默回落到缺省值——直接拦下更安全。
[ -f "$(env_file)" ] || die "缺少 $(env_file)，请先执行 ./orzmc.sh -d ${DATA_ROOT} init"

# apply 管理（删除并重建）的规则名；顺序无关。站点自建的公网 TLS 规则不在此列。
MANAGED_RULES="OrzMC-Panel OrzMC-EasyBot OrzMC-MC-TCP OrzMC-MC-UDP OrzMC-RCON OrzMC-MC-Public-TCP OrzMC-MC-Public-UDP"

ACTION="${1:-show}"
shift || true
DRY_RUN=0
for a in "$@"; do
    [ "$a" = "--dry-run" ] && DRY_RUN=1
done

env_val() { read_env_value "$1"; }

lan_cidr()   { local v; v="$(env_val LAN_CIDR)";        printf '%s' "${v:-192.168.0.0/24}"; }
extra_cidrs(){ local v; v="$(env_val ALLOW_EXTRA_CIDRS)"; printf '%s' "${v//,/ }"; }
bind_addr()  { local v; v="$(env_val LAN_BIND_ADDR)";   printf '%s' "${v:-0.0.0.0}"; }

# 端口清单：<规则名>:<协议>:<端口,端口>
port_specs() {
    local web eb tcp udp rcon
    web="$(env_val LAN_MCS_WEB_PORT)";  [ -n "$web" ]  || web="18090"
    eb="$(env_val LAN_EASYBOT_PORT)";   [ -n "$eb" ]   || eb="18091"
    tcp="$(env_val MC_TCP_PORTS)";      [ -n "$tcp" ]  || tcp="25565,25566"
    udp="$(env_val MC_UDP_PORTS)";      [ -n "$udp" ]  || udp="19132"
    rcon="$(env_val RCON_PORTS)";       [ -n "$rcon" ] || rcon="25575,25576"
    printf '%s\n' \
        "OrzMC-Panel:TCP:${web}" \
        "OrzMC-EasyBot:TCP:${eb}" \
        "OrzMC-MC-TCP:TCP:${tcp}" \
        "OrzMC-MC-UDP:UDP:${udp}" \
        "OrzMC-RCON:TCP:${rcon}"
}

# 公网游戏端口（有意 Any）：只有显式写进 .env 的端口才会放行给公网。
public_specs() {
    local tcp udp
    tcp="$(env_val MC_PUBLIC_TCP)"
    udp="$(env_val MC_PUBLIC_UDP)"
    if [ -n "$tcp" ]; then printf '%s\n' "OrzMC-MC-Public-TCP:TCP:${tcp}"; fi
    if [ -n "$udp" ]; then printf '%s\n' "OrzMC-MC-Public-UDP:UDP:${udp}"; fi
}

sources() { # 输出 RemoteAddress 的逗号列表
    local out; out="$(lan_cidr)"
    local e; e="$(extra_cidrs)"
    for c in $e; do out="${out},${c}"; done
    printf '%s' "$out"
}

# --------------------------- Windows ---------------------------
win_show() {
    local ps
    ps='Get-NetFirewallRule -Direction Inbound | Where-Object { $_.DisplayName -like "OrzMC-*" } | ForEach-Object { $pf=$_|Get-NetFirewallPortFilter; $af=$_|Get-NetFirewallAddressFilter; "{0}|{1}|{2}|{3}" -f $_.DisplayName,$_.Enabled,($pf.LocalPort -join ","),($af.RemoteAddress -join ",") }'
    powershell.exe -NoProfile -Command "$ps" 2>/dev/null | tr -d '\r' | while IFS='|' read -r name en ports remote; do
        printf '  %-16s enabled=%-5s ports=%-14s remote=%s\n' "$name" "$en" "$ports" "$remote"
    done
}

win_apply() {
    local src; src="$(sources)"
    local cmds=""
    cmds+='$ErrorActionPreference = "Stop"; '
    for n in $MANAGED_RULES; do
        cmds+="Get-NetFirewallRule -DisplayName '${n}' -ErrorAction SilentlyContinue | Remove-NetFirewallRule; "
    done
    while IFS=':' read -r name proto ports; do
        cmds+="New-NetFirewallRule -DisplayName '${name}' -Direction Inbound -Action Allow -Protocol ${proto} -LocalPort ${ports//,/','} -RemoteAddress ${src} -Profile Any | Out-Null; "
    done < <(port_specs)
    while IFS=':' read -r name proto ports; do
        cmds+="New-NetFirewallRule -DisplayName '${name}' -Direction Inbound -Action Allow -Protocol ${proto} -LocalPort ${ports//,/','} -RemoteAddress Any -Profile Any | Out-Null; "
    done < <(public_specs)
    cmds+='Write-Output "APPLIED"'
    if [ "$DRY_RUN" = 1 ]; then
        echo "  [dry-run] powershell -NoProfile -Command \"${cmds}\""
        return 0
    fi
    # 需要管理员：写临时 .ps1 后通过 UAC 提权执行
    local script="${TEMP:-/tmp}/orzmc-firewall.ps1"
    printf '%s\n' "$cmds" > "$script"
    local winpath; winpath="$(printf '%s' "$script" | sed 's#^/tmp#C:/Users/'"${USERNAME:-$(id -un)}"'/AppData/Local/Temp#')"
    echo "  应用规则（来源: ${src}）—— 需要管理员，请在弹出窗口点 是（UAC 确认）"
    powershell.exe -NoProfile -Command "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','${winpath}'" >/dev/null 2>&1 || true
    rm -f "$script"
    win_show
}

# --------------------------- Linux -----------------------------
linux_apply() {
    local src; src="$(sources)"
    if command -v ufw >/dev/null 2>&1; then
        echo "  使用 ufw（来源: ${src}）"
        while IFS=':' read -r name proto ports; do
            for p in ${ports//,/ }; do
                for s in ${src//,/ }; do
                    if [ "$DRY_RUN" = 1 ]; then
                        echo "  [dry-run] ufw allow proto $proto from $s to any port $p comment '$name'"
                    else
                        ufw allow proto "$(printf '%s' "$proto" | tr '[:upper:]' '[:lower:]')" from "$s" to any port "$p" comment "$name"
                    fi
                done
            done
        done < <(port_specs)
        while IFS=':' read -r name proto ports; do
            for p in ${ports//,/ }; do
                if [ "$DRY_RUN" = 1 ]; then
                    echo "  [dry-run] ufw allow proto $proto from any to any port $p comment '$name'"
                else
                    ufw allow proto "$(printf '%s' "$proto" | tr '[:upper:]' '[:lower:]')" from any to any port "$p" comment "$name"
                fi
            done
        done < <(public_specs)
    else
        echo "  未找到 ufw；请手工应用以下 iptables 规则（来源: ${src}）"
        while IFS=':' read -r name proto ports; do
            for p in ${ports//,/ }; do
                for s in ${src//,/ }; do
                    echo "  iptables -A INPUT -p $(printf '%s' "$proto" | tr '[:upper:]' '[:lower:]') -s $s --dport $p -j ACCEPT  # $name"
                done
            done
        done < <(port_specs)
        while IFS=':' read -r name proto ports; do
            for p in ${ports//,/ }; do
                echo "  iptables -A INPUT -p $(printf '%s' "$proto" | tr '[:upper:]' '[:lower:]') --dport $p -j ACCEPT  # $name（公网，有意）"
            done
        done < <(public_specs)
    fi
}

# macOS：不自动改 pf（系统 pf.conf 是全局配置，脚本改易误伤），只打印等价规则。
macos_apply() {
    local src; src="$(sources)"
    echo "  macOS：不自动修改 pf；以下是等价规则（来源: ${src}）。"
    echo "  更简单的做法是用 .env 的 LAN_BIND_ADDR 收紧绑定（见 docs/security.md）。"
    while IFS=':' read -r name proto ports; do
        for p in ${ports//,/ }; do
            for s in ${src//,/ }; do
                echo "  pass in quick proto $(printf '%s' "$proto" | tr '[:upper:]' '[:lower:]') from ${s} to any port ${p}  # ${name}"
            done
        done
    done < <(port_specs)
    while IFS=':' read -r name proto ports; do
        for p in ${ports//,/ }; do
            echo "  pass in quick proto $(printf '%s' "$proto" | tr '[:upper:]' '[:lower:]') from any to any port ${p}  # ${name}（公网，有意）"
        done
    done < <(public_specs)
}

# Linux/macOS 的 show：把端口清单拼成精确正则（逐端口，不能用 '25565,25566' 字面）。
posix_show() {
    local pat="" spec p
    while IFS=':' read -r _ _ spec; do
        for p in ${spec//,/ }; do
            pat="${pat:+${pat}|}${p}"
        done
    done < <(port_specs)
    while IFS=':' read -r _ _ spec; do
        for p in ${spec//,/ }; do
            pat="${pat:+${pat}|}${p}"
        done
    done < <(public_specs)
    if command -v ufw >/dev/null 2>&1; then
        echo "当前 ufw 规则（与项目端口相关，含 ${pat//|/,}）:"
        ufw status 2>/dev/null | grep -E "(${pat})" || echo "  （未匹配到相关端口规则）"
    else
        echo "（无 ufw：请用系统防火墙工具核对项目端口 ${pat//|/,}）"
    fi
}

# --------------------------- 分发 -----------------------------
echo "项目端口与来源策略："
echo "  绑定地址 LAN_BIND_ADDR = $(bind_addr)"
echo "  允许来源             = $(sources)"
echo "  端口                 = $(port_specs | tr '\n' ' ')"
if [ -n "$(public_specs)" ]; then
    echo "  公网游戏端口（Any）   = $(public_specs | tr '\n' ' ')"
else
    echo "  公网游戏端口（Any）   = 未开放（.env 的 MC_PUBLIC_TCP / MC_PUBLIC_UDP 留空）"
fi
echo

case "$ACTION" in
    show)
        if is_windows; then echo "当前防火墙规则："; win_show; else posix_show; fi
        ;;
    apply)
        if is_windows; then win_apply
        elif [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then macos_apply
        else linux_apply; fi
        ;;
    *)
        die "未知动作: ${ACTION}（可用 show|apply，apply 支持 --dry-run）"
        ;;
esac

echo
echo "提示：公网暴露不要靠放开 Any —— 优先 VPN（Tailscale/WireGuard），"
echo "      其次 TLS 反代（后端绑 127.0.0.1），最后才是路由器端口映射。"
echo "      唯一例外是游戏端口：显式写进 .env 的 MC_PUBLIC_TCP / MC_PUBLIC_UDP（RCON 永不外露）。"
