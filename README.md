<div align="center">

  <img src="assets/app-icon.png" alt="PaperRss 图标" width="120" height="120" />

  # PaperRss

  ***双语流转，克制智能化。让阅读回归纯粹与沉浸。***

  [English](README_EN.md) · **简体中文**

  [![Release](https://img.shields.io/github/v/release/ohmyangboy/PaperRss?include_prereleases&style=flat-square&color=1d4ed8)](https://github.com/ohmyangboy/PaperRss/releases)
[![Platform](https://img.shields.io/badge/platform-macOS%2014.0%2B-f7f5ef?style=flat-square&logo=apple&logoColor=000000)](https://github.com/ohmyangboy/PaperRss)
[![License](https://img.shields.io/badge/license-GPLv3-c92a2a?style=flat-square)](LICENSE)
[![Downloads](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fdownload.1leaf.cc%2Fdownload-stats.json&query=%24.downloads&label=downloads&color=brightgreen)](https://github.com/ohmyangboy/PaperRss/releases)

  [官方网站](https://ohmyangboy.github.io/PaperRss/) · [稳定版 v1.3.1](https://github.com/ohmyangboy/PaperRss/releases/latest) · [测试版 v1.3.2-beta.3](https://github.com/ohmyangboy/PaperRss/releases/tag/v1.3.2-beta.3) · [问题反馈](https://github.com/ohmyangboy/PaperRss/issues)

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
- **自由模型接入**：支持按供应商保存 OpenAI 兼容接口、DeepSeek 与 Google Gemini API Key；摘要、双语和三种划词能力可分别选择模型，切换配置不会隐藏已有 AI 产物。
- **多账户接入**：支持本地账户与 FreshRSS 服务，提供双向未读/星标同步。

更多功能升级和 Bugfix 计划见 [weekly.md](./weekly.md)

### AI 服务配置

在“设置 → AI 功能”中，“供应商与模型”只管理 OpenAI 兼容接口、DeepSeek、Google Gemini 或自定义端点的连接、API Key 与模型目录；远端模型经多选确认后才加入配置。“功能配置”分别为摘要、双语翻译、划词翻译、解释和提问设置开关与模型。Google Gemini 使用官方 OpenAI-compatible 地址 `https://generativelanguage.googleapis.com/v1beta/openai`，需要填入 Gemini API Key。

旧版本的单一 AI 配置会在首次启动时绑定到五项功能，原有 API Key、模型、开关和自定义 Prompt 都会保留；旧配置键仍保留用于兼容回滚。API Key 只保存在本机应用偏好，不参与 iCloud 同步。

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

**测试版 v1.3.2-beta.3（Build 20）** 新增当前文件夹和订阅源的未读文章筛选，阅读后保留本轮文章，并统一分页与快捷键导航。此版本供提前体验，稳定通道仍为 v1.3.1。详情见 [更新记录](CHANGELOG.md)。

从 [Releases](https://github.com/ohmyangboy/PaperRss/releases) 下载最新的 `.dmg` 安装包，打开后将 PaperRss 拖入 Applications 文件夹即可使用。

> 📝 备注：签名问题已解决——所有产物均经过 Developer ID 签名与 Apple 公证，首次打开不会再出现「无法验证」提示。接下来版本更新会加快，敬请谅解。

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

交流信息也可以随时发送邮件至 `ohmyangboy@gmail.com`。

## 隐私、内容与第三方软件

PaperRss 是本地优先而非“完全离线”的客户端：订阅和正文缓存默认保存在本机；刷新 Feed、同步 FreshRSS、加载原网页或图片、检查更新以及用户主动使用 AI 功能时，客户端会直接连接相应第三方服务。AI 功能可能按具体操作发送全部或部分文章内容，请在使用前审查所选模型服务商的条款。

- [隐私政策](PRIVACY.md)
- [内容与版权说明](CONTENT_NOTICE.md)
- [第三方软件声明](THIRD_PARTY_NOTICES.md)
- [官网法律与隐私页面](https://ohmyangboy.github.io/PaperRss/zh-CN/legal.html)

## 开源协议

PaperRss 基于 [GNU General Public License v3.0](LICENSE) 开源。
