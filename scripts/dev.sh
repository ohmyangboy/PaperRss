#!/bin/bash
# 快捷编译并拉起 PaperRss macOS 应用（免 Xcode GUI）
set -e

cd "$(dirname "$0")/.."

# 隔离验收复用指定目录，便于验证重启持久化；不关闭用户的日常实例。
ISOLATED_DIRECTORY=""
DERIVED_DATA="./build"
BUILD_OPTIONS=()
if [ "${1:-}" = "--isolated" ]; then
    ISOLATED_DIRECTORY="${2:-}"
    if [[ "$ISOLATED_DIRECTORY" != /* || ! -d "$ISOLATED_DIRECTORY" ]]; then
        echo "用法: ./scripts/dev.sh --isolated <已创建的绝对临时目录>" >&2
        exit 2
    fi
    DERIVED_DATA="${PAPERRSS_DEV_DERIVED_DATA:-./build-settings-ui}"
    BUILD_OPTIONS+=("PRODUCT_BUNDLE_IDENTIFIER=${PAPERRSS_DEV_BUNDLE_ID:-com.yangbukun.PaperRss.SettingsUI}")
elif [ $# -gt 0 ]; then
    echo "未知参数: $1" >&2
    exit 2
fi

if [ -z "$DEVELOPER_DIR" ]; then
    if [ -d "/Applications/Xcode-beta.app/Contents/Developer" ]; then
        export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
    else
        export DEVELOPER_DIR="$(xcode-select -p)"
    fi
fi

echo "🚀 正在编译 PaperRss..."
xcodebuild -project PaperRss.xcodeproj -scheme PaperRss -configuration Debug -derivedDataPath "$DERIVED_DATA" "${BUILD_OPTIONS[@]}" -quiet

# 编译成功后关闭已有运行实例，再启动新实例
if [ -z "$ISOLATED_DIRECTORY" ] && pgrep -x "PaperRss" >/dev/null 2>&1; then
    echo "🛑 检测到已运行的 PaperRss 实例，正在关闭..."
    pkill -x "PaperRss" || true
    sleep 0.5
fi

APP_BIN="$DERIVED_DATA/Build/Products/Debug/PaperRss.app/Contents/MacOS/PaperRss"

if [ ! -f "$APP_BIN" ]; then
    echo "❌ 未找到编译产物: $APP_BIN"
    exit 1
fi

echo "🚀 启动最新 PaperRss (控制台输出已连接，按 Ctrl+C 退出)..."
if [ -n "$ISOLATED_DIRECTORY" ]; then
    exec env CFFIXED_USER_HOME="$ISOLATED_DIRECTORY" "$APP_BIN"
else
    exec "$APP_BIN"
fi
