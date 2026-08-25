#!/bin/bash
set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

# Ticket05 的默认入口始终是 fixture/local dry-run；脚本不会调用 gh、git
# push、远程 appcast 写入或任何 --clobber 路径。
exec node "$ROOT_DIR/scripts/sparkle/publish_release_dry_run.mjs" --dry-run "$@"
