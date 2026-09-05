#!/bin/bash
# release.sh — PaperRss App Store 外发布流水线（唯一编排入口）
#
# 子命令:
#   build   --version <X.Y.Z[-beta.N]> --build <N> [--channel stable|beta]
#           [--skip-notarization] [--allow-dirty] [--no-tests] [--force]
#   verify  --manifest <release-manifest.json>
#   publish --manifest <release-manifest.json> …（默认 dry-run；--execute 见门禁）
#
# 门禁输出 [PASS]/[FAIL]，任一签名、公证、Staple、Gatekeeper 校验失败立即终止。
# 配置经环境变量或 scripts/sparkle/release.env（不入库）；脚本不回显任何变量值。
set -Eeuo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SPARKLE="$ROOT_DIR/scripts/sparkle"
cd "$ROOT_DIR"

pass()  { echo "[PASS] $*"; }
fail()  { echo "[FAIL] $*" >&2; exit 1; }
warn()  { echo "[WARN] $*"; }
step()  { echo ""; echo "━━━ $* ━━━"; }

usage() {
  sed -n '2,12p' "$0"
  exit "${1:-0}"
}

CMD="${1:-}"
[[ -n "$CMD" ]] || usage 1
shift
case "$CMD" in
  build|verify|publish) ;;
  *) fail "未知子命令: ${CMD}（可用: build / verify / publish）" ;;
esac

# ── 配置装载：环境变量优先，其次 release.env（gitignored）───────────────
if [[ -f "$SPARKLE/release.env" ]]; then
  # 只接受 KEY=VALUE 行；不 eval，杜绝注入。
  # 用 ${line%%=*}/${line#*=} 切分而非 IFS='=' read——后者会吞掉行尾的 '='，
  # 破坏 base64 值的规范 padding（EdDSA 公钥以 '=' 结尾）。
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    case "$line" in *=*) ;; *) continue ;; esac
    k="${line%%=*}"
    v="${line#*=}"
    case "$k" in
      PAPERRSS_TEAM_ID|PAPERRSS_NOTARY_PROFILE|PAPERRSS_SIGNING_ACCOUNT|\
      PAPERRSS_SUPUBLIC_ED_KEY|PAPERRSS_APPCAST_BASE_URL|PAPERRSS_PUBLISH_REPO|\
      PAPERRSS_APPCAST_REPO|PAPERRSS_APPCAST_BRANCH)
        if [[ -z "${!k:-}" ]]; then printf -v "$k" '%s' "$v"; fi ;;
    esac
  done < <(grep -v '^[[:space:]]*$' "$SPARKLE/release.env" || true)
fi

# 全局 Apple 凭据（仓库外持久层）：~/.appstoreconnect/notary.env
# 优先级：进程环境 > release.env > 全局文件；仅在变量为空时填充。
GLOBAL_NOTARY_ENV="$HOME/.appstoreconnect/notary.env"
if [[ -f "$GLOBAL_NOTARY_ENV" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    case "$line" in *=*) ;; *) continue ;; esac
    k="${line%%=*}"
    v="${line#*=}"
    case "$k" in
      PAPERRSS_TEAM_ID|PAPERRSS_NOTARY_KEY|PAPERRSS_NOTARY_KEY_ID|\
      PAPERRSS_NOTARY_ISSUER|PAPERRSS_SIGNING_ACCOUNT)
        if [[ -z "${!k:-}" ]]; then printf -v "$k" '%s' "$v"; fi ;;
    esac
  done < <(grep -v '^[[:space:]]*$' "$GLOBAL_NOTARY_ENV" || true)
fi
if [[ "${PAPERRSS_NOTARY_KEY:-}" == '~/'* ]]; then
  PAPERRSS_NOTARY_KEY="$HOME/${PAPERRSS_NOTARY_KEY#\~/}"
fi
export PAPERRSS_NOTARY_KEY PAPERRSS_NOTARY_KEY_ID PAPERRSS_NOTARY_ISSUER
PAPERRSS_APPCAST_BASE_URL="${PAPERRSS_APPCAST_BASE_URL:-https://ohmyangboy.github.io/PaperRss/appcast}"

# ══════════════════════════ build ══════════════════════════
if [[ "$CMD" == "build" ]]; then
  VERSION="" BUILD="" CHANNEL="stable" FORCE=false ALLOW_DIRTY=false NO_TESTS=false SKIP_NOTARIZATION=false
  OUTPUT_ROOT=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) VERSION="${2:-}"; shift 2 ;;
      --build) BUILD="${2:-}"; shift 2 ;;
      --channel) CHANNEL="${2:-}"; shift 2 ;;
      --force) FORCE=true; shift ;;
      --allow-dirty) ALLOW_DIRTY=true; shift ;;
      --no-tests) NO_TESTS=true; shift ;;
      --skip-notarization) SKIP_NOTARIZATION=true; shift ;;
      --output-root) OUTPUT_ROOT="${2:-}"; shift 2 ;;
      *) fail "build: 未知参数 $1" ;;
    esac
  done

  # [GATE 0] 环境预检
  step "[GATE 0] 环境预检"
  [[ -n "$VERSION" ]] || fail "缺少 --version"
  [[ -n "$BUILD" ]]  || fail "缺少 --build"
  [[ "$CHANNEL" == "stable" || "$CHANNEL" == "beta" ]] || fail "--channel 必须是 stable|beta"
  CLEAN_VERSION=${VERSION#v}
  [[ "$CLEAN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]] \
    || fail "版本号不符合 SemVer vX.Y.Z[-stage.N]: $VERSION"
  [[ "$BUILD" =~ ^[0-9]+$ ]] || fail "--build 必须是纯数字"
  if [[ "$CLEAN_VERSION" =~ -(alpha|beta|rc)\. ]] && [[ "$CHANNEL" == "stable" ]]; then
    fail "prerelease 版本（${CLEAN_VERSION}）必须使用 --channel beta；stable 通道不接受预发布版本"
  fi

  for tool in xcodebuild node git plutil ditto hdiutil codesign spctl; do
    command -v "$tool" >/dev/null 2>&1 || fail "缺少工具: $tool"
  done
  command -v create-dmg >/dev/null 2>&1 && HAVE_CREATE_DMG=true || HAVE_CREATE_DMG=false

  if [[ "$SKIP_NOTARIZATION" != true ]]; then
    for var in PAPERRSS_TEAM_ID PAPERRSS_SUPUBLIC_ED_KEY; do
      [[ -n "${!var:-}" ]] || fail "缺少 ${var}（检查环境或 scripts/sparkle/release.env）"
    done
    if [[ -n "${PAPERRSS_NOTARY_KEY:-}" && -n "${PAPERRSS_NOTARY_KEY_ID:-}" && -n "${PAPERRSS_NOTARY_ISSUER:-}" ]]; then
      NOTARY_SET=direct-key
    elif [[ -n "${PAPERRSS_NOTARY_PROFILE:-}" ]]; then
      NOTARY_SET=yes
    else
      fail "缺少公证凭据：PAPERRSS_NOTARY_PROFILE 或 PAPERRSS_NOTARY_KEY/KEY_ID/ISSUER 三元组（二选一）"
    fi
  else
    warn "公证已跳过：产物仅限本机演练，禁止对外分发"
    NOTARY_SET=skipped
    [[ -n "${PAPERRSS_TEAM_ID:-}" ]] || fail "Developer ID 导出仍需 PAPERRSS_TEAM_ID"
    [[ -n "${PAPERRSS_SUPUBLIC_ED_KEY:-}" ]] || fail "仍需 PAPERRSS_SUPUBLIC_ED_KEY（SUPublicEDKey 注入）"
  fi
  security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" \
    || fail "钥匙串中没有 Developer ID Application 证书"

  if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    if [[ "$ALLOW_DIRTY" == true ]]; then
      warn "工作树不干净（--allow-dirty）：provenance 将记录 HEAD 而非未提交内容"
      export PAPERRSS_ALLOW_DIRTY=1
    else
      fail "工作树不干净；请提交后构建，或显式使用 --allow-dirty"
    fi
  fi

  SOURCE_COMMIT=$(git rev-parse HEAD)
  TAG="v$CLEAN_VERSION"
  OUTPUT_ROOT="${OUTPUT_ROOT:-$ROOT_DIR/dist/release}"
  RELEASE_DIR="$OUTPUT_ROOT/$TAG"
  ARCHIVE_PATH="$RELEASE_DIR/PaperRss.xcarchive"
  EXPORT_DIR="$RELEASE_DIR/export"
  APP_PATH="$EXPORT_DIR/PaperRss.app"
  ZIP_PATH="$RELEASE_DIR/PaperRss-$TAG.zip"
  DMG_PATH="$RELEASE_DIR/PaperRss-$TAG.dmg"
  MANIFEST_PATH="$RELEASE_DIR/manifest.json"

  if [[ -e "$RELEASE_DIR" ]]; then
    if [[ "$FORCE" == true ]]; then
      warn "清理既有产物目录（--force）: $RELEASE_DIR"
      rm -rf "$RELEASE_DIR"
    else
      fail "产物目录已存在: ${RELEASE_DIR}（同内容重跑请用 verify；重打用 --force）"
    fi
  fi
  mkdir -p "$RELEASE_DIR"

  STABLE_FEED_URL="$PAPERRSS_APPCAST_BASE_URL/stable.xml"
  BETA_FEED_URL="$PAPERRSS_APPCAST_BASE_URL/beta.xml"

  pass "[PASS 0] 环境预检通过（notary-profile:${NOTARY_SET} create-dmg:$HAVE_CREATE_DMG commit:${SOURCE_COMMIT:0:12}）"

  # [PASS 1] 测试
  if [[ "$NO_TESTS" == true ]]; then
    warn "已跳过测试（--no-tests）——发布前必须完整跑过一轮 verify.sh --core"
  else
    step "[PASS 1] 单元与状态机测试（verify.sh --core）"
    ./scripts/verify.sh --core >"$RELEASE_DIR/verify-core.log" 2>&1 \
      || { tail -40 "$RELEASE_DIR/verify-core.log" >&2; fail "verify.sh --core 未通过"; }
    pass "[PASS 1] 测试全部通过（日志: $RELEASE_DIR/verify-core.log）"
  fi

  # [PASS 2] provenance 构建
  step "[PASS 2] Provenance 构建（注入 SUFeedURL/SUPublicEDKey/SourceCommit）"
  PROVENANCE_ARGS=(
    --archive-path "$ARCHIVE_PATH"
    --version "$CLEAN_VERSION" --build "$BUILD"
    --feed-url-stable "$STABLE_FEED_URL"
    --feed-url-beta "$BETA_FEED_URL"
    --public-ed-key "${PAPERRSS_SUPUBLIC_ED_KEY:-}"
    --source-commit "$SOURCE_COMMIT"
  )
  "$SPARKLE/build_with_provenance.sh" "${PROVENANCE_ARGS[@]}"

  # [PASS 3–6] 导出 + 签名 + 公证 + Staple
  step "[PASS 3–6] Developer ID 导出 / 签名 / 公证 / Staple 门禁"
  NOTARIZE_ARGS=(--archive "$ARCHIVE_PATH" --output-dir "$EXPORT_DIR" --team-id "${PAPERRSS_TEAM_ID}")
  if [[ "$SKIP_NOTARIZATION" != true ]]; then
    [[ -n "${PAPERRSS_NOTARY_PROFILE:-}" ]] && NOTARIZE_ARGS+=(--notary-profile "${PAPERRSS_NOTARY_PROFILE}")
  else
    NOTARIZE_ARGS+=(--skip-notarization)
  fi
  EXPORT_OUT=$("$SPARKLE/export_and_notarize.sh" "${NOTARIZE_ARGS[@]}")
  STAPLED_APP=$(printf '%s\n' "$EXPORT_OUT" | tail -n1)
  [[ -d "$STAPLED_APP" ]] || fail "未取得 stapled App"

  # [PASS 7] DMG + ZIP + EdDSA + manifest
  step "[PASS 7] 发布 DMG / Sparkle ZIP / EdDSA 签名 / manifest"
  DMG_ARGS=(--app "$STAPLED_APP" --output "$DMG_PATH" --version "$CLEAN_VERSION")
  if [[ "$SKIP_NOTARIZATION" == true ]]; then
    DMG_ARGS+=(--skip-notarization)
  else
    [[ -n "${PAPERRSS_NOTARY_PROFILE:-}" ]] && DMG_ARGS+=(--notary-profile "${PAPERRSS_NOTARY_PROFILE}")
  fi
  "$SPARKLE/make_release_dmg.sh" "${DMG_ARGS[@]}"

  ARTIFACT_ARGS=(
    --app "$STAPLED_APP"
    --channel "$CHANNEL"
    --version "$CLEAN_VERSION" --build "$BUILD"
    --source-commit "$SOURCE_COMMIT"
    --download-url "https://github.com/${PAPERRSS_PUBLISH_REPO:-ohmyangboy/PaperRss}/releases/download/$TAG/PaperRss-$TAG.zip"
    --premade-dmg "$DMG_PATH"
    --output-dir "$RELEASE_DIR"
  )
  [[ -n "${PAPERRSS_SIGNING_ACCOUNT:-}" ]] && ARTIFACT_ARGS+=(--signing-account "${PAPERRSS_SIGNING_ACCOUNT}")
  "$SPARKLE/build_artifacts.sh" "${ARTIFACT_ARGS[@]}"
  # 扁平化到发布目录（appcast 校验按 asset-root 平铺查找）
  SUBDIR="$RELEASE_DIR/PaperRss-v$CLEAN_VERSION"
  mv "$SUBDIR"/* "$RELEASE_DIR/" 2>/dev/null || true
  rmdir "$SUBDIR" 2>/dev/null || true
  MANIFEST_PATH="$RELEASE_DIR/manifest.json"
  [[ -f "$MANIFEST_PATH" ]] || fail "manifest.json 缺失"
  printf '%s\n' "${PAPERRSS_SUPUBLIC_ED_KEY:-}" > "$RELEASE_DIR/public-ed-key.txt"
  chmod 600 "$RELEASE_DIR/public-ed-key.txt"

  # [PASS 9] appcast 双通道生成与本地验证
  step "[PASS 9] Appcast 双通道生成 + 本地契约验证"
  PUBKEY_FILE="$RELEASE_DIR/public-ed-key.txt"
  for ch in stable beta; do
    node "$SPARKLE/appcast.mjs" generate \
      --channel "$ch" --manifest "$MANIFEST_PATH" \
      --output "$RELEASE_DIR/$ch.xml" --asset-root "$RELEASE_DIR" \
      --public-key "$PUBKEY_FILE" >/dev/null
    node "$SPARKLE/appcast.mjs" validate \
      --channel "$ch" --appcast "$RELEASE_DIR/$ch.xml" \
      --asset-root "$RELEASE_DIR" --public-key "$PUBKEY_FILE" >/dev/null
    pass "[PASS 9] appcast/$ch.xml 生成并验证通过"
  done

  # [DONE] 清单
  step "[DONE] 本地产物清单（dist/release/${TAG}）"
  du -h "$RELEASE_DIR"/* 2>/dev/null | sort -k2 || true
  echo ""
  echo "下一步:"
  echo "  ./scripts/release.sh verify --manifest $MANIFEST_PATH   # 复验"
  echo "  ./scripts/release.sh publish --manifest $MANIFEST_PATH --tag $TAG --channel $CHANNEL   # 默认 dry-run"
  exit 0
fi

# ══════════════════════════ verify ══════════════════════════
if [[ "$CMD" == "verify" ]]; then
  MANIFEST="" ARCHS="arm64"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --manifest) MANIFEST="${2:-}"; shift 2 ;;
      --require-architectures) ARCHS="${2:-}"; shift 2 ;;
      *) fail "verify: 未知参数 $1" ;;
    esac
  done
  [[ -f "$MANIFEST" ]] || fail "manifest 不存在: $MANIFEST"
  DIR=$(dirname "$MANIFEST")
  "$SPARKLE/validate_artifacts.sh" --manifest "$MANIFEST" --require-architectures "$ARCHS"
  PUBKEY_FILE=""
  if [[ -f "$DIR/public-ed-key.txt" ]]; then
    PUBKEY_FILE="$DIR/public-ed-key.txt"
  elif [[ -n "${PAPERRSS_SUPUBLIC_ED_KEY:-}" ]]; then
    PUBKEY_FILE=$(mktemp)
    printf '%s\n' "$PAPERRSS_SUPUBLIC_ED_KEY" > "$PUBKEY_FILE"
    trap 'rm -f "$PUBKEY_FILE"' EXIT
  fi
  if [[ -n "$PUBKEY_FILE" ]]; then
    for ch in stable beta; do
      [[ -f "$DIR/$ch.xml" ]] || continue
      node "$SPARKLE/appcast.mjs" validate --channel "$ch" \
        --appcast "$DIR/$ch.xml" --asset-root "$DIR" --public-key "$PUBKEY_FILE" >/dev/null \
        && pass "appcast/$ch.xml 验证通过"
    done
  fi
  pass "verify 完成: $MANIFEST"
  exit 0
fi

# ══════════════════════════ publish ══════════════════════════
if [[ "$CMD" == "publish" ]]; then
  exec "$SPARKLE/publish_release.sh" "$@"
fi
