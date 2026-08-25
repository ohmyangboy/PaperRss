#!/bin/bash
set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

# 仅使用本地临时 HTTPS、临时 Ed25519 密钥和 fixture App；不会触碰 Release、appcast
# 线上地址或仓库中的真实签名材料。
exec node --test "$ROOT_DIR/Tests/sparkle-upgrade-recovery.test.mjs"
