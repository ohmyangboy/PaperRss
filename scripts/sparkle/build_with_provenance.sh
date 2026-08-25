#!/bin/bash
set -Eeuo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PROJECT="$ROOT_DIR/PaperRss.xcodeproj"
SCHEME="PaperRss"
CONFIGURATION="Release"
ARCHIVE_PATH=""
SOURCE_COMMIT=""
VERSION=""
BUILD=""
STABLE_FEED_URL=""
BETA_FEED_URL=""
PUBLIC_ED_KEY=""

usage() {
  cat >&2 <<'EOF'
用法: build_with_provenance.sh --archive-path <PaperRss.xcarchive>
         --version <X.Y.Z[-beta.N]> --build <N>
         --feed-url-stable <https://…> [--feed-url-beta <https://…>]
         --public-ed-key <base64> [选项]

从干净且位于 HEAD 的工作树构建归档。构建期通过临时 Info.plist 注入：
SUFeedURL / SUBetaFeedURL / SUPublicEDKey / PaperRssSourceCommit，
并回读校验；缺键即失败（fail-closed）。

选项:
  --configuration <名称>      默认 Release
  --source-commit <40位 SHA>  仅允许当前 HEAD；默认当前 HEAD
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive-path) ARCHIVE_PATH="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --build) BUILD="${2:-}"; shift 2 ;;
    --feed-url-stable) STABLE_FEED_URL="${2:-}"; shift 2 ;;
    --feed-url-beta) BETA_FEED_URL="${2:-}"; shift 2 ;;
    --public-ed-key) PUBLIC_ED_KEY="${2:-}"; shift 2 ;;
    --configuration) CONFIGURATION="${2:-}"; shift 2 ;;
    --source-commit) SOURCE_COMMIT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误: 未知参数 $1" >&2; usage; exit 2 ;;
  esac
done

fail() { echo "[FAIL] $*" >&2; exit 1; }
pass() { echo "[PASS] $*"; }

[[ -n "$ARCHIVE_PATH" && "$ARCHIVE_PATH" == *.xcarchive ]] || fail "--archive-path 必须指向 .xcarchive"
[[ -n "$VERSION" ]] || fail "缺少 --version"
[[ -n "$BUILD" ]] || fail "缺少 --build"
[[ "$STABLE_FEED_URL" == https://* ]] || fail "--feed-url-stable 必须是 HTTPS URL"
if [[ -n "$BETA_FEED_URL" && "$BETA_FEED_URL" != https://* ]]; then
  fail "--feed-url-beta 必须是 HTTPS URL"
fi
[[ -n "$PUBLIC_ED_KEY" ]] || fail "缺少 --public-ed-key（SUPublicEDKey）"

HEAD_COMMIT=$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null) || fail "无法读取当前仓库 HEAD"
if [[ -z "$SOURCE_COMMIT" ]]; then
  SOURCE_COMMIT="$HEAD_COMMIT"
fi
[[ ! "$SOURCE_COMMIT" =~ ^[a-fA-F0-9]{40}$ ]] && fail "--source-commit 必须是 40 位 commit SHA"
SOURCE_COMMIT=$(printf '%s' "$SOURCE_COMMIT" | tr '[:upper:]' '[:lower:]')
[[ "$SOURCE_COMMIT" != "$HEAD_COMMIT" ]] && fail "--source-commit 必须等于当前 HEAD；请 checkout 目标 commit 后重新构建"

if [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]]; then
  if [[ "${PAPERRSS_ALLOW_DIRTY:-}" == "1" ]]; then
    echo "[WARN] 工作树不干净（PAPERRSS_ALLOW_DIRTY=1）：provenance 仍只记录 HEAD"
  else
    fail "provenance 构建要求干净工作树，拒绝为未提交源码声明 commit"
  fi
fi

TMP_PLIST=$(mktemp "${TMPDIR:-/tmp}/paperrss-release-Info.XXXXXX.plist")
cleanup() { rm -f "$TMP_PLIST"; }
trap cleanup EXIT

cp "$ROOT_DIR/PaperRss/Resources/macOS-Info.plist" "$TMP_PLIST"
/usr/bin/plutil -replace SUFeedURL -string "$STABLE_FEED_URL" "$TMP_PLIST" || fail "写入 SUFeedURL 失败"
if [[ -n "$BETA_FEED_URL" ]]; then
  /usr/bin/plutil -replace SUBetaFeedURL -string "$BETA_FEED_URL" "$TMP_PLIST" || fail "写入 SUBetaFeedURL 失败"
fi
/usr/bin/plutil -replace SUPublicEDKey -string "$PUBLIC_ED_KEY" "$TMP_PLIST" || fail "写入 SUPublicEDKey 失败"
/usr/bin/plutil -replace PaperRssSourceCommit -string "$SOURCE_COMMIT" "$TMP_PLIST" || fail "写入 PaperRssSourceCommit 失败"
chmod 600 "$TMP_PLIST"

echo "🏗️  provenance 构建: v$VERSION (build $BUILD) @ ${SOURCE_COMMIT:0:12}"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  -quiet \
  clean archive \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  INFOPLIST_FILE="$TMP_PLIST" \
  CODE_SIGNING_ALLOWED=YES \
  || fail "xcodebuild archive 失败"

INFO_PLIST="$ARCHIVE_PATH/Products/Applications/PaperRss.app/Contents/Info.plist"
[[ -f "$INFO_PLIST" ]] || fail "归档缺少 PaperRss.app/Contents/Info.plist"

REQUIRED_KEYS=(SUFeedURL SUPublicEDKey PaperRssSourceCommit CFBundleShortVersionString CFBundleVersion)
if [[ -n "$BETA_FEED_URL" ]]; then
  REQUIRED_KEYS+=(SUBetaFeedURL)
fi
for key in "${REQUIRED_KEYS[@]}"; do
  VALUE=$(/usr/bin/plutil -extract "$key" raw -o - "$INFO_PLIST" 2>/dev/null) || fail "归档 Info.plist 缺少 ${key}；拒绝使用未经校验的构建"
  case "$key" in
    CFBundleShortVersionString)
      [[ "$VALUE" == "$VERSION" ]] || fail "版本不一致（app=$VALUE 要求=${VERSION}）" ;;
    CFBundleVersion)
      [[ "$VALUE" == "$BUILD" ]] || fail "build 不一致（app=$VALUE 要求=${BUILD}）" ;;
    PaperRssSourceCommit)
      [[ "$VALUE" == "$SOURCE_COMMIT" ]] || fail "归档 PaperRssSourceCommit 与构建 HEAD 不一致；拒绝发布。" ;;
    SUFeedURL|SUBetaFeedURL)
      [[ "$VALUE" == https://* ]] || fail "$key 不是 HTTPS URL：拒绝发布" ;;
  esac
done

pass "provenance 归档已构建并验证: $ARCHIVE_PATH (v$VERSION build $BUILD @ ${SOURCE_COMMIT:0:12})"
