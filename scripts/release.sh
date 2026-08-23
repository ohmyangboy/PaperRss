#!/bin/bash
set -e

# 确保脚本在项目根目录下运行
CDPATH= cd "$(dirname "$0")/.."

# 1. 参数解析
LOCAL_ONLY=false
VERSION=""
NOTES_TEXT=""
NOTES_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --local|--dmg-only)
            LOCAL_ONLY=true
            shift
            ;;
        --notes)
            NOTES_TEXT="$2"
            shift 2
            ;;
        --notes-file)
            NOTES_FILE="$2"
            shift 2
            ;;
        *)
            if [ -z "$VERSION" ]; then
                VERSION="$1"
            fi
            shift
            ;;
    esac
done

# 2. 环境准备
if [ -d "/Applications/Xcode-beta.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
else
    export DEVELOPER_DIR="$(xcode-select -p)"
fi

echo "🔧 开发者环境: $DEVELOPER_DIR"

echo "🌐 正在检查官网目录状态..."
WEBSITE_CHANGES=$(git status --porcelain -- website/)
if [ -n "$WEBSITE_CHANGES" ]; then
    echo "⚠️ 提示: website/ 存在未提交变更。请确保发布前提交官网变更以便 GitHub Actions 自动更新 Pages："
    echo "$WEBSITE_CHANGES"
fi

if [ "$LOCAL_ONLY" = "false" ]; then
    # 检查 GitHub CLI 所需工具
    if ! command -v gh &> /dev/null; then
        echo "❌ 错误: 未安装 GitHub CLI ('gh')。请先通过 brew install gh 安装。"
        exit 1
    fi

    if ! gh auth status &> /dev/null; then
        echo "❌ 错误: gh 未登录，请先运行 'gh auth login'。"
        exit 1
    fi
fi

# 3. 版本号处理
PROJECT_NAME="PaperRss"

if [ -z "$VERSION" ]; then
    echo "🔍 未传递版本号，从 Xcode 项目配置中提取 MARKETING_VERSION..."
    VERSION=$(xcodebuild -project "${PROJECT_NAME}.xcodeproj" -scheme "$PROJECT_NAME" -showBuildSettings 2>/dev/null | grep -E "MARKETING_VERSION =" | head -n1 | awk -F '=' '{print $2}' | tr -d ' ')
fi

if [ -z "$VERSION" ]; then
    echo "❌ 无法获取版本号！请指定版本号，例如: ./scripts/release.sh 0.1.0"
    exit 1
fi

TAG_NAME="v${VERSION}"
DMG_NAME="${PROJECT_NAME}-${TAG_NAME}.dmg"
DIST_DIR="./dist"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"

IS_PRERELEASE=false
if [[ "$VERSION" =~ (beta|alpha|rc) ]]; then
    IS_PRERELEASE=true
fi

if [ "$LOCAL_ONLY" = "true" ]; then
    echo "📦 准备本地 DMG 打包: ${DMG_NAME}"
elif [ "$IS_PRERELEASE" = "true" ]; then
    echo "📦 准备 Beta / 预发布版本: ${TAG_NAME} (Prerelease)"
else
    echo "📦 准备正式发布版本: ${TAG_NAME}"
fi

# 3. 运行单元测试
echo "🧪 1/5 正在运行单元测试..."
swift test

# 4. 构建与导出 App
echo "🏗️ 2/5 正在编译打包 App..."
./scripts/archive.sh macOS

APP_PATH="${DIST_DIR}/export/${PROJECT_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
    # 回退尝试 xcarchive 中的 App 路径
    APP_PATH="${DIST_DIR}/${PROJECT_NAME}.xcarchive/Products/Applications/${PROJECT_NAME}.app"
fi

if [ ! -d "$APP_PATH" ]; then
    echo "❌ 找不到编译导出的 ${PROJECT_NAME}.app，打包终止！"
    exit 1
fi

echo "✅ App 编译成功: $APP_PATH"

# 5. 打包 DMG
echo "💿 3/5 正在制作 DMG 镜像包: ${DMG_PATH}..."
rm -f "$DMG_PATH"

echo "🎨 正在生成 DMG 安装包背景图..."
swift scripts/generate_dmg_background.swift

STAGING_DIR="${DIST_DIR}/dmg_staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"

HELPER_SCRIPT_NAME="join-beta.command"
HELPER_SRC="./scripts/${HELPER_SCRIPT_NAME}"
if [ -f "$HELPER_SRC" ]; then
    cp "$HELPER_SRC" "$STAGING_DIR/"
    chmod +x "$STAGING_DIR/${HELPER_SCRIPT_NAME}"
fi

if command -v create-dmg &> /dev/null; then
    echo "💡 使用 create-dmg 制作 UI 镜像..."
    CREATE_DMG_ARGS=(
      --volname "$PROJECT_NAME"
      --window-pos 200 120
      --window-size 660 440
      --icon-size 100
      --icon "${PROJECT_NAME}.app" 175 105
      --hide-extension "${PROJECT_NAME}.app"
      --app-drop-link 485 105
      --background "assets/dmg-background.png"
      --disk-image-size 200
      --no-internet-enable
      --overwrite
    )
    if [ -f "$STAGING_DIR/${HELPER_SCRIPT_NAME}" ]; then
        CREATE_DMG_ARGS+=(--icon "$HELPER_SCRIPT_NAME" 330 215)
    fi
    create-dmg "${CREATE_DMG_ARGS[@]}" "$DMG_PATH" "$STAGING_DIR" || true
fi

# 如果 create-dmg 失败，使用 hdiutil 备用方案
if [ ! -f "$DMG_PATH" ]; then
    echo "💡 使用系统原生 hdiutil 制作 DMG..."
    ln -s /Applications "$STAGING_DIR/Applications"
    
    hdiutil create \
      -volname "$PROJECT_NAME" \
      -srcfolder "$STAGING_DIR" \
      -ov \
      -format UDZO \
      "$DMG_PATH"
fi

rm -rf "$STAGING_DIR"

if [ ! -f "$DMG_PATH" ]; then
    echo "❌ DMG 制作失败！"
    exit 1
fi

echo "🎉 DMG 制作成功！产物位置: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"

if [ "$LOCAL_ONLY" = "true" ]; then
    echo "=================================================="
    echo "🎉 本地 DMG 打包已完成！"
    echo "📦 产物路径: $DMG_PATH"
    echo "💡 提示: 可运行 'open ./dist' 或双击 DMG 镜像进行安装与验证。"
    echo "=================================================="
    exit 0
fi

# 6. Git Tag 处理
echo "🏷️ 4/5 正在检查 Git Tag..."
if git rev-parse "$TAG_NAME" >/dev/null 2>&1; then
    echo "ℹ️ Tag ${TAG_NAME} 已存在。"
else
    echo "🏷️ 创建 Git Tag: ${TAG_NAME}"
    git tag -a "$TAG_NAME" -m "Release ${TAG_NAME}"
    echo "🚀 推送 Tag 至 origin..."
    git push origin "$TAG_NAME"
fi

# 7. GitHub Release 发布
echo "🚀 5/5 正在发布 Release 到 GitHub..."

if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
    RELEASE_NOTES=$(cat "$NOTES_FILE")
elif [ -n "$NOTES_TEXT" ]; then
    RELEASE_NOTES="$NOTES_TEXT"
else
    # 动态获取上一个 tag 到当前 HEAD 之间的提交与更新说明
    PREV_TAG=$(git tag --sort=-creatordate 2>/dev/null | grep -v "^${TAG_NAME}$" | head -n1 || echo "")
    if [ -n "$PREV_TAG" ]; then
        COMMITS_RANGE="${PREV_TAG}..HEAD"
    else
        COMMITS_RANGE="HEAD~10..HEAD"
    fi

    CHANGELOG=$(git log "$COMMITS_RANGE" --oneline --no-merges 2>/dev/null | sed 's/^[a-f0-9]* /- /')
    if [ -z "$CHANGELOG" ]; then
        CHANGELOG=$(git log -n 5 --oneline --no-merges | sed 's/^[a-f0-9]* /- /')
    fi

    # 提取本次版本发布提交（release commit）中的要点说明
    RELEASE_BODY=$(git log "$COMMITS_RANGE" --grep="^release:" -n 1 --format=%b 2>/dev/null | sed '/^[[:space:]]*$/d' || true)
    if [ -z "$RELEASE_BODY" ]; then
        RELEASE_BODY=$(git log -n 1 --format=%b 2>/dev/null | sed '/^[[:space:]]*$/d' || true)
    fi

    if [ -n "$RELEASE_BODY" ]; then
        RELEASE_NOTES=$(cat <<EOF
🎉 PaperRss ${TAG_NAME}

### 🌟 本次更新要点
${RELEASE_BODY}

### 📝 变更明细
${CHANGELOG}
EOF
)
    else
        RELEASE_NOTES=$(cat <<EOF
🎉 PaperRss ${TAG_NAME}

### 📝 本次变更明细
${CHANGELOG}
EOF
)
    fi
fi

PRERELEASE_FLAG=""
if [ "$IS_PRERELEASE" = "true" ]; then
    PRERELEASE_FLAG="--prerelease"
fi

if gh release view "$TAG_NAME" >/dev/null 2>&1; then
    echo "ℹ️ Release ${TAG_NAME} 已存在，正在更新附件与说明..."
    gh release upload "$TAG_NAME" "$DMG_PATH" --clobber
    if [ "$IS_PRERELEASE" = "true" ]; then
        gh release edit "$TAG_NAME" --notes "$RELEASE_NOTES" --prerelease
    else
        gh release edit "$TAG_NAME" --notes "$RELEASE_NOTES"
    fi
else
    echo "🌟 创建全新的 Release ${TAG_NAME}..."
    gh release create "$TAG_NAME" "$DMG_PATH" \
      --title "PaperRss ${TAG_NAME}" \
      --notes "$RELEASE_NOTES" \
      $PRERELEASE_FLAG
fi

echo "=================================================="
echo "🎉 发布成功！"
echo "🔗 Release 页面: $(gh release view "$TAG_NAME" --json url -q .url)"
echo "=================================================="
