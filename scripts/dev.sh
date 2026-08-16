#!/bin/bash
# 快捷编译并拉起 PaperRss macOS 应用（免 Xcode GUI）
set -e

cd "$(dirname "$0")/.."

if [ -z "$DEVELOPER_DIR" ]; then
    if [ -d "/Applications/Xcode-beta.app/Contents/Developer" ]; then
        export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
    else
        export DEVELOPER_DIR="$(xcode-select -p)"
    fi
fi

echo "🚀 正在编译 PaperRss..."
xcodebuild -project PaperRss.xcodeproj -scheme PaperRss -configuration Debug -derivedDataPath ./build -quiet

# 编译成功后关闭已有运行实例，再启动新实例
if pgrep -x "PaperRss" >/dev/null 2>&1; then
    echo "🛑 检测到已运行的 PaperRss 实例，正在关闭..."
    pkill -x "PaperRss" || true
    sleep 0.5
fi

APP_BIN="./build/Build/Products/Debug/PaperRss.app/Contents/MacOS/PaperRss"

if [ ! -f "$APP_BIN" ]; then
    echo "❌ 未找到编译产物: $APP_BIN"
    exit 1
fi

echo "🚀 启动最新 PaperRss (控制台输出已连接，按 Ctrl+C 退出)..."
exec "$APP_BIN"

