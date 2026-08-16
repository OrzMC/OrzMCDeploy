#!/usr/bin/env bash
# ===========================================================================
# OrzMC 免克隆一键安装（ADR-018）
#
# 用法:
#   ./install.sh [-d INSTALL_DIR] [-v VERSION] [-r REPO]
#
#   不克隆仓库，直接从 GitHub Release 下载"运行时" tarball：
#     1. 解析版本：-v 显式指定，否则取仓库最新 release（GitHub API）
#     2. 下载 orzmc-<VERSION>.tar.gz 及其 .sha256
#     3. 校验 sha256（防篡改/下载损坏）
#     4. 解压到 INSTALL_DIR（默认见下），然后照常 ./orzmc.sh
#
# 默认:
#   REPO         orzmc/orzmc-deploy（-r 覆盖，支持 "owner/repo" 或完整 URL 前缀）
#   INSTALL_DIR  ~/.local/share/orzmc-deploy（macOS/Linux）；Windows 无自定义则用
#                "$HOME/orzmc-deploy"
#   版本         最新 release
#
# 特性: 幂等（可重复跑，不覆盖已存在的 DATA_ROOT）；不写仓库内任何数据/密钥；
#       三平台一致（依赖 bash / curl / tar / sha256sum|openssl）。
# ===========================================================================

set -euo pipefail

REPO="orzmc/orzmc-deploy"
VERSION=""
INSTALL_DIR=""

usage() {
    cat <<'EOF'
用法: ./install.sh [-d INSTALL_DIR] [-v VERSION] [-r REPO]

  -d INSTALL_DIR   安装目录（默认 ~/.local/share/orzmc-deploy）
  -v VERSION       指定版本号（默认最新 release，如 v1.2.3；可带/不带 v）
  -r REPO          GitHub 仓库 "owner/repo"（默认 orzmc/orzmc-deploy）
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -d|--dir)      [ "$#" -ge 2 ] || { usage; exit 1; }; INSTALL_DIR="$2"; shift 2 ;;
        -v|--version)  [ "$#" -ge 2 ] || { usage; exit 1; }; VERSION="$2"; shift 2 ;;
        -r|--repo)     [ "$#" -ge 2 ] || { usage; exit 1; }; REPO="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage; exit 1 ;;
    esac
done

# 统一 REPO 形态（支持 "owner/repo" 或 "https://github.com/owner/repo"）
REPO="${REPO#https://github.com/}"
REPO="${REPO%/}"

if [ -z "$INSTALL_DIR" ]; then
    INSTALL_DIR="${HOME}/.local/share/orzmc-deploy"
fi

BASE_URL="https://github.com/${REPO}/releases"

echo "==> 仓库: $REPO"

# ---- 解析版本 ---------------------------------------------------------------
if [ -z "$VERSION" ]; then
    echo "==> 解析最新 release ..."
    # GitHub API 无需 token（公开仓库）；curl -fsSL 失败即退出
    VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$VERSION" ] || { echo "!! 无法解析最新版本，请用 -v 显式指定" >&2; exit 1; }
    echo "    最新版本: $VERSION"
fi
VERSION="${VERSION#v}"   # 去掉前导 v，统一命名
TAG="v${VERSION}"

ASSET="orzmc-${VERSION}.tar.gz"
SUM_ASSET="orzmc-${VERSION}.tar.gz.sha256"
TARBALL_URL="${BASE_URL}/download/${TAG}/${ASSET}"
SUM_URL="${BASE_URL}/download/${TAG}/${SUM_ASSET}"

# ---- 下载 -------------------------------------------------------------------
echo "==> 下载 $ASSET"
curl -fSL "$TARBALL_URL" -o "/tmp/${ASSET}"
curl -fSL "$SUM_URL"      -o "/tmp/${SUM_ASSET}"

# ---- 校验 sha256 ------------------------------------------------------------
echo "==> 校验 sha256"
EXPECTED="$(awk '{print $1}' "/tmp/${SUM_ASSET}")"
if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL="$(sha256sum "/tmp/${ASSET}" | awk '{print $1}')"
else
    ACTUAL="$(openssl dgst -sha256 "/tmp/${ASSET}" | awk '{print $NF}')"
fi
if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "!! sha256 校验失败（期望 $EXPECTED，实际 $ACTUAL）" >&2
    echo "   下载可能被篡改或损坏，已中止安装。" >&2
    exit 1
fi
echo "    sha256 OK: $ACTUAL"

# ---- 安装 -------------------------------------------------------------------
echo "==> 解压到 $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
# 覆盖解压（幂等）；不删除无关文件，不触碰 DATA_ROOT（运行时/数据分离）
tar -xzf "/tmp/${ASSET}" -C "$INSTALL_DIR"

# 确保入口可执行（GitHub 打包保留可执行位，保险起见再设一次）
chmod +x "$INSTALL_DIR/orzmc.sh" 2>/dev/null || true

echo ""
echo "==> 安装完成：$INSTALL_DIR"
echo ""
echo "下一步（照常，与 git clone 部署完全一致）："
echo "  cd $INSTALL_DIR"
echo "  ./orzmc.sh -e <cloudflare|local|lan> init   # 建目录树 + 生成 .env + 边缘层配置"
echo "  # 编辑 \$DATA_ROOT/.env 填入真实值（域名/密码/CLOUDFLARE_TUNNEL_ID 等）"
echo "  ./orzmc.sh validate                          # 校验配置（可选但建议）"
echo "  ./orzmc.sh up                                # 启动平台层"
echo ""
echo "完整说明见 $INSTALL_DIR/README.md。更新到新版本：重跑本脚本（-v 或默认最新）。"
