#!/usr/bin/env bash
# ===========================================================================
# 刷新 compose 编排中锁定的镜像 digest（ADR-017 起镜像分散在 3 个文件）
#
# 用法: ./update-image-digests.sh [服务...]      # 省略则全部
#   服务: cloudflared mcsmanager-web mcsmanager-daemon easybot caddy
#
# 为什么要 digest 锁定：升级 = 改仓库里的 digest + git commit，回滚 = git revert
# （见 AGENTS.md「镜像一律用 digest 锁定」）。
#
# 服务分布（ADR-017 把边缘层拆成 override 文件后，镜像不再都在 compose.yaml）：
#   compose.yaml                  → mcsmanager-web / mcsmanager-daemon / easybot
#   compose.edge.cloudflare.yaml  → cloudflared
#   compose.edge.local.yaml       → caddy
#
# EasyBot 用**发布 tag**（非 latest）：上游 `latest` 跟踪 main 分支（label
# `org.opencontainers.image.version=main`），直接钉 latest 会引入未发布构建。
# 升级时把下面的 EASYBOT_TAG 改成目标发布版本（如 0.0.43 → 0.0.44）。
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/compose.yaml"
EDGE_CLOUDFLARE_FILE="${SCRIPT_DIR}/compose.edge.cloudflare.yaml"
EDGE_LOCAL_FILE="${SCRIPT_DIR}/compose.edge.local.yaml"

EASYBOT_TAG="${EASYBOT_TAG:-0.0.43}"

for f in "$COMPOSE_FILE" "$EDGE_CLOUDFLARE_FILE" "$EDGE_LOCAL_FILE"; do
    [ -f "$f" ] || { echo "未找到 compose 文件: $f" >&2; exit 1; }
done

# 服务 → 上游源镜像（用于 docker pull / 取 digest）
source_image_for_service() {
    case "$1" in
        cloudflared)       echo "cloudflare/cloudflared:latest" ;;
        mcsmanager-web)    echo "githubyumao/mcsmanager-web:latest" ;;
        mcsmanager-daemon) echo "githubyumao/mcsmanager-daemon:latest" ;;
        easybot)           echo "ghcr.io/easyindie/easybot:${EASYBOT_TAG}" ;;
        caddy)             echo "caddy:latest" ;;
        *) return 1 ;;
    esac
}

# 服务 → 声明它的 compose 文件
compose_file_for_service() {
    case "$1" in
        cloudflared) echo "$EDGE_CLOUDFLARE_FILE" ;;
        caddy)       echo "$EDGE_LOCAL_FILE" ;;
        *)           echo "$COMPOSE_FILE" ;;
    esac
}

# 逻辑服务名 → compose 中的服务键（caddy 在 edge.local 里叫 reverse-proxy）
compose_key_for_service() {
    case "$1" in
        caddy) echo "reverse-proxy" ;;
        *)     echo "$1" ;;
    esac
}

ALL_SERVICES=(cloudflared mcsmanager-web mcsmanager-daemon easybot caddy)

if [ "$#" -eq 0 ]; then
    SERVICES=("${ALL_SERVICES[@]}")
else
    SERVICES=("$@")
fi

for service in "${SERVICES[@]}"; do
    if ! source_image_for_service "$service" >/dev/null; then
        echo "不支持的服务名: $service" >&2
        echo "可选服务: ${ALL_SERVICES[*]}" >&2
        exit 1
    fi
done

for service in "${SERVICES[@]}"; do
    image_ref="$(source_image_for_service "$service")"
    echo "拉取镜像: ${service} -> ${image_ref}"
    docker pull "$image_ref" >/dev/null
done

# 传参：service=compose文件 对，python 负责取 digest 并原地替换
pairs=()
for service in "${SERVICES[@]}"; do
    pairs+=("${service}=$(compose_file_for_service "$service"):$(compose_key_for_service "$service")")
done

python3 - "${pairs[@]}" <<'PY'
import re
import subprocess
import sys
from pathlib import Path

EASYBOT_TAG = __import__("os").environ.get("EASYBOT_TAG", "0.0.43")
source_images = {
    "cloudflared": "cloudflare/cloudflared:latest",
    "mcsmanager-web": "githubyumao/mcsmanager-web:latest",
    "mcsmanager-daemon": "githubyumao/mcsmanager-daemon:latest",
    "easybot": f"ghcr.io/easyindie/easybot:{EASYBOT_TAG}",
    "caddy": "caddy:latest",
}

changes = []
for pair in sys.argv[1:]:
    service, target = pair.split("=", 1)
    compose_path, compose_key = target.rsplit(":", 1)
    compose_file = Path(compose_path)
    image_ref = source_images[service]

    digests = subprocess.check_output(
        ["docker", "image", "inspect", image_ref, "--format", "{{join .RepoDigests \"\\n\"}}"],
        text=True,
    ).strip().splitlines()
    if not digests:
        raise SystemExit(f"未找到镜像摘要: {image_ref}")

    repo = image_ref.split(":")[0]
    digest_ref = next((item for item in digests if item.startswith(repo + "@")), digests[0])

    text = compose_file.read_text()
    pattern = rf"(^  {re.escape(compose_key)}:\n(?:    .*\n)*?    image: ).*$"
    match = re.search(pattern, text, flags=re.MULTILINE)
    if not match:
        raise SystemExit(f"未在 {compose_file.name} 中找到服务: {compose_key}")

    old_line = match.group(0).splitlines()[-1].strip()
    # 保留原有的行尾注释（如资源上限说明），只替换镜像引用
    compose_file.write_text(
        re.sub(pattern, rf"\1{digest_ref}", text, count=1, flags=re.MULTILINE)
    )
    changes.append((compose_file.name, service, old_line.removeprefix("image: ").strip(), digest_ref))

for fname, service, old, new in changes:
    print(f"[{fname}] {service}: {'未变化' if old == new else '已更新'}")
    print(f"  old: {old}")
    print(f"  new: {new}")
PY

echo
echo "摘要更新完成。建议下一步执行："
echo "  git diff -- '*.yaml'"
echo "  git add compose.yaml compose.edge.cloudflare.yaml compose.edge.local.yaml"
echo "  git commit -m 'chore: update docker image digests'"
echo "  ./orzmc.sh validate && ./orzmc.sh stop && ./orzmc.sh up   # 重建容器加载新镜像"
