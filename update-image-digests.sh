#!/usr/bin/env bash
# ===========================================================================
# 刷新 compose.yaml 中锁定的镜像 digest
#
# 用法: ./update-image-digests.sh [服务...]      # 省略则全部
#   服务: mcsmanager-web mcsmanager-daemon easybot
#
# 为什么要 digest 锁定：升级 = 改仓库里的 digest + git commit，回滚 = git revert
# （见 AGENTS.md「镜像一律用 digest 锁定」）。
#
# 全部镜像都在 compose.yaml（ADR-027 去掉边缘层后不再有 override 文件）：
#   mcsmanager-web / mcsmanager-daemon / easybot
#
# EasyBot 用**发布 tag**（非 latest）：上游 `latest` 跟踪 main 分支（label
# `org.opencontainers.image.version=main`），直接钉 latest 会引入未发布构建。
# 升级时把下面的 EASYBOT_TAG 改成目标发布版本（如 0.0.43 → 0.0.44）。
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/compose.yaml"

EASYBOT_TAG="${EASYBOT_TAG:-0.0.43}"

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "未找到 compose 文件: $COMPOSE_FILE" >&2
    exit 1
fi

# 服务 → 上游源镜像（用于 docker pull / 取 digest）
source_image_for_service() {
    case "$1" in
        mcsmanager-web)    echo "githubyumao/mcsmanager-web:latest" ;;
        mcsmanager-daemon) echo "githubyumao/mcsmanager-daemon:latest" ;;
        easybot)           echo "ghcr.io/easyindie/easybot:${EASYBOT_TAG}" ;;
        *) return 1 ;;
    esac
}

ALL_SERVICES=(mcsmanager-web mcsmanager-daemon easybot)

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

# 传参：service|源镜像|compose 文件（服务→镜像映射只在本 shell 一处，python 不再重复）
pairs=()
for service in "${SERVICES[@]}"; do
    pairs+=("${service}|$(source_image_for_service "$service")|${COMPOSE_FILE}")
done

python3 - "${pairs[@]}" <<'PY'
import re
import subprocess
import sys
from pathlib import Path

changes = []
for pair in sys.argv[1:]:
    service, rest = pair.split("|", 1)
    image_ref, compose_path = rest.split("|", 1)
    compose_file = Path(compose_path)
    compose_key = service

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
    old_ref = old_line.split("image:", 1)[-1].strip()
    # 保留原有的行尾注释（如资源上限说明），只替换镜像引用
    compose_file.write_text(
        re.sub(pattern, rf"\1{digest_ref}", text, count=1, flags=re.MULTILINE)
    )
    changes.append((compose_file.name, service, old_ref, digest_ref))

for fname, service, old, new in changes:
    print(f"[{fname}] {service}: {'未变化' if old == new else '已更新'}")
    print(f"  old: {old}")
    print(f"  new: {new}")
PY

echo
echo "摘要更新完成。建议下一步执行："
echo "  git diff -- '*.yaml'"
echo "  git add compose.yaml"
echo "  git commit -m 'chore: update docker image digests'"
echo "  ./orzmc.sh validate && ./orzmc.sh stop && ./orzmc.sh up   # 重建容器加载新镜像"
