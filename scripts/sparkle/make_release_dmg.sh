#!/bin/bash
# make_release_dmg.sh — 从已 Staple 的 App 制作美化发布 DMG（可选签名/公证/Staple DMG 自身）
# 对应流水线 [PASS 7 前半] 与 [PASS 8]。失败即终止；临时目录 trap 清理。
set -Eeuo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
APP_PATH=""
OUTPUT_PATH=""
VERSION=""
SKIP_NOTARIZATION=false
NOTARY_PROFILE=""

usage() {
  cat >&2 <<'EOF'
用法: make_release_dmg.sh --app <PaperRss.app> --output <PaperRss-vX.Y.Z.dmg>
        --version <X.Y.Z[-beta.N]> [--notary-profile <profile>] [--skip-notarization]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_PATH="${2:-}"; shift 2 ;;
    --output) OUTPUT_PATH="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --notary-profile) NOTARY_PROFILE="${2:-}"; shift 2 ;;
    --skip-notarization) SKIP_NOTARIZATION=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误: 未知参数 $1" >&2; usage; exit 2 ;;
  esac
done

[[ "${PAPERRSS_SKIP_NOTARIZATION:-}" == "1" ]] && SKIP_NOTARIZATION=true
[[ -n "$APP_PATH" && -d "$APP_PATH" ]] || { echo "[FAIL] --app 必须指向 .app 目录" >&2; exit 2; }
[[ -n "$OUTPUT_PATH" ]] || { echo "[FAIL] 缺少 --output" >&2; exit 2; }
[[ -n "$VERSION" ]] || { echo "[FAIL] 缺少 --version" >&2; exit 2; }

pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*" >&2; exit 1; }
step() { echo "── $*"; }
APP_PATH=$(CDPATH= cd -- "$APP_PATH" && pwd)
mkdir -p "$(dirname "$OUTPUT_PATH")"
rm -f "$OUTPUT_PATH"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/paperrss-dmg.XXXXXX")
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

STAGING="$TMP_DIR/dmg_staging"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
xattr -cr "$STAGING" 2>/dev/null || true

step "[7] create-dmg 美化镜像（背景图 + 拖拽布局）"
if [[ -x "$ROOT_DIR/scripts/generate_dmg_background.swift" || -f "$ROOT_DIR/scripts/generate_dmg_background.swift" ]]; then
  swift "$ROOT_DIR/scripts/generate_dmg_background.swift" || echo "⚠️ 背景图生成失败，使用无背景 fallback"
fi

DMG_ARGS=(
  --volname "PaperRss"
  --window-pos 200 120
  --window-size 660 440
  --icon-size 100
  --icon "PaperRss.app" 175 105
  --hide-extension "PaperRss.app"
  --app-drop-link 485 105
  --disk-image-size 200
  --no-internet-enable
  --overwrite
)
[[ -f "$ROOT_DIR/assets/dmg-background.png" ]] && DMG_ARGS+=(--background "$ROOT_DIR/assets/dmg-background.png")

set +e
create-dmg "${DMG_ARGS[@]}" "$OUTPUT_PATH" "$STAGING" >"$TMP_DIR/create-dmg.log" 2>&1
CREATE_DMG_STATUS=$?
set -e
if [[ ! -f "$OUTPUT_PATH" ]]; then
  RW_DMG=$(find "$(dirname "$OUTPUT_PATH")" -maxdepth 1 -type f -name "rw*.$(basename "$OUTPUT_PATH")" -print | head -1)
  if [[ -n "$RW_DMG" ]]; then
    DEVICE=$(hdiutil info | awk -v image="$RW_DMG" 'index($0,"image-path      : " image)==1{f=1;next} f&&$1~/^\/dev\/disk/{print $1;exit}')
    [[ -n "$DEVICE" ]] && hdiutil detach -force "$DEVICE" >/dev/null 2>&1 || true
    hdiutil convert "$RW_DMG" -format UDZO -o "$OUTPUT_PATH" -ov || fail "create-dmg 中间镜像压缩失败"
    rm -f "$RW_DMG"
  elif [[ "$CREATE_DMG_STATUS" -ne 0 ]]; then
    tail -20 "$TMP_DIR/create-dmg.log" >&2 || true
    hdiutil create -volname "PaperRss" -srcfolder "$STAGING" -ov -format UDZO "$OUTPUT_PATH" \
      || fail "DMG 制作失败（含原生 fallback）"
  fi
fi
[[ -f "$OUTPUT_PATH" ]] || fail "DMG 未生成"
pass "[PASS 7] 发布 DMG 已制作: $OUTPUT_PATH ($(du -h "$OUTPUT_PATH" | cut -f1))"

# ── [PASS 8] DMG 自身签名/公证/Staple ─────────────────────────────────────
if [[ "$SKIP_NOTARIZATION" == true ]]; then
  echo "[SKIP] [PASS 8] DMG 公证已显式跳过（仅限本机演练）"
else
  step "[8] DMG 签名 + 公证 + Staple"
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/^\s*[0-9]+\) ([A-F0-9]+) (.*)$/\1/')
  [[ -n "$IDENTITY" ]] || fail "找不到 Developer ID Application 证书"
  codesign --sign "$IDENTITY" --timestamp "$OUTPUT_PATH" || fail "DMG codesign 失败"
  xcrun notarytool submit "$OUTPUT_PATH" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$TMP_DIR/notary.log" \
    | grep -qi "Accepted" || fail "DMG 公证未 Accepted"
  xcrun stapler staple "$OUTPUT_PATH" || fail "DMG stapler staple 失败"
  xcrun stapler validate "$OUTPUT_PATH" || fail "DMG stapler validate 未通过"
  hdiutil verify "$OUTPUT_PATH" >/dev/null 2>&1 || fail "hdiutil verify 未通过"
  pass "[PASS 8] DMG 公证 + Staple + 校验全部通过"
fi
