# PaperRss 隐私政策 / Privacy Policy

**生效日期 / Effective date:** 2026-08-27  
**联系邮箱 / Contact:** [ohmyangboy@gmail.com](mailto:ohmyangboy@gmail.com)

本文档说明 PaperRss macOS 应用及其官方网站如何处理信息。PaperRss 是本地优先的开源 RSS 阅读器。项目维护者目前不运营用于集中收集用户订阅、阅读历史或文章正文的 PaperRss 服务器。

This document explains how the PaperRss macOS app and its website handle information. PaperRss is a local-first, open-source RSS reader. The project maintainer does not currently operate a PaperRss server that centrally collects users' subscriptions, reading history, or article content.

## 1. 应用在本机保存的信息 / Information stored on your Mac

PaperRss 会在本机保存运行所需的数据，包括：

- RSS、Atom、JSON Feed 订阅地址、Feed 元数据和文章条目；
- 已读、未读、星标、文件夹等阅读状态；
- Feed 正文、按需提取的网页正文、图片地址及相关缓存；
- AI 摘要、翻译、划词解释和问答结果；
- 应用偏好、刷新设置和 AI 服务配置；
- FreshRSS 等用户主动添加的服务账户信息。

PaperRss stores data needed to operate locally, including:

- RSS, Atom, and JSON Feed URLs, feed metadata, and article entries;
- read, unread, starred, and folder state;
- feed content, on-demand extracted web content, image URLs, and related caches;
- AI summaries, translations, selection explanations, and answers;
- app preferences, refresh settings, and AI service configuration; and
- account information for services such as FreshRSS that you choose to add.

网页正文缓存保存在本机数据库中，可在应用设置的“缓存数据”中清除。移除服务账户会删除 PaperRss 保存的相应账户配置；彻底删除所有本地数据可通过删除应用及其应用支持数据完成。

Extracted article caches are stored in the local database and can be cleared from “Cached Data” in Settings. Removing a service account removes the corresponding PaperRss account configuration. You can remove all local PaperRss data by deleting the app and its application-support data.

## 2. 凭据保存 / Credential storage

- FreshRSS 等服务凭据通过 macOS Keychain 保存。
- 用户配置的 AI API Key 当前按供应商保存在该 Mac 的 PaperRss 本地应用偏好（`UserDefaults`）中，不同步到 PaperRss 服务器或 iCloud，也不以 Keychain 级别加密。升级迁移会保留旧的单一 API Key 用于兼容回滚；清空某个供应商的新键不会把旧键重新写回该供应商。请勿在共享的 macOS 用户账户中保存敏感 API Key。
- PaperRss 不会把 API Key 写入公开仓库、反馈内容或文章导出。

- Credentials for services such as FreshRSS are stored in macOS Keychain.
- User-configured AI API keys are currently stored per provider in PaperRss's local app preferences (`UserDefaults`) on that Mac. They are not synchronized to a PaperRss server or iCloud and are not encrypted at the level provided by Keychain. Upgrade migration retains the former single key for rollback compatibility; clearing a provider's new key does not repopulate it from that legacy key. Do not store a sensitive API key in a shared macOS user account.
- PaperRss does not intentionally include API keys in the public repository, feedback content, or article exports.

## 3. 应用发生的网络请求 / Network requests made by the app

根据用户配置和操作，PaperRss 客户端可能直接连接：

1. **订阅源及原网站**：刷新 Feed、读取图标、加载文章图片；当 Feed 内容不足且用户打开文章时，可能请求公开的原文章页面并在本地提取正文。网站运营者会正常看到用户 IP、请求时间和请求头。
2. **FreshRSS 或兼容服务**：同步订阅、文章及阅读状态。相关服务按其自身隐私政策处理数据。
3. **用户选择的 AI 服务**：只有在用户配置接口并主动使用 AI 功能时才会发起请求。根据功能不同，请求可能包含文章标题、文章正文或其片段、选中文字、附近段落、用户问题、自定义 Prompt 和目标语言。模型服务商会按其条款与隐私政策处理这些内容。
4. **GitHub/Sparkle 更新来源**：检查更新和下载用户选择安装的新版本。

Depending on your configuration and actions, the PaperRss client may connect directly to:

1. **Feed and publisher servers** to refresh feeds, retrieve icons, and load article images. If a feed does not provide sufficient content and you open an article, PaperRss may request the publicly accessible article page and extract readable content locally. The publisher will ordinarily receive your IP address, request time, and request headers.
2. **FreshRSS or compatible services** to synchronize subscriptions, entries, and reading state. Those services process data under their own privacy policies.
3. **Your selected AI provider**, only after you configure an endpoint and invoke an AI feature. Depending on the feature, a request may include the article title, all or part of the article text, selected text, nearby paragraphs, your question, custom prompt, and target language. The provider processes this data under its own terms and privacy policy.
4. **GitHub/Sparkle update sources** to check for updates and download a version you choose to install.

在提交保密、付费、受访问限制或含敏感个人信息的内容给第三方 AI 服务前，请先确认你有权这样做，并审查服务商的数据保留与训练政策。

Before sending confidential, paid, access-restricted, or sensitive personal information to a third-party AI provider, confirm that you are permitted to do so and review that provider's retention and training policies.

## 4. 遥测、广告和开发者服务器 / Telemetry, advertising, and maintainer servers

当前版本未集成产品分析 SDK、广告 SDK、跨应用追踪或由 PaperRss 维护者运营的阅读数据收集接口。系统、网络运营者、用户选择的服务商以及应用分发平台仍可能根据各自政策生成标准网络、安全、购买或下载日志。

The current version does not integrate product-analytics SDKs, advertising SDKs, cross-app tracking, or a maintainer-operated API for collecting reading data. Operating systems, network providers, user-selected services, and distribution platforms may still create ordinary network, security, purchase, or download logs under their own policies.

## 5. 官网信息处理 / Website data handling

PaperRss 官网托管于 GitHub Pages。网站：

- 不设置 PaperRss 账户，也不包含广告或产品分析脚本；
- 使用浏览器 `localStorage` 记住语言选择；
- 加载同站点的静态 GitHub 星标数量文件；
- 通过 Google Fonts 获取网页字体，因此访问时 Google 可能收到 IP、浏览器和请求信息；
- 链接至 GitHub、PayPal 和其他外部站点，只有在用户点击后才会访问相应站点。

GitHub Pages、Google 及外部站点分别按其自身隐私政策处理请求信息。项目维护者不控制这些第三方的保留期限。

The PaperRss website is hosted on GitHub Pages. It:

- does not provide PaperRss accounts and contains no advertising or product-analytics script;
- uses browser `localStorage` to remember the selected language;
- loads a same-origin static file containing the displayed GitHub star count;
- obtains web fonts from Google Fonts, so Google may receive IP, browser, and request information; and
- links to GitHub, PayPal, and other external sites, which are contacted only after you follow those links.

GitHub Pages, Google, and external sites process request information under their own privacy policies. The PaperRss maintainer does not control their retention periods.

## 6. 数据共享、出售与跨境处理 / Sharing, sale, and international processing

PaperRss 维护者不出售用户数据。客户端只会按照上述功能把必要信息直接发送给用户订阅的网站、配置的服务或选择的 AI 提供商。第三方服务可能位于用户所在国家或地区之外；是否发生跨境处理取决于用户选择的服务和该服务的基础设施。

The PaperRss maintainer does not sell user data. The client sends necessary information only to the sites, services, or AI providers selected or invoked by the user as described above. A third-party service may operate outside your country or region; any international processing depends on the service you choose and its infrastructure.

## 7. 保留、安全与用户选择 / Retention, security, and your choices

- 本地数据会保留到用户清除缓存、删除账户、删除相应记录或移除应用数据为止。
- 第三方服务的数据保留期限由其自身条款决定。
- 用户可以不配置 AI 服务，并继续使用核心 RSS 阅读功能。
- 用户可以在设置中清除网页正文缓存，并可随时移除 FreshRSS 等账户。
- 任何本地软件都无法承诺绝对安全；请保护 Mac 登录账户、磁盘和 API Key。

- Local data remains until you clear caches, remove an account or related record, or delete the app's data.
- Third-party retention is governed by the relevant provider's terms.
- You may use the core RSS reader without configuring an AI service.
- You may clear extracted article caches in Settings and remove accounts such as FreshRSS at any time.
- No local software can promise absolute security; protect your Mac account, disk, and API keys.

## 8. 儿童 / Children

PaperRss 不专门面向儿童，也不要求用户创建 PaperRss 账户或提交年龄信息。监护人应根据订阅内容及所选第三方服务判断是否适合儿童使用。

PaperRss is not directed specifically to children and does not require a PaperRss account or age information. Guardians should assess the suitability of subscribed content and selected third-party services.

## 9. 变更与联系 / Changes and contact

本政策可能随功能、数据流或法律要求更新。重大变更将通过仓库、官网或版本说明公布。有关隐私、数据删除或安全问题，请联系 [ohmyangboy@gmail.com](mailto:ohmyangboy@gmail.com) 或提交不含敏感数据的 [GitHub Issue](https://github.com/ohmyangboy/PaperRss/issues)。请勿在公开 Issue 中粘贴 API Key、订阅密钥、私人 Feed 地址或文章中的敏感信息。

This policy may be updated as features, data flows, or legal requirements change. Material changes will be announced through the repository, website, or release notes. For privacy, deletion, or security questions, contact [ohmyangboy@gmail.com](mailto:ohmyangboy@gmail.com) or open a [GitHub Issue](https://github.com/ohmyangboy/PaperRss/issues) without sensitive data. Never paste API keys, subscription secrets, private feed URLs, or sensitive article content into a public issue.
