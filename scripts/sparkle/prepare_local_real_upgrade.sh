#!/bin/bash
set -euo pipefail

# Prepare a real, local-only Sparkle N/N+1 acceptance environment. This script
# deliberately never opens or replaces an app, publishes a Release/appcast, or
# writes a private key to disk. Sparkle's private key is read by sign_update
# from the macOS Keychain account named below.

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SERVER_SCRIPT="$ROOT_DIR/scripts/sparkle/local_https_feed_server.mjs"
BUILD_ARTIFACTS_SCRIPT="$ROOT_DIR/scripts/sparkle/build_artifacts.sh"
APPCAST_SCRIPT="$ROOT_DIR/scripts/sparkle/appcast.mjs"
NODE_BIN="${NODE_BIN:-node}"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"
XCODEBUILD_BIN="${XCODEBUILD_BIN:-xcodebuild}"
SECURITY_BIN="${SECURITY_BIN:-/usr/bin/security}"
GENERATE_KEYS_BIN="${GENERATE_KEYS_BIN:-$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_keys}"
SPARKLE_SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update}"

ACCOUNT="${SPARKLE_KEYCHAIN_ACCOUNT:-paperrss-issue11-local}"
CODE_SIGN_IDENTITY="${PAPERRSS_LOCAL_CODE_SIGN_IDENTITY:-Apple Development}"
DEVELOPMENT_TEAM="${PAPERRSS_LOCAL_DEVELOPMENT_TEAM:-LGKLTGNTY2}"
CODE_SIGN_STYLE="Automatic"
CHANNEL="beta"
CONFIGURATION="Release"
CURRENT_VERSION="1.3.0-beta.1"
NEXT_VERSION="1.3.0-beta.2"
CURRENT_BUILD="10"
NEXT_BUILD="11"
WORKSPACE=""
WORKSPACE_OWNED=false
KEEP=false
WAIT=false
PLAN_ONLY=false
NO_SERVER=false
INSTALL_CA=false
GENERATE_KEY=false
PUBLIC_KEY_FILE=""

usage() {
  cat <<'EOF'
用法: scripts/sparkle/prepare_local_real_upgrade.sh [选项]

准备仅本机使用的真实 PaperRss Sparkle N/N+1 验收环境。默认 channel 为 beta，
默认使用 Sparkle Keychain account paperrss-issue11-local。私钥从未写入文件、日志
或 appcast；默认也不会修改 Keychain。命令会打印真实 .app、ZIP、appcast 和 HTTPS 地址，
但不会自动打开、替换或重启用户 App。

选项:
  --workspace <目录>             保留产物的工作目录（默认使用临时目录）
  --keep                         退出时保留自动创建的临时目录
  --keep-workspace               --keep 的别名
  --wait                         构建后保持 HTTPS server 运行，直到 Ctrl-C
  --plan-only                    只生成本地 CA/server 与 xcodebuild 注入计划，不构建 App
  --no-server                    计划/测试模式不绑定本机端口（真实验收不能使用）
  --install-ca                   明确请求将临时 CA 安装到默认 login Keychain
  --channel <stable|beta>        appcast 通道（默认 beta）
  --account <名称>               Sparkle Keychain account（默认 paperrss-issue11-local）
  --public-key-file <文件>       公开的 Sparkle raw base64 公钥；默认从 Keychain 查询
  --generate-key                 明确允许 generate_keys 在 Keychain 创建/复用该 account
  --current-version <版本>       N 显示版本（默认 1.3.0-beta.1）
  --next-version <版本>          N+1 显示版本（默认 1.3.0-beta.2）
  --current-build <build>        N build（默认 10）
  --next-build <build>           N+1 build（默认 11）
  --configuration <名称>         Xcode configuration（默认 Release）
  --code-sign-identity <名称>    本机测试签名（默认 Apple Development；可传 - 使用 ad hoc）
  --development-team <Team ID>  本机测试签名 Team（默认 LGKLTGNTY2）
  --generate-keys-bin <路径>     测试/自定义 generate_keys 路径
  --sign-update-bin <路径>       测试/自定义 sign_update 路径
  --xcodebuild-bin <路径>        测试/自定义 xcodebuild 路径
  --security-bin <路径>          测试/自定义 security 路径
  -h, --help                     显示帮助

真实验收步骤:
  1. 在当前终端保持此命令运行；若没有安装 CA，请按输出的唯一授权步骤执行 --install-ca。
  2. 启动输出的 N App，进入设置选择 Beta，点击“检查更新”。
  3. 在 Sparkle 标准 UI 中点击下载，观察后台下载完成后选择立即重启或退出时安装。
  4. 核对 N+1 版本及本地 feeds、已读、收藏、订阅和设置仍然存在。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WORKSPACE="${2:-}"; shift 2 ;;
    --keep|--keep-workspace) KEEP=true; shift ;;
    --wait) WAIT=true; shift ;;
    --plan-only) PLAN_ONLY=true; shift ;;
    --no-server) NO_SERVER=true; shift ;;
    --install-ca) INSTALL_CA=true; shift ;;
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --account) ACCOUNT="${2:-}"; shift 2 ;;
    --public-key-file) PUBLIC_KEY_FILE="${2:-}"; shift 2 ;;
    --generate-key) GENERATE_KEY=true; shift ;;
    --current-version) CURRENT_VERSION="${2:-}"; shift 2 ;;
    --next-version) NEXT_VERSION="${2:-}"; shift 2 ;;
    --current-build) CURRENT_BUILD="${2:-}"; shift 2 ;;
    --next-build) NEXT_BUILD="${2:-}"; shift 2 ;;
    --configuration) CONFIGURATION="${2:-}"; shift 2 ;;
    --code-sign-identity) CODE_SIGN_IDENTITY="${2:-}"; shift 2 ;;
    --development-team) DEVELOPMENT_TEAM="${2:-}"; shift 2 ;;
    --generate-keys-bin) GENERATE_KEYS_BIN="${2:-}"; shift 2 ;;
    --sign-update-bin) SPARKLE_SIGN_UPDATE="${2:-}"; shift 2 ;;
    --xcodebuild-bin) XCODEBUILD_BIN="${2:-}"; shift 2 ;;
    --security-bin) SECURITY_BIN="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误: 未知参数 $1" >&2; usage >&2; exit 2 ;;
  esac
done

fail() {
  echo "错误: $*" >&2
  exit 1
}

[[ "$CHANNEL" == stable || "$CHANNEL" == beta ]] || fail "channel 必须是 stable 或 beta。"
[[ "$CURRENT_BUILD" =~ ^[0-9]+$ && "$CURRENT_BUILD" -gt 0 ]] || fail "current build 必须是正整数。"
[[ "$NEXT_BUILD" =~ ^[0-9]+$ && "$NEXT_BUILD" -gt "$CURRENT_BUILD" ]] || fail "next build 必须大于 current build。"
[[ -n "$ACCOUNT" ]] || fail "Sparkle Keychain account 不能为空。"
[[ -n "$CODE_SIGN_IDENTITY" ]] || fail "code signing identity 不能为空。"
if [[ "$CODE_SIGN_IDENTITY" == - ]]; then
  CODE_SIGN_STYLE="Manual"
  DEVELOPMENT_TEAM=""
fi
command -v "$OPENSSL_BIN" >/dev/null 2>&1 || [[ -x "$OPENSSL_BIN" ]] || fail "找不到 openssl: $OPENSSL_BIN"
command -v "$NODE_BIN" >/dev/null 2>&1 || [[ -x "$NODE_BIN" ]] || fail "找不到 node: $NODE_BIN"

extract_public_key() {
  # Sparkle's generate_keys output contains explanatory text. The only value
  # accepted here is canonical raw Ed25519 public-key base64 (32 bytes).
  sed -nE 's/^[[:space:]]*([A-Za-z0-9+\/]{43}=)[[:space:]]*$/\1/p' | tail -n 1
}

PUBLIC_KEY=""
if [[ -n "$PUBLIC_KEY_FILE" ]]; then
  [[ -f "$PUBLIC_KEY_FILE" ]] || fail "公钥文件不存在: $PUBLIC_KEY_FILE"
  PUBLIC_KEY=$(extract_public_key < "$PUBLIC_KEY_FILE")
elif [[ "$GENERATE_KEY" == true ]]; then
  [[ -x "$GENERATE_KEYS_BIN" ]] || fail "找不到 generate_keys: $GENERATE_KEYS_BIN"
  # This is the only branch that may create a Sparkle key. It is explicit so
  # normal local preparation remains read-only with respect to Keychain.
  PUBLIC_KEY=$("$GENERATE_KEYS_BIN" --account "$ACCOUNT" 2>/dev/null | extract_public_key)
else
  [[ -x "$GENERATE_KEYS_BIN" ]] || fail "找不到 generate_keys；请先构建 Sparkle，或提供 --public-key-file。"
  PUBLIC_KEY=$("$GENERATE_KEYS_BIN" -p --account "$ACCOUNT" 2>/dev/null | extract_public_key) || true
fi
[[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail "无法从 Sparkle Keychain 取得有效公钥；默认不会创建 Keychain 项，请显式加 --generate-key。"

if [[ -z "$WORKSPACE" ]]; then
  WORKSPACE=$(mktemp -d "${TMPDIR:-/tmp}/paperrss-local-real-upgrade.XXXXXX")
  WORKSPACE_OWNED=true
else
  mkdir -p "$WORKSPACE"
  WORKSPACE=$(CDPATH= cd -- "$WORKSPACE" && pwd)
fi

TLS_DIR="$WORKSPACE/tls"
FEED_ROOT="$WORKSPACE/feed"
FEED_RELEASES="$FEED_ROOT/releases"
ARTIFACTS_DIR="$WORKSPACE/artifacts"
SERVER_READY="$WORKSPACE/server-ready.json"
SERVER_LOG="$WORKSPACE/server.log"
PUBLIC_KEY_PATH="$WORKSPACE/sparkle-public-key.txt"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ "$WORKSPACE_OWNED" == true && "$KEEP" != true ]]; then
    rm -rf "$WORKSPACE"
  fi
}
trap cleanup EXIT INT TERM

mkdir -p "$TLS_DIR" "$FEED_RELEASES" "$ARTIFACTS_DIR"
printf '%s\n' "$PUBLIC_KEY" > "$PUBLIC_KEY_PATH"

CA_KEY="$TLS_DIR/ca-key.pem"
CA_CERT="$TLS_DIR/ca.pem"
LEAF_KEY="$TLS_DIR/leaf-key.pem"
LEAF_CSR="$TLS_DIR/leaf.csr"
LEAF_CERT="$TLS_DIR/leaf.pem"
LEAF_EXT="$TLS_DIR/leaf.ext"

echo "正在生成仅存于临时工作目录的本地测试 CA 与 localhost leaf 证书。"
"$OPENSSL_BIN" req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
  -subj '/CN=PaperRss local update test CA' -keyout "$CA_KEY" -out "$CA_CERT" >/dev/null 2>&1
"$OPENSSL_BIN" req -new -newkey rsa:2048 -nodes -sha256 \
  -subj '/CN=localhost' -keyout "$LEAF_KEY" -out "$LEAF_CSR" >/dev/null 2>&1
printf '%s\n' 'subjectAltName=DNS:localhost,IP:127.0.0.1' > "$LEAF_EXT"
"$OPENSSL_BIN" x509 -req -in "$LEAF_CSR" -CA "$CA_CERT" -CAkey "$CA_KEY" \
  -CAcreateserial -out "$LEAF_CERT" -days 1 -sha256 -extfile "$LEAF_EXT" >/dev/null 2>&1
chmod 600 "$CA_KEY" "$LEAF_KEY"

if [[ "$INSTALL_CA" == true ]]; then
  [[ -x "$SECURITY_BIN" || "$SECURITY_BIN" == */* ]] || fail "找不到 security: $SECURITY_BIN"
  DEFAULT_KEYCHAIN=$("$SECURITY_BIN" default-keychain 2>/dev/null \
    | sed -E -e 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/' \
      -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' | tail -n 1)
  [[ -n "$DEFAULT_KEYCHAIN" ]] || fail "无法确定默认 login Keychain，拒绝安装临时 CA。"
  "$SECURITY_BIN" add-trusted-cert -d -r trustRoot -k "$DEFAULT_KEYCHAIN" "$CA_CERT" \
    || fail "安装临时 CA 失败；未继续构建。"
  echo "已按 --install-ca 明确请求将 CA 加入: $DEFAULT_KEYCHAIN"
else
  echo "默认未修改 Keychain。若要让 Sparkle 信任本地 HTTPS，请重新执行并加入 --install-ca。"
fi

start_server() {
  # A kept workspace may contain readiness data from a server that has already
  # exited. Remove only this harness-owned marker before starting a new server.
  rm -f "$SERVER_READY"
  "$NODE_BIN" "$SERVER_SCRIPT" --root "$FEED_ROOT" --tls-key "$LEAF_KEY" \
    --tls-cert "$LEAF_CERT" --ready-file "$SERVER_READY" > "$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 100); do
    if [[ -f "$SERVER_READY" ]]; then return; fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      sed -n '1,120p' "$SERVER_LOG" >&2 || true
      fail "本地 HTTPS server 启动失败。"
    fi
    sleep 0.1
  done
  fail "等待本地 HTTPS server 超时。"
}

read_ready_field() {
  "$NODE_BIN" -e 'const fs=require("node:fs"); const json=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); process.stdout.write(String(json[process.argv[2]]));' "$SERVER_READY" "$1"
}

if [[ "$NO_SERVER" == true ]]; then
  [[ "$PLAN_ONLY" == true ]] || fail "--no-server 只允许与 --plan-only 一起使用。"
  BASE_URL="https://127.0.0.1:0"
  STABLE_URL="$BASE_URL/stable.xml"
  BETA_URL="$BASE_URL/beta.xml"
else
  start_server
  BASE_URL=$(read_ready_field baseURL)
  STABLE_URL=$(read_ready_field stableURL)
  BETA_URL=$(read_ready_field betaURL)
fi

echo ""
echo "PaperRss 本地 Sparkle N/N+1 验收环境"
echo "工作目录: $WORKSPACE"
echo "本地 CA: $CA_CERT"
echo "localhost leaf: $LEAF_CERT"
echo "HTTPS feed: $BASE_URL"
echo "Stable appcast: $STABLE_URL"
echo "Beta appcast: $BETA_URL"
echo "N:   $CURRENT_VERSION (build $CURRENT_BUILD)"
echo "N+1: $NEXT_VERSION (build $NEXT_BUILD)"
echo "Sparkle account: ${ACCOUNT}（仅从 Keychain 读取私钥）"
echo "公钥: $PUBLIC_KEY_PATH"
echo ""
echo "xcodebuild 注入参数:"
echo "  临时 INFOPLIST_FILE=<workspace>/<N|N-plus-1>-Info.plist"
echo "  SUFeedURL=$STABLE_URL"
echo "  SUBetaFeedURL=$BETA_URL"
echo "  SUPublicEDKey=$PUBLIC_KEY"
echo "  PaperRssSourceCommit=$(git -C "$ROOT_DIR" rev-parse HEAD)"

if [[ "$PLAN_ONLY" == true ]]; then
  echo "计划模式完成：未构建 App、未调用 sign_update、未调用远程发布工具。"
  if [[ "$WAIT" == true ]]; then
    echo "按 Ctrl-C 结束本地 HTTPS server。"
    while true; do sleep 3600; done
  fi
  exit 0
fi

command -v "$XCODEBUILD_BIN" >/dev/null 2>&1 || [[ -x "$XCODEBUILD_BIN" ]] || fail "找不到 xcodebuild: $XCODEBUILD_BIN"
[[ -x "$SPARKLE_SIGN_UPDATE" ]] || fail "找不到 Sparkle sign_update: ${SPARKLE_SIGN_UPDATE}；请先构建 Sparkle。"
SOURCE_COMMIT=$(git -C "$ROOT_DIR" rev-parse HEAD)

build_archive() {
  local label="$1" version="$2" build="$3"
  local archive="$WORKSPACE/$label.xcarchive"
  local info_plist="$WORKSPACE/$label-Info.plist"
  local build_log="$WORKSPACE/$label-xcodebuild.log"
  cp "$ROOT_DIR/PaperRss/Resources/macOS-Info.plist" "$info_plist"
  /usr/bin/plutil -replace SUFeedURL -string "$STABLE_URL" "$info_plist"
  /usr/bin/plutil -replace SUBetaFeedURL -string "$BETA_URL" "$info_plist"
  /usr/bin/plutil -replace SUPublicEDKey -string "$PUBLIC_KEY" "$info_plist"
  /usr/bin/plutil -replace PaperRssSourceCommit -string "$SOURCE_COMMIT" "$info_plist"
  chmod 600 "$info_plist"
  echo "正在构建真实 $label App: $version (build $build)；完整日志: $build_log" >&2
  # A kept workspace may contain an archive from an earlier run. Remove only
  # this harness-owned archive so a failed rebuild cannot be mistaken for the
  # current N/N+1 evidence.
  rm -rf "$archive"
  if ! "$XCODEBUILD_BIN" \
    -project "$ROOT_DIR/PaperRss.xcodeproj" \
    -scheme PaperRss \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -archivePath "$archive" \
    -derivedDataPath "$WORKSPACE/derived-$label" \
    clean archive \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build" \
    INFOPLIST_FILE="$info_plist" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_STYLE="$CODE_SIGN_STYLE" \
    CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" >"$build_log" 2>&1; then
    echo "错误: 构建 $label App 失败。以下是 xcodebuild 日志末尾：" >&2
    tail -n 80 "$build_log" >&2 || true
    return 1
  fi
  local app="$archive/Products/Applications/PaperRss.app"
  [[ -d "$app" ]] || fail "$label archive 缺少 PaperRss.app。"
  for key in SUFeedURL SUBetaFeedURL SUPublicEDKey PaperRssSourceCommit; do
    /usr/bin/plutil -extract "$key" raw -o - "$app/Contents/Info.plist" >/dev/null \
      || fail "$label App 的 Info.plist 缺少 ${key}；拒绝继续。"
  done
  echo "已完成 $label App: $app" >&2
  printf '%s\n' "$app"
}

CURRENT_APP=$(build_archive N "$CURRENT_VERSION" "$CURRENT_BUILD" | tail -n 1)
NEXT_APP=$(build_archive N-plus-1 "$NEXT_VERSION" "$NEXT_BUILD" | tail -n 1)

build_local_artifacts() {
  local app="$1" version="$2" build="$3"
  "$BUILD_ARTIFACTS_SCRIPT" \
    --app "$app" \
    --output-dir "$ARTIFACTS_DIR" \
    --channel "$CHANNEL" \
    --version "$version" \
    --build "$build" \
    --download-url "$BASE_URL/releases/PaperRss-v${version}.zip" \
    --signing-account "$ACCOUNT" \
    --source-commit "$SOURCE_COMMIT"
}

build_local_artifacts "$CURRENT_APP" "$CURRENT_VERSION" "$CURRENT_BUILD"
build_local_artifacts "$NEXT_APP" "$NEXT_VERSION" "$NEXT_BUILD"

CURRENT_RELEASE="$ARTIFACTS_DIR/PaperRss-v$CURRENT_VERSION"
NEXT_RELEASE="$ARTIFACTS_DIR/PaperRss-v$NEXT_VERSION"
cp "$CURRENT_RELEASE/PaperRss-v$CURRENT_VERSION.zip" "$FEED_RELEASES/"
cp "$NEXT_RELEASE/PaperRss-v$NEXT_VERSION.zip" "$FEED_RELEASES/"

"$NODE_BIN" "$APPCAST_SCRIPT" generate \
  --channel "$CHANNEL" \
  --manifest "$CURRENT_RELEASE/manifest.json" \
  --manifest "$NEXT_RELEASE/manifest.json" \
  --output "$FEED_ROOT/$CHANNEL.xml" \
  --asset-root "$FEED_RELEASES" \
  --public-key "$PUBLIC_KEY_PATH"
"$NODE_BIN" "$APPCAST_SCRIPT" validate \
  --channel "$CHANNEL" \
  --appcast "$FEED_ROOT/$CHANNEL.xml" \
  --asset-root "$FEED_RELEASES" \
  --public-key "$PUBLIC_KEY_PATH"

# Keep the non-selected feed valid but empty. This prevents an automatic check
# on the default Stable channel from turning a Beta-only local run into a feed
# error before the tester switches channels in Settings.
if [[ "$CHANNEL" == beta ]]; then
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>PaperRss Stable (local empty)</title></channel></rss>' > "$FEED_ROOT/stable.xml"
else
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>PaperRss Beta (local empty)</title></channel></rss>' > "$FEED_ROOT/beta.xml"
fi

echo ""
echo "已准备真实本地 Sparkle 产物（未打开、未替换用户 App）："
echo "N App:   $CURRENT_APP"
echo "N+1 App: $NEXT_APP"
echo "N ZIP:   $CURRENT_RELEASE/PaperRss-v$CURRENT_VERSION.zip"
echo "N+1 ZIP: $NEXT_RELEASE/PaperRss-v$NEXT_VERSION.zip"
echo "Appcast: $FEED_ROOT/$CHANNEL.xml"
echo "HTTPS:   $BASE_URL"
echo ""
echo "人工验收："
echo "  1. 保持本命令运行；启动上面的 N App（Beta 通道请在设置中选择 Beta）。"
echo "  2. 点击“检查更新”，在 Sparkle 标准 UI 中下载 N+1。"
echo "  3. 观察下载完成后的立即重启/退出时安装，并核对本地数据。"
echo "  4. 当前 CA 只在本机临时目录；若未使用 --install-ca，需将 CA 导入信任后重试。"
echo ""
echo "本地 server PID: ${SERVER_PID}（结束时按 Ctrl-C；不会自动安装或重启）"

if [[ "$WAIT" == true ]]; then
  while true; do sleep 3600; done
fi
