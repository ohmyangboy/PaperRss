#!/bin/bash
# PaperRss 稳定版安装器；仅依赖 macOS 自带工具，不修改阅读库或设置。
set -euo pipefail

fail() { printf 'PaperRss: %s\n' "$*" >&2; exit 1; }
info() { printf 'PaperRss: %s\n' "$*"; }
json() { plutil -extract "$2" raw -o - "$1"; }
fetch() { curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 3 "$@"; }

cleanup() {
  local status=$?
  trap - EXIT
  set +e
  # 替换失败或被中断时恢复旧应用；恢复失败时保留备份供人工处理。
  if [[ -n "$STAGE" && -e "$STAGE/previous.app" && "$INSTALLED" != true ]]; then
    if [[ ! -e "$TARGET" ]] && mv "$STAGE/previous.app" "$TARGET"; then
      info "已恢复原有应用。"
    else
      printf 'PaperRss: 原应用备份保留在 %s/previous.app\n' "$STAGE" >&2
      STAGE=""
    fi
  fi
  [[ -z "$STAGE" ]] || rm -rf "$STAGE"
  [[ -z "$WORK" ]] || rm -rf "$WORK"
  [[ "$LOCKED" != true ]] || rmdir "$APP_DIR/.paperrss-install.lock"
  exit "$status"
}

main() {
  APP_DIR="/Applications"
  DRY_RUN=false
  WORK=""; STAGE=""; TARGET=""; LOCKED=false; INSTALLED=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app-dir) [[ $# -ge 2 && -n "$2" ]] || fail "--app-dir 需要目录"; APP_DIR="$2"; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      -h|--help)
        printf '%s\n' '用法: bash install.sh [--app-dir /Applications] [--dry-run]' \
          '默认安装或更新最新稳定版；--dry-run 只下载与校验，不安装。' \
          '无需 Homebrew。可指定 --app-dir "$HOME/Applications" 安装到个人目录。'
        return ;;
      *) fail "未知参数: $1" ;;
    esac
  done
  [[ "$(uname -s)" == Darwin ]] || fail "仅支持 macOS 14 或更新版本。"
  OS_VERSION=$(sw_vers -productVersion)
  [[ "${OS_VERSION%%.*}" -ge 14 ]] || fail "需要 macOS 14 或更新版本。"
  [[ "$APP_DIR" == /* ]] || fail "--app-dir 必须是绝对路径。"
  TARGET="${APP_DIR%/}/PaperRss.app"
  [[ ! -L "$TARGET" ]] || fail "目标应用是符号链接，请通过原安装方式升级。"
  if [[ "$DRY_RUN" != true ]] && pgrep -x PaperRss >/dev/null; then
    fail "请先退出 PaperRss，再重新执行安装命令。"
  fi

  WORK=$(mktemp -d "${TMPDIR:-/tmp}/paperrss-install.XXXXXX")
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  info "正在查询最新稳定版…"
  fetch 'https://api.github.com/repos/ohmyangboy/PaperRss/releases/latest' -o "$WORK/release.json"
  TAG=$(json "$WORK/release.json" tag_name)
  [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "最新版本不是稳定版。"
  [[ "$(json "$WORK/release.json" draft)" == false && "$(json "$WORK/release.json" prerelease)" == false ]] || fail "拒绝安装草稿或预发布版本。"
  NAME="PaperRss-${TAG}.zip"
  INDEX=0; FOUND=false
  while ASSET_NAME=$(json "$WORK/release.json" "assets.$INDEX.name" 2>/dev/null); do
    if [[ "$ASSET_NAME" == "$NAME" ]]; then FOUND=true; break; fi
    INDEX=$((INDEX + 1))
  done
  [[ "$FOUND" == true ]] || fail "Release 缺少 $NAME。"
  URL=$(json "$WORK/release.json" "assets.$INDEX.browser_download_url")
  DIGEST=$(json "$WORK/release.json" "assets.$INDEX.digest")
  SIZE=$(json "$WORK/release.json" "assets.$INDEX.size")
  [[ "$URL" == "https://github.com/ohmyangboy/PaperRss/releases/download/$TAG/$NAME" ]] || fail "安装包地址不匹配。"
  [[ "$DIGEST" =~ ^sha256:[a-f0-9]{64}$ && "$SIZE" =~ ^[1-9][0-9]*$ ]] || fail "Release 缺少有效的 SHA-256 或文件长度。"

  info "正在下载 ${TAG}…"
  fetch "$URL" -o "$WORK/app.zip"
  [[ "$(wc -c < "$WORK/app.zip" | tr -d ' ')" == "$SIZE" ]] || fail "安装包长度不匹配。"
  HASH=$(shasum -a 256 "$WORK/app.zip")
  [[ "${HASH%% *}" == "${DIGEST#sha256:}" ]] || fail "安装包 SHA-256 不匹配。"
  ditto -x -k "$WORK/app.zip" "$WORK/unpacked"
  APP="$WORK/unpacked/PaperRss.app"
  [[ -d "$APP" && ! -L "$APP" ]] || fail "安装包中没有有效的 PaperRss.app。"
  PLIST="$APP/Contents/Info.plist"
  [[ "$(json "$PLIST" CFBundleIdentifier)" == com.yangbukun.PaperRss ]] || fail "应用标识不匹配。"
  [[ "$(json "$PLIST" CFBundleShortVersionString)" == "${TAG#v}" ]] || fail "应用版本与 Release 不匹配。"
  codesign --verify --deep --strict "$APP"
  spctl --assess --type execute "$APP"
  info "$TAG 下载、SHA-256、签名与 Gatekeeper 校验通过。"
  if [[ "$DRY_RUN" == true ]]; then info "演练完成，未安装或修改现有应用。"; return; fi

  mkdir -p "$APP_DIR"
  [[ -w "$APP_DIR" ]] || fail '目标目录不可写；可添加 --app-dir "$HOME/Applications"，或改用 DMG 手动安装。'
  mkdir "$APP_DIR/.paperrss-install.lock" 2>/dev/null || fail "另一个安装正在运行，或存在未清理的 .paperrss-install.lock。"
  LOCKED=true
  [[ ! -L "$TARGET" ]] || fail "目标应用是符号链接，拒绝替换。"
  if [[ -e "$TARGET" ]]; then
    [[ -d "$TARGET" && "$(json "$TARGET/Contents/Info.plist" CFBundleIdentifier)" == com.yangbukun.PaperRss ]] || fail "目标不是 PaperRss，拒绝替换。"
    OLD=$(json "$TARGET/Contents/Info.plist" CFBundleShortVersionString)
    [[ "$OLD" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || fail "无法识别已安装版本，拒绝替换。"
    IFS=. read -r OLD_MAJOR OLD_MINOR OLD_PATCH <<< "${OLD%%-*}"
    IFS=. read -r NEW_MAJOR NEW_MINOR NEW_PATCH <<< "${TAG#v}"
    if (( 10#$OLD_MAJOR > 10#$NEW_MAJOR ||
          (10#$OLD_MAJOR == 10#$NEW_MAJOR && 10#$OLD_MINOR > 10#$NEW_MINOR) ||
          (10#$OLD_MAJOR == 10#$NEW_MAJOR && 10#$OLD_MINOR == 10#$NEW_MINOR && 10#$OLD_PATCH > 10#$NEW_PATCH) )); then
      fail "已安装 $OLD 比稳定版 ${TAG#v} 更新，拒绝降级。"
    fi
  fi
  STAGE=$(mktemp -d "$APP_DIR/.paperrss-install.XXXXXX")
  ditto "$APP" "$STAGE/PaperRss.app"
  # 同一文件系统中替换应用，旧版本保留至新版本成功落位。
  if pgrep -x PaperRss >/dev/null; then fail "PaperRss 正在运行，请退出后重试。"; fi
  [[ ! -e "$TARGET" ]] || mv "$TARGET" "$STAGE/previous.app"
  mv "$STAGE/PaperRss.app" "$TARGET"
  INSTALLED=true
  info "已安装 ${TAG#v}：${TARGET}。订阅、阅读记录与设置保持不变。"
}

main "$@"
