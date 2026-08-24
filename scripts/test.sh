#!/bin/bash
# 启动一个与正式 PaperRss 相互独立的新用户测试实例。
set -euo pipefail

CDPATH= cd "$(dirname "$0")/.."

FRESH_TEST_BUNDLE_ID="com.yangbukun.PaperRss.FreshLaunchTest"
FRESH_TEST_PRODUCT_NAME="PaperRssFresh"
FRESH_TEST_BUILD_ROOT="$(pwd)/build/FreshLaunchTest"
FRESH_TEST_SOURCE_APP="${FRESH_TEST_BUILD_ROOT}/Build/Products/Debug/PaperRss.app"
FRESH_TEST_APP="${FRESH_TEST_BUILD_ROOT}/Build/Products/Debug/${FRESH_TEST_PRODUCT_NAME}.app"
FRESH_TEST_APP_BIN="${FRESH_TEST_APP}/Contents/MacOS/${FRESH_TEST_PRODUCT_NAME}"
FRESH_TEST_PREFERENCES_PLIST="${HOME}/Library/Preferences/${FRESH_TEST_BUNDLE_ID}.plist"
FRESH_TEST_SKIP_BUILD=false
FRESH_TEST_APP_PID=""
FRESH_TEST_HOME=""

usage() {
    cat <<'EOF'
用法：
  ./scripts/test.sh               构建并启动隔离的新用户实例
  ./scripts/test.sh --skip-build  复用上次隔离构建并启动
  ./scripts/test.sh --help        显示帮助

隔离范围：
  - 独立 Bundle ID 与 UserDefaults 偏好域
  - 独立 DerivedData 与应用产物
  - 每次运行使用全新的临时 Application Support、缓存和 HTTP 存储
  - 忽略正式应用的窗口恢复状态

注意：系统 Keychain 不在隔离范围内。在测试 FreshRSS 账号配置时，
不要将此实例视为可安全写入正式凭据的完全沙盒。

按 Ctrl+C 或退出 PaperRssFresh（⌘Q）后，临时数据与测试偏好会自动清理。
EOF
}

case "${1:-}" in
    "")
        ;;
    --skip-build)
        FRESH_TEST_SKIP_BUILD=true
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    *)
        echo "❌ 未知参数：$1" >&2
        usage >&2
        exit 2
        ;;
esac

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM

    if [ -n "$FRESH_TEST_APP_PID" ] && kill -0 "$FRESH_TEST_APP_PID" 2>/dev/null; then
        kill "$FRESH_TEST_APP_PID" 2>/dev/null || true
        wait "$FRESH_TEST_APP_PID" 2>/dev/null || true
    fi

    defaults delete "$FRESH_TEST_BUNDLE_ID" >/dev/null 2>&1 || true

    case "$FRESH_TEST_PREFERENCES_PLIST" in
        /Users/*/Library/Preferences/com.yangbukun.PaperRss.FreshLaunchTest.plist)
            rm -f -- "$FRESH_TEST_PREFERENCES_PLIST"
            ;;
    esac

    case "$FRESH_TEST_HOME" in
        /private/tmp/paperrss-fresh-test.*)
            rm -rf -- "$FRESH_TEST_HOME"
            ;;
    esac

    echo "🧹 已清理隔离实例的临时数据与测试偏好。"
    exit "$exit_code"
}

if pgrep -x "$FRESH_TEST_PRODUCT_NAME" >/dev/null 2>&1; then
    echo "❌ ${FRESH_TEST_PRODUCT_NAME} 已在运行，请先退出后再试。" >&2
    exit 1
fi

FRESH_TEST_HOME="$(mktemp -d /private/tmp/paperrss-fresh-test.XXXXXX)"
trap cleanup EXIT INT TERM

if [ -z "${DEVELOPER_DIR:-}" ]; then
    if [ -d "/Applications/Xcode-beta.app/Contents/Developer" ]; then
        export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
    else
        export DEVELOPER_DIR="$(xcode-select -p)"
    fi
fi

if [ "$FRESH_TEST_SKIP_BUILD" = false ]; then
    echo "🔨 正在构建隔离测试应用..."
    xcodebuild \
        -project PaperRss.xcodeproj \
        -scheme PaperRss \
        -configuration Debug \
        -destination "platform=macOS" \
        -derivedDataPath "$FRESH_TEST_BUILD_ROOT" \
        SWIFT_EMIT_LOC_STRINGS=NO \
        CODE_SIGNING_ALLOWED=NO \
        -quiet

    rm -rf -- "$FRESH_TEST_APP"
    ditto "$FRESH_TEST_SOURCE_APP" "$FRESH_TEST_APP"
    mv \
        "$FRESH_TEST_APP/Contents/MacOS/PaperRss" \
        "$FRESH_TEST_APP_BIN"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $FRESH_TEST_BUNDLE_ID" "$FRESH_TEST_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $FRESH_TEST_PRODUCT_NAME" "$FRESH_TEST_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $FRESH_TEST_PRODUCT_NAME" "$FRESH_TEST_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $FRESH_TEST_PRODUCT_NAME" "$FRESH_TEST_APP/Contents/Info.plist"
    codesign --force --deep --sign - "$FRESH_TEST_APP"
elif [ ! -x "$FRESH_TEST_APP_BIN" ]; then
    echo "❌ 没有可复用的隔离构建，请先运行 ./scripts/test.sh。" >&2
    exit 1
fi

defaults delete "$FRESH_TEST_BUNDLE_ID" >/dev/null 2>&1 || true

echo "🧪 正在启动 ${FRESH_TEST_PRODUCT_NAME}..."
echo "   正式数据库、缓存和常规偏好不会被读取；系统 Keychain 不隔离。"
echo "   按 Ctrl+C 或退出应用（⌘Q）结束测试。"

CFFIXED_USER_HOME="$FRESH_TEST_HOME" \
    "$FRESH_TEST_APP_BIN" -ApplePersistenceIgnoreState YES &
FRESH_TEST_APP_PID=$!
wait "$FRESH_TEST_APP_PID"
