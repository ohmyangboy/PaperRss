#!/bin/bash
# 回收可重建的构建缓存（默认只预览，--apply 才删除）。
set -euo pipefail

cd "$(dirname "$0")/.."

APPLY=false
KEEP_DAYS=7

usage() {
    cat <<'EOF'
用法：
  ./scripts/clean.sh                   预览可回收的构建缓存
  ./scripts/clean.sh --apply           执行回收（持有全部构建锁，不与脚本构建并行）
  ./scripts/clean.sh --keep-days 14    修改保留期，默认 7 天（0 表示不按时间过滤）

回收范围：脚本自有的 DerivedData 根（build/isolated、build/archive、build/upgrade、
build/FreshLaunchTest 等）、build/ 主 DerivedData 的编译缓存、.build SwiftPM 缓存。
锁文件、build/visual-verification 等素材、dist/ 发布产物与报告不在回收范围。
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)
            APPLY=true
            shift
            ;;
        --keep-days)
            [ $# -ge 2 ] || { echo "❌ --keep-days 缺少参数" >&2; exit 2; }
            KEEP_DAYS="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "❌ 未知参数：$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ "$APPLY" = true ] && [ "${PAPERRSS_CLEAN_LOCKED:-}" != "1" ]; then
    # 通过构建包装器持有 app + tests 两条泳道锁，确保没有脚本构建在写缓存。
    exec env PAPERRSS_CLEAN_LOCKED=1 python3 scripts/build-support.py --lane all -- "$0" --apply --keep-days "$KEEP_DAYS"
fi

if [ "$APPLY" = true ]; then
    exec python3 scripts/build-support.py --clean --apply --keep-days "$KEEP_DAYS"
fi
exec python3 scripts/build-support.py --clean --keep-days "$KEEP_DAYS"
