<div align="center">

  <img src="assets/app-icon.png" alt="PaperRss 图标" width="120" height="120" />

  # PaperRss

  ***双语流转，克制智能化。让阅读回归纯粹与沉浸。***

  [English](README_EN.md) · **简体中文**

  [![Release](https://img.shields.io/github/v/release/ohmyangboy/PaperRss?include_prereleases&style=flat-square&color=1d4ed8)](https://github.com/ohmyangboy/PaperRss/releases)
  [![Platform](https://img.shields.io/badge/platform-macOS%2014.0%2B-f7f5ef?style=flat-square&logo=apple&logoColor=000000)](https://github.com/ohmyangboy/PaperRss)
  [![License](https://img.shields.io/badge/license-GPLv3-c92a2a?style=flat-square)](LICENSE)

  [官方网站](https://ohmyangboy.github.io/PaperRss/) · [下载最新版 v1.3.0-beta.2](https://github.com/ohmyangboy/PaperRss/releases/latest) · [问题反馈](https://github.com/ohmyangboy/PaperRss/issues)

</div>

---

## 软件简介

**PaperRss** 是一款现代纸感 RSS 阅读器(macos)，拥有简约舒缓的沉浸式界面、双语翻译可配置的AI功能，一切把控在阅读者手里。

没有sticky的聊天机器人或者LUI，PaperRss主张主动阅读，并提供克制的AI功能，让一切润物细无声。

**Reading First, AI Second**

_本项目灵感启发自另一款优秀的开源RSS预读器 [NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire/)_

## 核心亮点

- **沉浸式纸感阅读**：适合长文的衬线排版、明暗主题与稳定的三栏导航。
- **渲染引擎与数学公式（LaTeX）**：重构富文本准备引擎，原生集成 MathJax 排版与公式防转义保护，完美呈现学术长文。
- **按需 AI 摘要**：所有功能完全可以选用，如果你不喜欢AI，干掉它；或者在需要的时候按下V键
- **划词翻译、解释与提问**：结合文章上下文理解所选文字。
- **自由模型接入**：支持自定义配置DeepSeek、OpenAI 兼容 API KEY，提供设置个性化prompt
- **多账户接入**：支持本地账户与 FreshRSS 服务，提供双向未读/星标同步。

## 真实界面

### 沉浸式纸感阅读

![PaperRss 三栏主界面](assets/screenshots/paper-rss-main.png)

![PaperRss 沉浸阅读视图](assets/screenshots/paper-rss-second.png)

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

从 [Releases](https://github.com/ohmyangboy/PaperRss/releases) 下载最新的 `.dmg` 安装包，打开后将 PaperRss 拖入 Applications 文件夹。

由于当前为个人开源 Beta 版本（未加入 Apple 付费开发者公证），若首次打开提示“无法验证开发者”或“应用已损坏”，可任选以下方式打开：

1. **方法一（推荐）**：直接双击 DMG 安装包内的 `join-beta.command` 内测一键助手，按提示回车即可自动完成修复并打开；
2. **方法二**：打开 macOS「系统设置」→「隐私与安全性」，向下滑动至“安全性”一栏，点击「仍要打开」；
3. **方法三**：在终端手动执行清除隔离标记命令：
   ```bash
   xattr -dr com.apple.quarantine /Applications/PaperRss.app
   ```

_注：PaperRss 当前处于 Beta 测试阶段，后续产品功能稳定后会接入 Apple 官方公证签名。_

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