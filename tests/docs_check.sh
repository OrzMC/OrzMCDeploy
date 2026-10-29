#!/usr/bin/env bash
# ===========================================================================
# 文档健康检查：markdown 相对链接 + 锚点是否有效
#
# 用法：bash tests/docs_check.sh     # 0=通过，1=有失效项
# CI：lint job 调用（见 .github/workflows/ci.yml）
#
# 锚点规则按 GitHub 的 slug 近似实现：小写、去掉标点（保留 - _）、空格转 -
# 中文标题原样保留。改文档后本地跑一遍即可，避免 README/手册互链失效。
# ===========================================================================
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$REPO_ROOT"

python3 - <<'PY'
import pathlib
import re
import sys
import unicodedata


def slug(heading: str) -> str:
    out = []
    for ch in heading.strip().lower():
        cat = unicodedata.category(ch)
        if cat.startswith(("P", "S")):
            if ch in "-_":
                out.append(ch)
            continue
        out.append(ch)
    return re.sub(r"\s+", "-", "".join(out))


files = list(pathlib.Path(".").glob("*.md")) + list(pathlib.Path("docs").glob("*.md"))
anchors = {
    f.resolve(): {
        slug(m.group(2))
        for line in f.read_text().splitlines()
        if (m := re.match(r"^(#{1,4})\s+(.*)$", line))
    }
    for f in files
}

bad = []
for f in files:
    for link in re.findall(r"\]\(([^)\s]+)\)", f.read_text()):
        if link.startswith(("http", "mailto:")):
            continue
        target, _, frag = link.partition("#")
        tf = (f.parent / target).resolve() if target else f.resolve()
        if target and not tf.exists():
            bad.append(f"{f}: 文件不存在 {link}")
        elif frag and tf.suffix == ".md" and frag not in anchors.get(tf, set()):
            bad.append(f"{f}: 锚点失效 {link}")

if bad:
    print("\n".join(bad))
    sys.exit(f"{len(bad)} 处链接/锚点失效")
print(f"docs OK: {len(files)} 个 markdown，链接与锚点全部有效")
PY
