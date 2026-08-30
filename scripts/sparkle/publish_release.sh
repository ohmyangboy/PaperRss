#!/bin/bash
set -euo pipefail

# 正式 Sparkle Release 的唯一编排入口。默认只运行本地 dry-run；远程模式
# 需要双重确认，并把固定 appcast 发布交给仓库内受审计实现。
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DRY_RUN="$ROOT_DIR/scripts/sparkle/publish_release_dry_run.sh"
APPCAST_TOOL="$ROOT_DIR/scripts/sparkle/publish_appcast_github.mjs"

EXECUTE=false
RESUME_APPCAST=false
REPO=""
TAG=""
CHANNEL=""
MANIFEST=""
OUTPUT_DIR=""
PUBLIC_KEY=""
TARGET_COMMIT=""
APPCAST_REPO=""
APPCAST_BRANCH=""
APPCAST_REMOTE_PATH=""
NOTES_FILE=""
TITLE=""

usage() {
  cat >&2 <<'EOF'
用法:
  publish_release.sh [--dry-run] --channel <stable|beta> --tag <vX.Y.Z>
    --manifest <manifest.json> --output-dir <目录> [--public-key <文件>]

未来正式发布（必须得到单独授权）额外需要：
  --execute --repo <owner/repository> --target-commit <40位 SHA>
  --appcast-repo <owner/repository> --appcast-branch <branch>
  --appcast-path <website/appcast/stable.xml|website/appcast/beta.xml>
  PAPERRSS_RELEASE_AUTHORIZED=YES
  PAPERRSS_RELEASE_CONFIRM="PUBLISH <tag>"

Release 已公开但 appcast 失败时，保留上述参数并增加 --resume-appcast。
恢复模式只核对既有 tag/Release/远程 ZIP+DMG，然后重试固定 appcast。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute) EXECUTE=true; shift ;;
    --resume-appcast) RESUME_APPCAST=true; shift ;;
    --dry-run) shift ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --public-key) PUBLIC_KEY="${2:-}"; shift 2 ;;
    --target-commit) TARGET_COMMIT="${2:-}"; shift 2 ;;
    --appcast-repo) APPCAST_REPO="${2:-}"; shift 2 ;;
    --appcast-branch) APPCAST_BRANCH="${2:-}"; shift 2 ;;
    --appcast-path) APPCAST_REMOTE_PATH="${2:-}"; shift 2 ;;
    --notes-file) NOTES_FILE="${2:-}"; shift 2 ;;
    --title) TITLE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误: 未知参数 $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$CHANNEL" || -z "$TAG" || -z "$MANIFEST" || -z "$OUTPUT_DIR" ]]; then
  usage
  exit 2
fi

if [[ "$EXECUTE" != true ]]; then
  if [[ "$RESUME_APPCAST" == true ]]; then
    echo "错误: --resume-appcast 只能与经过授权的 --execute 一起使用。" >&2
    exit 2
  fi
  DRY_ARGS=(--channel "$CHANNEL" --tag "$TAG" --manifest "$MANIFEST" --output-dir "$OUTPUT_DIR")
  [[ -n "$PUBLIC_KEY" ]] && DRY_ARGS+=(--public-key "$PUBLIC_KEY")
  exec "$DRY_RUN" "${DRY_ARGS[@]}"
fi

if [[ "${PAPERRSS_RELEASE_AUTHORIZED:-}" != "YES" ||
      "${PAPERRSS_RELEASE_CONFIRM:-}" != "PUBLISH $TAG" ]]; then
  echo "错误: 正式发布需要完整授权门禁；默认拒绝远程变更。" >&2
  exit 2
fi
if [[ -z "$REPO" || -z "$PUBLIC_KEY" || -z "$TARGET_COMMIT" ||
      -z "$APPCAST_REPO" || -z "$APPCAST_BRANCH" || -z "$APPCAST_REMOTE_PATH" ]]; then
  echo "错误: 正式发布缺少 repo、公钥、target commit 或固定 appcast 目标。" >&2
  exit 2
fi
if [[ ! "$TARGET_COMMIT" =~ ^[a-f0-9]{40}$ ]]; then
  echo "错误: --target-commit 必须是 40 位小写 commit SHA。" >&2
  exit 2
fi
if [[ ! -f "$MANIFEST" || ! -f "$PUBLIC_KEY" ]]; then
  echo "错误: manifest 或 Ed25519 公钥文件不存在。" >&2
  exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "错误: 正式发布需要 GitHub CLI gh；未执行任何远程操作。" >&2
  exit 1
fi
if [[ ! "$TAG" =~ ^v[0-9]+(\.[0-9]+){1,3}(-(alpha|beta|rc)\.[0-9]+)?$ ]]; then
  echo "错误: 非法 release tag: $TAG" >&2
  exit 2
fi

MANIFEST_DIR=$(CDPATH= cd -- "$(dirname -- "$MANIFEST")" && pwd)
ZIP_NAME=$(node -e 'const m=require(process.argv[1]); process.stdout.write(m.filename)' "$MANIFEST")
DMG_NAME=$(node -e 'const m=require(process.argv[1]); process.stdout.write(m.dmgFilename)' "$MANIFEST")
DISPLAY_VERSION=$(node -e 'const m=require(process.argv[1]); process.stdout.write(String(m.displayVersion))' "$MANIFEST")
SOURCE_COMMIT=$(node -e 'const m=require(process.argv[1]); process.stdout.write(String(m.sourceCommit || ""))' "$MANIFEST")
ZIP_PATH="$MANIFEST_DIR/$ZIP_NAME"
DMG_PATH="$MANIFEST_DIR/$DMG_NAME"
APPCAST_PATH="$OUTPUT_DIR/$CHANNEL.xml"

if [[ "$TAG" != "v$DISPLAY_VERSION" ]]; then
  echo "错误: tag 与 manifest displayVersion 不一致。" >&2
  exit 1
fi
if [[ "$SOURCE_COMMIT" != "$TARGET_COMMIT" ]]; then
  echo "错误: manifest sourceCommit 与 --target-commit 不一致。" >&2
  exit 1
fi
if ! git cat-file -e "$TARGET_COMMIT^{commit}" 2>/dev/null ||
   [[ "$(git rev-parse "$TARGET_COMMIT^{commit}")" != "$TARGET_COMMIT" ]]; then
  echo "错误: 本地仓库不存在指定 target commit。" >&2
  exit 1
fi
REMOTE_COMMIT=$(gh api "repos/$REPO/commits/$TARGET_COMMIT" --jq .sha) || {
  echo "错误: 无法确认远程 target commit。" >&2
  exit 1
}
if [[ "$REMOTE_COMMIT" != "$TARGET_COMMIT" ]]; then
  echo "错误: 远程 commit 与 --target-commit 不一致。" >&2
  exit 1
fi
if [[ ! -f "$ZIP_PATH" || ! -f "$DMG_PATH" ]]; then
  echo "错误: ZIP/DMG 资产不完整。" >&2
  exit 1
fi

EXPECTED_WORK=$(mktemp -d "${TMPDIR:-/tmp}/paperrss-expected-appcast.XXXXXX")
trap 'rm -rf "$EXPECTED_WORK"' EXIT
"$DRY_RUN" --channel "$CHANNEL" --tag "$TAG" --manifest "$MANIFEST" \
  --output-dir "$EXPECTED_WORK/generated" --public-key "$PUBLIC_KEY"
EXPECTED_APPCAST="$EXPECTED_WORK/generated/$CHANNEL.xml"
if [[ -e "$APPCAST_PATH" ]]; then
  if ! cmp -s "$EXPECTED_APPCAST" "$APPCAST_PATH"; then
    echo "错误: 既有 appcast 不是由当前 manifest 生成，拒绝发布旧版或不匹配 feed。" >&2
    exit 1
  fi
else
  mkdir -p "$OUTPUT_DIR"
  mv "$EXPECTED_APPCAST" "$APPCAST_PATH"
fi
rm -rf "$EXPECTED_WORK"
trap - EXIT

remote_absent() {
  local description="$1"; shift
  local response
  if response=$(gh "$@" 2>&1); then
    echo "错误: $description 已存在，发布资产不可变: $response" >&2
    exit 1
  fi
  if [[ ! "$response" =~ [Nn]ot[[:space:]-]?[Ff]ound|404 ]]; then
    echo "错误: 无法证明 $description 不存在；拒绝继续: $response" >&2
    exit 1
  fi
}

verify_published_release() {
  local remote_tag release_json remote_dir
  remote_tag=$(gh api "repos/$REPO/git/ref/tags/$TAG" --jq .object.sha) || {
    echo "错误: 恢复发布时无法读取远程 tag。" >&2; exit 1;
  }
  [[ "$remote_tag" == "$TARGET_COMMIT" ]] || {
    echo "错误: 远程 tag 未指向 target commit。" >&2; exit 1;
  }
  release_json=$(gh release view "$TAG" --repo "$REPO" --json isDraft,tagName,targetCommitish,assets) || {
    echo "错误: 恢复发布时找不到 Release。" >&2; exit 1;
  }
  node -e '
    const release = JSON.parse(process.argv[1]);
    const [tag, commit, zip, dmg] = process.argv.slice(2);
    const names = new Set((release.assets || []).map((asset) => asset.name));
    if (release.isDraft !== false || release.tagName !== tag || release.targetCommitish !== commit ||
        !names.has(zip) || !names.has(dmg)) process.exit(1);
  ' "$release_json" "$TAG" "$TARGET_COMMIT" "$ZIP_NAME" "$DMG_NAME" || {
    echo "错误: Release 仍为 draft、commit 不符或缺少 ZIP/DMG。" >&2; exit 1;
  }
  remote_dir=$(mktemp -d "${TMPDIR:-/tmp}/paperrss-release-readback.XXXXXX")
  trap 'rm -rf "$remote_dir"' RETURN
  gh release download "$TAG" --repo "$REPO" --pattern "$ZIP_NAME" --pattern "$DMG_NAME" --dir "$remote_dir"
  node -e '
    const { createHash } = require("node:crypto");
    const { readFileSync } = require("node:fs");
    const { join } = require("node:path");
    const manifest = JSON.parse(readFileSync(process.argv[1], "utf8"));
    const root = process.argv[2];
    for (const [nameKey, lengthKey, hashKey] of [
      ["filename", "byteLength", "sha256"], ["dmgFilename", "dmgByteLength", "dmgSha256"],
    ]) {
      const bytes = readFileSync(join(root, manifest[nameKey]));
      if (bytes.length !== manifest[lengthKey] || createHash("sha256").update(bytes).digest("hex") !== manifest[hashKey]) process.exit(1);
    }
  ' "$MANIFEST" "$remote_dir" || {
    echo "错误: 远程 ZIP/DMG 与 manifest 不一致。" >&2; exit 1;
  }
  rm -rf "$remote_dir"
  trap - RETURN
}

if [[ "$RESUME_APPCAST" == true ]]; then
  verify_published_release
else
  if [[ -n "$(git tag --list "$TAG")" ]]; then
    echo "错误: 本地 tag $TAG 已存在；拒绝创建不可变发布。" >&2
    exit 1
  fi
  remote_absent "远程 tag $TAG" api "repos/$REPO/git/ref/tags/$TAG"
  remote_absent "远程 release $TAG" release view "$TAG" --repo "$REPO" --json id

  RELEASE_TITLE="${TITLE:-PaperRss $TAG}"
  CREATE_ARGS=(release create "$TAG" --repo "$REPO" --draft --target "$TARGET_COMMIT" --title "$RELEASE_TITLE")
  # 在公开前标记 beta，避免进入 latest 或触发稳定版镜像同步。
  if [[ "$CHANNEL" == "beta" ]]; then
    CREATE_ARGS+=(--prerelease --latest=false)
  fi
  if [[ -n "$NOTES_FILE" ]]; then
    [[ -f "$NOTES_FILE" ]] || { echo "错误: notes 文件不存在: $NOTES_FILE" >&2; exit 1; }
    CREATE_ARGS+=(--notes-file "$NOTES_FILE")
  else
    CREATE_ARGS+=(--notes "PaperRss $TAG")
  fi
  gh "${CREATE_ARGS[@]}"
  gh release upload "$TAG" "$ZIP_PATH" "$DMG_PATH" --repo "$REPO"
  EDIT_ARGS=(release edit "$TAG" --repo "$REPO" --draft=false)
  [[ "$CHANNEL" == "beta" ]] && EDIT_ARGS+=(--latest=false)
  gh "${EDIT_ARGS[@]}"
fi

APPCAST_TARGET="$APPCAST_REPO:$APPCAST_BRANCH:$APPCAST_REMOTE_PATH"
PAPERRSS_APPCAST_AUTHORIZED=YES \
PAPERRSS_APPCAST_CONFIRM="PUBLISH $APPCAST_TARGET" \
  node "$APPCAST_TOOL" --execute --repo "$APPCAST_REPO" --branch "$APPCAST_BRANCH" \
    --path "$APPCAST_REMOTE_PATH" --channel "$CHANNEL" --appcast "$APPCAST_PATH" \
    --asset-root "$MANIFEST_DIR" --public-key "$PUBLIC_KEY"

if [[ "$RESUME_APPCAST" == true ]]; then
  echo "appcast 恢复完成；未修改既有 Release 资产。"
else
  echo "正式发布顺序完成：target commit -> draft -> upload-all -> publish -> appcast readback。"
fi
