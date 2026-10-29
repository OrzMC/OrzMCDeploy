#!/usr/bin/env bash
# ===========================================================================
# OrzMC 统一部署入口（唯一入口，三平台一致）
#
# 用法: ./orzmc.sh [-d DATA_ROOT] init|up|stop|status|validate|backup
#
# 运行模型（ADR-027）：**只有局域网模式**——面板与 EasyBot 发布到宿主端口，纯 HTTP，
# 局域网设备直连；对外访问由站点自备（DDNS + 端口映射 / 反代 / VPN），本仓库不管。
# daemon 不对宿主发布端口（ADR-026：面板自己中转浏览器↔daemon 数据流）。
#
# 可选服务（.env 里，缺省 true）: ENABLE_EASYBOT
#   （核心 mcsmanager-web / mcsmanager-daemon 常驻，不随开关变化）
#
# 安全默认（ADR-028）：端口只绑 LAN_BIND_ADDR（缺省 0.0.0.0），防火墙默认只放行
# LAN_CIDR（+ 可选 ALLOW_EXTRA_CIDRS）；`firewall apply` 幂等应用该策略。
#
# DATA_ROOT 无默认路径（ADR-033）：-d/--data-root 参数 > ORZMC_DATA_ROOT 环境变量；
#   两者都没有时直接报错，请在首次 init 时明确选定数据目录。
# 全部 compose 调用统一走 lib/common.sh 的 compose_cmd。
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# 注意：source common.sh 会把 SCRIPT_DIR 覆写为 lib/ 目录，须先保存仓库根
ORZMC_BIN_DIR="$SCRIPT_DIR"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DATA_ROOT=""

usage() {
    cat <<'EOF'
用法:
  orzmc.sh -d <数据目录> init           # 建目录树 + 生成 .env（-d 必填，无默认路径）
  orzmc.sh -d <数据目录> up             # init + compose up -d（启动平台层）
  orzmc.sh -d <数据目录> stop           # compose down --remove-orphans
  orzmc.sh -d <数据目录> status         # 局域网访问地址 + compose ps
  orzmc.sh -d <数据目录> validate       # 必需变量检查 + compose config -q
  orzmc.sh -d <数据目录> backup         # 打包 $DATA_ROOT（可加 --stop/--keep）
  orzmc.sh -d <数据目录> firewall show|apply   # 防火墙收敛（默认只信任局域网，ADR-028）
  orzmc.sh -d <数据目录> print-root     # 打印解析后的 DATA_ROOT

DATA_ROOT 无默认值（ADR-033）：用 -d/--data-root 或 export ORZMC_DATA_ROOT=<数据目录>；
数据、密钥、备份源都落在这里，请先确认磁盘与（Windows）Docker 文件共享白名单。
局域网入口：面板 LAN_MCS_WEB_PORT（缺省 18090）、EasyBot LAN_EASYBOT_PORT（缺省 18091）；
可选服务开关在 $DATA_ROOT/.env 的 ENABLE_EASYBOT。
三平台命令一致；Windows 下 daemon 默认由 compose 管理（见 ADR-029）。
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -d|--data-root)
            [ "$#" -ge 2 ] || die "$1 需要一个参数"
            DATA_ROOT="$(norm_path "$2")"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            die "未知选项: $1"
            ;;
        *)
            break
            ;;
    esac
done

[ "$#" -ge 1 ] || { usage; exit 1; }
# 没给 -d 时只能来自 ORZMC_DATA_ROOT；两者都没有则报错（无默认路径，ADR-033）
[ -n "$DATA_ROOT" ] || DATA_ROOT="$(resolve_data_root)"
export DATA_ROOT
CMD="$1"; shift

# 内部脚本一律用 bash 显式调用：不依赖文件系统执行位（Windows 克隆 / ZIP 下载
# 可能丢 +x，CI 曾因此 Permission denied 失败）。用户入口 ./orzmc.sh 自身需 +x。
case "$CMD" in
    init)       bash "${ORZMC_BIN_DIR}/deploy.sh" -d "$DATA_ROOT" init ;;
    up)         bash "${ORZMC_BIN_DIR}/deploy.sh" -d "$DATA_ROOT" up ;;
    stop)       bash "${ORZMC_BIN_DIR}/deploy.sh" -d "$DATA_ROOT" stop ;;
    status)     bash "${ORZMC_BIN_DIR}/deploy.sh" -d "$DATA_ROOT" status ;;
    validate)   bash "${ORZMC_BIN_DIR}/deploy.sh" -d "$DATA_ROOT" validate ;;
    backup)     bash "${ORZMC_BIN_DIR}/backup.sh" -d "$DATA_ROOT" "$@" ;;
    firewall)   bash "${ORZMC_BIN_DIR}/lib/firewall.sh" "$@" ;;
    print-root) echo "$DATA_ROOT" ;;
    *) usage; exit 1 ;;
esac
