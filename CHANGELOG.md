# 更新记录 / Changelog

## v1.3.3-beta.8 · Build 29 · 2026-09-09

本次为 FreshRSS 订阅生命周期与侧边栏交互修复 Beta；建议测试 FreshRSS 增删改管理的用户升级测试，稳定通道仍为 v1.3.2。

- FreshRSS 文章防重与生命周期：修复退订后重新添加同一订阅时服务端重编 entry ID 导致文章列表出现重复的问题；实现删除时关联清理、重新添加与远端同步时旧数据净化，并在持久化时基于规范 URL 幂等去重与 ID 重新绑定。
- 历史脏数据自愈迁移：新增 `v11-deduplicate-feed-articles` 数据库自愈迁移，平滑清洗历史存量重复文章；同时无损继承已有的 AI 翻译产物与已读/标星状态，并补齐外键级联清理，杜绝数据库启动约束异常。
- 侧边栏文件夹右键弹窗修复：修复右键文件夹选择「添加订阅...」时首次弹窗未锚定到当前文件夹、仍默认显示“本地订阅根目录”的 SwiftUI 状态时序问题；显式初始化初态并隔离视图缓存，确保首次打开即精确选中目标。
- 自动化测试与验证：新增退订重加全流程、多外键关联去重自愈回归测试，确保数据完整性与交互一致性。

---

This Beta fixes FreshRSS article deduplication across subscription lifecycles and sidebar sheet folder anchoring. Recommended for users testing FreshRSS feed management; the stable channel remains on v1.3.2.

- FreshRSS deduplication & lifecycle: Fix duplicate articles appearing after deleting and re-subscribing to feeds due to server-side entry ID reassignment; clean associated items on deletion and re-addition, and bind remote items idempotently by canonical URL on persist.
- Database self-healing migration: Add `v11-deduplicate-feed-articles` migration to deduplicate existing dirty data while migrating AI translation artifacts and reading states, with full foreign-key cascading checks to prevent initialization crashes.
- Sidebar right-click sheet anchoring: Fix the sheet picker defaulting to local subscription root on the first right-click of a folder; explicitly initialize SwiftUI state and isolate view identity to accurately anchor to the targeted folder on first click.
- Tests and stability: Add full integration tests for feed deletion/re-addition lifecycles and complex foreign-key data healing.

## v1.3.3-beta.7 · Build 28 · 2026-09-09

本次为 FreshRSS 订阅管理与侧边栏操作体验优化 Beta；建议测试 FreshRSS 订阅添加及文件夹管理的用户升级测试，稳定通道仍为 v1.3.2。

- FreshRSS 订阅管理：支持从 App 直接添加订阅并自动获取服务端解析的权威标题与真实图标，避免被域名覆盖；添加完成后立即拉取前 50 篇最新文章，自动选中新源展示内容。
- 订阅源与文件夹操作：支持从“我的 Mac”或 FreshRSS 账号右键直接调起添加订阅与新建文件夹弹窗并预设目标；文件夹右键支持直接添加订阅（杜绝文件夹嵌套）。
- 文件夹删除反馈：删除文件夹时当前文件夹图标呈现与刷新一致的脉冲闪烁反馈，直至远端退订与本地清理完全结束后平滑移除。
- 稳定性与测试：新增 FreshRSS 订阅自动元数据提取、初始文章抓取与生命周期自动化测试，保证同步逻辑与交互状态严密闭环。

---

This Beta improves FreshRSS subscription management and sidebar interactions. Recommended for users testing FreshRSS feed addition and folder management; the stable channel remains on v1.3.2.

- FreshRSS subscription management: Automatically retrieve authoritative feed titles and icons parsed by the server when adding feeds from the app, preventing domain fallback override; fetch the latest 50 articles immediately and auto-select the newly added feed.
- Sidebar shortcuts: Add right-click context menus on accounts to add feeds and create folders with presets; allow adding feeds directly from folder context menus (with nested folders disabled).
- Folder deletion feedback: Pulsing sync animation on folder icons during deletion until remote unsubscription and local database cleanup are complete.
- Stability and testing: Add integration tests for metadata extraction, initial article fetching, and CRUD lifecycle.

## v1.3.3-beta.6 · Build 27 · 2026-09-09

本次为 FreshRSS 同步与侧边栏体验修复 Beta；建议遇到未读缺失或大批量同步卡顿的用户升级测试，稳定通道仍为 v1.3.2。

- FreshRSS 同步：修复首次添加账号只拉取部分未读的问题，并补齐旧账号缺失的未读与收藏正文；按批次落库，断网、超时或取消后保留已完成内容并支持重试。
- 同步反馈：账号从排队时显示 loading 并闪烁，取得真实待下载总量后切换为进度圆环；分类文件夹仅闪烁，结束或失败后清理加载状态。
- 侧边栏：修复文件夹展开箭头错位和选中背景下进度不清晰的问题，减少大量订阅同步时的重复查询、图标更新与列表重绘。
- 账号设置：补充 FreshRSS 钥匙串访问说明，帮助区分 Mac 登录密码与 FreshRSS 凭据。
- 开发维护：复用构建目录、串行执行构建并回收测试临时文件，保留发布归档；新增同步恢复、滚动性能与构建管理回归测试。

---

This Beta fixes FreshRSS synchronization and sidebar feedback. Recommended for testing if unread items are missing or large syncs affect scrolling; the stable channel remains on v1.3.2.

- FreshRSS sync: Fix incomplete unread downloads when adding an account and recover missing unread and starred content in existing accounts. Save batches independently and retain completed content for retries after network failures, timeouts or cancellation.
- Sync feedback: Show loading and pulse account icons as soon as accounts enter the queue, then switch to a determinate ring once the actual download total is known. Folder icons pulse without progress rings, and indicators stop on completion or failure.
- Sidebar: Fix folder disclosure alignment and progress contrast on selected rows. Reduce repeated queries, icon updates and list rendering during large syncs.
- Account settings: Explain FreshRSS Keychain access and distinguish the Mac login password from FreshRSS credentials.
- Development: Reuse build directories, serialize builds and reclaim test temporary files while preserving release archives. Add sync recovery, scrolling performance and build management regression tests.

## v1.3.3-beta.5 · Build 26 · 2026-09-08

本次为自动翻译与社区支持功能 Beta；建议测试自动翻译和订阅黑白名单，稳定通道仍为 v1.3.2。

- 自动翻译：新增默认关闭的 Beta 开关，根据本地正文语言识别自动开启外语文章翻译；支持订阅白名单固定翻译、黑名单跳过，以及单篇手动关闭记录。
- 阅读与兼容：改进首屏可见段落握手，隔离正文和目标语言变化后的翻译结果；通过增量迁移保留阅读状态、正文与译文缓存及 AI 配置。
- 社区入口：区分 Issue 问题反馈与 Discussion 想法交流，新增社交动态、可点击的小红书主页及赞助列表，统一赞赏码圆角显示。
- 官网与文档：嵌入曝光后加载的赞赏名单，同步中英文 README；网站部署时自动截取最新名单预览。

---

This Beta adds automatic translation and community support features. Please test automatic translation and feed lists; the stable channel remains on v1.3.2.

- Automatic translation: Add an opt-in Beta switch using local article language detection, with a whitelist to always translate, a blacklist to skip, and remembered per-article manual opt-outs.
- Reading and compatibility: Improve the initial visible-paragraph handshake and isolate translation results after content or target-language changes. Incremental migrations preserve reading state, article and translation caches, and AI configuration.
- Community: Separate Issue bug reports from Discussion ideas, add social updates, clickable Xiaohongshu profiles and supporter lists, and align sponsor QR styling.
- Website and documentation: Embed the supporters page on exposure, update both READMEs, and capture a fresh supporter preview during website deployment.

## v1.3.3-beta.4 · Build 25 · 2026-09-08

本次为工具栏交互修复 Beta；建议使用 v1.3.3-beta.3 的用户升级，稳定通道仍为 v1.3.2。

- 工具栏：修复退出禅模式后阅读工具栏错位到文章列表上方的问题，保持侧栏切换后的布局与阅读工具栏实例。
- 发布验证：补充禅模式往返回归，新增真实交互发现明显问题即中断发布的门禁。

---

This Beta fixes a toolbar interaction issue. Recommended for users of v1.3.3-beta.3; the stable channel remains on v1.3.2.

- Toolbar: Fix the reader toolbar moving above the article list after leaving Zen mode, preserving layout and the reader toolbar instance across sidebar transitions.
- Release validation: Add Zen mode round-trip regression coverage and require releases to stop when real interaction checks reveal obvious problems.

## v1.3.3-beta.3 · Build 24 · 2026-09-08

本次为整合当前代码的体验优化 Beta；建议测试侧栏展开收起与阅读工具栏表现，稳定通道仍为 v1.3.2。

- 工具栏：调整侧栏收起时的紧凑布局，展开收起时保留阅读工具栏实例，减少界面重建。
- 阅读体验：仅在禅模式切换时更新分栏显隐，避免重复设置列表选中样式；包含上一 Beta 的 RSS 图片和内容适配修复。

---

This Beta includes the current code changes. Recommended for testing sidebar transitions and reader toolbar behavior; the stable channel remains on v1.3.2.

- Toolbar: Refine the compact layout when the sidebar is collapsed and preserve the reader toolbar instance across sidebar transitions.
- Reading: Update split-column visibility only when Zen mode changes and avoid resetting list selection styling unnecessarily. Includes the previous Beta's RSS image and content adaptation fixes.

## v1.3.3-beta.2 · Build 23 · 2026-09-08

本次为阅读器图片修复 Beta；建议遇到 RSS 图片缺失的用户升级测试，稳定通道仍为 v1.3.2。

- 图片显示：修复部分 RSS 文章段落内图片丢失的问题，保留图片、链接和强调格式（#31）。
- 内容适配：统一原文与双语阅读的 HTML 结构处理，复杂段落保守保留，并避免段落结构变化后匹配到旧译文。

---

This Beta fixes missing images in the reader. Recommended for testing if RSS images are missing; the stable channel remains on v1.3.2.

- Image display: Fix missing images inside paragraphs in some RSS articles while preserving images, links and emphasis (#31).
- Content adaptation: Share HTML structure handling between original and bilingual reading, preserve complex paragraphs, and avoid matching stale translations after paragraph structure changes.

## v1.3.3-beta.1 · Build 22 · 2026-09-07

本次为小范围修复与体验优化的 Beta 版本；可升级体验独立的订阅源未读筛选，稳定通道仍为 v1.3.2。

- 订阅源筛选：文件夹与账号独立筛选未读 Feed，切换订阅保留过滤；开启时展开有未读内容的文件夹，关闭时收起。
- 侧栏体验：账号显示未读总数并支持展开收起，改善选中对比度与文件夹打开图标。
- 阅读修复：修复底部包含图片或视频的文章无法通过空格继续导航的问题，统一文章列表与阅读工具栏图标尺寸。

---

This Beta contains a small set of fixes and refinements. Upgrade to try independent unread feed filtering; the stable channel remains on v1.3.2.

- Feed filtering: Filter unread feeds independently by folder or account and retain filters when switching feeds. Expand folders containing unread items when enabling the filter and collapse them when disabling it.
- Sidebar: Show account unread totals, support account expansion and collapse, and refine selection contrast and open-folder icons.
- Reading fixes: Restore Space-key navigation for articles ending with images or videos, and align article-list and reader toolbar icon sizes.

## v1.3.2 · Build 21 · 2026-09-06

本次为稳定版本，整合多供应商 AI、模型翻译适配与原位译文展示，并改进未读筛选和阅读外观，建议所有用户升级。

- AI 配置：支持 DeepSeek、Google Gemini、OpenAI 兼容及自定义供应商，按摘要、翻译和划词功能选择模型；设置草稿与运行配置隔离。
- 模型适配：新增通用、单条用户消息和 Qwen-MT 翻译协议，改进连接探测、思考能力选项、语言映射和截断检测，修复 OpenRouter 能力缓存过期后配置失效。
- 翻译体验：支持上下文对照与原位替换，悬浮或聚焦查看原文；目标语言、浅深色译文颜色与预览统一设置，切换展示复用缓存。
- 阅读效率：文件夹及单选、多选订阅源支持未读筛选；摘要与翻译独立调度，翻译分批并行并逐批显示，减少文章切换时结果串台。
- 阅读外观：新增正文与译文行距，划词浮层跟随阅读字体；改进空状态添加／导入入口、应用图标、代码高亮、图片排版及 X/Twitter 头像过滤。
- 连接安全：修正本地 HTTP 地址识别，拒绝将特定前缀的公网域名视为局域网接口。
- 升级兼容：保留既有阅读数据、AI 配置、模型与已有摘要和译文，同步中英文 README、官网及稳定更新通道。

---

This stable release brings multi-provider AI, model-aware translation and in-place translated text, plus unread filtering and reading appearance improvements. Recommended for all users.

- AI configuration: Support DeepSeek, Google Gemini, OpenAI-compatible and custom providers, with per-feature model routing and settings drafts isolated from active requests.
- Model adaptation: Add general, single-user-message and Qwen-MT translation protocols; improve connection probing, reasoning options, language mapping and truncation detection, and keep saved OpenRouter reasoning modes usable after catalog expiry.
- Translation experience: Choose contextual or in-place translation, with hover or focus revealing the original. Configure target language and light/dark translation colors with a preview; display changes reuse cached results.
- Reading efficiency: Filter unread articles within folders or selected feeds. Schedule summaries and translation independently, translate batches concurrently with incremental results, and improve result isolation across articles.
- Reading appearance: Adjust original and translated text line spacing and match selection popovers to reader typography. Improve empty-state add/import actions, app icons, code highlighting, image layout and X/Twitter avatar filtering.
- Connection security: Correct local HTTP address validation so public domains with local-looking prefixes are rejected.
- Upgrade compatibility: Preserve reading data, AI configuration, models and existing summaries/translations; update bilingual READMEs, the website and the stable update channel.

## v1.3.2-beta.3 · Build 20 · 2026-09-05

本次为阅读与 AI 设置体验预发布版本；建议希望体验未读筛选、阅读行距和翻译优化的用户升级，稳定通道仍为 v1.3.1。

- 未读筛选：文件夹、单个及多选订阅源可仅显示未读文章；本轮已阅读文章继续保留，分页与快捷键导航保持一致。
- AI 设置：设置页在主窗口内切换，保留尚未保存的供应商编辑；隔离未保存配置与运行时请求，并避免过期测试结果覆盖新编辑。
- 模型配置：修正首次使用时的默认供应商绑定；翻译默认关闭受支持模型的思考，不支持关闭的模型显示实际可用模式。
- 翻译调度：摘要和翻译使用独立并发额度，优先处理当前文章；翻译分批并行、去重并逐批显示结果。
- 阅读外观：新增可保存的正文与译文行距设置，划词浮层跟随阅读字体与字号。

---

This prerelease improves reading and AI settings. Upgrade to try unread filtering, adjustable line spacing, and translation improvements; the stable channel remains on v1.3.1.

- Unread filtering: Filter folders, individual feeds, or selected feeds; retain articles read during the session and keep pagination and keyboard navigation consistent.
- AI settings: Switch to settings within the main window while preserving unsaved provider edits. Keep drafts separate from runtime requests and reject stale connection-test results.
- Model configuration: Correct first-launch provider defaults. Translation disables reasoning by default where supported, while other models show their available mode.
- Translation scheduling: Separate summary and translation concurrency, prioritize the current article, and deduplicate and translate batches concurrently with incremental results.
- Reading appearance: Save line spacing for original text and translations. Selection popovers follow the reader font and text size.

## v1.3.2-beta.2 · Build 19 · 2026-09-04

本次为 AI 能力架构与设置体验预发布版本；建议希望验证多供应商、Gemini 和并发摘要/翻译的用户升级，稳定通道用户可继续使用 v1.3.1。

- AI 供应商：新增 Google Gemini 官方 OpenAI-compatible 接口，支持 DeepSeek、OpenAI 兼容接口及自定义供应商分别保存连接、密钥和多个模型。
- 功能路由：摘要、双语翻译、划词翻译、划词解释和划词提问可分别启用并选择供应商、模型与思考深度；首次使用优先采用 DeepSeek。
- 并发与隔离：摘要和双语翻译共享最多六个后台任务槽，切换文章后继续处理已提交任务，并按文章、任务和文档代次隔离流式结果，修复摘要、译文和划词结果串台。
- 产物稳定性：切换供应商或模型不再隐藏已有摘要和译文；重新生成成功后才替换当前摘要，失败或取消时保留旧结果。
- 设置体验：重做 AI 功能卡片和供应商主从配置界面，加入官方品牌图标、供应商启用状态、手动确认模型目录和整卡点击热区。
- 数据兼容：升级 AI 设置与产物数据库结构，保留旧配置、API Key、模型、开关和 Prompt，并继续支持回滚兼容。

---

This prerelease focuses on the AI runtime architecture and settings experience. Upgrade to test multi-provider routing, Gemini, and concurrent summaries/translations; stable-channel users may remain on v1.3.1.

- AI providers: Added Google Gemini through its official OpenAI-compatible endpoint, with separate connections, keys, and multi-model catalogs for DeepSeek, OpenAI-compatible, and custom providers.
- Feature routing: Summaries, bilingual translation, selection translation, explanation, and Q&A can each be enabled and assigned a provider, model, and reasoning depth. New installs prefer DeepSeek.
- Concurrency and isolation: Summaries and bilingual translation share up to six background slots, continue submitted work across article switches, and isolate streaming results by article, job, and document generation to prevent cross-article leakage.
- Stable artifacts: Switching providers or models no longer hides existing summaries or translations. Regeneration replaces the current summary only after success and preserves the previous result on failure or cancellation.
- Settings experience: Redesigned the AI feature cards and provider master-detail interface with official brand marks, provider enablement, confirmed model catalogs, and full-card selection hit areas.
- Data compatibility: Upgraded AI settings and artifact storage while preserving legacy configuration, API keys, models, toggles, prompts, and rollback compatibility.

## v1.3.2-beta.1 · Build 18 · 2026-08-30

本次为预发布版本，供提前体验图标与阅读器改进；需要稳定体验的用户请继续使用 v1.3.1。

- 图标：采用更简洁的 A 版图标，移除小字和红色装饰，放大 P，保留 macOS 圆角与透明留边；修复启动后“关于”页及 Dock 仍显示旧图标的问题。
- 阅读器：为标注语言的代码块提供本地语法高亮，改进图片对齐及多图并排展示。
- 内容清理：过滤 X/Twitter 正文中混入的作者头像，保留推文媒体图片，并重新清理旧缓存。
- 阅读列表：右键菜单新增“复制文章 ID”，方便反馈和排查问题。
- 官网：同步新图标、测试版入口及中英文说明，保留稳定版下载；beta 更新仅进入测试通道。

---

This is a preview release for trying the icon and reader improvements. Stay on v1.3.1 if you prefer the stable channel.

- Icon: Adopted the cleaner A design, removed small text and red decorations, and enlarged the P while retaining rounded corners and transparent margins on macOS. Fixed stale icons in About and the Dock after launch.
- Reader: Added local syntax highlighting for code blocks with a language label and improved image alignment and side-by-side image layouts.
- Content cleanup: Removed author avatars embedded in X/Twitter article bodies while preserving post media and refreshing older cached content.
- Article list: Added “Copy Article ID” to the context menu for reporting and troubleshooting.
- Website: Updated the icon, beta links, and bilingual release information while keeping stable downloads available. Beta updates remain in the beta channel.
