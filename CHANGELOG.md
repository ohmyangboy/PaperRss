# 更新记录 / Changelog

## v1.5.3-beta.2 · Build 49 · 2026-11-11

本次 Beta 优化 MCP 工具：外部助手可以拉取已有订阅的最新文章，无需再次批准。欢迎 Beta 通道用户测试，稳定版仍为 v1.5.2。

- **MCP 刷新订阅**：可刷新全部订阅、单个账号，或本地与 iCloud 的指定订阅。调用立即返回进度编号，完成前不标记已读，也不返回正文。FreshRSS 与 Miniflux 按账号同步。

---

This Beta improves the MCP tools: an external assistant can refresh subscribed feeds without another approval. Beta channel users are invited to test it; the stable release remains v1.5.2.

- **MCP feed refresh**: Refresh every feed, one account, or selected local and iCloud feeds. The call returns a progress id immediately. Articles stay unread, and article text is not returned. FreshRSS and Miniflux sync by account.

## v1.5.3-beta.1 · Build 48 · 2026-11-07

本次 Beta 增加与 iPhone 上 Papery 的配对导入，并更新 MCP 和订阅管理；欢迎 Beta 通道用户测试，稳定版仍为 v1.5.2。

- **iPhone 兼容**：在同一局域网通过二维码配对，将所选账号的订阅或 AI 配置导入 Papery；iOS 版仍在开发中。
- **MCP 批量订阅管理**：外部助手可为指定账号规划批量添加、重命名和删除订阅，按设置的审批模式执行。
- **订阅管理**：导入 OPML 时可选择目标账号，也可将订阅拖到其他账号复制；导入结果显示成功、已存在和失败数量。

---

This Beta adds pairing with Papery on iPhone and updates MCP and subscription management. Beta channel users are invited to test it; the stable release remains v1.5.2.

- **iPhone compatibility**: Pair over the same local network with a QR code to import subscriptions from a selected account or AI configuration into Papery. The iOS app is still in development.
- **MCP batch feed management**: External assistants can plan additions, renames and removals for a selected account, with execution governed by the configured approval mode.
- **Subscription management**: Choose a destination account when importing OPML or drag feeds to another account to copy them. Import results show added, existing and failed counts.

## v1.5.2 · Build 47 · 2026-11-04

本次稳定版优化正文加载、订阅切换和键盘阅读体验，并修复图片预览及本地助手连接问题；推荐所有用户升级。

- **正文更快显示**：优化长文处理与阅读缓存，先显示已有正文，后台补齐全文；全文就绪后由你点击查看，避免打断阅读位置和文字选择。
- **订阅切换更平稳**：新列表就绪后整体替换，减少中间空白；快速切换时忽略过期结果，保持标题、筛选与列表一致。
- **键盘阅读更顺畅**：改善方向键选文、视口边缘滚动和跨页定位，保留缩略图位置，减少列表跳动。
- **图片预览与刷新**：放大图片避开关闭按钮；大批量订阅刷新时减少不必要的界面更新。
- **本地 MCP 更稳定**：改进助手进程退出与连接关闭，减少断开连接后的残留进程。

---

This stable release improves article loading, feed switching and keyboard reading, with fixes for image previews and local assistant connections. Recommended for all users.

- **Faster article display**: Improve long-article processing and reading caches. Show available content first and fetch the full article in the background; choose when to open it without interrupting your reading position or text selection.
- **Smoother feed switching**: Replace the list once results are ready, reducing blank flashes. Ignore outdated results during rapid switching and keep titles, filters and articles in sync.
- **Better keyboard reading**: Improve arrow-key selection, scrolling near viewport edges and cross-page navigation. Preserve thumbnail space to reduce layout shifts.
- **Image previews and refresh**: Keep enlarged images clear of the close button and reduce unnecessary interface updates during large feed refreshes.
- **More reliable local MCP**: Improve helper shutdown and connection cleanup to reduce lingering processes after disconnection.

## v1.5.1 · Build 46 · 2026-10-28

本次稳定版带来本地 MCP 外部助手、iCloud 同步，以及自 v1.4.5 以来 Beta 通道的阅读与翻译改进；推荐所有用户升级。

- **本地 MCP 外部助手**：设置 → AI → MCP 可一键接入 Cursor、VS Code、Claude Code、Codex，并提供 Claude Desktop、Windsurf、Gemini CLI 的配置片段；App 内嵌已签名的 `paperrss-agent`，助手可查询资料库与订阅，添加/重命名/删除订阅需在 App 审批面板确认（按订阅分行、影响篇数显示在订阅行右侧）；支持审批模式、提示与资源、状态查询，以及打开文章与批量标记已读计划。
- **iCloud 同步**：设置 → 账号可添加 iCloud，在多台 Mac 之间同步订阅源、目录、已读/未读与收藏；与「我的 Mac」、FreshRSS、Miniflux 相互独立。高级审阅与恢复入口仍在完善中。并修复本地副本快照稳定性。
- **关闭自动全文抓取**：设置中可关闭「自动抓取全文网页」；关闭后仅使用订阅源/缓存正文，手动重新抓取仍可用；默认保持开启。[#42](https://github.com/ohmyangboy/PaperRss/issues/42)
- **双语翻译与 AI 摘要**：改进对照排版、滚动中译文更新与请求调度；AI 摘要支持完整 Markdown / GFM 表格；默认摘要约 300 词并应用表达偏好；设置页支持键盘导航。[#45](https://github.com/ohmyangboy/PaperRss/issues/45)、[#44](https://github.com/ohmyangboy/PaperRss/issues/44)
- **订阅与分享**：支持重命名订阅源、侧栏多选批量删除；列表右键可系统共享、拷贝链接、在浏览器打开；修复 Kimi 官方接口温度参数。[#46](https://github.com/ohmyangboy/PaperRss/issues/46)、[#47](https://github.com/ohmyangboy/PaperRss/issues/47)

---

This stable release adds local MCP external assistants, iCloud sync, and the reading/translation improvements from the Beta channel since v1.4.5. Recommended for all users.

- **Local MCP assistants**: Settings → AI → MCP offers one-click setup for Cursor, VS Code, Claude Code and Codex, plus config snippets for Claude Desktop, Windsurf and Gemini CLI. The app embeds a signed `paperrss-agent` helper so assistants can query your library and feeds; feed add/rename/remove require confirmation in the in-app approval panel (per-feed rows with impact counts on the right). Approval modes, prompts, resources, status, opening articles and plan mark-read are included.
- **iCloud sync**: Add an iCloud account in Settings → Accounts to sync feeds, folders, read/unread and starred state across Macs. My Mac, FreshRSS, Miniflux and iCloud stay separate. Advanced review and recovery UI continues to mature. Local-copy snapshot stability is improved.
- **Disable automatic full-article fetch**: Settings can turn off automatic full-article web fetching. When off, use feed/cache content only; manual refetch still works. Default remains on. [#42](https://github.com/ohmyangboy/PaperRss/issues/42)
- **Bilingual translation and AI summaries**: Improve side-by-side layout, in-scroll translation updates and request scheduling; AI summaries render full Markdown / GFM tables; default summary aims for about 300 words with expression preferences; Settings supports keyboard navigation. [#45](https://github.com/ohmyangboy/PaperRss/issues/45), [#44](https://github.com/ohmyangboy/PaperRss/issues/44)
- **Feeds and sharing**: Rename feeds and multi-select delete in the sidebar; article-list context menu adds system Share, Copy Link and Open in Browser; omit temperature on official Kimi endpoints that reject it. [#46](https://github.com/ohmyangboy/PaperRss/issues/46), [#47](https://github.com/ohmyangboy/PaperRss/issues/47)

## v1.5.0-beta.4 · Build 45 · 2026-10-27

本次 Beta 新增可关闭自动全文抓取的设置项，并修复 Kimi 官方接口温度参数与 iCloud 本地快照稳定性；推荐 Beta 通道用户更新测试，稳定版仍为 v1.4.5。

- **关闭自动全文抓取**：设置中可关闭「自动抓取全文网页」；关闭后仅使用订阅源/缓存正文，手动重新抓取仍可用；默认保持开启。[#42](https://github.com/ohmyangboy/PaperRss/issues/42)
- **Kimi 温度参数**：对拒绝 temperature 的 Kimi 官方接口省略该参数，避免请求失败。
- **iCloud 本地快照**：修复本地副本快照 JSON 规范化与摘要列绑定，提升同步稳定性。

---

This Beta adds a setting to disable automatic full-article web fetch, and fixes Kimi official-endpoint temperature handling plus iCloud local-copy snapshot stability. Recommended for Beta channel users; the stable release remains v1.4.5.

- **Disable automatic full-article fetch**: Settings can turn off automatic full-article web fetching. When off, use feed/cache content only; manual refetch still works. Default remains on. [#42](https://github.com/ohmyangboy/PaperRss/issues/42)
- **Kimi temperature**: Omit temperature on official Kimi endpoints that reject it, avoiding request failures.
- **iCloud local snapshots**: Fix local-copy snapshot JSON canonicalization and digest column binding for more stable sync.

## v1.5.0-beta.3 · Build 44 · 2026-10-14

本次 Beta 改进双语翻译排版、滚动更新与请求调度，并补齐设置页键盘导航；推荐 Beta 通道用户更新测试，稳定版仍为 v1.4.5。

- **双语对照排版**：嵌套列表按项目逐一对照，父项译文放在子列表之前；引用块按段落对照，共享原有的边框与缩进。
- **译文换行**：保留原文的单换行，减少译文中多余的空行，让原文与译文的间距更一致。
- **滚动与段落更新**：滚动中及时显示已完成译文，合并布局更新并保持阅读位置，改善长文章和密集列表、表格后续段落的翻译。
- **翻译请求调度**：正文、标题和划词翻译协调同模型请求，服务限流时自动等待后重试，额度不足时及时停止请求，并改进翻译专用模型的标题翻译兼容性。
- **设置键盘操作**：再次按 ⌘, 返回主界面；上下方向键切换分类，右方向键或 Tab 进入控件，左方向键返回分类。输入框保留光标操作，关闭设置后恢复主界面焦点。

---

This Beta improves bilingual translation layout, scrolling updates and request scheduling, and adds keyboard navigation in Settings. Recommended for Beta channel users; the stable release remains v1.4.5.

- **Bilingual layout**: Nested lists show translations beside individual items, with parent translations before child lists. Blockquotes align translations paragraph by paragraph while sharing the original borders and indentation.
- **Translation line breaks**: Preserve single line breaks and reduce extra blank lines for spacing that better matches the original text.
- **Scrolling and paragraph updates**: Show completed translations during scrolling, batch layout updates and preserve the reading position. Improve translation of long articles and paragraphs following dense lists or tables.
- **Translation requests**: Coordinate article, title and selection requests for the same model, retry after temporary rate limits, stop when quota is exhausted, and improve title translation compatibility with translation-specific models.
- **Settings keyboard controls**: Press ⌘, again to return to the main window. Use Up and Down for categories, Right or Tab to enter controls, and Left to return. Text fields retain cursor controls, and closing Settings restores the main window's keyboard focus.

## v1.5.0-beta.2 · Build 43 · 2026-10-13

本次 Beta 支持 AI 摘要的 Markdown 完整渲染，结合自定义表达偏好可清晰排版表格与结构化内容；欢迎 Beta 通道用户测试，稳定版仍为 v1.4.5。

- **AI 摘要支持 Markdown 完整渲染**：摘要卡片支持 GFM 表格排版，结合「表达偏好」（如指定「表格列出」）可将要点与事实规整对齐展示；支持粗体、斜体、列表、代码块、引用块及公式。
- **排版与换行优化**：单换行按段内断行展示，改善卡片视觉边距与表头背景，折叠预览与直接复制体验更稳定。

![表达偏好设置](assets/screenshots/ai-summary-custom-prompt.png)

![AI 摘要表格渲染](assets/screenshots/ai-summary-markdown-table.png)

---

This Beta adds full Markdown rendering to AI summaries, cleanly formatting tables and structured content when configured via custom expression preferences. Beta channel users are invited to test it; the stable release remains v1.4.5.

- **Full Markdown rendering for AI summaries**: The summary card now formats GFM tables, neatly aligning key points and facts when custom expression preferences (such as requesting tabular summaries) are set. Headings, bold, italics, lists, code blocks, blockquotes, and math formulas are also supported.
- **Layout and line break improvements**: Soft line breaks render as in-paragraph breaks, table headers and borders match the reader theme, and card folding preview and direct copying remain smooth.

![Expression preference setting](assets/screenshots/ai-summary-custom-prompt.png)

![AI summary markdown table](assets/screenshots/ai-summary-markdown-table.png)
## v1.5.0-beta.1 · Build 42 · 2026-10-13

本次 Beta 新增 macOS iCloud 同步，并改进订阅管理与 AI 阅读；欢迎 Beta 通道用户测试，稳定版仍为 v1.4.5。iCloud 界面仍处于开发调试阶段。

- **iCloud 账户（Beta）**：在「设置 → 账号 → 添加账号」中选择 iCloud，使用系统已登录的 Apple Account，在多台 Mac 之间同步订阅源、目录、已读/未读和收藏状态；「我的 Mac」、FreshRSS、Miniflux 与 iCloud 各自独立，添加 iCloud 不会自动搬走现有资料。开发版使用的测试云库与本次 Beta 的正式云库相互独立，测试资料不会自动迁入。
- **正文同步范围**：收藏文章始终同步 RSS 原正文；未读正文默认不上传，可在 iCloud 账户的高级选项中开启。同步的是 RSS 提供的正文，不包含额外抓取的网页全文、AI 摘要/译文、模型设置、API Key 或本机阅读外观；订阅链接及其中的访问参数会进入你的私有 iCloud。缺少可靠原始身份的历史文章及超出大小限制的正文会保留在本机。
- **离线与同步反馈**：离线阅读、收藏和订阅调整先在本机保存，待联网后发送；后台状态同步减少刷新动画，频繁切回 App 时合并云端拉取，手动刷新仍可立即执行。账户页可查看待发送数量与错误，高级选项提供云端记录和恢复资料的审阅入口。
- **订阅管理**：支持重命名订阅源，名称重启后保留，并按账户同步能力处理；侧栏可用 Command/Shift 多选，再按 Delete/Backspace 打开批量删除确认。[#46](https://github.com/ohmyangboy/PaperRss/issues/46)
- **AI 阅读**：默认摘要提示词要求控制在约 300 词（提示词约束），并应用自定义表达偏好；双语翻译按简单列表的每一项紧邻排版，引用块译文保留引用样式，复杂嵌套列表保持整体翻译。[#45](https://github.com/ohmyangboy/PaperRss/issues/45)、[#44](https://github.com/ohmyangboy/PaperRss/issues/44)
- **链接共享**：文章列表右键菜单新增 macOS 系统共享、拷贝链接和在浏览器中打开；可使用本机已安装 App 提供的共享扩展。[#47](https://github.com/ohmyangboy/PaperRss/issues/47)

---

This Beta adds iCloud sync on macOS and improves feed management and AI reading. Beta channel users are invited to test it; the stable release remains v1.4.5. The iCloud interface is still in the developer debugging stage.

- **iCloud account (Beta)**: Choose iCloud in Settings → Accounts → Add Account to use the Apple Account signed in on your Mac. Sync feeds, folders, read/unread and starred states across Macs. My Mac, FreshRSS, Miniflux and iCloud remain separate accounts; adding iCloud does not automatically move existing data. The development test database and this Beta’s production database are separate; test data is not migrated automatically.
- **Article content scope**: Starred articles always sync their original RSS content. Unread content is off by default and can be enabled in the iCloud account’s advanced options. Sync includes RSS content, rather than separately extracted web pages, AI summaries/translations, model settings, API keys or local reader appearance. Feed URLs and their access parameters go to your private iCloud. Historical articles without reliable source identities and content above the size limit stay on this Mac.
- **Offline use and sync feedback**: Reading states, stars and feed edits save locally before being sent when online. Background state sync shows fewer refresh animations, repeated app activations coalesce cloud fetches, and manual refresh remains immediate. Account settings show pending changes and errors; advanced options provide reviews of cloud records and recovery data.
- **Feed management**: Rename feeds with names preserved after relaunch and handled according to each account’s sync capabilities. Select multiple feeds with Command/Shift, then press Delete/Backspace to open the deletion confirmation. [#46](https://github.com/ohmyangboy/PaperRss/issues/46)
- **AI reading**: The default summary prompt requests approximately 300 words (a prompt instruction) and applies custom expression preferences. Bilingual translations appear beside individual items in simple lists, and blockquote translations retain quote styling; complex nested lists keep whole-block translation. [#45](https://github.com/ohmyangboy/PaperRss/issues/45), [#44](https://github.com/ohmyangboy/PaperRss/issues/44)
- **Link sharing**: The article-list context menu adds native macOS sharing, Copy Link and Open in Browser, using sharing extensions supplied by apps installed on your Mac. [#47](https://github.com/ohmyangboy/PaperRss/issues/47)

## v1.4.5 · Build 41 · 2026-09-27

本次稳定版带来更顺畅的列表与阅读体验，并修复滚动闪退和部分正文图片加载失败；推荐所有用户升级。

- 列表与阅读响应更快：异步加载文章页、减少切换文章时的主线程查询，并将缩略图准备限定在可见范围；修复普通列表连续滚动时偶发的布局闪退。
- 正文图片加载更可靠：图片加载失败时自动重试，减少需要重新拉取原文的情况。
- 杂志阅读更稳定：优化封面与翻页过渡、相邻页标题翻译预取，并新增 Paper、White、Book 三种纸张质感。
- 阅读音浪改用系统输出音频的频谱驱动；AI 摘要支持直接复制。

---

This stable release makes list navigation and reading smoother, fixes an occasional scrolling crash and improves article image loading. Recommended for all users.

- Faster list and reader response: load article pages asynchronously, reduce main-thread queries during article switching and prepare thumbnails only for visible rows; fix an occasional layout crash during continuous list scrolling.
- More reliable article images: retry failed image loads so fewer articles need to be fetched again.
- More stable magazine reading: refine cover and page-turn transitions, prefetch title translations for adjacent pages and add Paper, White and Book textures.
- Drive the reading audio wave from the system output spectrum; copy AI summaries directly.

## v1.4.5-beta.1 · Build 40 · 2026-09-26

本次 Beta 聚焦列表与阅读性能提升，欢迎 Beta 通道用户升级测试；稳定版仍为 v1.4.4。

- 列表切换和跨页加载更顺畅：文章查询改为异步执行，缩略图只为当前可见的列表行准备。
- 标题翻译减少卡顿：语言识别移至后台处理，切换订阅范围后会丢弃过期结果。
- 正文更快就绪：文章清理、段落索引和阅读文档渲染移至后台，快速切换时会取消过期渲染。
- AI 摘要可直接复制；选中摘要文字时不会意外折叠卡片。

---

This Beta focuses on faster list navigation and article reading. Beta channel users are invited to try it; the stable version remains v1.4.4.

- Smoother list switching and pagination: article queries run asynchronously, and thumbnails are prepared only for rows currently visible in the list.
- Less interruption from title translation: language detection runs in the background, and stale results are discarded after changing feed scope.
- Faster article readiness: article cleanup, paragraph indexing and reader document rendering run in the background; outdated renders are cancelled during rapid switching.
- Copy AI summaries directly, and select summary text without accidentally collapsing the card.

## v1.4.4 · Build 39 · 2026-09-25

本次是体验优化版本，推荐所有用户升级。

- 文章列表切换更跟手：减少列表行重复更新与标题翻译请求，缩略图预处理改为增量执行。
- 键盘快速切换和跨页浏览更顺畅：选中态保持稳定，列表在接近边缘或切换页面时将当前文章滚动到视口中间。
- 正文加载反馈更清晰：连续切换文章时显示小尺寸加载提示，减少阅读区空白等待。
- 标题翻译动画继续保留；列表左侧 48% 的整行区域可悬停查看原文。

---

This is an experience-focused update. Recommended for all users.

- Faster article-list navigation: reduce repeated row updates and title-translation requests, and prepare thumbnails incrementally.
- Smoother keyboard and cross-page browsing: keep selection stable and center the current article when it reaches the viewport edge or a new page.
- Clearer reader loading feedback: show a compact progress indicator during rapid article switches instead of an empty reader pane.
- Keep the translated-title animation; hover over the left 48% of a list row to reveal the original text.

## v1.4.3 · Build 38 · 2026-09-24

PaperRss 1.4.3 新增中西文字体分别设置与列表标题、摘要按需翻译，并收敛标题切换交互；同时把 1.4.3 Beta 的正文抓取、深色纸面插图与 Dock 图标修复带入稳定通道，建议所有用户升级。

- 中西文字体分别设置（新功能）：阅读排版新增「中文字体」与「西文字体」两项，正文、文章标题和译文按「西文 → 中文 → 系统回退」逐字承接；旧版单字体设置可无损继续使用，未配置时保持原有观感。
- 列表标题与摘要按需翻译（新功能）：设置中可独立开启「列表标题」并为「标题翻译」指定模型；普通列表、时间线卡片与杂志视图会按可见范围翻译外语标题和描述，支持黑白名单、本地语言判断、视口预取与翻译缓存。
- 标题译文交互优化：默认显示译文；鼠标停留标题左侧热区 300ms 后可查看原文，切换采用从右向左的轻量翻页与少量淡入淡出。首次使用会在当前条目显示一次操作提示，移出热区即恢复译文。
- 按需翻译稳定性：相同标题或摘要只请求一次，标题与摘要合并批处理；滚动停止后再取新条目，失败文本自动退避，重启或再次浏览时优先命中本地缓存，避免滚动过程中的请求风暴。
- 正文抓取修复：修复 Tailwind 新版式站点（如 openai.com）的 CSS 变量与变体前缀被误判为页面导航词元、导致正文容器被删除的问题；受影响文章会重新抓取完整正文。
- 深色纸面与 Dock 修复：深色纸面下自动反相深色线稿、图表与公式图并保留照片原貌；「隐藏 Dock 图标」现在随窗口显隐即时生效，无需重启。

---

PaperRss 1.4.3 adds separate CJK and Latin font settings and on-demand translation for timeline titles and summaries, while refining title-reveal interactions. It also promotes the 1.4.3 Beta fixes for article extraction, dark-paper images and Dock icon behavior to stable. Recommended for all users.

- Separate CJK and Latin fonts (new): Reader typography now provides independent Chinese and Latin font settings; article bodies, headings and translations use a “Latin → CJK → system fallback” stack. Existing single-font settings remain compatible, and an unconfigured install keeps its previous appearance.
- On-demand timeline title and summary translation (new): a dedicated “List Titles” preference and “Title Translation” model route are available across list, timeline-card and magazine views. Visible foreign titles and descriptions are translated on demand with feed lists, local language detection, viewport prefetching and a local translation cache.
- Refined translated-title interaction: translations show by default; move to the title’s left-side hot zone for 300ms to reveal the original with a subtle right-to-left page transition and light fade. A one-time item-level coachmark appears on first use, and leaving the hot zone restores the translation.
- Reliable on-demand requests: duplicate titles and summaries are sent once, title and summary work is batched, newly visible rows wait for scrolling to settle, failed text backs off, and cached translations are reused after relaunch or revisits to prevent request storms.
- Article extraction fix: Tailwind-based sites such as openai.com no longer lose the full article container when CSS variables or variant prefixes resemble navigation keywords; affected articles automatically refetch their complete bodies.
- Dark-paper and Dock fixes: dark line art, diagrams and formula images are lightness-inverted on dark paper while photos and colour illustrations remain unchanged; “Hide Dock Icon” now follows window visibility immediately without a relaunch.

## v1.4.3-beta.2 · Build 37 · 2026-09-22

本次 Beta 修复部分网站正文抓取失败的问题；稳定通道仍为 v1.4.2。

- 正文抓取修复：修复 Tailwind 新版式站点（如 openai.com）正文容器 class 中的 CSS 变量与变体前缀被误判为页面导航词元、整篇文章被当作页面元素删除的问题。此前这些站点只能抓到摘要，点「重新拉取正文」会提示失败；现在可正常抓取全文，受影响的旧文章打开时会自动重抓。
- 回归保护：新增两条正文抽取回归用例（CSS 变量名容器、Tailwind 变体前缀容器），并保留既有导航、作者行、分享栏等页面元素的剔除契约。

---

This Beta fixes article extraction failures on some sites; the stable channel remains on v1.4.2.

- Extraction fix: on Tailwind-based layouts (e.g. openai.com), CSS variables and variant prefixes inside a container's class were misread as navigation keywords, so the whole article container was stripped as page chrome. Those sites previously returned only the summary and “Refetch Article Body” failed; full article bodies now load, and affected articles refetch automatically when opened.
- Regression coverage: two new extraction tests (CSS-variable containers and Tailwind variant prefixes) while keeping the existing chrome-stripping contracts for navigation, bylines and share bars.

## v1.4.3-beta.1 · Build 36 · 2026-09-21

本次 Beta 修复深色纸面下公式与线稿插图不可读的问题，并让「隐藏 Dock 图标」随窗口即时生效；稳定通道仍为 v1.4.2。

- 深色纸面插图反相（修复）：深色纸面下自动识别正文中的深色线稿、图表与公式图并反转明度（保留色相），照片与彩色插图保持原样；行内公式小图同样参与判定，修复 issue #41 深色模式下公式看不清的问题。
- 判定按需且受限：仅深色纸面触发，逐篇按张数与并发上限分析，超限或失败一律按「不反相」处理，不阻塞阅读；结果复用系统图片缓存，重复阅读不产生额外流量。
- 隐藏 Dock 图标即时生效（修复）：开关不再需要重启；窗口打开期间应用仍保留程序坞与 Cmd+Tab 入口，窗口全部关闭后才隐藏，再次打开窗口自动恢复。

---

This Beta fixes unreadable formulas and line-art figures on dark paper, and makes “Hide Dock Icon” take effect immediately with window visibility; the stable channel remains on v1.4.2.

- Dark-paper image inversion (fix): on dark paper, dark line art, diagrams and formula images in article bodies are detected and inverted in lightness (hue preserved), while photos and colour illustrations stay untouched; inline formula thumbnails are included, fixing the low contrast reported in issue #41.
- Bounded, on-demand analysis: only triggered on dark paper, with per-article count and concurrency limits; over-limit or failed images fall back to “no inversion” so reading is never blocked, and results reuse the system image cache, so re-reading costs no extra traffic.
- Hide Dock Icon takes effect immediately (fix): no relaunch needed; while a window is open the app keeps its Dock and Cmd-Tab entry, hides only after every window is closed, and reappears when a window opens again.

## v1.4.2 · Build 35 · 2026-09-18

PaperRss 1.4.2 修复了 macOS 14 与 macOS 15 用户自 1.4.1 起遇到的冷启动闪退，并带来 Miniflux 账号接入、阅读页「打开原文」入口与多项正文提取改进；建议所有用户升级。

- 冷启动闪退修复（重要）：修复 1.4.1 起在 macOS 14 / 15 上打开应用即闪退（EXC_BREAKPOINT）的问题。原因为应用启动早期读取尚未就绪的系统菜单与 AppKit 单例；现在菜单扫描推迟到应用完成启动之后执行，并在系统菜单不可用时保持安全，任何系统版本都不再受影响。
- Miniflux 账号接入（新功能）：设置 → 账号 → 添加账号新增 Miniflux 服务预设，使用 Miniflux「设置 → 集成 → Google Reader」配置的用户名与密码连接；支持订阅与分类拉取（含服务端空分类）、文章同步与双向已读/星标同步，离线修改可恢复重试。
- 用户数据与多账号隔离：Miniflux 凭据保存在独立 Keychain 命名空间，与 FreshRSS、本地账号及各自状态队列完全隔离，可多账号并存互不影响。
- 打开原文入口（新功能）：阅读工具栏胶囊最右新增「打开原文」按钮，没有原文链接时置灰；与快捷键（默认连按 `O O`）共用同一动作入口。
- 正文与图片提取修复：修复 Substack 型 CDN 图片因 srcset 逗号切分被截断导致的破图；减少正文混入站点导航、作者行、点赞/分享等页面元素；标题与摘要中的 HTML 实体不再原样显示，旧缓存打开时自动重新清洗。
- Dock 图标隐藏与菜单栏模式：支持隐藏 Dock 图标（含 Cmd+Tab）并常驻菜单栏显示图标与未读数，Dock 未读徽标与菜单栏未读文案一致（99+ 折叠），可随时切回。
- 阅读工具栏与滚动细节：胶囊宽度与图标在窄窗口下保持稳定，修正列表 / 杂志切换后顶部导航模糊绑定丢失的问题。

---

PaperRss 1.4.2 fixes cold-launch crashes that macOS 14 and macOS 15 users hit since 1.4.1, and adds Miniflux account support, an “Open Original” reader entry and article-extraction improvements. Recommended for all users.

- Cold-launch crash fix (important): fixed the crash-on-launch (EXC_BREAKPOINT) that affected macOS 14 / 15 users since 1.4.1. The app used to read the system menu and AppKit singletons before they were ready during launch; menu scanning now runs only after the app finishes launching and stays safe when the system menu is unavailable, on every macOS version.
- Miniflux accounts (new): a Miniflux preset in Settings → Accounts → Add Account using the username and password from Miniflux “Settings → Integrations → Google Reader”; supports subscriptions and categories (including empty ones), article sync, two-way read/starred sync, and recoverable offline changes.
- Data and multi-account isolation: Miniflux credentials live in a dedicated Keychain namespace, fully isolated from FreshRSS, local accounts and their state queues, so accounts coexist independently.
- Open-original entry (new): the reader toolbar capsule gains an “Open Original” button (disabled when no link exists), sharing one action with the shortcut (default double-press `O O`).
- Article and image extraction fixes: Substack-style CDN images no longer break from comma-split srcset URLs; site navigation, bylines and like/share chrome leak into article bodies less often; HTML entities in titles and summaries are no longer shown raw, and old caches re-clean on open.
- Hide Dock icon & menu bar mode: hide the Dock icon (including Cmd+Tab) and keep PaperRss in the menu bar with an unread count; the Dock badge and menu bar count stay consistent (99+ capped), and you can switch back anytime.
- Reader toolbar and scrolling polish: capsule width and icons stay stable in narrow windows, and the top navigation blur keeps its binding after switching between list and magazine views.

## v1.4.2-beta.1 · Build 34 · 2026-09-15

本次为 Miniflux 账号接入的实验性 Beta；建议使用自建 Miniflux 的用户升级测试，稳定通道仍为 v1.4.1。

- Miniflux 账号接入（新功能）：设置 → 账号 → 添加账号新增 Miniflux 服务预设，使用 Miniflux「设置 → 集成 → Google Reader」配置的用户名与密码连接；支持订阅与分类拉取（含服务端空分类）、文章同步与双向已读/星标同步，离线修改可恢复重试。
- 用户数据与多账号隔离：Miniflux 凭据保存在独立 Keychain 命名空间，与 FreshRSS、本地账号及各自状态队列完全隔离，可多账号并存互不影响。
- 分类与订阅生命周期：删除分类只移除分类并保留订阅（与 Miniflux 服务端语义一致），添加订阅使用服务端返回的真实订阅标识，重复添加同一账号会被拒绝。
- 数据库迁移 v13：扩展 accounts 表类型约束以支持 Miniflux，兼容早期 Schema 并完整保留现有账号、订阅、文章与阅读状态数据。

---

This Beta introduces Miniflux account support. Recommended for users running self-hosted Miniflux; the stable channel remains on v1.4.1.

- Miniflux accounts (new): Add a Miniflux preset under Settings → Accounts → Add Account using the username and password configured in Miniflux “Settings → Integrations → Google Reader”; supports subscriptions and categories (including empty ones), article sync, two-way read/starred sync, and recoverable offline changes.
- Data and multi-account isolation: Miniflux credentials are stored in a dedicated Keychain namespace and fully isolated from FreshRSS, local accounts and their state queues; accounts coexist independently.
- Category & subscription lifecycle: Deleting a category keeps subscriptions (matching Miniflux server semantics); adding a subscription uses the server-returned feed identity, and duplicate accounts are rejected.
- Database migration v13: Extends the `accounts` type constraint for Miniflux, compatible with early schemas while preserving existing accounts, subscriptions, articles and reading states.

## v1.4.1 · Build 33 · 2026-09-14

PaperRss 1.4.1 带来「文章阅读」自定义快捷键，并优化杂志模式方向键导航；所有用户可直接升级。

- 文章阅读自定义快捷键（新功能）：在 macOS「键盘快捷键…」（`⌘/`）中为对照翻译、AI 摘要、上一篇/下一篇、收藏、禅模式等动作录制 VS Code 风格组合键，支持「防误触」连按两次、冲突检测与一键重置；保留 `C / V / K / J / M / F / O / Space` 默认键，新增连按 `O O` 打开原文。
- 杂志方向键导航优化：方向键改为遥控式就近移动（左右只横向、上下只纵向），只在一侧没有卡片即到达页面边缘时才翻页；从右半页翻到下一页再翻回，会恢复到离开的那张卡片。
- 性能与交互优化：按键识别改为绑定表精确比对，不再逐次解析字符与硬编码分支；杂志翻页与选择状态复用不变，方向键移动不会折返绕圈。

---

PaperRss 1.4.1 adds customizable reader shortcuts and refines magazine arrow-key navigation. All users can upgrade directly.

- Customizable reader shortcuts (new): record VS Code-style key combos for bilingual toggle, AI summary, previous/next article, starring, zen mode and more in **Keyboard Shortcuts…** (`⌘/`), with double-press confirmation, conflict detection and one-click reset; defaults `C / V / K / J / M / F / O / Space` are kept, plus `O O` to open the original article.
- Magazine arrow-key navigation: arrows now move to the geometrically nearest card (left/right move horizontally, up/down vertically) and only turn pages at the page edge; returning from the next page restores the card you left.
- Performance & interaction polish: shortcut matching now uses an exact bindings lookup rather than per-keystroke character parsing and hard-coded branches; magazine page turning and selection state are reused, and arrow navigation never loops back.

## v1.4.0 · Build 31 · 2026-09-14

PaperRss 1.4.0 正式版发布！带来全新的沉浸式杂志浏览体验、原生 Metal 拟真折纸翻页、视觉时间线视图切换，以及完善的数据库存储治理与历史文章保留策略。

### 重点更新：
- 沉浸式杂志浏览（Magazine View）：重塑信息流展现形态，引入全新双页排版编排（Balanced Duo Layout），支持画报级封面导读、文章首图自适应提取呈现与专题网格布局。
- 原生拟真翻页与流体交互（Fold Turning）：基于 Metal 着色器开发的高性能卷曲与折纸翻页动效，高度还原纸张真实光影与角落弧度阻尼，搭配原生翻页音效；配备底部快速导读滑轨（Scrubbing Page Rail），支持快速掠览与跳页导航。
- 阅读模式与流体返回：时间线支持经典列表与画报杂志随心切换，文章正文无缝承接原有沉浸式纸感阅读器；支持双指横向滑动、鼠标侧键或快捷键（ESC / Delete）一键流畅返回杂志时间线。
- 翻页边缘瑕疵清零：深度重构 Metal 渲染器视口与透明度混合机制，彻底消除翻页动效边缘的白边与暗纹，色彩过渡纯净自然。
- 存储治理与历史文章自动淘汰：在设置中提供「存储与历史记录」管理，支持配置历史文章保留期限（180天默认 / 1年 / 永久），严格以拉取下载到达时间为准淘汰超期已读文章，并提供带二次确认的原生弹窗清理工具。
- 铁律保护与墓碑防幽灵机制：未读与星标文章绝对永久保留；清理历史文章时采用墓碑保留机制，杜绝源站刷新时老文章复活为未读。
- 订阅源右键强制重新获取：侧边栏订阅源右键菜单新增「重新获取此订阅」，支持绕过 HTTP 304 缓存强制拉取最新条目并自动回填正文。
- 数据库性能与空闲空间回收：清理后自动执行 WAL 截断与 VACUUM 物理释放磁盘碎片，并在应用退至后台时提供限时防锁库空闲自动维护。
- 启动性能优化：限制图标探测并发，采用轻量早停 XML 剪枝与持久化探测冷却，彻底消除冷启动时的瞬时 CPU 飙升。

---

PaperRss 1.4.0 is officially released! Introducing an all-new immersive Magazine View, native Metal-powered fold page turning, visual timeline style switching, and comprehensive database storage governance with automated retention policies.

### Highlights:
- Immersive Magazine View: Reimagined timeline browsing with Balanced Duo editorial layouts, cover-led issues, automatic article preview image extraction, and flexible multi-story spreads.
- Native Metal Fold Turning: Fluid 3D curl-and-fold page transitions powered by Metal shaders with realistic paper lighting and adjustable corner curvature, paired with native page-turning audio; equipped with a bottom scrubbing page rail for rapid skimming and navigation.
- Reader Modes & Gesture Navigation: Seamless switching between classic list and magazine views; articles open seamlessly into the distraction-free paper reader; return effortlessly to the magazine timeline using two-finger swipe, mouse back button, or shortcut keys (ESC / Delete).
- Flawless Visual Rendering: Metal renderer viewport and alpha blending refined to eliminate edge artifacts and dark/white border lines during page turning transitions.
- Storage Governance & History Retention: New "Storage & History" settings to configure article retention periods (180 days default / 1 year / keep forever), pruning read items based on arrival time with confirmation prompts.
- Protection & Tombstone Preservation: Unread and starred items are permanently preserved; pruned read items keep tombstones to prevent ghost resurrection upon feed refreshes.
- Force Reload Feeds: Context menu action "Reload Feed" to bypass HTTP 304 caches and retrieve the latest entries with full content backfill.
- Database Compaction: Automatic WAL truncation and VACUUM compaction to reclaim physical disk space during background idle windows.
- Startup Performance: Throttled icon probe concurrency with early-exit XML pruning and persistent cooldowns, eliminating cold-start CPU spikes.

## v1.4.0-beta.1 · Build 30 · 2026-09-10

本次为数据库存储治理、自动淘汰保留策略与启动性能优化的实验性调整 Beta；稳定通道仍为 v1.3.2。

- 存储治理与历史文章自动淘汰：在设置中提供「存储与历史记录」管理，支持配置历史文章保留期限（180天默认 / 1年 / 永久），严格以拉取下载到达时间为准淘汰超期已读文章，并提供带二次确认的原生弹窗清理工具。
- 铁律保护与墓碑防幽灵机制：未读与星标文章绝对永久保留；清理历史文章时采用墓碑保留机制，杜绝源站刷新时老文章复活为未读。
- 订阅源右键强制重新获取：侧边栏订阅源右键菜单新增「重新获取此订阅」，支持绕过 HTTP 304 缓存强制拉取最新条目并自动回填正文，配有局部旋转 Loading 反馈。
- 数据库性能与空闲空间回收：清理后自动执行 WAL 截断与 VACUUM 物理释放磁盘碎片，并在应用退至后台时提供限时防锁库空闲自动维护。
- 启动 CPU 尖峰优化：限制图标探测并发，采用轻量早停 XML 剪枝与持久化探测冷却，彻底消除冷启动时的瞬时 CPU 飙升。
- 订阅源级联物理清理：修复删除订阅源时的僵尸数据残留，通过 `v12` 迁移彻底清洗存量软删除废弃条目。

---

This Beta introduces experimental adjustments for database storage governance, retention policies, and startup performance optimizations; the stable channel remains on v1.3.2.

- Storage governance & retention policy: Add "Storage & History" management in Settings with configurable retention periods (180 days default / 1 year / keep forever), pruning read articles based on arrival time with confirmation alerts.
- Protection & tombstone preservation: Unread and starred articles are kept forever; pruned read articles preserve tombstones to prevent ghost resurrection upon feed refreshes.
- Context menu feed reload: Add "Reload Feed" to sidebar feed context menus to force-fetch latest items bypassing HTTP 304 caches and restore missing article content with inline loading spinners.
- Database compaction & background maintenance: Automatically reclaim disk space via VACUUM and WAL truncation, with staged non-blocking maintenance during background idle periods.
- Startup CPU peak optimization: Throttle feed icon probe concurrency, introduce early-exit XML pruning, and persist probe cooldowns to eliminate cold-start CPU spikes.
- Feed deletion cascading & cleanup: Cascading physical deletion for removed feeds with `v12` migration purging leftover soft-deleted records.

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
