#!/bin/bash
set -e

# 确保脚本在项目根目录下运行
CDPATH= cd "$(dirname "$0")/.."

# 本地 DMG 打包专用脚本（不推送 Tag，不上传 GitHub Release）
exec ./scripts/release.sh "$@" --local
