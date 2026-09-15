# PaperRss Issue #10：RSS 阅读器自定义外观与菜单架构调研

- **研究日期**：2026-08-23
- **关联需求**：[Issue #10 希望能增加更多外观自定义](https://github.com/ohmyangboy/PaperRss/issues/10)、[Issue #9 建议增加本地修改字体功能](https://github.com/ohmyangboy/PaperRss/issues/9)、`weekly.md` 的“字体设置”草案
- **仓库基线**：PaperRss `d670750b4e52198bf8ae779ce0f14192c3d9c074`，Swift Package 目标为 macOS 14
- **平台范围**：本轮只研究 macOS 主体验；不把 iOS、CloudKit 同步或发布流程纳入范围
- **文档性质**：研究结论，不是已批准规格；没有授权实现代码

## 0. 证据标记与版本边界

本文严格区分三类信息：

- **来源事实**：来自 Issue、当前仓库源码或产品/平台的一手文档。
- **工程推断**：基于来源事实为 PaperRss 作出的设计与架构建议，仍需维护者批准并通过实现验证。
- **未验证**：官方资料没有公开、版本过旧，或需要真实 App / 运行时才能确认的内容。

竞品功能会变化。本文只把检索日期前可在官方文档、官方源码、官方 App Store 发行说明中确认的能力列为来源事实；未用第三方评测补齐空白。

## 1. 执行摘要

### 结论

1. **不要把 Codex 外观面板整套复制到 PaperRss。** Codex 当前官方文档公开了 base theme、浅/暗/系统模式、强调色/背景色/前景色、UI/代码字体、半透明侧栏、contrast、主题导入/复制等能力，这是很好的“高级主题编辑器”参考；但 RSS 阅读器还存在文章排版这一条独立轴线。[OpenAI 官方 Settings 文档](https://developers.openai.com/codex/reference/settings)
2. **PaperRss 应明确分成“应用外观”和“阅读排版”两层，但都集中在 Settings > 外观。** 应用外观控制三栏、窗口 chrome、强调色和纸张底色；阅读排版控制文章字体、字号，后续再考虑行距、行宽。Apple 建议把全局、低频设置放进 Settings，把任务内经常调整的选项放在任务界面；竞品因此常提供 `Aa`，但维护者已明确要求阅读页面保持简洁，PaperRss 不在阅读器工具栏增加入口，仅保留现有字号快捷键。[Apple HIG：Settings](https://developer.apple.com/design/human-interface-guidelines/settings)
3. **MVP 只开放两个颜色输入：强调色与“纸张颜色”。** 前景色、侧栏、列表、边框、选择态、笔记卡片等由语义 token 派生；浅色和深色必须分别保存，不能简单反相。这样既满足 Issue #10，又避免让用户手工维护十几个相互依赖的颜色。
4. **MVP 保留现有 `AppTheme.system/light/dark`，但它只表达 color scheme。** 另设 `ThemeID`/palette ID 表达“纸张、清简、高对比、自定义”；不要把 `.custom` 塞进 `AppTheme`。系统跟随与主题风格是两种不同概念。
5. **MVP 将 Issue #9 的本机已安装文章字体纳入同一信息架构，但实现上与 Issue #10 分票。** UI 继续用系统字体；文章正文允许系统无衬线、系统衬线或本机已安装字体。只保存字体标识，不复制、同步或导出字体文件。Issue #9 点名的仓耳今楷 02-W04 / 03-W04 不在仓耳字库官方免费开源字体附件的 22 款清单中；其公开产品页只明确“个人非商业免费使用”，而官方又把“软/硬件嵌入”单列为需咨询的授权范围。因此在取得覆盖 macOS App 嵌入与再分发的权利人书面授权前，不得随 PaperRss 内置这两款字体。[仓耳今楷 02-W04](https://tsanger.cn/product/33)、[仓耳今楷 03-W04](https://tsanger.cn/product/38)、[仓耳免费开源字体授权声明及附件](https://tsanger.cn/107.html)、[仓耳商业授权](https://tsanger.cn/article/2)
6. **设置页保留即时预览，但预览必须覆盖三栏和文章，而不是只展示两段文字。** 浅/暗预览卡只用于比较，不应偷偷改变真实 App 模式；恢复动作应拆成“恢复当前主题”“恢复阅读排版”“恢复所有外观”。
7. **任意 CSS/HTML、字体文件导入、UI/代码字体、contrast 滑杆、半透明侧栏、主题分享/导入全部后置。** NetNewsWire 的 `.nnwtheme` 是文章 Reader 主题格式，不是 App UI 主题；FreshRSS 与 Miniflux 的官方资料也说明自由主题会带来兼容和维护成本。[NetNewsWire Themes technote](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Technotes/Themes.md)、[FreshRSS Theming](https://freshrss.github.io/FreshRSS/en/admins/11_Themes.html)、[Miniflux FAQ](https://miniflux.app/faq.html)

### 建议的一句话产品定义

> PaperRss 的外观系统是一组“成对的浅/暗应用主题”加一组独立的“文章阅读默认值”；Settings > 外观是唯一配置入口，阅读页面不新增工具栏控件，阅读时仅保留现有字号快捷键。

## 2. 需求证据

### 2.1 Issue 与 weekly

- **来源事实**：Issue #10 的用户原话是“如果背景色和强调色能够自定义就更好了”；维护者回复“自定义外观、修改字体功能等已在草案中，大致对标 codex app 的体验”。[Issue #10](https://github.com/ohmyangboy/PaperRss/issues/10)
- **来源事实**：Issue #9 希望使用本地字体，点名仓耳今楷 02W04/03W04；维护者回复本地字体“应该没啥问题”，内置字体仍需调研版权。[Issue #9](https://github.com/ohmyangboy/PaperRss/issues/9)
- **来源事实**：`weekly.md:23-25` 已记录“字体设置：支持阅读视图字体自定义”。
- **工程推断**：Issue #10 的验收核心应是“背景色 + 强调色”，字体是相邻需求，不宜把 UI 字体、代码字体、字体文件管理和完整文章主题市场一起塞进同一 MVP。

### 2.2 用户提供的视觉证据

- **来源事实**：用户提供的 PaperRss 截图显示，当前“外观”页已有模式分段控件、14/17/20/23pt 预设、13–25pt 滑杆和实时预览。
- **来源事实**：用户提供的 Codex 截图展示浅/暗主题分别编辑，字段包括强调色、背景、前景、UI 字体、代码字体、半透明侧栏和对比度，并提供导入、复制主题与主题选择。
- **工程推断**：值得借鉴的是“成对 variant、少量语义字段、预设和复制/导入的层级关系”；不应把 Codex 的开发工具专属字段直接搬进阅读器。

## 3. PaperRss 现状审计

### 3.1 已有能力

| 现状 | 来源事实 | 影响 |
|---|---|---|
| Settings 已有独立“外观”入口 | `PaperRss/Sources/App/SettingsView.swift:12-55` | 无需新增一级设置栏目 |
| 模式为 `system/light/dark` | `PaperRss/Sources/Core/AppStore.swift:6-28` | 可保留兼容；只表达 scheme |
| 模式与文章字号写入 `UserDefaults` | `AppStore.swift:169-174, 245-252, 1845-1860` | 新模型需迁移旧键 |
| 字号默认 17，范围 13–25，支持增减/重置 | `AppStore.swift:1851-1860` | 保留现有快捷键与行为 |
| Settings 有预设、滑杆和实时预览 | `SettingsView.swift:639-741` | 可演进，不必推翻 |
| 主视图和 Settings 都使用 `preferredColorScheme` | `RootView.swift:62-64`、`SettingsView.swift:99` | 系统/浅/暗模式已贯穿 SwiftUI 树 |
| Format/Text Formatting 命令已有 `⌘+`、`⌘-`、`⌘0` | `PaperRssApp.swift:45-65` | 保留为阅读时快速调字号的唯一入口，不另建状态或工具栏控件 |
| 字号已有 Core 测试 | `Tests/PaperRssCoreTests.swift:946-971` | 新模型可沿用纯策略测试思路 |

### 3.2 当前主题不是可配置系统

- **来源事实**：`PaperTheme.swift:9-55` 将 accent、warm accent、三种 surface 的浅/暗颜色、grain/fiber、note background/border 全部硬编码。
- **来源事实**：`RootView.swift`、`SettingsView.swift`、`ArticleReaderView.swift` 多处直接引用 `PaperTheme.accent`；部分设置控件又使用 `Color.accentColor`，目前不是单一 token 来源。
- **来源事实**：`ThreeColumnSplitView.swift:696-700` 直接按 `ColorScheme` 计算 `NSWindow.backgroundColor`；AppKit 窗口背景也是独立更新 seam。
- **来源事实**：文章 WKWebView 的 `paperArticleStyle` 另有一套硬编码浅/暗 CSS 变量，包括 `--paper-ink`、`--paper-accent`、`--paper-card`；它通过 `@media (prefers-color-scheme: dark)` 切换。`ArticleReaderView.swift:1186-1223`
- **来源事实**：macOS/iOS 两份 `documentHTML` 的 CSP 都是 `font-src 'none'`，且样式只允许 inline；当前仅注入 `--paper-font-size`。`ArticleReaderView.swift:4316-4324, 4921-4929`
- **工程推断**：一个颜色设置至少要贯穿三个投影：SwiftUI 语义颜色、AppKit window/background seam、WKWebView CSS variables。只把 `PaperTheme.accent` 改成可变值会造成主题“半生效”。
- **工程推断**：新的纯数据模型不应继续把 SwiftUI `ColorScheme` 放在 Core。当前 `AppStore.swift` 引入 SwiftUI 且 `AppTheme.colorScheme` 返回 UI 类型，与仓库“Core 不依赖 SwiftUI/AppKit/UIKit”的原则存在张力；新配置应使用纯 Foundation 值，UI 投影移到 App。

### 3.3 当前实时预览有真实性缺口

- **来源事实**：预览用 SwiftUI 的 `.primary/.secondary` 和 `.system(... design: .serif)` 绘制，不复用文章 WKWebView 的 CSS 字体、line-height、标题栈或颜色变量。`SettingsView.swift:716-740`
- **工程推断**：当前预览只能验证字号趋势，不能证明自定义主题、文章字体、链接、选中态、列表/侧栏在真实阅读器中一致。
- **建议**：建立共同的 typed theme/reader style 输入；预览与真实界面使用同一个 resolver，而不是复制第二套颜色常量。

## 4. 竞品与平台一手证据矩阵

| 对象与证据边界 | 已验证做法 | 对 PaperRss 的可用启发 | 不应外推的内容 |
|---|---|---|---|
| **Codex / ChatGPT desktop 当前官方 Settings 文档，检索 2026-08-23** | base theme；Light/Dark/System；浅暗主题分别有 accent/background/foreground、UI/code font、translucent sidebar、contrast；支持分享自定义主题，页面示例含 Import/Copy theme | 浅暗成对、主题预设、少量语义输入、进阶能力后置 | contrast 数字的算法、导入文件格式、同步/安全校验均未公开；不能推测 |
| **NetNewsWire `main` 的 Themes technote，检索 2026-08-23** | `.nnwtheme` 包含 `Info.plist`、`template.html`、`stylesheet.css`；可用 URL scheme 导入 zip | Reader 主题可独立于 App 外壳；主题包必须有 ID/名称/作者/版本 | 这是文章渲染主题，不证明 NetNewsWire 支持 App 全局 palette 编辑；不适合作为 PaperRss MVP App 主题格式 |
| **Readwise Reader 当前官方 Appearance FAQ，检索 2026-08-23** | Web 的 `Aa`、移动端 `... > Appearance`；typeface、14–80px 字号、行距、Web 行宽；Light/Dark/Auto；部分方向/分页按文档设置 | 证明上下文入口是行业模式；PaperRss 因沉浸式阅读目标明确不采用，只借鉴全局默认与文档级选项分层 | 没有证据说明其支持任意 App 背景/强调色或本地字体 |
| **Reeder Classic 5.3.1/5.3.2 官方 App Store 发行说明（2022）** | Settings > Appearance 提供 UI font style 预设；文章 viewer 可选择任何已安装字体；Settings > Reading 可开 colored links | UI 字体与 Reader 字体应分开；本机字体选择是成熟做法 | 证据针对 Reeder Classic 5.x，不代表 2026 新 Reeder；无当前任意配色证据 |
| **Inoreader v13 官方发布文（2020）及 Sepia 官方文（2021）** | 文章 text preferences bar 将居中/左对齐/全宽与字号移到阅读上下文；全局有主题，Sepia 可从 Profile/footer 快速切换 | 阅读布局靠近内容；主题可用预设降低复杂度 | 资料较旧，2026 当前菜单与权限未验证；不把 custom CSS 当默认用户路径 |
| **FreshRSS `edge` 官方 Configuration/Theming，检索 2026-08-23** | 官方文档列出 13 个主题；内容宽度有 550/800/1000/无限；小修改建议 CustomCSS；个人主题可能更新时被覆盖 | 预设 + 少量阅读宽度比暴露全部 CSS 更友好；自由主题有兼容成本 | Web/self-hosted 的 CSS 扩展能力不应直接移植到沙箱化原生 App |
| **Miniflux 当前官方 README/FAQ/API，检索 2026-08-23** | 内置 System/Light/Dark × Sans/Serif 组合；用户模型有 theme/stylesheet；FAQ 明确不加载外部 stylesheet，官方主题需维护，插件系统会增加复杂度 | “模式 × 字体类别”的少量组合可覆盖多数需要；克制范围本身是产品策略 | Web 自定义 stylesheet 与原生 App token 系统安全边界不同 |

### 4.1 Codex：借鉴结构，不复制字段

- **来源事实**：官方文档明确写出 base theme、accent/background/foreground、UI/code fonts 与分享主题；页面同时展示浅色和深色 variant、透明侧栏与 contrast。[OpenAI Settings](https://developers.openai.com/codex/reference/settings)
- **工程推断**：PaperRss 可采用相同的 `ThemeID -> light/dark variants` 结构，但 MVP 只让用户编辑 accent 和 paper/background。foreground、sidebar、list、divider 通过 resolver 派生。
- **未验证**：Codex 的 contrast `45/60` 不是公开的 WCAG 比率，不应照搬成 PaperRss 的 0–100 滑杆。

### 4.2 NetNewsWire：Reader theme 是第二阶段的不同产品面

- **来源事实**：NetNewsWire 的文章主题同时允许 HTML 模板与 CSS，并要求元数据；URL scheme 导入的是 zip 后的 `.nnwtheme`。[官方 Themes technote](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Technotes/Themes.md)
- **来源事实**：本地官方源码快照还显示 `ArticleThemesManager` 负责安装、选择、删除和降级到默认主题，`ArticleRenderer` 才消费主题；App 外壳没有因此变成任意颜色编辑器。
- **工程推断**：如果 PaperRss 未来支持社区 Reader 主题，应另立 reader theme contract；不应让一份任意 CSS 同时控制 SwiftUI/AppKit 外壳。

### 4.3 Readwise / Reeder / Inoreader：上下文入口是行业模式，但 PaperRss 不采用

- **来源事实**：Readwise 将字体、字号、行距、行宽直接放进阅读器 Appearance panel，并提供键盘快捷键；Light/Dark/Auto 也可从 Appearance 切换。[Readwise Appearance](https://docs.readwise.io/reader/docs/faqs/appearance)
- **来源事实**：Reeder Classic 官方发行说明把 UI font style 放在 Settings > Appearance，把 installed font chooser 与 colored links 放在文章阅读能力中。[Reeder Classic App Store](https://apps.apple.com/us/app/reeder-classic/id1529448980?mt=12&platform=iphone)
- **来源事实**：Inoreader v13 官方说明将文章宽度和字号从深层 Preferences 移到文章 text preferences bar。[Inoreader v13](https://www.inoreader.com/pl/blog/2020/01/inoreader-v13-is-here-with-improved-looks-and-new-features.html)
- **维护者决策**：PaperRss 了解上述上下文入口模式，但为了保持阅读页面简洁，不在阅读器工具栏增加 `Aa`、主题、字体或“外观设置…”入口。
- **工程推断**：PaperRss 设置页保存“用于所有文章”的默认值；现有 `⌘+`、`⌘-`、`⌘0` 只调整同一字号状态。每订阅/每文章 override 暂不进入 MVP。

### 4.4 FreshRSS / Miniflux：自由扩展的真实成本

- **来源事实**：FreshRSS 官方文档提供大量内置主题，并明确个人主题可能被升级覆盖，建议小改动使用 CustomCSS。[FreshRSS Configuration](https://github.com/FreshRSS/FreshRSS/blob/edge/docs/en/users/05_Configuration.md)、[FreshRSS Theming](https://freshrss.github.io/FreshRSS/en/admins/11_Themes.html)
- **来源事实**：Miniflux FAQ 说明外部 stylesheet 不加载、官方主题必须持续维护；不做插件系统的理由包括复杂度和维护者流失。[Miniflux FAQ](https://miniflux.app/faq.html)
- **工程推断**：任意 CSS 不是“免费高级功能”，而是长期兼容与安全承诺。PaperRss MVP 应只接受 typed tokens。

## 5. Apple 平台约束

### 5.1 Settings 的位置与频率

- **来源事实**：Apple 建议给大多数人提供良好默认值、尽量减少设置项；全局且不常变的设置放 Settings，特定任务的选项尽量靠近任务。macOS 应从 App menu 的 Settings / `⌘,` 打开，设置导航应稳定，并恢复上次 pane。[Apple HIG：Settings](https://developer.apple.com/design/human-interface-guidelines/settings)
- **维护者决策**：主题配色、文章字体和默认字号都留在 Settings > 外观；阅读器工具栏不新增任何外观入口。
- **工程推断**：阅读时的字号微调继续使用现有 `⌘+`、`⌘-`、`⌘0`。不要新建顶级“主题”菜单、View/Appearance 子菜单，也不要把 ColorWell 放进主工具栏。

### 5.2 浅色、深色与系统跟随

- **来源事实**：Apple 说明用户预期 App 尊重 Dark Mode，Dark Mode 是动态外观；自定义颜色需要在浅色、深色和增强对比度环境都工作。[Apple HIG：Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)、[Apple HIG：Color](https://developer.apple.com/design/human-interface-guidelines/color)
- **工程推断**：每个 `ThemeID` 必须有 light/dark 两个 variant；`system` 决定当前取哪个 variant。不能把浅色 RGB 简单求反得到深色，也不能只让用户编辑当前模式而留下另一模式不可用。

### 5.3 对比度与不只靠颜色

- **来源事实**：Apple Accessibility Inspector 以 WCAG AA 为参考：17pt 及以下普通文字至少 4.5:1；18pt 或粗体至少 3:1；Dark Mode 两套都要检查。[Apple HIG：Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility/)
- **来源事实**：Apple 要求不要仅靠颜色表达状态，并建议用灰度测试；SwiftUI 提供 `accessibilityDifferentiateWithoutColor` 环境值。[Apple Differentiate Without Color](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/differentiate-without-color-alone-evaluation-criteria)、[SwiftUI EnvironmentValues](https://developer.apple.com/documentation/swiftui/environmentvalues)
- **工程推断**：自定义强调色不能成为选中、未读、错误状态的唯一差异；现有未读圆点可以保留形状，选中行还要有背景/边框/字重变化。Color editor 应实时显示“正文/背景”“强调色/背景”的结果和警告。
- **建议门槛**：MVP 不允许保存透明背景色；正常文字低于 4.5:1 或非文字状态低于 3:1 时至少强警告。内置“高对比”主题必须默认达标，并响应系统 Increase Contrast。

### 5.4 Reduce Transparency

- **来源事实**：SwiftUI 的 `accessibilityReduceTransparency == true` 时，主要窗口背景应不透明。[Apple `accessibilityReduceTransparency`](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducetransparency)
- **工程推断**：Codex 的“半透明侧栏”不进入 PaperRss MVP。若后续加入，必须是材料策略而非颜色 alpha，并在 Reduce Transparency 时强制落到不透明 surface。

### 5.5 字体可用性、版权与沙箱

- **来源事实**：`NSFontManager` 可列出系统可用字体/字体家族，并能打开标准 Font panel。[Apple NSFontManager](https://developer.apple.com/documentation/appkit/nsfontmanager)
- **来源事实**：Apple Typography 建议减少字体数量、保证自定义字体可读，并让自定义字体支持相当的辅助功能；系统字体应通过系统 API 使用，不应嵌入 App。[Apple HIG：Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- **来源事实**：Apple 技术上支持把自定义字体文件加入 macOS App bundle，并明确把前提写成“licensed font”；macOS target 可通过 `ATSApplicationFontsPath` 指向 Resources 中的字体目录。这只证明实现可行，不提供第三方字体授权。[Apple：Applying custom fonts to text](https://developer.apple.com/documentation/swiftui/applying-custom-fonts-to-text)、[Apple：ATSApplicationFontsPath](https://developer.apple.com/documentation/bundleresources/information-property-list/atsapplicationfontspath)
- **来源事实**：Font Book 安装字体时会验证字体；导出字体前 Apple 明确要求检查字体 License 的 Usage 信息。[Font Book：安装与验证](https://support.apple.com/en-ca/guide/font-book/fntbk1000/mac)、[Font Book：导出](https://support.apple.com/en-ca/guide/font-book/fntbk1014/mac)
- **来源事实**：仓耳今楷 02-W04 与 03-W04 的官方产品页均写明“本站所有字体均可免费下载，允许个人非商业免费使用”，同时提供“商业授权”购买项；公开列出的全媒体、广告、新媒体、Logo、包装、书刊、影视、官网/店铺等用途没有写明可把字体文件嵌入软件或随软件再分发。[02-W04 官方产品页](https://tsanger.cn/product/33)、[03-W04 官方产品页](https://tsanger.cn/product/38)
- **来源事实**：仓耳官方商业授权表把“软/硬件嵌入”作为独立授权范围，用途为“单个软件或硬件设备的嵌入使用”，价格栏不是普通商业发布套餐，而是要求致电咨询。故购买字体、个人使用权或“单一公司全媒体”等设计/发布授权，均不能据此推定包含 App 内嵌和字体二进制再分发。[仓耳商业授权](https://tsanger.cn/article/2)
- **来源事实**：仓耳免费开源字体许可只适用于附件指定的 6 套 22 款字体；该许可确实允许复制、嵌入、修改和再分发，但附件清单仅含周珂正大榜书、小丸子、渔阳体 W01–W05、与墨 W01–W05、舒圆体 W01–W05、非白 W01–W05，**不含仓耳今楷 02-W04 或 03-W04**。不能把这份免费许可外推到官网其他可下载字体。[仓耳免费开源字体授权声明及官方 PDF 附件](https://tsanger.cn/107.html)
- **来源事实**：即便申请主体是依法登记的非营利公益组织，仓耳官方公益声明仍要求 APP 嵌入先获得其邮件确认；该声明不自动适用于普通个人开发者、开源项目或商业发行。[仓耳免费授权公益组织使用字库声明](https://tsanger.cn/109.html)
- **来源事实**：若未来让用户选择字体文件，`NSOpenPanel` 会给沙箱 App 所选文件访问权限；Core Text 可按 process/session/persistent scope 注册字体。[Apple NSOpenPanel](https://developer.apple.com/documentation/appkit/nsopenpanel)、[CTFontManagerScope](https://developer.apple.com/documentation/coretext/ctfontmanagerscope)
- **工程推断**：MVP 只选择用户已经安装且 App 可见的字体，不复制字体二进制，因此不发生“由 PaperRss 把字体随 App 再分发”；但“已安装”“免费下载”“已购买”都不等于 PaperRss 获得嵌入或再分发授权。主题复制/导出只保存 PostScript/family 标识，不包含字体文件。
- **授权结论**：当前官方公开资料不足以授权 PaperRss 打包仓耳今楷 02-W04 / 03-W04。除非取得北京仓耳文字技术有限公司的书面授权，明确覆盖具体字款、macOS App 字体文件嵌入、PaperRss 的实际发行渠道和再分发范围，否则不得把字体二进制放入 App bundle、公开源码仓库、安装包、主题包或更新包。Apple 提供字体注册能力不构成字体版权许可。
- **未验证**：本机安装字体在当前 WKWebView + `font-src 'none'` CSP 下通过普通 `font-family` 解析的实际行为，需要真实 macOS 运行测试。字体文件导入会涉及 CSP、文件持久化和注册生命周期，必须另做安全与许可研究。

## 6. 推荐信息架构与菜单

### 6.1 Settings > 外观：唯一外观配置入口

建议继续使用当前左侧“外观”栏目，内容按以下顺序纵向排列：

```text
外观
├─ 界面模式
│  └─ [跟随系统] [浅色] [深色]
├─ 主题
│  ├─ 主题预设：纸张 / 清简 / 高对比 / 自定义
│  ├─ 浅色主题：强调色、纸张颜色
│  └─ 深色主题：强调色、纸张颜色
├─ 阅读排版
│  ├─ 文章字体：系统默认 / 系统衬线 / 本机字体…
│  └─ 正文字号：保留 14/17/20/23pt 与 13–25pt 微调
├─ 实时预览
│  └─ 三栏 + 文章，浅/暗并排或切换预览
└─ 恢复
   ├─ 恢复当前主题
   ├─ 恢复阅读排版
   └─ 恢复所有外观
```

#### 关键规则

- **工程推断**：`界面模式` 与 `主题` 必须是两行，不能把“系统/浅/暗/自定义”混成一个枚举。
- **工程推断**：三个内置 `ThemeID` 都带浅/暗配对：
  - `paper` / 纸张：精确保留当前 PaperRss 默认视觉，确保升级无惊讶。
  - `clean` / 清简：中性、低纹理、接近 Codex 的克制外观，但仍是 PaperRss 自有设计。
  - `high-contrast` / 高对比：满足增强对比度场景。
- **工程推断**：选择内置主题后再改颜色，应自动创建/切换为“自定义（基于纸张/清简/高对比）”，不要静默改坏内置 preset。
- **工程推断**：设置页只开放 accent 和 paper/background。foreground、sidebar/list surfaces、divider、selection、note、warm accent 都由 semantic resolver 生成。
- **工程推断**：浅/暗预览不会改 `appTheme`；只有模式分段控件会改变真实 App 当前 scheme。

### 6.2 阅读页面：保持零新增入口

- **维护者决策**：文章工具栏保持当前结构，不新增 `Aa`、主题、字体或“外观设置…”控件。
- **产品理由**：阅读页面的首要目标是沉浸和内容聚焦；外观定制是全局偏好，不应持续占用文章工具栏空间。
- **工程推断**：主题、文章字体和默认字号全部由 Settings > 外观管理；阅读时需要临时调字号的用户继续使用现有菜单命令和快捷键，不再维护第二套 UI 或状态。
- **后续约束**：即使后续增加行距、行宽、标题/正文字体分离或每 Feed override，也默认先进入 Settings；除非维护者重新批准，否则不借机增加阅读器入口。

### 6.3 macOS 菜单与快捷键

- 保留 App menu > Settings… / `⌘,` 作为总入口。
- 保留现有放大、缩小、默认正文字号命令与 `⌘+`、`⌘-`、`⌘0`，继续调用同一 `AppStore` action。
- 不新增顶级 Theme 菜单或 View/Appearance 子菜单；主题和字体选择统一进入 Settings > 外观。
- 所有可点击色块必须有文本名称/HEX、键盘焦点与 VoiceOver label；当前选中主题不能只靠描边颜色表示。

## 7. 推荐 MVP 与阶段拆分

### 7.1 MVP：Issue #10 外观基础

1. 建立版本化、纯 Foundation 的 `AppearancePreferences`，迁移现有 scheme 与字号。
2. 保留 `AppTheme.system/light/dark` 语义；增加独立 `ThemeID`。
3. 内置“纸张/清简/高对比”浅暗配对主题。
4. 自定义主题仅开放两套 variant 的 accent + paper/background，alpha 固定 1。
5. 建立 AppAppearanceResolver，将输入派生成完整 SwiftUI/AppKit semantic tokens。
6. 建立 ReaderStyleResolver，将 Reader scheme/主题映射成受控 CSS variables；Reader 可跟随 scheme，但不强制与 App shell 使用同一 palette。
7. 设置页三栏 + 文章即时预览；支持分范围恢复和标准 Undo。
8. 保持文章工具栏结构不变；复用现有正文字号菜单命令与快捷键，不新增外观入口。

### 7.2 相邻 MVP：Issue #9 本机文章字体

建议在同一外观页呈现，但保留独立实现 ticket：

1. 只列举 App 可见的本机字体；提供系统默认与系统衬线快速项。
2. 只修改文章正文；标题继续使用 PaperRss 的层级字体，UI 继续系统字体。
3. 持久化 PostScript name、family name、display name；缺失时回退，但保留用户原选择，字体重新安装后可自动恢复。
4. 不同步字体文件，不将字体文件塞进主题导出。
5. 在中英文、Emoji、代码块、粗体/斜体、缺字 fallback 上做真实文章验证。

### 7.3 Phase 2：阅读舒适度

- 行距预设、文章行宽预设、正文/标题字体分离。
- 每订阅 override 与“恢复为全局默认”。
- 高对比 resolver、Reduce Transparency 策略完善。
- 颜色编辑的对比度说明与自动修复建议。

### 7.4 Phase 3：可移植主题

- 版本化、白名单 JSON 主题导入/导出、导入前预览、冲突处理。
- 只导出 theme metadata、sRGB colors、reader style ID、字体标识；不含字体文件、账户、凭据、订阅或同步信息。
- 未安装字体显示明确 fallback，不静默替换并覆盖原选择。
- 主题 schema 稳定后再考虑“复制主题”。

### 7.5 明确不在近期范围

- 任意 CSS/HTML/JS、远程 URL 主题安装、插件系统。
- UI font、code font、字体文件打包/跨设备分发。
- 不透明度颜色、背景图片、动态主题、主题市场。
- Codex 式未知语义的 contrast 数字滑杆。
- 将 appearance 自动写入 CloudKit 或账号同步。

## 8. 数据模型草图

以下是**工程推断**，用于明确契约，不是实现代码：

```swift
// Core / Foundation only
struct AppearancePreferences: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var scheme: AppSchemePreference       // system / light / dark
    var activeAppThemeID: ThemeID         // paper / clean / highContrast / custom UUID
    var customThemes: [ThemeDefinition]
    var reader: ReaderAppearancePreferences
}

struct ThemeDefinition: Codable, Equatable, Sendable {
    var id: ThemeID
    var name: String
    var basedOn: ThemeID?
    var light: ThemeVariant
    var dark: ThemeVariant
}

struct ThemeVariant: Codable, Equatable, Sendable {
    var accent: SRGBColor                 // typed RGBA, MVP requires alpha == 1
    var paper: SRGBColor
}

struct ReaderAppearancePreferences: Codable, Equatable, Sendable {
    var theme: ReaderThemePreference      // inherit / paper / clean / highContrast
    var bodyFont: ReaderFontChoice
    var fontSizePoints: Int               // existing 13...25
}

enum ReaderFontChoice: Codable, Equatable, Sendable {
    case systemSans
    case systemSerif
    case installed(postScriptName: String, familyName: String, displayName: String)
}
```

### Resolver 边界

```text
AppearancePreferences
├─ AppAppearanceResolver (App target)
│  ├─ SwiftUI semantic colors/materials
│  └─ AppKit NSWindow background / under-page background
└─ ReaderStyleResolver (App target)
   └─ validated WKWebView CSS variable payload
```

- **工程推断**：Core 只存 sRGB 数值/HEX 和语义 enum，不存 `SwiftUI.Color`、`ColorScheme`、`NSColor` 或 CSS 字符串。
- **工程推断**：App resolver 派生 `page/articleList/sidebar/chrome/foreground/muted/divider/selection/note`，调用方不自己混色。
- **工程推断**：Reader resolver 独立，是因为文章阅读主题可能跟随 scheme，却不一定继承 App shell 的所有 palette。例如用户可能想要中性侧栏 + sepia 文章。
- **工程推断**：不要让 `PaperTheme` 变成可变全局单例；它应成为可测试的 resolved value/environment projection。

### 迁移与损坏数据

1. 读取新的 versioned Codable Data key；不存在时，用旧 `PaperRss.appTheme` 与 `PaperRss.articleFontSize` 合成新默认。
2. 兼容期写新 key，同时双写旧 theme/font-size key，便于旧版本回退；何时停止双写需单独版本决策。
3. 未知 schema 或损坏 Data 时，不删除原数据；记录可诊断但不含私人信息的错误，运行时回退内置 Paper 默认。
4. 未知 `ThemeID` 回退 `paper`；缺失字体回退 system sans，但保留 installed font 标识。
5. appearance 继续是本机 preference，不进入 `AppDatabase`/CloudKit，除非未来单独授权同步策略。

## 9. 交互规则

### 9.1 即时预览、提交与 Undo

- 主题、字体、字号的有效变更即时投影到预览和真实 App。
- 连续 ColorWell/Slider 拖动只生成一个 Undo transaction；`Esc` 或取消颜色面板恢复拖动前值。
- 选择内置主题、恢复默认是可撤销操作，不弹阻断确认框。
- 自定义颜色先通过 typed validator，再进入 resolver；无效 HEX、NaN、透明色不得进入持久化。
- “浅色预览/深色预览”只改变 preview environment，不改变用户选择的真实 `scheme`。

### 9.2 恢复范围

- **恢复当前主题**：恢复当前 ThemeID 的 palette；如果是 custom，恢复到 `basedOn` preset。
- **恢复阅读排版**：正文 system sans、17pt、reader theme 跟随应用。
- **恢复所有外观**：scheme 跟随系统、Paper preset、默认阅读排版。
- 每个动作都应可 Undo，并用可访问的非颜色反馈说明结果。

### 9.3 运行时更新

- SwiftUI：environment/resolved theme 变更后重绘。
- AppKit：同步 `NSWindow.backgroundColor` 与 WKWebView `underPageBackgroundColor`，避免滚动边缘露出旧色。
- WKWebView：增量更新 CSS variables，避免 `reload`；重载会丢失滚动位置、选区、翻译状态、TOC 状态和临时交互。
- CSS 变量值通过 typed arguments/JSON 安全传递，不拼接用户输入到 JavaScript 字符串。
- 字体/字号/主题更新复用同一 update seam；若更新影响布局，要保留当前阅读 anchor。

### 9.4 字体 fallback

- 选择字体前用真实示例预览中文、英文、数字和 Emoji。
- 某 family 缺少 bold/italic 时，resolver 使用系统 fallback，不伪造不存在的 face。
- 缺字按受控 fallback stack 处理；显示名称与 PostScript name 分开保存。
- 不把本机字体存在性当作许可证授权结论。

## 10. 安全、隐私与导入/导出边界

### MVP 为什么禁止任意 CSS/HTML

- **来源事实**：PaperRss 当前 Reader CSP 允许文章图片从 `http/https/data/blob` 加载、允许 inline style、禁止 script 和 font source。
- **工程推断**：即使 `script-src 'none'`，任意 CSS 仍可使用 `background-image: url(...)` 触发外部请求，也能隐藏/覆盖 DOM、破坏 TOC/翻译/选区和文章可读性。
- **工程推断**：允许主题修改 HTML 模板会把 NetNewsWire 级别的长期渲染 contract、安全验证和兼容维护一并引入，不符合 Issue #10 的最小目标。

### 未来 JSON 主题的安全边界

- 只接受固定 schema、固定字段、大小上限、sRGB 范围和已知 enum。
- 禁止 URL、CSS、HTML、JavaScript、文件路径、书签数据和二进制字体。
- 导入先展示浅/暗预览、来源 metadata、缺失字体和对比度问题，再由用户确认。
- ID 冲突提供“替换副本/另存副本”，默认不静默覆盖。
- 导出不包含 API key、账号、Feed、阅读历史、同步状态或本机绝对路径。
- 不提供网络 URL 自动安装；如未来增加，需要另做下载大小、签名、重定向、MIME、解压路径穿越和撤销机制设计。

## 11. 风险清单

| 风险 | 证据/原因 | 缓解 |
|---|---|---|
| 主题只在部分区域生效 | SwiftUI、AppKit、WKWebView 现有三套 seam | typed config + 两个 resolver + window update contract |
| 自定义背景导致正文不可读 | `.primary` 与 Paper CSS ink 目前独立 | foreground 由 resolver 派生；浅暗/高对比自动测试 |
| 预览与实际不一致 | 当前预览不复用 Reader CSS | 共用 resolver，加入三栏与真实文章状态样本 |
| 颜色成为唯一状态提示 | 未读/选中大量使用 accent | 同时使用形状、背景、边框、字重/图标 |
| 主题切换破坏阅读上下文 | WebView reload 会丢状态 | CSS variables 增量更新并保 anchor |
| 本机字体缺失或缺字 | 字体可被卸载，CJK family 覆盖不一 | 保存标识、运行时 fallback、保留原选择 |
| 字体许可被误解 | 仓耳今楷 02/03-W04 的公开条款只明确个人非商业免费；官方把软件嵌入单列，免费开源附件又不含这两款 | 默认只引用本机已安装字体；未取得覆盖 App bundle 与发行渠道的权利人书面授权前，不内置、不入仓库、不随主题/安装包/更新包分发 |
| raw CSS 产生隐私请求 | CSS URL 不需要脚本 | MVP 禁止 raw CSS/HTML/URL |
| 新模型破坏旧设置 | 旧值分散在两个 UserDefaults key | versioned migration、兼容期双写、损坏数据不删除 |
| “高对比”只是名字 | 自定义 token 可能忽略系统设置 | Increase Contrast/Reduce Transparency/灰度真实验证 |
| iOS 被误报支持 | Package 主目标 macOS 14，但文件含 iOS 分支 | 本轮只声明 macOS；共享 CSS 改动仍做编译/契约核对 |

## 12. 验证计划

### 12.1 Core / 纯策略

- 新旧 preference 迁移：system/light/dark、13/17/25 边界、缺失键、损坏 Data、未知 schema。
- sRGB 解析、alpha 禁止、ThemeID fallback、custom `basedOn`。
- light/dark variant 解析，不允许简单反相或缺少一侧。
- 对比度计算与内置 Paper/Clean/High Contrast snapshot。
- installed font 缺失 fallback 且原标识保留。
- 导出 schema 白名单（仅在 Phase 3）。

### 12.2 Reader CSS contract

- resolver 只输出允许的 CSS variable 名和值。
- accent/paper/font/size 更新不产生可执行 CSS、URL 或 HTML。
- macOS WebView 增量更新后滚动 anchor、选区、翻译、TOC、摘要卡状态不丢。
- `underPageBackgroundColor` 与文章 surface 同步。
- 中英文、RTL 片段、代码块、表格、图片、链接、选中态、错误卡在所有内置主题中可读。

### 12.3 Tier 3：真实 macOS GUI

按仓库原则，外观功能涉及 `PaperRss/Sources/App/`，实现后必须：

1. 运行匹配影响面的自动化测试与 CSS/治理契约测试。
2. 完成 macOS 宿主编译。
3. 用 `./scripts/dev.sh` 启动真实 Dev App。
4. 实际操作 Settings、ColorWell、主题/模式、现有字号快捷键、恢复与 Undo，并确认文章工具栏没有新增外观入口。
5. 检查三栏、窗口边缘、滚动、全屏、现有 popover、Reader 内容和设置窗口。
6. 在 Light/Dark/System、Increase Contrast、Reduce Transparency、Differentiate Without Color、灰度、VoiceOver、Full Keyboard Access 下复测。
7. 若 Agent 无法真正点击或观察 GUI，报告 **Manual UI verification required**，不能以进程启动代替视觉验证。

### 12.4 视觉样本矩阵

| 维度 | 最少样本 |
|---|---|
| Scheme | Light / Dark / System 两次切换 |
| Theme | Paper / Clean / High Contrast / Custom |
| 自定义 | 极浅背景、极深背景、低对比 accent、CJK 字体、缺失字体 |
| 视图 | Sidebar / Article list / Reader / Settings / Popover / Full screen |
| 状态 | 未读、选中、收藏、错误、链接、代码、选区、AI 卡片、TOC |
| 辅助功能 | Increase Contrast / Reduce Transparency / Differentiate Without Color / Grayscale |

## 13. 未决问题

### 需维护者产品决策

1. “清简”是否作为 Codex-like 内置 preset 上线，还是 MVP 只做 Paper + High Contrast + Custom？
2. Reader 主题默认是否完全跟随 App ThemeID，还是只跟随 scheme、保留独立 Paper reader palette？本文建议后者，以免 App 外壳偏好绑架长文阅读。
3. 文章字体/字号在 MVP 是全局默认，还是允许每 Feed override？本文建议先全局；无论采用哪种范围，都不在阅读器工具栏增加入口。
4. 主题颜色是否允许输入 HEX，还是只使用原生 ColorWell？建议两者共用同一 validated value。
5. 自定义主题数量是只保留一个，还是支持多个命名主题？本文数据模型允许多个，但 MVP UI 可先只维护一个 custom slot。
6. 是否需要在设置页同时显示浅/暗预览，还是使用切换器？窄窗口下需要真实原型比较。

### 需工程验证

1. 当前 WKWebView 在 `font-src 'none'` 下对本机已安装字体 `font-family` 的解析行为。
2. `preferredColorScheme` 变化是否稳定触发 WKWebView 的 `prefers-color-scheme`，以及 AppKit window background 更新时序。
3. 不 reload 的 CSS variable 更新如何覆盖所有现有 Reader 状态并保持 anchor。
4. `NSFontManager.availableFontFamilies` 与 WKWebView 可实际使用的 font family 集合是否一致。
5. 自定义主题变更时 PaperGrain/Canvas 重绘的性能影响。
6. macOS 14 下 ColorWell、UndoManager、Settings window 最后 pane 恢复的最终交互实现。

### 需权利人书面确认后才能内置字体

若维护者仍希望把仓耳今楷 02-W04 或 03-W04 随 PaperRss 分发，应通过[仓耳官网商业授权渠道](https://tsanger.cn/article/2)取得可留档的书面授权，并至少确认：

1. 精确授权字款与文件版本：02-W04、03-W04，还是其中之一。
2. 是否允许把完整字体文件或子集嵌入一个 macOS App；是否允许格式转换、subset、压缩或混淆。
3. 是否允许通过 PaperRss 实际采用的 GitHub Releases、Homebrew、Mac App Store、自动更新等渠道向最终用户再分发；公开源码仓库是否必须排除字体文件。
4. 授权主体、产品数量（官方表述为“单个软件”）、地域、期限、版本升级、免费/收费发行与衍生版本边界。
5. App 内须附带的版权声明、许可文本、品牌标注，以及授权终止后的存量版本与更新处理。

在收到书面答复前，上述问题均为**未授权/未验证**，不能用“已购买字体”“个人可免费下载”“开源项目”或 Apple 技术上支持字体注册来替代。

### 仍未验证的竞品事实

- Codex 主题导入格式、主题存储位置、跨设备同步与 contrast 算法没有官方公开证据。
- 新 Reeder（非 Reeder Classic）在 2026 年的字体/配色菜单没有足够官方证据。
- Inoreader 2020/2021 的菜单在 2026 当前版本是否原样保留未验证。
- NetNewsWire `.nnwtheme` 的完整安全审计与远程导入防护不在本轮范围。

## 14. 建议的下一步

1. 维护者先确认第 13 节六个产品决策，尤其是 Reader 是否独立 palette 与 custom theme 数量。
2. 基于本研究写 Issue #10 的 accepted spec 候选，只覆盖 palette foundation、设置 IA、预览、恢复、现有字号快捷键复用与“文章工具栏零新增入口”回归约束。
3. Issue #9 单独写字体实现 ticket，共用 `ReaderAppearancePreferences`，不把字体二进制导入塞进首版。
4. 在实现前做一个仅验证 resolver + 三栏/Reader 预览的低成本原型，确定窄设置窗口里的浅暗配对布局。
5. 主题分享/导入在 schema 与迁移至少稳定一个版本后再研究。

## 15. 一手来源索引

- [OpenAI：Codex / ChatGPT desktop Settings](https://developers.openai.com/codex/reference/settings)
- [Apple HIG：Settings](https://developer.apple.com/design/human-interface-guidelines/settings)
- [Apple HIG：Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)
- [Apple HIG：Color](https://developer.apple.com/design/human-interface-guidelines/color)
- [Apple HIG：Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility/)
- [Apple HIG：Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- [Apple：Differentiate Without Color Alone](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/differentiate-without-color-alone-evaluation-criteria)
- [Apple：SwiftUI EnvironmentValues](https://developer.apple.com/documentation/swiftui/environmentvalues)
- [Apple：NSFontManager](https://developer.apple.com/documentation/appkit/nsfontmanager)
- [Apple：Applying custom fonts to text](https://developer.apple.com/documentation/swiftui/applying-custom-fonts-to-text)
- [Apple：ATSApplicationFontsPath](https://developer.apple.com/documentation/bundleresources/information-property-list/atsapplicationfontspath)
- [Apple：NSOpenPanel](https://developer.apple.com/documentation/appkit/nsopenpanel)
- [Apple：CTFontManagerScope](https://developer.apple.com/documentation/coretext/ctfontmanagerscope)
- [Apple Font Book：安装与验证字体](https://support.apple.com/en-ca/guide/font-book/fntbk1000/mac)
- [Apple Font Book：导出字体与许可证提醒](https://support.apple.com/en-ca/guide/font-book/fntbk1014/mac)
- [仓耳今楷 02-W04：官方产品与商业授权页](https://tsanger.cn/product/33)
- [仓耳今楷 03-W04：官方产品与商业授权页](https://tsanger.cn/product/38)
- [仓耳字库：商业授权范围（“软/硬件嵌入”单列）](https://tsanger.cn/article/2)
- [仓耳字库：免费开源字体授权声明及 22 款附件清单](https://tsanger.cn/107.html)
- [仓耳字库：免费授权公益组织使用字库声明](https://tsanger.cn/109.html)
- [NetNewsWire：Themes technote](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Technotes/Themes.md)
- [Readwise Reader：Appearance](https://docs.readwise.io/reader/docs/faqs/appearance)
- [Reeder Classic：官方 App Store 发行说明](https://apps.apple.com/us/app/reeder-classic/id1529448980?mt=12&platform=iphone)
- [Inoreader：v13 UI redesign](https://www.inoreader.com/pl/blog/2020/01/inoreader-v13-is-here-with-improved-looks-and-new-features.html)
- [Inoreader：Sepia theme](https://www.inoreader.com/blog/2021/05/get-that-vintage-look-with-inoreaders-sepia-theme.html)
- [FreshRSS：Configuration](https://github.com/FreshRSS/FreshRSS/blob/edge/docs/en/users/05_Configuration.md)
- [FreshRSS：Theming](https://freshrss.github.io/FreshRSS/en/admins/11_Themes.html)
- [Miniflux：官方仓库](https://github.com/miniflux/v2)
- [Miniflux：FAQ](https://miniflux.app/faq.html)
