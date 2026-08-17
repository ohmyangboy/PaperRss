#!/bin/bash
# ==============================================================================
# PaperRss 自动化全链路与功能回归验证脚本
#
# 用法:
#   ./scripts/verify.sh               # 运行全量回归验证 (Features + Web/Bridge + Core)
#   ./scripts/verify.sh --feature     # 仅回归 App 关键功能（Feed点击、文章更新、未读计数、分类等）
#   ./scripts/verify.sh --web         # 仅回归 Web Reader / JS Bridge / 快捷键策略
#   ./scripts/verify.sh --core        # 仅回归 Swift Core 底层数据与性能套件
#   ./scripts/verify.sh --filter <名> # 运行指定测试类或测试方法
# ==============================================================================
set -e

cd "$(dirname "$0")/.."

# 开发者目录与 Xcode 工具链检测
if [ -z "$DEVELOPER_DIR" ]; then
    if [ -d "/Applications/Xcode-beta.app/Contents/Developer" ]; then
        export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
    else
        export DEVELOPER_DIR="$(xcode-select -p)"
    fi
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BLUE}${BOLD}🔍 [PaperRss] 启动自动化回归验证流程...${NC}"
echo -e "   工具链环境: ${DEVELOPER_DIR}"

MODE="${1:-all}"
FILTER_ARG=""

if [ "$1" == "--filter" ] && [ -n "$2" ]; then
    MODE="filter"
    FILTER_ARG="$2"
fi

run_feature_tests() {
    echo -e "\n${BLUE}▶ [1/3] 执行 App 核心功能回归测试 (AppFeatureRegressionTests)...${NC}"
    echo -e "   包含: 文章标题/正文变更、Feed/Folder点击过滤、未读/星标计数流转、离线缓存、分页"
    swift test --filter AppFeatureRegressionTests
    echo -e "${GREEN}✔ App 核心功能回归测试全部通过！${NC}"
}

run_web_tests() {
    echo -e "\n${BLUE}▶ [2/3] 执行 Web Reader / JS Bridge / 快捷键回归测试...${NC}"
    echo -e "   包含: Reader 快捷键策略、TOC 目录提取、划词翻译与多语言"
    node --test Tests/*.test.mjs
    echo -e "${GREEN}✔ Web / Bridge 回归测试全部通过！${NC}"
}

run_core_tests() {
    echo -e "\n${BLUE}▶ [3/3] 执行 Swift Core 数据与性能全量回归测试...${NC}"
    echo -e "   包含: SQLite 数据库迁移、LocalProvider、FreshRSS 同步、分页性能"
    swift test
    echo -e "${GREEN}✔ Swift Core 全量回归测试全部通过！${NC}"
}

START_TIME=$(date +%s)

case "$MODE" in
    --feature)
        run_feature_tests
        ;;
    --web)
        run_web_tests
        ;;
    --core)
        run_core_tests
        ;;
    filter)
        echo -e "\n${BLUE}▶ 执行自定义过滤回归测试: ${FILTER_ARG}...${NC}"
        swift test --filter "$FILTER_ARG"
        echo -e "${GREEN}✔ 自定义测试 ${FILTER_ARG} 执行完成！${NC}"
        ;;
    all|*)
        run_feature_tests
        run_web_tests
        run_core_tests
        ;;
esac

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo -e "\n${GREEN}${BOLD}==============================================${NC}"
echo -e "${GREEN}${BOLD}🎉 自动化回归验证已全部通过！(总耗时: ${DURATION}s)${NC}"
echo -e "${GREEN}${BOLD}==============================================${NC}"
