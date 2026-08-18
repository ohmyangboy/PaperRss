<div align="center">

  <img src="assets/app-icon.png" alt="PaperRss 图标" width="120" height="120" />

  # PaperRss

  ***双语流转，克制智能化。让阅读回归纯粹与沉浸。***

  [English](README_EN.md) · **简体中文**

  [![Release](https://img.shields.io/github/v/release/ohmyangboy/PaperRss?include_prereleases&style=flat-square&color=1d4ed8)](https://github.com/ohmyangboy/PaperRss/releases)
  [![Platform](https://img.shields.io/badge/platform-macOS%2014.0%2B-f7f5ef?style=flat-square&logo=apple&logoColor=000000)](https://github.com/ohmyangboy/PaperRss)
  [![License](https://img.shields.io/badge/license-GPLv3-c92a2a?style=flat-square)](LICENSE)

  [官方网站](https://ohmyangboy.github.io/PaperRss/) · [下载最新版 v1.3.0-beta.1](https://github.com/ohmyangboy/PaperRss/releases/latest) · [问题反馈](https://github.com/ohmyangboy/PaperRss/issues)

</div>

---

## 软件简介

**PaperRss** 是一款现代纸感 RSS 阅读器(macos)，拥有简约舒缓的沉浸式界面、双语翻译可配置的AI功能，一切把控在阅读者手里。

没有sticky的聊天机器人或者LUI，PaperRss主张主动阅读，并提供克制的AI功能，让一切润物细无声。

**Reading First, AI Second**

_本项目灵感启发自另一款优秀的开源RSS预读器 [NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire/)_

## 核心亮点

- **沉浸式纸感阅读**：适合长文的衬线排版、明暗主题与稳定的三栏导航。
- **按需 AI 摘要**：所有功能完全可以选用，如果你不喜欢AI，干掉它；或者在需要的时候按下V键
- **划词翻译、解释与提问**：结合文章上下文理解所选文字。
- **自由模型接入**：支持自定义配置DeepSeek、OpenAI 兼容 API KEY，提供设置个性化prompt
- **多账户接入**：目前支持本地账户、FreshRSS 服务

## 真实界面

### 沉浸式纸感阅读

![PaperRss 三栏主界面](assets/screenshots/paper-rss-main.png)

![PaperRss 全屏沉浸阅读](assets/screenshots/full-screen.png)

### AI 全文摘要

![AI 摘要卡片](assets/screenshots/ai-summary-card.png)

### 划词解释与翻译

<p align="center">
  <img src="assets/screenshots/ai-explain-popover.png" width="48%" alt="划词 AI 解释" />
  <img src="assets/screenshots/ai-translate-popover.png" width="48%" alt="划词 AI 翻译" />
</p>

### AI 模型配置

![PaperRss AI 设置](assets/screenshots/settings-ai-config.png)

### 多账号接入

![PaperRss 多账号设置](assets/screenshots/accounts.png)

## 下载与安装

从 [Releases](https://github.com/ohmyangboy/PaperRss/releases/latest) 下载 `PaperRss-v1.3.0-beta.1.dmg`，打开后将 PaperRss 拖入 Applications 文件夹。

当前 Release 没有 Apple 公证。若首次打开提示无法验证或应用已损坏，请在终端执行：

```bash
sudo xattr -rd com.apple.quarantine /Applications/PaperRss.app
```

或者在点击完成后，到 系统 > 隐私与设置 > 仍要打开，在视图最下方点击后即可

_由于PaperRss还在构建完善中，期待并感谢获得更多朋友的关注和反馈，后续会考虑处理Apple安装问题_

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

如果 PaperRss 改善了你的日常阅读体验，欢迎使用微信扫码赞，支持独立开发与持续维护。

或者点个免费的 **star**，这能让作者开心一整天 ;D

<div align="center">
  <img src="assets/wechat-sponsor-qr.jpg" alt="微信赞赏码" width="220" />
  <p><i>感谢每一位热爱独立软件与专注阅读的读者。</i></p>
</div>

问题、功能想法与代码改进请提交到 [GitHub Issues](https://github.com/ohmyangboy/PaperRss/issues)。或者在[社交媒体](https://xhslink.cn/m/972wHfC16uj)留言～

交流信息也可以随时 email: ohmyangboy@gmail

## 开源协议

PaperRss 基于 [GNU General Public License v3.0](LICENSE) 开源。