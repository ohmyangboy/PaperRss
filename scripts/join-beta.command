#!/bin/bash
set -euo pipefail

APP_PATH="/Applications/PaperRss.app"

echo "======================================================"
echo "    PaperRss macOS 一键打开与隔离修复助手"
echo "    PaperRss macOS Open Helper"
echo "======================================================"
echo
echo "【用途说明 / Notice】"
echo "由于当前为个人开源构建版本（未加入 Apple 付费开发者公证），"
echo "macOS 首次打开可能会提示“已损坏”或“无法打开”。"
echo "本脚本仅用于自动移除 /Applications/PaperRss.app 的隔离标记 (quarantine)。"
echo
echo "------------------------------------------------------"

if [[ ! -d "$APP_PATH" ]]; then
  echo "❌ 未在 /Applications 中找到 PaperRss.app"
  echo "   PaperRss.app was not found in /Applications."
  echo
  echo "👉 请先将 PaperRss.app 拖入 Applications (应用程序) 文件夹，"
  echo "   然后再双击运行本脚本。"
  echo "   (Drag PaperRss.app into Applications first, then run this helper again.)"
  echo
  read -r -p "按回车键退出 / Press Return to exit..." _
  exit 1
fi

echo "✔ 已在 /Applications 中检测到 PaperRss.app"
echo
read -r -p "是否立即修复并移除隔离标记？Continue? [Y/n] " answer
answer="${answer:-Y}"
case "$answer" in
  [yY]|[yY][eE][sS]) ;;
  *)
    echo "已取消操作 / Cancelled."
    read -r -p "按回车键退出 / Press Return to exit..." _
    exit 0
    ;;
esac

echo
echo "🚀 正在清除隔离标记 (Removing quarantine flag)..."

if xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null; then
  echo "✔ 隔离标记移除成功！(Quarantine flag removed successfully!)"
else
  echo "⚠️ 正在尝试使用管理员权限执行..."
  if sudo xattr -dr com.apple.quarantine "$APP_PATH"; then
    echo "✔ 隔离标记移除成功！"
  else
    echo "❌ 自动修复失败。您可以尝试在终端手动执行："
    echo "   sudo xattr -dr com.apple.quarantine /Applications/PaperRss.app"
    echo
    read -r -p "按回车键退出 / Press Return to exit..." _
    exit 1
  fi
fi

echo
echo "🎉 修复完成！(Done!)"
echo "💡 现在可以直接在“应用程序”中打开 PaperRss 了。"
echo

read -r -p "是否立即启动 PaperRss？Launch PaperRss now? [Y/n] " launch_answer
launch_answer="${launch_answer:-Y}"
case "$launch_answer" in
  [yY]|[yY][eE][sS])
    open "$APP_PATH"
    ;;
  *) ;;
esac

echo
echo "祝您使用愉快！"
read -r -p "按回车键关闭此窗口 / Press Return to close this window..." _
