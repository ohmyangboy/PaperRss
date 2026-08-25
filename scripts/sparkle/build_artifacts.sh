#!/bin/bash
set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
MANIFEST_TOOL="$ROOT_DIR/scripts/sparkle/artifact_manifest.mjs"
DITTO_BIN="${SPARKLE_DITTO:-/usr/bin/ditto}"
HDIUTIL_BIN="${SPARKLE_HDIUTIL:-/usr/bin/hdiutil}"

APP_PATH=""
OUTPUT_DIR="$ROOT_DIR/dist/sparkle"
CHANNEL=""
EXPECTED_VERSION=""
EXPECTED_BUILD=""
REQUIRED_ARCHITECTURES=""
DOWNLOAD_URL=""
SIGNING_ACCOUNT=""
READ_SIGNING_KEY_FROM_STDIN=false
SOURCE_COMMIT=""
PREMADE_DMG=""

usage() {
  cat >&2 <<'EOF'
用法: build_artifacts.sh --app <PaperRss.app> --channel <stable|beta> [选项]

选项:
  --output-dir <目录>             本地产物目录（默认 dist/sparkle）
  --version <版本>                要求与 CFBundleShortVersionString 一致
  --build <build>                 要求与 CFBundleVersion 一致
  --require-architectures <列表>  逗号分隔，例如 arm64,x86_64
  --download-url <HTTPS URL>      appcast enclosure 使用的 ZIP 地址（默认 GitHub Release 地址）
  --signing-account <名称>        Sparkle Keychain account（默认 ed25519）
  --stdin-key                     从 stdin 受保护地提供 EdDSA 私钥给 sign_update
  --source-commit <40位 SHA>      构建来源 commit（默认当前仓库 HEAD）
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_PATH="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --version) EXPECTED_VERSION="${2:-}"; shift 2 ;;
    --build) EXPECTED_BUILD="${2:-}"; shift 2 ;;
    --require-architectures) REQUIRED_ARCHITECTURES="${2:-}"; shift 2 ;;
    --download-url) DOWNLOAD_URL="${2:-}"; shift 2 ;;
    --signing-account) SIGNING_ACCOUNT="${2:-}"; shift 2 ;;
    --stdin-key) READ_SIGNING_KEY_FROM_STDIN=true; shift ;;
    --source-commit) SOURCE_COMMIT="${2:-}"; shift 2 ;;
    --premade-dmg) PREMADE_DMG="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误: 未知参数 $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$APP_PATH" || -z "$CHANNEL" ]]; then
  usage
  exit 2
fi
if [[ "$CHANNEL" != "stable" && "$CHANNEL" != "beta" ]]; then
  echo "错误: channel 必须是 stable 或 beta" >&2
  exit 2
fi
if [[ ! -d "$APP_PATH" || "$APP_PATH" != *.app ]]; then
  echo "错误: --app 必须指向一个 .app 目录" >&2
  exit 2
fi
APP_PATH=$(CDPATH= cd -- "$APP_PATH" && pwd)
INFO_PLIST="$APP_PATH/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "错误: .app 缺少 Contents/Info.plist" >&2
  exit 1
fi

read_plist() {
  /usr/bin/plutil -extract "$1" raw -o - "$INFO_PLIST" 2>/dev/null
}

VERSION=$(read_plist CFBundleShortVersionString) || {
  echo "错误: 无法读取 CFBundleShortVersionString" >&2
  exit 1
}
BUILD=$(read_plist CFBundleVersion) || {
  echo "错误: 无法读取 CFBundleVersion" >&2
  exit 1
}
APP_NAME=${APP_PATH##*/}
APP_NAME=${APP_NAME%.app}

if [[ -n "$EXPECTED_VERSION" && "$EXPECTED_VERSION" != "$VERSION" ]]; then
  echo "错误: 版本不一致（app=${VERSION}，要求=${EXPECTED_VERSION}）" >&2
  exit 1
fi
if [[ -n "$EXPECTED_BUILD" && "$EXPECTED_BUILD" != "$BUILD" ]]; then
  echo "错误: build 不一致（app=${BUILD}，要求=${EXPECTED_BUILD}）" >&2
  exit 1
fi
if [[ -z "$SOURCE_COMMIT" ]]; then
  SOURCE_COMMIT=$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null) || {
    echo "错误: 无法确定构建来源 commit；请传入 --source-commit。" >&2
    exit 1
  }
fi
if [[ ! "$SOURCE_COMMIT" =~ ^[a-fA-F0-9]{40}$ ]]; then
  echo "错误: --source-commit 必须是 40 位 commit SHA。" >&2
  exit 2
fi
SOURCE_COMMIT=$(printf '%s' "$SOURCE_COMMIT" | tr '[:upper:]' '[:lower:]')
APP_SOURCE_COMMIT=$(read_plist PaperRssSourceCommit) || {
  echo "错误: .app 缺少 PaperRssSourceCommit 构建来源标记；请使用 scripts/sparkle/build_with_provenance.sh 重新构建。" >&2
  exit 1
}
if [[ ! "$APP_SOURCE_COMMIT" =~ ^[a-f0-9]{40}$ ]]; then
  echo "错误: .app 的 PaperRssSourceCommit 必须是小写 40 位 commit SHA。" >&2
  exit 1
fi
if [[ "$APP_SOURCE_COMMIT" != "$SOURCE_COMMIT" ]]; then
  echo "错误: .app 构建来源 commit 与 --source-commit 不一致（app=${APP_SOURCE_COMMIT}，source=${SOURCE_COMMIT}）；拒绝伪造 provenance。" >&2
  exit 1
fi

resolve_signer() {
  if [[ -n "${SPARKLE_SIGN_UPDATE:-}" ]]; then
    printf '%s' "$SPARKLE_SIGN_UPDATE"
    return
  fi
  local candidate
  for candidate in \
    "$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update" \
    "$ROOT_DIR/build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"; do
    if [[ -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return
    fi
  done
  return 1
}

SIGNER=$(resolve_signer 2>/dev/null) || {
  echo "错误: 找不到 Sparkle sign_update；请先构建 Sparkle，或设置 SPARKLE_SIGN_UPDATE。" >&2
  exit 1
}
if [[ ! -x "$SIGNER" ]]; then
  echo "错误: Sparkle sign_update 不可执行: $SIGNER" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(CDPATH= cd -- "$OUTPUT_DIR" && pwd)
RELEASE_DIR_NAME="${APP_NAME}-v${VERSION}"
FINAL_RELEASE_DIR="$OUTPUT_DIR/$RELEASE_DIR_NAME"
if [[ -z "$DOWNLOAD_URL" ]]; then
  DOWNLOAD_URL="https://github.com/ohmyangboy/PaperRss/releases/download/v${VERSION}/${APP_NAME}-v${VERSION}.zip"
fi

if [[ -e "$FINAL_RELEASE_DIR" || -L "$FINAL_RELEASE_DIR" ]]; then
  echo "错误: 版本产物目录已存在，拒绝覆盖既有证据: $FINAL_RELEASE_DIR" >&2
  exit 1
fi

# mkdir 是原子的。先占用版本专属锁，避免两个发布者都在“最终目录不存在”
# 的窗口继续执行，并在 BSD mv 的目标目录语义下出现嵌套或半成品。
VERSION_LOCK_DIR="$OUTPUT_DIR/.${RELEASE_DIR_NAME}.lock"
if ! mkdir "$VERSION_LOCK_DIR" 2>/dev/null; then
  echo "错误: 该版本已有本地打包在进行中（或遗留 fail-closed 锁）: $VERSION_LOCK_DIR" >&2
  exit 1
fi
if [[ -e "$FINAL_RELEASE_DIR" || -L "$FINAL_RELEASE_DIR" ]]; then
  rmdir "$VERSION_LOCK_DIR" 2>/dev/null || true
  echo "错误: 版本产物目录已存在，拒绝覆盖既有证据: $FINAL_RELEASE_DIR" >&2
  exit 1
fi

# 产物暂存目录位于最终输出目录内，确保最后的 mv 保持在同一文件系统，
# 从而可以用原子 rename 落盘；失败时 cleanup 只会移除本轮暂存内容。
ARTIFACT_STAGING_DIR=""
STAGING_DIR=""
cleanup() {
  [[ -z "$ARTIFACT_STAGING_DIR" ]] || rm -rf "$ARTIFACT_STAGING_DIR"
  [[ -z "$STAGING_DIR" ]] || rm -rf "$STAGING_DIR"
  rmdir "$VERSION_LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT
ARTIFACT_STAGING_DIR=$(mktemp -d "$OUTPUT_DIR/.${RELEASE_DIR_NAME}.staging.XXXXXX")
ZIP_PATH="$ARTIFACT_STAGING_DIR/${APP_NAME}-v${VERSION}.zip"
DMG_PATH="$ARTIFACT_STAGING_DIR/${APP_NAME}-v${VERSION}.dmg"
MANIFEST_PATH="$ARTIFACT_STAGING_DIR/manifest.json"
STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/paperrss-sparkle-dmg.XXXXXX")

echo "正在创建完整 ZIP: $ZIP_PATH"
"$DITTO_BIN" --norsrc -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

if [[ -n "$PREMADE_DMG" ]]; then
  if [[ ! -f "$PREMADE_DMG" ]]; then
    echo "错误: --premade-dmg 指定的 DMG 不存在: $PREMADE_DMG" >&2
    exit 1
  fi
  echo "使用预制作 DMG: $PREMADE_DMG"
  cp "$PREMADE_DMG" "$DMG_PATH"
else
  cp -R "$APP_PATH" "$STAGING_DIR/"
  ln -s /Applications "$STAGING_DIR/Applications"
  echo "正在创建 DMG: $DMG_PATH"
  "$HDIUTIL_BIN" create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null
fi

SIGN_ARGS=()
if [[ -n "$SIGNING_ACCOUNT" ]]; then
  SIGN_ARGS+=(--account "$SIGNING_ACCOUNT")
fi
if [[ "$READ_SIGNING_KEY_FROM_STDIN" == true ]]; then
  SIGN_ARGS+=(--ed-key-file -)
fi
# Keep Sparkle's standard metadata output. The -p mode emits only the raw
# signature, while the manifest boundary needs both edSignature and length.
SIGN_ARGS+=("$ZIP_PATH")

echo "正在使用 Sparkle EdDSA 签名 ZIP（Keychain 或受保护 stdin）"
if [[ "$READ_SIGNING_KEY_FROM_STDIN" == true ]]; then
  SIGN_OUTPUT=$("$SIGNER" "${SIGN_ARGS[@]}" < /dev/stdin) || {
    echo "错误: sign_update 无法取得 EdDSA 私钥；请确认 Keychain 或 stdin 输入可用。" >&2
    exit 1
  }
else
  SIGN_OUTPUT=$("$SIGNER" "${SIGN_ARGS[@]}") || {
    echo "错误: sign_update 无法取得 EdDSA 私钥；请确认 Sparkle Keychain account 可用。" >&2
    exit 1
  }
fi

SIGNATURE=$(printf '%s\n' "$SIGN_OUTPUT" | sed -nE 's/.*edSignature[=:]"?([A-Za-z0-9+\/=]+)"?.*/\1/p' | tail -n 1)
SIGNED_LENGTH=$(printf '%s\n' "$SIGN_OUTPUT" | sed -nE 's/.*length[=:]"?([0-9]+)"?.*/\1/p' | tail -n 1)
if [[ -z "$SIGNATURE" || -z "$SIGNED_LENGTH" ]]; then
  echo "错误: 无法从 sign_update 输出提取 edSignature/length；产物不会流转。" >&2
  exit 1
fi

node "$MANIFEST_TOOL" create \
  --app "$APP_PATH" \
  --zip "$ZIP_PATH" \
  --dmg "$DMG_PATH" \
  --manifest "$MANIFEST_PATH" \
  --channel "$CHANNEL" \
  --download-url "$DOWNLOAD_URL" \
  --signature "$SIGNATURE" \
  --signed-length "$SIGNED_LENGTH" \
  --source-commit "$SOURCE_COMMIT"

VALIDATE_ARGS=(--manifest "$MANIFEST_PATH")
if [[ -n "$REQUIRED_ARCHITECTURES" ]]; then
  VALIDATE_ARGS+=(--require-architectures "$REQUIRED_ARCHITECTURES")
fi
"$ROOT_DIR/scripts/sparkle/validate_artifacts.sh" "${VALIDATE_ARGS[@]}"
mv "$ARTIFACT_STAGING_DIR" "$FINAL_RELEASE_DIR"
echo "本地 Sparkle 产物已验证: ${FINAL_RELEASE_DIR}；没有创建或修改远程 Release/appcast。"
