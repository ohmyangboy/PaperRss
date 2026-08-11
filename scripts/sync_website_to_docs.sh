#!/bin/bash
set -euo pipefail

CDPATH= cd "$(dirname "$0")/.."

# GitHub Pages 从 docs/ 发布。en、zh-CN 与 assets 完全归官网所有，先清理
# 再复制，避免已从 website/ 删除的文件继续发布；docs/agents 与
# docs/research 等项目文档不在清理范围内。
for owned_dir in docs/en docs/zh-CN docs/assets; do
    case "$owned_dir" in
        docs/en|docs/zh-CN|docs/assets) rm -rf -- "$owned_dir" ;;
        *) echo "❌ 拒绝清理非官网目录: $owned_dir"; exit 1 ;;
    esac
done
mkdir -p docs/en docs/zh-CN docs/assets
cp website/index.html docs/index.html
cp website/locale.mjs docs/locale.mjs
cp website/styles.css docs/styles.css
cp website/en/index.html docs/en/index.html
cp website/zh-CN/index.html docs/zh-CN/index.html
cp -R website/assets/. docs/assets/

test -d docs/agents
test -d docs/research
cmp website/index.html docs/index.html
cmp website/en/index.html docs/en/index.html
cmp website/zh-CN/index.html docs/zh-CN/index.html
diff -qr website/assets docs/assets

echo "✅ 官网已同步到 docs/，并保留项目文档目录。"
