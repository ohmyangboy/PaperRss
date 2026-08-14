<div align="center">

  <img src="assets/app-icon.png" alt="PaperRss 图标" width="120" height="120" />

  # PaperRss

  ***双语流转，克制智能化。让阅读回归纯粹与沉浸。***

  [English](README_EN.md) · **简体中文**

  [![Release](https://img.shields.io/github/v/release/ohmyangboy/PaperRss?style=flat-square&color=1d4ed8)](https://github.com/ohmyangboy/PaperRss/releases/latest)
  [![Platform](https://img.shields.io/badge/platform-macOS%2014.0%2B-f7f5ef?style=flat-square&logo=apple&logoColor=000000)](https://github.com/ohmyangboy/PaperRss)
  [![License](https://img.shields.io/badge/license-GPLv3-c92a2a?style=flat-square)](LICENSE)

  [官方网站](https://ohmyangboy.github.io/PaperRss/) · [下载最新版 v1.2.5](https://github.com/ohmyangboy/PaperRss/releases/latest) · [问题反馈](https://github.com/ohmyangboy/PaperRss/issues)

</div>

---

## 软件简介

PaperRss 是一款专为 macOS 打造的现代纸感 RSS 阅读器，并在真正有帮助的地方提供 AI 能力。

它把散落的订阅还原为安静、清晰的三栏阅读空间。你可以按需生成全文摘要，选中文字进行上下文翻译、解释或提问，并连接 DeepSeek、OpenAI 兼容服务或可信局域网中的自建模型。

## 核心亮点

- **沉浸式纸感阅读**：适合长文的衬线排版、明暗主题与稳定的三栏导航。
- **文章章节导航（TOC Rail）**：长文章右侧提供极简刻度轨道，支持波峰悬停预览、视线重心平滑滚动与拖拽映射。
- **按需 AI 摘要**：手动生成，或在首次打开没有缓存的文章时自动生成。
- **划词翻译、解释与提问**：结合文章上下文理解所选文字。
- **本地优先**：API Key 保存在本机，不参与 iCloud 同步。
- **自由模型接入**：支持 DeepSeek、OpenAI 兼容 API 与可信局域网 HTTP 服务。
- **独立语言设置**：应用界面可以跟随系统或切换中英文；AI 输出语言与界面语言互不绑定。

## 真实界面

### 三栏式纸感主界面

![PaperRss 三栏主界面](assets/screenshots/paper-rss-main.png)

### AI 全文摘要

![AI 摘要卡片](assets/screenshots/ai-summary-card.png)

### 划词解释与翻译

<p align="center">
  <img src="assets/screenshots/ai-explain-popover.png" width="48%" alt="划词 AI 解释" />
  <img src="assets/screenshots/ai-translate-popover.png" width="48%" alt="划词 AI 翻译" />
</p>

### AI 模型配置

![PaperRss AI 设置](assets/screenshots/settings-ai-config.png)

## 下载与安装

从 [Releases](https://github.com/ohmyangboy/PaperRss/releases/latest) 下载 `PaperRss-v1.2.5.dmg`，打开后将 PaperRss 拖入 Applications 文件夹。

当前 Release 没有 Apple 公证。若首次打开提示无法验证或应用已损坏，请在终端执行：

```bash
sudo xattr -rd com.apple.quarantine /Applications/PaperRss.app
```

## 从源码构建

要求：macOS 14.0+、Xcode 15.0+、Swift 5.9+。

```bash
git clone https://github.com/ohmyangboy/PaperRss.git
cd PaperRss
swift build -c release

# 或使用 Xcode
open PaperRss.xcodeproj
```

## 赞赏与反馈

如果 PaperRss 改善了你的日常阅读体验，欢迎使用微信扫码赞赏，支持独立开发与持续维护。

<div align="center">
  <img src="assets/wechat-sponsor-qr.jpg" alt="微信赞赏码" width="220" />
  <p><i>感谢每一位热爱独立软件与专注阅读的读者。</i></p>
</div>

问题、功能想法与代码改进请提交到 [GitHub Issues](https://github.com/ohmyangboy/PaperRss/issues)。

## 开源协议

PaperRss 基于 [GNU General Public License v3.0](LICENSE) 开源。
