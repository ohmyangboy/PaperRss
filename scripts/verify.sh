#!/bin/bash
# ==============================================================================
# PaperRss 自动化全链路与分级验证脚本 (Automated Verification Matrix)
#
# 用法:
#   ./scripts/verify.sh               # 运行全量自动化验证 (--all: Swift + Web + xcodebuild + git diff)
#   ./scripts/verify.sh --all         # 运行全量自动化验证 (同上，无冗余执行)
#   ./scripts/verify.sh --feature     # 仅执行 App 核心功能回归测试 (AppFeatureRegressionTests)
#   ./scripts/verify.sh --web         # 仅执行 Web Reader / JS Bridge / 快捷键策略测试
#   ./scripts/verify.sh --core        # 仅执行 Swift Core 数据与性能全量回归测试
#   ./scripts/verify.sh --filter <名> # 运行指定测试类或测试方法
#
# 注意: 本脚本负责自动化代码/数据/构建校验，真实 macOS 进程与 UI 交互验证请使用 ./scripts/dev.sh
# ==============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

# 开发者目录与 Xcode 工具链检测 (优先尊重已有 DEVELOPER_DIR，否则使用系统当前选择的 xcode-select)
if [ -z "${DEVELOPER_DIR:-}" ]; then
    export DEVELOPER_DIR="$(xcode-select -p)"
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BLUE}${BOLD}🔍 [PaperRss] 启动自动化验证流程...${NC}"
echo -e "   工具链环境: ${DEVELOPER_DIR}"

MODE="${1:-all}"
FILTER_ARG=""

if [ "$MODE" = "--filter" ]; then
    if [ -z "${2:-}" ]; then
        echo -e "${RED}错误: --filter 参数缺少测试名称${NC}" >&2
        echo -e "用法: ./scripts/verify.sh --filter <TestClassName/testMethodName>" >&2
        exit 1
    fi
    FILTER_ARG="$2"
fi

run_feature_tests() {
    echo -e "\n${BLUE}▶ 执行 App 核心功能回归测试 (AppFeatureRegressionTests)...${NC}"
    swift test --filter AppFeatureRegressionTests
    echo -e "${GREEN}✔ App 核心功能回归测试通过！${NC}"
}

run_web_tests() {
    echo -e "\n${BLUE}▶ 执行 Web Reader / JS Bridge / 快捷键测试...${NC}"
    node --test Tests/*.test.mjs
    echo -e "${GREEN}✔ Web / Bridge 测试全部通过！${NC}"
}

run_core_tests() {
    echo -e "\n${BLUE}▶ 执行 Swift 全量单元与集成测试 (Core/Data/FreshRSS/Performance)...${NC}"
    swift test
    echo -e "${GREEN}✔ Swift 全量回归测试全部通过！${NC}"
}

run_build_test() {
    echo -e "\n${BLUE}▶ 执行 macOS 宿主 Clean Build (xcodebuild)...${NC}"
    xcodebuild -scheme PaperRss -destination "platform=macOS" clean build
    echo -e "${GREEN}✔ macOS 宿主编译构建成功！${NC}"
}

run_git_diff_check() {
    echo -e "\n${BLUE}▶ 执行代码规范与空白字符核查 (git diff --check)...${NC}"
    git diff --check -- . ':!weekly.md'
    echo -e "${GREEN}✔ 代码格式规范无违规！${NC}"
}

print_git_status() {
    echo -e "\n${BLUE}▶ 当前代码工作区状态 (git status --short):${NC}"
    git status --short || true
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
    --filter)
        echo -e "\n${BLUE}▶ 执行自定义过滤回归测试: ${FILTER_ARG}...${NC}"
        swift test --filter "$FILTER_ARG"
        echo -e "${GREEN}✔ 自定义测试 ${FILTER_ARG} 执行完成！${NC}"
        ;;
    all|--all)
        echo -e "\n${BLUE}▶ [1/4] 执行 Swift 全量测试套件 (包含 Core / Features / Regression)...${NC}"
        run_core_tests
        echo -e "\n${BLUE}▶ [2/4] 执行 Web / JS Bridge / 治理测试...${NC}"
        run_web_tests
        echo -e "\n${BLUE}▶ [3/4] 执行 macOS 宿主构建...${NC}"
        run_build_test
        echo -e "\n${BLUE}▶ [4/4] 检查代码规范与格式...${NC}"
        run_git_diff_check
        print_git_status
        ;;
    *)
        echo -e "${RED}错误: 未知验证模式 '${MODE}'${NC}" >&2
        echo -e "用法:" >&2
        echo -e "  ./scripts/verify.sh               # 全量自动化验证 (--all)" >&2
        echo -e "  ./scripts/verify.sh --all         # 全量自动化验证" >&2
        echo -e "  ./scripts/verify.sh --feature     # 仅回归 App 核心功能 (AppFeatureRegressionTests)" >&2
        echo -e "  ./scripts/verify.sh --web         # 仅回归 Web / JS Bridge" >&2
        echo -e "  ./scripts/verify.sh --core        # 仅回归 Swift Core 测试" >&2
        echo -e "  ./scripts/verify.sh --filter <名> # 运行指定测试类/方法" >&2
        exit 1
        ;;
esac

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo -e "\n${GREEN}${BOLD}==============================================${NC}"
echo -e "${GREEN}${BOLD}🎉 自动化验证已全部通过！(总耗时: ${DURATION}s)${NC}"
echo -e "${GREEN}${BOLD}==============================================${NC}"
