<div align="center">

  <img src="assets/app-icon.png" alt="Paper RSS Logo" width="120" height="120" style="border-radius: 24px; box-shadow: 0 8px 24px rgba(0,0,0,0.12);" />

  # Paper RSS

  ***双语流转，克制智能化。让阅读回归纯粹与沉浸。***

  [![Release](https://img.shields.io/github/v/release/ohmyangboy/PaperRss?style=flat-square&color=1d4ed8)](https://github.com/ohmyangboy/PaperRss/releases/latest)
  [![Platform](https://img.shields.io/badge/platform-macOS%2013.0%2B-f7f5ef?style=flat-square&logo=apple&logoColor=000000)](https://github.com/ohmyangboy/PaperRss)
  [![License](https://img.shields.io/badge/license-GPLv3-c92a2a?style=flat-square)](LICENSE)
  [![GitHub Pages](https://img.shields.io/badge/website-gh--pages-10b981?style=flat-square)](https://ohmyangboy.github.io/PaperRss/)

  [**官方网站**](https://ohmyangboy.github.io/PaperRss/) | [**下载最新版 v1.2.1**](https://github.com/ohmyangboy/PaperRss/releases/latest) | [**问题反馈 Issues**](https://github.com/ohmyangboy/PaperRss/issues)

</div>

---

## 📖 软件简介

**Paper RSS** 是一款专为 macOS 打造的现代纸感 RSS 订阅与 AI 强力阅读助手。

没有喧宾夺主的 AI 噪声，只有恰到好处的全文摘要与划词双语翻译。把散落的全网订阅，还原为安静优雅的纸张阅读。结合大语言模型（DeepSeek / OpenAI 兼容服务），为您提供**全文深度摘要**、**划词实时双语翻译与概念解释**，以及**私密安全的 100% 本地 API 架构**。

---

## ✦ 核心亮点 (Key Features)

- 📜 **极简纸墨风格**：精心调配的羊皮纸亮色与暗夜深色主题，辅以典雅衬线排版与流畅的侧边栏索引。
- 🤖 **AI 深度摘要**：打开文章或一键手动触发全文本要旨分析，快速掌握复杂资讯核心逻辑。
- 🔤 **划词即享翻译与解释**：长按或滑动选中任何非母词汇、难懂概念，悬浮助手即刻给出精准上下文翻译与百科阐释。
- 🔒 **100% 本地隐私保障**：所有 API Key 仅保存在本机 Keychain / 局部配置中，不参与任何第三方服务端上传或云端收集。
- ⚙️ **灵活的模型服务接入**：内置 DeepSeek 官方推荐 Endpoint (Flash / Pro)，同时支持自建 Ollama、LocalAI 或任意 OpenAI 兼容接口。
- ☁️ **iCloud 状态同步 (TODO)**：跨设备无缝同步订阅源列表、已读/未读状态、收藏夹与 AI 生成记录（未完成开发，规划中）。

---

## 🖼 真实界面展示 (Screenshots)

### 1. 三栏式纸感排版主界面
![Paper RSS 三栏主界面](assets/screenshots/paper-rss-main.png)

### 2. AI 智能全文摘要模块
![AI 摘要解析卡片](assets/screenshots/ai-summary-card.png)

### 3. 划词实时 AI 概念解释与翻译浮窗
<p align="center">
  <img src="assets/screenshots/ai-explain-popover.png" width="48%" alt="划词 AI 解释" />
  <img src="assets/screenshots/ai-translate-popover.png" width="48%" alt="划词 AI 翻译" />
</p>

### 4. 灵活的 AI 功能与模型配置
![Paper RSS AI 设置面板](assets/screenshots/settings-ai-config.png)

---

## 🚀 下载与安装说明 (Installation)

### 官方 Release 下载
前往 [Releases 页面](https://github.com/ohmyangboy/PaperRss/releases/latest) 下载最新版本的 `PaperRss-v1.2.1.dmg`，打开后拖入 `Applications` 应用程序文件夹。

### macOS 安全提示（解除隔离标记）
由于软件为个人独立开源构建版本（未付费购买 Apple 签名公证证书），初次打开若提示 `“PaperRss”已损坏，无法打开`，请打开终端（Terminal）执行以下命令绕过系统隔离校验：

```bash
sudo xattr -rd com.apple.quarantine /Applications/PaperRss.app
```

---

## 🛠 本地构建指南 (Building from Source)

环境要求：
- macOS 13.0 +
- Xcode 15.0+ / Swift 5.9+

```bash
# 克隆项目仓库
git clone https://github.com/ohmyangboy/PaperRss.git
cd PaperRss

# 使用 Swift Package Manager 进行构建
swift build -c release

# 或直接使用 Xcode 打开 PaperRss.xcodeproj 进行运行/调试
open PaperRss.xcodeproj
```

---

## 💖 赞赏与支持 (Sponsor & Community)

如果 **Paper RSS** 提升了您的日常阅读体验，欢迎使用微信扫码赞赏支持开发者的持续更新！

<div align="center">

  <img src="assets/wechat-sponsor-qr.jpg" alt="微信赞赏码" width="220" />

  <p><i>感谢每一位热爱独立软件与专注阅读的读者！</i></p>

</div>

如有问题反馈、功能想法或代码改进，欢迎在 [GitHub Issues](https://github.com/ohmyangboy/PaperRss/issues) 中随时与我交流。

---

## 📄 开源协议 (License)

本项目基于 [GNU General Public License v3.0 (GPLv3)](LICENSE) 协议开源。
