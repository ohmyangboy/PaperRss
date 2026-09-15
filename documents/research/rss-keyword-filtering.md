# RSS 屏蔽词功能：市场做法与 PaperRss 产品建议

> 研究日期：2026-08-10
> 结论性质：竞品事实尽量来自产品官方帮助、官方博客、官方源码仓库与 App Store 开发者资料；设计建议均标注为“产品推断”。

## 一句话结论

**建议 PaperRss 添加，但不应把它做成“命中即删除”的黑名单。** 用户已经明确提出需求，且主流专业 RSS 产品已经形成稳定的降噪范式：规则需要有范围、可预览、可撤销、能解释为什么某篇文章被隐藏。对 PaperRss 而言，最合适的 MVP 是“屏蔽规则 + 隐藏列表 + 命中原因”，默认仅影响今后进入列表的文章展示，保留原始文章数据。

这不是所有 RSS 用户都会使用的基础功能，却是高订阅量、高重复内容、强厌恶主题用户的高价值功能。它更接近“阅读控制权”而不是“高级搜索”。

## 研究问题与证据边界

本研究回答：

1. RSS 产品如何命名并实现屏蔽/过滤；
2. 免费与付费限制；
3. 匹配字段、大小写、正则、作用范围、应用时点、历史文章、同步与可解释性；
4. 用户真正想完成的任务（JTBD）和产品风险；
5. PaperRss 应做的 MVP、非目标与后续演进。

“未发现”只代表在本次检索到的官方文档、官方仓库或产品维护者公开说明中未找到证据，不等同于证明功能永远不存在。

## 决策摘要

### 来源证实

- Feedly、Inoreader、NewsBlur、FreshRSS、Miniflux 和 Reeder 都提供了某种关键词降噪或正/负过滤能力，只是语义从“隐藏/标为已读”到“保留/排除的自定义时间线”不等。[Feedly Mute Filters](https://docs.feedly.com/article/109-how-can-i-add-create-a-mute-filter)、[Inoreader Automations](https://www.inoreader.com/blog/2026/01/save-time-with-automations.html)、[NewsBlur Intelligence Training](https://newsblur.com/features/intelligence-training)、[FreshRSS Filtering](https://freshrss.github.io/FreshRSS/en/users/10_filter.html)、[Miniflux Rules](https://miniflux.app/docs/rules.html)、[Reeder App Store](https://apps.apple.com/us/app/reeder/id6475002485)
- 市场没有统一采用“屏蔽词”这个词。常见命名包括 **Mute Filters**、**Filters / Rules**、**Intelligence Training**、**Block / Keep Rules**、**Include / Exclude Filters**，终端阅读器 Newsboat 还沿用 Usenet 的 **killfile** 术语。[Newsboat Killfiles](https://newsboat.org/releases/2.42/docs/newsboat.html)
- 成熟产品普遍不会让过滤成为不可见的黑箱：Feedly 显示每条规则移除了多少文章，并可查看最近最多 100 篇命中文章；Inoreader 显示每日移除量；NewsBlur 将匹配结果分成 Focus、Unread、Hidden；Miniflux 则明确提示命中屏蔽规则的文章不会入库。[Feedly 管理过滤器](https://docs.feedly.com/article/101-how-do-i-manage-my-filters)、[Feedly 查看命中](https://docs.feedly.com/article/102-how-do-i-know-if-my-mute-filter-is-working)、[Inoreader Automations](https://www.inoreader.com/blog/2026/01/save-time-with-automations.html)、[NewsBlur Intelligence Training](https://newsblur.com/features/intelligence-training)、[Miniflux Rules](https://miniflux.app/docs/rules.html)

### 产品推断

- “已有用户主动要求”比竞品覆盖率更强：它说明 PaperRss 已出现真实降噪场景，应进入近期产品队列，而不是只放在愿望清单。
- PaperRss 的核心承诺是安静、克制、由用户主动控制的信息流；屏蔽规则与这个定位一致，但“后台替用户永久删除内容”与该定位冲突。
- MVP 不需要 AI、正则或复杂布尔表达式。先把安全语义和可解释性做好，比一开始追求 Inoreader/Miniflux 的规则引擎更重要。

## 竞品对照

| 产品 | 官方命名与动作 | 范围 | 匹配能力 | 应用时点与历史 | 免费/付费 | 可解释性与同步 |
|---|---|---|---|---|---|---|
| Feedly | **Mute Filters**；命中后从信息流移除，跨 Web/移动端表现为标为已读 | 指定 Feed/文件夹或全部 Feed；可设 1 天、1 周、1 月、永久 | 关键词/短语；全部内容或仅标题；`author:`、`site:`；若源只给摘要，只匹配摘要 | 官方创建说明使用 “going forward”；没有承诺创建后重跑全部历史文章，但可查看最近最多 100 篇已移除文章 | Pro+、Enterprise；旧 Pro 25 条、Pro+ 100 条、Business 200 条、Enterprise 500 条 | 规则面板显示移除数、到期时间，可暂停/恢复/编辑；可显示已屏蔽文章；Web 创建的规则作用于移动端 |
| Inoreader | **Content Filters** 可 keep/remove；**Rules** 可标记已读、打标签、通知等 | 全账户、文件夹或订阅，取决于规则触发与所选对象 | 标题/内容、作者、URL、附件/图片/视频、语言、RSS 分类；AND/OR；官方旧文档确认规则支持正则 | 对“新进入”的文章自动执行；可用 Run rule 测试。官方资料未明确承诺过滤器创建后自动重算全部历史文章 | Pro：30 条 Rules、50 条 Filters；免费版不含 | 面板显示每日命中/移除量，可启停、编辑、删除；规则可测试 |
| NewsBlur | **Intelligence Training**；喜欢项进入 Focus，不喜欢项进入 Hidden | 默认每个站点；Premium Archive 支持文件夹和全局 | 免费：标题、作者、标签、站点；Premium：URL 精确短语；Archive：正文精确短语；Pro：标题/正文/URL 正则，正则不区分大小写 | 官方资料确认新自然语言分类器会立即处理近期文章、以后处理新文章；对传统精确分类器的统一历史重算语义未明确说明 | 站点级标题/作者/标签免费；全文、全局/文件夹和正则分层付费 | 可管理所有训练项；匹配文章显示 Focus/Hidden；正向与负向冲突时“green always wins” |
| FreshRSS | 搜索/保存的 **User Queries**；每个 Feed 的 **Filter** 可自动标为已读 | 搜索可按 Feed、分类、保存查询组合；自动标已读过滤器配置在 Feed 上 | 作者、标题、正文、URL、标签、日期等；负操作符、AND/OR、括号、正则；正则默认区分大小写，可用 `i` | 新文章可自动标为已读；Feed 菜单提供“运行已定义过滤器”来处理已有文章。保存查询只保存查询，不冻结结果 | 自托管自由软件（AGPL 3），无功能订阅墙；自托管成本另计 | 通过“标为已读”保留文章；查询可保存并输出 HTML/RSS/OPML |
| Miniflux | **Block Rules / Keep Rules** | 每个 Feed；2.2.10 起也支持全局，顺序为全局 block → Feed block → 全局 keep → Feed keep | RE2 正则；标题、URL、评论 URL、正文、作者、标签、日期；大小写由表达式决定，例如 `(?i)` | 在 Feed 处理时执行；被 Block 的文章**不写入数据库**，所以不能在应用内恢复。官方未提供对既有文章重跑规则的承诺 | 自托管免费开源（Apache 2.0）；官方托管另收费 | 规则文本本身可审计，但命中文章不入库，撤销安全性最低 |
| NetNewsWire | 本次未发现当前版本的内建关键词屏蔽功能；2026-04 官方论坛中维护者表示希望未来做 filters 和 smart feeds | 未实现 | 未实现 | 未实现 | App 免费开源 | 官方功能列表确认支持 Feedbin、Feedly、Inoreader、NewsBlur、FreshRSS 等同步账户；各服务的过滤结果如何完整映射到客户端，本次未逐项验证。iCloud/本地账户当前没有同等内建能力 |
| Reeder（新版本 `Reeder.`） | **Filters** 创建自定义时间线；支持关键词、媒体类型、Feed 类型；关键词查询支持 include/exclude | 官方资料确认是自定义时间线，未公开更细的文件夹/Feed 范围规则 | 2025.9 起关键词默认整词匹配；前后加 `*` 可做包含匹配；include/exclude 均支持多条查询。未发现官方正则说明 | 作为时间线过滤器工作；官方资料未明确说明创建时是否重算所有本地历史项目 | App Store 为免费下载安装，含 $1/月或 $10/年内购；官方资料未明确过滤功能的免费额度 | iCloud 只同步订阅、时间线位置和标签项目；官方资料未明确过滤规则是否同步 |

表格来源：

- Feedly：[创建与范围](https://docs.feedly.com/article/109-how-can-i-add-create-a-mute-filter)、[仅标题](https://docs.feedly.com/article/106-can-i-filter-by-just-the-article-title)、[作者](https://docs.feedly.com/article/248-muting-authors)、[摘要限制](https://docs.feedly.com/article/103-if-a-source-only-displays-an-excerpt-in-feedly-will-my-filter-work-on-the-full-text)、[数量限制](https://docs.feedly.com/article/246-how-many-mute-filters-can-i-have)、[移动端语义](https://docs.feedly.com/article/107-will-my-filters-apply-to-articles-on-mobile-devices)、[查看屏蔽文章](https://docs.feedly.com/article/389-is-there-an-option-to-see-the-muted-articles)
- Inoreader：[2026 自动化说明](https://www.inoreader.com/blog/2026/01/save-time-with-automations.html)、[当前价格与额度](https://us.inoreader.com/pricing)、[规则字段与正则](https://www.inoreader.com/blog/2015/03/inoreader-how-to-save-time-with-rules.html)
- NewsBlur：[功能与免费边界](https://newsblur.com/features/intelligence-training)、[字段/正则/订阅层级](https://blog.newsblur.com/2026/01/22/intelligence-trainer-overhaul/)、[文件夹与全局范围](https://blog.newsblur.com/2026/02/02/global-and-folder-scoped-intelligence-training/)、[当前价格](https://www.newsblur.com/faq)
- FreshRSS：[过滤语法](https://freshrss.github.io/FreshRSS/en/users/10_filter.html)、[Feed 自动标已读](https://freshrss.github.io/FreshRSS/en/users/04_Subscriptions.html)、[运行 Feed 过滤器](https://freshrss.github.io/FreshRSS/en/users/03_Main_view.html)、[保存查询](https://freshrss.github.io/FreshRSS/en/users/user_queries.html)、[开源与自托管](https://www.freshrss.org/)
- Miniflux：[规则完整说明](https://miniflux.app/docs/rules.html)、[开源与自托管](https://miniflux.app/)
- NetNewsWire：[维护者对过滤功能的公开回复](https://discourse.netnewswire.com/t/feature-request-filters-for-feeds/232)、[当前 App 功能列表](https://apps.apple.com/us/app/netnewswire-rss-reader/id1480640210)、[官方开源仓库](https://github.com/Ranchero-Software/NetNewsWire)
- Reeder：[当前 App 描述、价格与版本说明](https://apps.apple.com/us/app/reeder/id6475002485)

## 市场实现模式

### 1. 屏蔽不是唯一动作

来源证实：

- Feedly 采用隐藏并标为已读的软处理；用户仍能显示已屏蔽文章。[Feedly 移动端语义](https://docs.feedly.com/article/107-will-my-filters-apply-to-articles-on-mobile-devices)、[查看屏蔽文章](https://docs.feedly.com/article/389-is-there-an-option-to-see-the-muted-articles)
- Inoreader 把“Filter（保留/移除）”与“Rule（标已读、打标签、通知等动作）”分开。[Inoreader Automations](https://www.inoreader.com/blog/2026/01/save-time-with-automations.html)
- NewsBlur 用排序/可见性层级表达偏好，而不是删除：Focus、Unread、Hidden。[NewsBlur Intelligence Training](https://newsblur.com/features/intelligence-training)
- Miniflux 的 Block 是硬入口：文章不写入数据库。[Miniflux Rules](https://miniflux.app/docs/rules.html)
- Tiny Tiny RSS 明确区分“Delete article（不导入）”与“Mark as read（导入但已读）”，并允许打星、标签、分数等动作。[Tiny Tiny RSS Content Filters](https://tt-rss.org/docs/Content-Filters.html)

产品推断：对普通用户，产品文案应叫“屏蔽规则”或“减少此类文章”，底层动作应是**隐藏**，而不是“删除”。“过滤器/规则”适合设置页的管理名称；“killfile”过于技术化且有破坏性暗示，不适合作为中文 UI 主词。

### 2. 负向过滤与正向过滤是两种不同任务

来源证实：Miniflux、Inoreader、Reeder 都同时提供 Keep/Include 与 Block/Exclude；NewsBlur 同时提供喜欢和不喜欢。[Miniflux Rules](https://miniflux.app/docs/rules.html)、[Inoreader Automations](https://www.inoreader.com/blog/2026/01/save-time-with-automations.html)、[Reeder App Store](https://apps.apple.com/us/app/reeder/id6475002485)、[NewsBlur Intelligence Training](https://newsblur.com/features/intelligence-training)

产品推断：

- 屏蔽词解决“我不想看到什么”；
- 关注词/智能文件夹解决“我只想看到什么”；
- 两者混在一个 MVP 中会迅速引入 AND/OR、冲突优先级和空结果问题。PaperRss 第一版只做负向规则，后续再独立设计“关注主题”。

### 3. 范围是必要属性，不是高级设置

来源证实：Feedly、Inoreader、NewsBlur 和 Miniflux 都至少区分单 Feed 与更大范围，NewsBlur 还明确区分站点、文件夹、全局。[Feedly 创建过滤器](https://docs.feedly.com/article/109-how-can-i-add-create-a-mute-filter)、[Inoreader Rules](https://www.inoreader.com/blog/2015/03/inoreader-how-to-save-time-with-rules.html)、[NewsBlur 范围](https://blog.newsblur.com/2026/02/02/global-and-folder-scoped-intelligence-training/)、[Miniflux Rules](https://miniflux.app/docs/rules.html)

产品推断：没有范围的全局屏蔽很容易误伤。PaperRss 应默认从用户发起操作的位置推断范围：从某个订阅操作时默认“仅此订阅”，从设置页创建时默认“全部订阅”；文件夹范围可随 MVP 一起提供，因为 PaperRss 已有文件夹模型。

### 4. 可解释性决定用户是否敢用

来源证实：Feedly、Inoreader、NewsBlur 都提供命中数或结果分层；Feedly 还能直接查看最近命中项目。[Feedly 管理过滤器](https://docs.feedly.com/article/101-how-do-i-manage-my-filters)、[Inoreader Automations](https://www.inoreader.com/blog/2026/01/save-time-with-automations.html)、[NewsBlur 管理训练](https://blog.newsblur.com/2026/01/22/intelligence-trainer-overhaul/)

产品推断：创建规则时必须预览“会隐藏多少篇”和若干样例；隐藏列表应显示“因规则『促销』命中标题而隐藏”。否则用户遇到文章消失时无法判断是 Feed 故障、刷新失败还是规则误伤。

## 匹配语义：PaperRss 应如何取舍

### 来源证实的市场差异

- Feedly 提供简单关键词/短语和标题限定，且只对 Feed 实际提供的摘要或正文进行匹配，不会自动抓网页全文补齐。[Feedly 标题过滤](https://docs.feedly.com/article/106-can-i-filter-by-just-the-article-title)、[Feedly 摘要限制](https://docs.feedly.com/article/103-if-a-source-only-displays-an-excerpt-in-feedly-will-my-filter-work-on-the-full-text)
- Reeder 默认整词匹配，用 `*` 显式切换为子串包含，说明“一个词是否命中更长单词”是实际产品问题。[Reeder App Store 2025.9 说明](https://apps.apple.com/us/app/reeder/id6475002485)
- FreshRSS 的正则默认区分大小写，需 `i` 修饰符改为不区分大小写；NewsBlur 的正则明确不区分大小写；Miniflux 则通过 RE2 表达式 `(?i)` 指定。[FreshRSS Filtering](https://freshrss.github.io/FreshRSS/en/users/10_filter.html)、[NewsBlur Regex](https://blog.newsblur.com/2026/01/22/intelligence-trainer-overhaul/)、[Miniflux Rules](https://miniflux.app/docs/rules.html)
- FreshRSS 和 Inoreader 的高级规则覆盖标题、正文、作者、URL、标签/分类等多个字段。[FreshRSS Filtering](https://freshrss.github.io/FreshRSS/en/users/10_filter.html)、[Inoreader Automations](https://www.inoreader.com/blog/2026/01/save-time-with-automations.html)

### 产品推断：MVP 匹配合同

1. **字段**：只提供“标题”与“标题 + Feed 摘要/正文”；默认标题 + Feed 内容。作者、网址稍后加入。
2. **大小写**：英文默认不区分大小写；中文不存在该问题。
3. **空白与 Unicode**：规则和待匹配文本先做 Unicode 规范化、去首尾空白；连续空白按一个处理。
4. **边界**：中文按子串；英文默认整词/短语，避免 `AI` 误伤 `said` 一类词。后续可增加“包含任意位置”。
5. **不抓全文**：匹配只使用 RSS/Atom/JSON Feed 已取得的标题、summary、contentHTML。不要为了过滤自动访问原网页；否则结果受网页加载、付费墙和网络状态影响，也违背本地、克制的产品预期。
6. **不支持正则**：MVP 不暴露正则。正则错误、性能和跨平台语义会显著增加测试面，专业用户需求出现后再做“高级匹配”。
7. **一条规则一个短语**：先不支持用户手写 AND/OR。多条规则之间是 OR，即命中任一规则就隐藏。

## 应用时点、历史文章和数据安全

### 来源证实

- Feedly 的说明使用“going forward”，并允许回看最近命中；FreshRSS 同时提供“新文章自动标已读”和手动运行过滤器；Miniflux 与 Tiny Tiny RSS 在 Feed 导入/处理时应用规则，其中 Miniflux 命中后不入库，TT-RSS 明确提醒不要依赖规则追溯处理创建前的文章。[Feedly 标题过滤](https://docs.feedly.com/article/106-can-i-filter-by-just-the-article-title)、[FreshRSS Feed 设置](https://freshrss.github.io/FreshRSS/en/users/04_Subscriptions.html)、[FreshRSS 运行过滤器](https://freshrss.github.io/FreshRSS/en/users/03_Main_view.html)、[Miniflux Rules](https://miniflux.app/docs/rules.html)、[Tiny Tiny RSS Filters](https://tt-rss.org/docs/Content-Filters.html)

### 产品推断

- **存储与展示分离**：PaperRss 应继续保存文章，只在索引/列表层计算 `isMuted`。不要在 Feed 合并时丢弃 Entry。
- **创建规则时预览历史，不默认修改历史**：创建页显示“当前资料库有 23 篇匹配”；用户可选“同时隐藏已有文章”。默认只影响现在及以后列表展示，避免突然清空大量未读。
- **删除规则立即恢复**：因为文章从未删除，重建索引即可重新出现；已读/收藏状态保持原样。
- **通知在过滤后计算**：刷新结果、未读数和新文章通知应排除被隐藏文章，否则 UI 说有 10 篇新文章但列表只出现 3 篇。
- **收藏优先**：已收藏文章即使后来命中规则也不隐藏，或至少提供明确提示。用户主动收藏是比自动规则更强的意图。

## 用户真实需求：JTBD

### 核心任务

当用户订阅一个总体有价值、但夹杂重复或令人厌烦内容的来源时，他想自动跳过某些主题，而不必退订整个来源，从而把有限注意力留给真正想读的内容。

### 常见具体场景

- **促销与商业噪声**：屏蔽“优惠”“Black Friday”“Sponsored”等，但保留媒体其余报道。Feedly 官方专门提供屏蔽促销事件和站点的用法，Miniflux 文档也以 discount/deals/gift guide 为屏蔽例子。[Feedly 临时屏蔽说明](https://docs.feedly.com/article/104-can-i-change-the-duration-of-my-mute-filters)、[Miniflux Rules](https://miniflux.app/docs/rules.html)
- **重复热点疲劳**：重大事件爆发时，临时屏蔽一天或一周；Feedly 把过滤器有效期作为一等属性。[Feedly 时限](https://docs.feedly.com/article/104-can-i-change-the-duration-of-my-mute-filters)
- **来源有价值、个别作者/栏目无价值**：Feedly 支持按作者，NewsBlur 免费层支持作者/标签/标题训练。[Feedly 作者屏蔽](https://docs.feedly.com/article/248-muting-authors)、[NewsBlur Intelligence Training](https://newsblur.com/features/intelligence-training)
- **敏感/触发内容回避**：NetNewsWire 的功能请求直接提到 triggering/annoying 主题，并希望文章保留但默认隐藏且可显示。[NetNewsWire 官方论坛请求](https://discourse.netnewswire.com/t/feature-request-filters-for-feeds/232)
- **高容量监控**：不是简单“不看”，而是正向筛出关键主题、通知或自动归档；这是 Inoreader Rules 和 NewsBlur Focus 的主场，不应塞进 PaperRss 第一版。[Inoreader Rules](https://www.inoreader.com/blog/2026/01/save-time-with-automations.html)、[NewsBlur Intelligence Training](https://newsblur.com/features/intelligence-training)

## 主要风险与防护

| 风险 | 后果 | MVP 防护 |
|---|---|---|
| 误伤 | 用户错过重要文章，失去对阅读器的信任 | 创建前预览；隐藏而非删除；保留“已屏蔽”列表；收藏优先 |
| 语义含糊 | 用户不知道匹配标题、摘要还是网页全文 | 创建页明确写字段；命中原因显示具体字段 |
| 中英文匹配不一致 | 英文短词大量误命中，中文分词结果不可预测 | 中文子串、英文整词；暂不做自动分词和词干化 |
| 规则冲突 | 同一篇同时被关注和屏蔽，结果不稳定 | MVP 只有负向规则；以后定义明确优先级 |
| 未读数/通知不一致 | 用户看到幽灵未读数或无内容通知 | 所有派生统计共用同一过滤结果 |
| 同步漂移 | Mac 与 iPhone 看到不同列表 | 若规则尚未进入可验证的 CloudKit 同步路径，UI 明示“仅此设备”；不要宣称已同步 |
| 隐私扩大 | 为了匹配全文而抓原网页或调用 AI | 只用 Feed 已下载字段；规则匹配纯本地，不调用模型 |
| 规则过多导致列表卡顿 | 每次 SwiftUI 刷新重复扫描正文 | 在资料变更/规则变更时预计算命中集合，列表读取稳定结果 |

## PaperRss MVP 建议

### 用户界面

1. 设置新增“屏蔽规则”。
2. 创建规则字段：
   - 关键词或短语；
   - 匹配位置：标题 / 标题与 Feed 内容；
   - 范围：仅此订阅 / 某文件夹 / 全部订阅；
   - 可选：“同时隐藏已有文章”。
3. 创建页实时显示：命中数量 + 最近 3–5 篇样例。
4. 文章右键/更多菜单提供“减少此类文章…”，自动带入所选标题文字并默认当前订阅范围。
5. 侧边栏或列表筛选菜单提供“已屏蔽”，可以恢复查看；文章行显示命中规则和字段。
6. 规则列表显示启用状态、范围、累计命中数；支持暂停、编辑、删除。

### 行为规则

- 默认软隐藏，不删除、不自动标记为已读。
- 隐藏文章不计入未读数、新文章通知和刷新后的新文章列表。
- 收藏文章不被隐藏。
- 删除或暂停规则后文章立即恢复，原有已读/收藏状态不变。
- 一篇文章命中多条规则时，只隐藏一次，但详情列出所有命中规则。
- Feed 只给摘要时就只匹配摘要；不自动抓原网页全文。

### 当前架构落点（基于仓库代码检查，非外部来源）

- 新增可 Codable 的 `MuteRule`，持久化进 `AppDatabase`；旧数据库解码时用 `decodeIfPresent ?? []` 保持兼容。
- `MuteRule` 至少包含：`id`、`query`、`fields`、`scope`、`isEnabled`、`applyToExisting`、`createdAt`、`updatedAt`。
- 匹配器放在 Core 层，输入 `Entry + Feed + rules`，输出结构化 `MuteMatch`，避免 UI 自己重复实现语义。
- `EntryLibraryIndex` 重建时计算隐藏集合，并让 all/today/unread/byFeed/byFolder、对应计数和 `FeedRefreshOutcome.newUnreadEntries` 共用该结果。
- 不建议给 `Entry` 写入永久 `isMuted` 布尔值：规则编辑或删除后会产生失效状态。可缓存“规则版本 → 命中的 entryID 集合”，但真相仍是规则和文章字段。
- 当前 `CloudLibrary` 只包含 feeds、readingStates、artifacts。第一版若不扩展并真实验证 CloudKit，同步设置必须明确为本机；后续再把规则作为带 `updatedAt` 的独立同步实体加入。

### 验收标准

- 中文关键词、英文大小写与英文整词边界有单元测试。
- 标题/内容字段范围、Feed/文件夹/全局范围有组合测试。
- 创建、暂停、删除规则后索引、未读数、刷新结果同步变化。
- 被隐藏文章仍存在数据库，取消规则后能恢复。
- 已收藏文章不被隐藏。
- 老版本 `library.json` 无规则字段时可正常加载。
- 1 万篇文章、100 条规则的索引重建耗时有基准测试；滚动列表时不重新扫描全文。

## MVP 非目标

- 正则表达式、AND/OR 可视化规则组；
- AI 语义分类、“少看类似内容”自动学习；
- 作者、URL、标签、发布日期等高级字段；
- 正向关注词、智能文件夹和通知自动化；
- 导入时丢弃文章或永久删除历史文章；
- 为匹配而自动抓取网页全文；
- 在未完成真机/双端验证前宣称 iCloud 规则同步；
- 订阅/免费额度设计。PaperRss 当前首先需要验证价值，不应先人为制造限制。

## 后续演进顺序

1. **MVP 数据验证**：记录规则创建数、7/30 日活跃规则数、命中后恢复查看率、暂停/删除率、被恢复文章率。所有分析可先仅本地展示，不必上传。
2. **更多字段**：作者、站点、URL、Feed 标签；依据用户真实规则样本排序。
3. **临时屏蔽**：1 天/1 周/自定义到期，借鉴 Feedly 对热点疲劳的处理。[Feedly 时限](https://docs.feedly.com/article/104-can-i-change-the-duration-of-my-mute-filters)
4. **跨设备同步**：规则独立同步、按 `updatedAt` 合并，并验证 Mac/iPhone 离线编辑冲突。
5. **高级模式**：正则、AND/OR、保留规则，借鉴 Inoreader/FreshRSS/Miniflux；高级入口与普通关键词入口分离。
6. **智能关注而非智能屏蔽**：若引入 AI，优先用它建立可查看的 Focus/主题视图，避免 AI 静默隐藏文章。NewsBlur 的 Focus/Hidden 分层比直接删除更符合可控性。[NewsBlur Intelligence Training](https://newsblur.com/features/intelligence-training)

## 最终产品判断

**必要性判断：值得做，优先级为“近期小版本”，但不是阻塞核心阅读的 P0。**

理由：

- 用户已主动提出，证明不是纯竞品跟随；
- 专业 RSS 产品反复采用该能力，说明它能解决订阅规模扩大后的结构性噪声；
- PaperRss 已有 Feed、文件夹、本地持久化和预计算列表索引，实现一个安全 MVP 不需要引入服务器或 AI；
- 但过滤误伤的信任成本很高，所以交付标准必须包括预览、可撤销和命中解释，不能只交付一个关键词文本框。

建议对用户的承诺可以是：

> 你可以屏蔽不想看的关键词，并选择只作用于当前订阅、文件夹或全部订阅。文章不会被删除，可随时在“已屏蔽”中查看和恢复。
