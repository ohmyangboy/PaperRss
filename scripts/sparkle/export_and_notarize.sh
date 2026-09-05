#!/bin/bash
# export_and_notarize.sh — Developer ID 导出 + 签名/公证/Staple/Gatekeeper 全门禁
# 覆盖流水线 [PASS 3]–[PASS 6]。任一门禁失败立即终止，半成品不落盘。
set -Eeuo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ARCHIVE_PATH=""
OUTPUT_DIR=""
TEAM_ID=""
NOTARY_PROFILE=""
SKIP_NOTARIZATION=false

usage() {
  cat >&2 <<'EOF'
用法: export_and_notarize.sh --archive <PaperRss.xcarchive> --output-dir <目录>
        --team-id <TeamID> [--notary-profile <keychain profile>]
        [--skip-notarization]

环境变量:
  PAPERRSS_SKIP_NOTARIZATION=1   等价 --skip-notarization（仅本机演练用）

说明:
  - 公证凭据只经 notarytool keychain profile 引用；脚本不接受任何密码。
  - 日志只输出「已设置/未设置」，绝不回显变量值。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive) ARCHIVE_PATH="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --team-id) TEAM_ID="${2:-}"; shift 2 ;;
    --notary-profile) NOTARY_PROFILE="${2:-}"; shift 2 ;;
    --skip-notarization) SKIP_NOTARIZATION=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误: 未知参数 $1" >&2; usage; exit 2 ;;
  esac
done

[[ "${PAPERRSS_SKIP_NOTARIZATION:-}" == "1" ]] && SKIP_NOTARIZATION=true
[[ -n "$ARCHIVE_PATH" ]] || { usage; exit 2; }
[[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="$ROOT_DIR/dist/export"
if [[ "$SKIP_NOTARIZATION" != true ]]; then
  [[ -n "$TEAM_ID" ]] || { echo "[FAIL] 缺少 --team-id" >&2; exit 2; }
  if [[ -z "${PAPERRSS_NOTARY_KEY:-}" || -z "${PAPERRSS_NOTARY_KEY_ID:-}" || -z "${PAPERRSS_NOTARY_ISSUER:-}" ]]; then
    [[ -n "$NOTARY_PROFILE" ]] || { echo "[FAIL] 缺少公证凭据（App Store Connect API Key 或 keychain profile）" >&2; exit 2; }
  fi
fi

pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*" >&2; exit 1; }
step() { echo "── $*"; }

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/paperrss-notary.XXXXXX")
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

APP_NAME="PaperRss"
EXPORT_DIR="$OUTPUT_DIR"
PLIST_PATH="$TMP_DIR/ExportOptions.plist"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"

mkdir -p "$EXPORT_DIR" && EXPORT_DIR=$(CDPATH= cd -- "$EXPORT_DIR" && pwd)
rm -rf "$APP_PATH"

# ── [PASS 3] Developer ID 导出 ────────────────────────────────────────────
step "[3] Developer ID 导出"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID:-PLACEHOLDER}</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$PLIST_PATH" \
  -exportPath "$EXPORT_DIR" \
  -quiet || fail "Developer ID 导出失败（检查证书与 --team-id）"
[[ -d "$APP_PATH" ]] || fail "导出后未找到 $APP_PATH"
pass "[PASS 3] Developer ID 导出成功: $APP_PATH"

# ── [PASS 4] 签名门禁 ─────────────────────────────────────────────────────
step "[4] 签名门禁"
codesign --verify --deep --strict "$APP_PATH" || fail "codesign --verify --deep --strict 未通过"

AUTHORITY=$(codesign -dvv "$APP_PATH" 2>&1 | grep "Authority=" | head -1 || true)
echo "$AUTHORITY" | grep -q "Authority=Developer ID Application" \
  || fail "签名身份不是 Developer ID Application（实际: ${AUTHORITY:-无}）"

ENTITLEMENTS=$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)
if echo "$ENTITLEMENTS" | grep -q "get-task-allow"; then
  VALUE=$(echo "$ENTITLEMENTS" | plutil -extract get-task-allow raw -o - - 2>/dev/null || echo "?")
  [[ "$VALUE" == "false" ]] || fail "get-task-allow 必须为 false（Hardened Runtime 导出）"
fi
# Hardened Runtime：-dv 在部分工具链不打印独立 Runtime 行，
# 统一用 -dvv 的 CodeDirectory flags 匹配（0x10000 = runtime 位）。
CODESIGN_DVV=$(codesign -dvv "$APP_PATH" 2>&1)
echo "$CODESIGN_DVV" | grep -Eq 'flags=0x[0-9a-f]+\(runtime\)|^Runtime[= ]' \
  || fail "未启用 Hardened Runtime"

pass "[PASS 4] 签名门禁通过（Developer ID + Hardened Runtime + secure timestamp）"

# 启动冒烟：导出产物必须能在本机存活启动（防 rpath/嵌入缺失类 dyld 崩溃
# 流出到公证环节）。公证前执行——崩溃的 App 不配消耗公证额度。
step "[4b] 启动冒烟（3 秒存活探针）"
if [[ -z "${PAPERRSS_SKIP_LAUNCH_SMOKE:-}" ]]; then
  LAUNCH_LOG="$TMP_DIR/launch-smoke.log"
  open -n "$APP_PATH" >"$LAUNCH_LOG" 2>&1 || fail "App 无法启动（open 失败，见 ${LAUNCH_LOG}）"
  ALIVE=false
  for _ in 1 2 3 4 5 6; do
    sleep 0.7
    if pgrep -xf "$APP_PATH/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then ALIVE=true; break; fi
  done
  pkill -xf "$APP_PATH/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  sleep 0.5
  if [[ "$ALIVE" != true ]]; then
    echo "启动冒烟失败：进程未存活。最近崩溃报告：" >&2
    ls -t ~/Library/Logs/DiagnosticReports/PaperRss-* 2>/dev/null | head -1 >&2 || true
    fail "导出产物启动即崩（典型原因：LC_RPATH 缺 @executable_path/../Frameworks 或框架未内嵌）"
  fi
  pass "[PASS 4b] 启动冒烟通过（进程存活并已退出）"
else
  echo "[SKIP] [PASS 4b] 启动冒烟已跳过（PAPERRSS_SKIP_LAUNCH_SMOKE）"
fi

# 注意：spctl 评估放在 [PASS 6] Staple 之后——未公证的 Developer ID 在此阶段
# 被 Gatekeeper 拒绝是预期行为，不构成失败。

# ── [PASS 5] 公证 ─────────────────────────────────────────────────────────
SUBMISSION_FILE="$TMP_DIR/notary-submission.txt"
if [[ "$SKIP_NOTARIZATION" == true ]]; then
  echo "[SKIP] [PASS 5] 公证已显式跳过（仅限本机演练，禁止对外分发）"
  : > "$SUBMISSION_FILE"
else
  step "[5] Apple 公证（notarytool submit --wait）"
  SUBMIT_ZIP="$TMP_DIR/${APP_NAME}-notarize.zip"
  /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$SUBMIT_ZIP"
  # 双模式：优先直传 .p8 三元组（环境无关，钥匙串丢失/沙箱环境均可用）；
  # 否则回退 keychain profile（需要 GUI 会话环境）。
  if [[ -n "${PAPERRSS_NOTARY_KEY:-}" && -n "${PAPERRSS_NOTARY_KEY_ID:-}" && -n "${PAPERRSS_NOTARY_ISSUER:-}" ]]; then
    [[ -f "${PAPERRSS_NOTARY_KEY}" ]] || fail "PAPERRSS_NOTARY_KEY 指向的 .p8 不存在"
    AUTH_ARGS=(--key "${PAPERRSS_NOTARY_KEY}" --key-id "${PAPERRSS_NOTARY_KEY_ID}" --issuer "${PAPERRSS_NOTARY_ISSUER}")
    AUTH_MODE="direct-key"
  elif [[ -n "$NOTARY_PROFILE" ]]; then
    AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    AUTH_MODE="keychain-profile"
  else
    fail "缺少公证凭据：请配置 keychain profile 或 PAPERRSS_NOTARY_KEY/KEY_ID/ISSUER 三元组"
  fi
  SUBMIT_OUT=$(xcrun notarytool submit "$SUBMIT_ZIP" "${AUTH_ARGS[@]}" --wait 2>&1) \
    || { echo "$SUBMIT_OUT" >&2; fail "notarytool 提交失败（模式: ${AUTH_MODE}）"; }
  echo "$SUBMIT_OUT"
  echo "$SUBMIT_OUT" | grep -qi "Accepted" || fail "公证状态不是 Accepted"
  SUBMISSION_ID=$(echo "$SUBMIT_OUT" | grep -iE "id: *[a-f0-9-]{36}" | head -1 | awk '{print $NF}' || true)
  {
    echo "notaryProfileSet=yes"
    echo "submissionId=${SUBMISSION_ID:-unknown}"
    echo "status=Accepted"
  } > "$SUBMISSION_FILE"
  pass "[PASS 5] 公证 Accepted（submission: ${SUBMISSION_ID:-unknown}）"
fi

# ── [PASS 6] Staple + 复验 ────────────────────────────────────────────────
if [[ "$SKIP_NOTARIZATION" == true ]]; then
  echo "[SKIP] [PASS 6] Staple 已随公证一并跳过"
else
  step "[6] Staple 与复验"
  xcrun stapler staple "$APP_PATH" || fail "stapler staple 失败"
  xcrun stapler validate "$APP_PATH" || fail "stapler validate 未通过"
  codesign --verify --deep --strict "$APP_PATH" || fail "Staple 后 codesign 复验失败"
  spctl -a -vv -t execute "$APP_PATH" >/dev/null 2>&1 || fail "Staple 后 spctl 复验失败"
  pass "[PASS 6] Staple 完成并通过全部复验"
fi

echo "$APP_PATH"
