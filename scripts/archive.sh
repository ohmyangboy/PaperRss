#!/bin/bash
set -e

# 确保脚本在项目根目录下运行
cd "$(dirname "$0")/.."

# 设置开发者目录：优先使用 Xcode-beta.app，若不存在则回退至默认 Xcode
if [ -d "/Applications/Xcode-beta.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
else
    export DEVELOPER_DIR="$(xcode-select -p)"
fi

PROJECT_NAME="PaperRss"
SCHEME_NAME="PaperRss"
CONFIGURATION="Release"
DIST_DIR="./dist"
ARCHIVE_PATH="${DIST_DIR}/${PROJECT_NAME}.xcarchive"
EXPORT_PATH="${DIST_DIR}/export"
PLIST_PATH="${DIST_DIR}/ExportOptions.plist"

PLATFORM="${1:-macOS}" # 默认 macOS，支持传入 iOS

echo "🔧 使用开发者环境: $DEVELOPER_DIR"
echo "📦 准备 Archive [$PROJECT_NAME] 平台: $PLATFORM, 配置: $CONFIGURATION..."

# 清理并创建产物目录
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# 1. 执行 Archive 动作
echo "⏳ 正在打包 .xcarchive..."
if [ "$PLATFORM" == "iOS" ]; then
    xcodebuild \
      -project "${PROJECT_NAME}.xcodeproj" \
      -scheme "$SCHEME_NAME" \
      -configuration "$CONFIGURATION" \
      -destination "generic/platform=iOS" \
      archive \
      -archivePath "$ARCHIVE_PATH" \
      -quiet
else
    xcodebuild \
      -project "${PROJECT_NAME}.xcodeproj" \
      -scheme "$SCHEME_NAME" \
      -configuration "$CONFIGURATION" \
      archive \
      -archivePath "$ARCHIVE_PATH" \
      -quiet
fi

echo "✅ Archive 成功！产物位于: $ARCHIVE_PATH"

# 2. 生成本地 Development 导出的 ExportOptions.plist
cat <<EOF > "$PLIST_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>compileBitcode</key>
    <false/>
</dict>
</plist>
EOF

# 3. 尝试导出应用 (.app / .ipa)
echo "🚀 正在导出应用产物..."
if xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$PLIST_PATH" \
  -exportPath "$EXPORT_PATH" \
  -quiet; then
    echo "🎉 导出成功！最终产物目录: $EXPORT_PATH"
    open "$EXPORT_PATH" 2>/dev/null || true
else
    echo "⚠️ 自动导出带有限制（如未配置 App Store / Development 签名证书）。"
    echo "💡 你可以直接在 Xcode Organizer 中打开并导出该 Archive："
    echo "   open \"$ARCHIVE_PATH\""
fi
