# 更新记录 / Changelog

## v1.3.2-beta.3 · Build 20 · 2026-09-05

本次为未读筛选预发布版本；建议希望按文件夹或订阅源集中阅读未读文章的用户升级，稳定通道仍为 v1.3.1。

- 未读筛选：文章列表顶部新增过滤按钮，支持文件夹、单个订阅源和多选订阅源。
- 阅读连续性：切换订阅范围保持筛选，本轮点开后变为已读的文章继续留在列表；重启后默认显示全部。
- 导航一致性：分页、上一篇／下一篇和键盘导航遵循同一筛选范围，支持中英文提示与主题色。

---

This prerelease adds unread filtering within folders and feeds. Upgrade to try focused unread reading; the stable channel remains on v1.3.1.

- Unread filtering: Added a filter button above the article list for folders, individual feeds, and multiple selected feeds.
- Reading continuity: Keep the filter enabled when switching scopes and retain articles read during the current session. Restarting defaults to showing all articles.
- Consistent navigation: Pagination, previous/next actions, and keyboard navigation follow the same filter, with localized labels and theme colors.

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
