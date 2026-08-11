<div align="center">

  <img src="assets/app-icon.png" alt="PaperRss icon" width="120" height="120" />

  # PaperRss

  ***Move between languages. Keep intelligence in its place.***

  **English** · [简体中文](README.md)

  [![Release](https://img.shields.io/github/v/release/ohmyangboy/PaperRss?style=flat-square&color=1d4ed8)](https://github.com/ohmyangboy/PaperRss/releases/latest)
  [![Platform](https://img.shields.io/badge/platform-macOS%2014.0%2B-f7f5ef?style=flat-square&logo=apple&logoColor=000000)](https://github.com/ohmyangboy/PaperRss)
  [![License](https://img.shields.io/badge/license-GPLv3-c92a2a?style=flat-square)](LICENSE)

  [Website](https://ohmyangboy.github.io/PaperRss/) · [Download v1.2.3](https://github.com/ohmyangboy/PaperRss/releases/latest) · [Report an Issue](https://github.com/ohmyangboy/PaperRss/issues)

</div>

---

## About PaperRss

PaperRss is a modern, paper-inspired RSS reader for macOS. It keeps your feeds calm and readable, then brings in AI only where it genuinely helps.

Use the focused three-column reading space for everyday browsing, generate a full-article summary when you need one, or select text to translate it, explain it, or ask a contextual question. PaperRss works with DeepSeek, OpenAI-compatible services, and trusted local models.

## Highlights

- **Focused, paper-inspired reading** with serif typography, light and dark appearances, and dependable three-column navigation.
- **AI summaries on your terms**, generated manually or automatically when an uncached article is first opened.
- **Contextual selection tools** for translation, explanation, and questions.
- **Local-first credentials**: API keys stay on your Mac and are excluded from iCloud sync.
- **Bring your own model service** through DeepSeek, OpenAI-compatible APIs, or trusted local HTTP endpoints.
- **Independent language controls**: switch the app interface between Chinese and English without changing the AI output language.

## Screenshots

The screenshots currently show the Chinese interface; the macOS app itself supports both Chinese and English.

### Three-column reading space

![PaperRss main window](assets/screenshots/paper-rss-main.png)

### AI summary

![AI summary card](assets/screenshots/ai-summary-card.png)

### Selection explanation and translation

<p align="center">
  <img src="assets/screenshots/ai-explain-popover.png" width="48%" alt="AI explanation popover" />
  <img src="assets/screenshots/ai-translate-popover.png" width="48%" alt="AI translation popover" />
</p>

### Model configuration

![PaperRss AI settings](assets/screenshots/settings-ai-config.png)

## Download and Install

Download `PaperRss-v1.2.3.dmg` from the [latest release](https://github.com/ohmyangboy/PaperRss/releases/latest), open it, and drag PaperRss into your Applications folder.

The current release is not notarized by Apple. If macOS says the app cannot be verified or is damaged, run:

```bash
sudo xattr -rd com.apple.quarantine /Applications/PaperRss.app
```

## Build from Source

Requirements: macOS 14.0+, Xcode 15.0+, and Swift 5.9+.

```bash
git clone https://github.com/ohmyangboy/PaperRss.git
cd PaperRss
swift build -c release

# Or open the Xcode project
open PaperRss.xcodeproj
```

## Support and Feedback

PaperRss is independently developed and open source. If it improves your reading, you can [support continued development through PayPal](https://paypal.me/ohmyangboy).

For bugs, ideas, and code improvements, please open a [GitHub Issue](https://github.com/ohmyangboy/PaperRss/issues).

## License

PaperRss is available under the [GNU General Public License v3.0](LICENSE).
