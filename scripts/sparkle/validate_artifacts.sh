#!/bin/bash
set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
MANIFEST_TOOL="$ROOT_DIR/scripts/sparkle/artifact_manifest.mjs"
MANIFEST=""
REQUIRED_ARCHITECTURES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --require-architectures) REQUIRED_ARCHITECTURES="${2:-}"; shift 2 ;;
    -h|--help)
      echo "用法: validate_artifacts.sh --manifest <manifest.json> [--require-architectures arm64,x86_64]"
      exit 0
      ;;
    *) echo "错误: 未知参数 $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$MANIFEST" ]]; then
  echo "错误: 必须提供 --manifest" >&2
  exit 2
fi
if [[ ! -f "$MANIFEST" ]]; then
  echo "错误: manifest 不存在: $MANIFEST" >&2
  exit 1
fi

ARGS=(validate --manifest "$MANIFEST")
if [[ -n "$REQUIRED_ARCHITECTURES" ]]; then
  ARGS+=(--require-architectures "$REQUIRED_ARCHITECTURES")
fi
exec node "$MANIFEST_TOOL" "${ARGS[@]}"
