# PaperRss 开发交接（2026-07-31）

## 项目与目标

- 工作目录：`/Users/yangbukun/Desktop/code/websiteProjects/PaperRss`
- 产品：Mac + iPhone 的 SwiftUI RSS 阅读器，第一优先级是 macOS 日常阅读体验；系统目标为 macOS 14+/iOS 17+。
- 定位：NetNewsWire 式三栏 RSS 阅读器，使用柔和、低干扰的「纸张」阅读体验；支持用户自行配置 DeepSeek / OpenAI Chat Completions 兼容 API。
- 用户重视：真实可用、速度、缓存命中、图片稳定、细节交互统一。不要为了演示而自动发送文章到模型；AI 请求应由用户显式动作触发（AI 摘要可在设置中选择自动/手动）。

## 当前可运行状态

最近一次已验证：

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project PaperRss.xcodeproj -scheme PaperRss -configuration Debug build
```

- Core 测试：21/21 通过。
- macOS Debug 构建：通过。
- Xcode Debug 产物通常在：
  `/Users/yangbukun/Library/Developer/Xcode/DerivedData/PaperRss-fphrsmbtjgfejdeqwkujlpkgrjhc/Build/Products/Debug/PaperRss.app`
- 应由用户在 Xcode 中 Stop 后 Run，才能加载最新构建；不要随意杀掉其正在调试的进程。

## 主要代码地图

| 责任 | 文件 | 说明 |
| --- | --- | --- |
| 应用状态、筛选、持久化、AI 编排 | `PaperRss/Sources/Core/AppStore.swift` | `EntryLibraryIndex`、文章筛选、AI 缓存、单一 AI 请求锁、删除订阅时级联清除文章 |
| LLM 协议与请求 | `PaperRss/Sources/Core/LLMService.swift` | OpenAI `/chat/completions` 兼容、DeepSeek 参数、翻译/摘要/划词解释 |
| 网页阅读器与 WKWebView 桥接 | `PaperRss/Sources/App/ArticleReaderView.swift` | 纸张样式、图片 URL scheme、滚动头部、逐段翻译、划词解释和 macOS/iOS coordinator |
| 三栏根布局 | `PaperRss/Sources/App/RootView.swift` | sidebar / entry list / reader |
| API 与阅读设置 | `PaperRss/Sources/App/SettingsView.swift` | 设置分组，AI 服务相关选项放在 AI 服务类别 |
| RSS / OPML | `PaperRss/Sources/Core/FeedParser.swift`、`FeedService.swift`、`OPMLService.swift` | RSS、Atom、JSON Feed、HTTP 缓存与导入导出 |
| 核心测试 | `Tests/PaperRssCoreTests.swift` | 目前含翻译时禁用 DeepSeek thinking 的回归测试 |

## 已完成的重要实现与设计决定

### 阅读器、排版、图片

- Mac 为三栏：左订阅源、中文章列表、右正文；正文区域优先获得较大宽度（先前调过约 61.8% 内容占比）。
- 视觉为暖白纸张、低对比颗粒、标题偏衬线、正文偏无衬线；避免重装饰和不必要的动画。
- 阅读页顶部信息区会随正文滚动收缩；目前目标是正文不出现反向回弹位移。
- `ArticleReaderView.swift` 中使用 `ReaderImageRepository` + `paperrss-image://` 自定义 scheme：内存缓存、URLSession 缓存和 in-flight 去重，处理快速切换文章后图片变损坏/占位图的问题。
- 文章列表必须只用摘要预览，**不要**在每个 row 绑定全文 HTML；较长正文（特别是阮一峰订阅）曾造成切换 1–2 秒卡顿。
- `EntryLibraryIndex` 已用于避免每次切换订阅源都从持久化对象和全文内容重新构造大型数组。

### RSS 与数据行为

- Feed：RSS、Atom、JSON Feed；去重使用 GUID / 规范化 URL / 日期；保存 ETag 与 Last-Modified。
- 删除某订阅源时，应该同步删除该源的文章和关联本地数据；此级联清除已经实现，后续修改勿回退。
- 默认文章列表较长时，优先保留 SwiftUI `List` 的原生惰性复用；问题核心原本不是“没有虚拟滚动”，而是数据映射、全文字符串、WebView 重建和图片加载落在切换路径上。

### DeepSeek / OpenAI 兼容 API

- Base URL 是 API 根路径，应用自行追加 `/chat/completions`；DeepSeek 常用根路径应为 `https://api.deepseek.com/v1`。
- Key 仅为本地 API 配置：此前 Keychain 的访问授权弹窗破坏了体验，现行方向是不要把普通本地配置做成需要用户二次“允许”的流程。
- 正常接口支持 HTTPS；HTTP 仅允许用户明确开启“局域网 HTTP（不安全）”。
- 不打印 API Key、Authorization Header 或完整请求头到日志/导出。

### 翻译：以当前阅读位置为中心

- 产品要求不是替换整篇页面：原文保留，在原文段落下方插入中文；只有点到翻译功能后，才在当前可见段落和即将进入视口的少量段落预加载。
- `IntersectionObserver` 在 WebView 内感知可见段落；结果依据稳定段落 ID 回填。
- 翻译缓存依据文章内容哈希、段落内容、目标语言、模型与提示词版本；避免重复扣费。
- 为接近 Read Frog 的低首字延迟，翻译批次目前是**最多 1,200 字符、4 段**，而非旧版约 7,000 字符大批。
- 翻译请求会强制 DeepSeek `thinking: {"type":"disabled"}`；推理对翻译无益，原先会拖慢首段显示和提高成本。摘要/解释不能不加判断地沿用此开关。
- 没有照抄 Read Frog 的 100ms 聚合窗口，因为 PaperRss 的“屏幕内先见”目标更看重第一段立即发出；若观察到 API 并发受限，再考虑很短的聚合/令牌桶。

### AI 摘要

- 用户点“生成 AI 摘要”后，摘要默认展开。
- 设置应提供“自动解读（自动生成摘要）/手动点击”开关；此类选项归到“AI 服务”，不要散落在阅读设置。
- 摘要的折叠/展开状态与顶部标题模块的折叠应有一致的 icon / 文案规则，避免一处是文字另一处是箭头造成歧义。

### 划词 AI 解释（最新改动，需重点保留）

用户的最终交互要求：

1. 在网页中选中一段文字，出现浮动 ✦ 按钮；点击后询问 AI：这段文字在本文中是什么意思。
2. 模型需要获得全文感知，但要节省 token：`AppStore.explainSelection` 构造文章上下文，再用“选中文本 + 邻近上下文 + 压缩全文上下文”的缓存键。相同选择与上下文应命中缓存。
3. **点击 ✦ 即视为任务已提交**。原文不再添加 AI 下划线或背景标记；选区末尾只追加一个轻量批注图标，pending 状态用低透明度呼吸提示。
4. 用户点空白处关闭 popover 只能隐藏 popover，**绝不能取消网络请求**；否则已发出的 API 请求既耗费成本又没有任何可见结果。
5. 请求完成后再次点击该选区末尾图标/对应选区，会在原文附近打开可滚动 Popover，显示已完成的解释。
6. 翻译按钮只翻译当前选区，同样使用 Popover 和流式输出，不改写原文。
7. 多个划词解释在每个 WebView coordinator 内串行排队，避免旧逻辑的“已有 AI 任务正在进行，请稍后再试”。
8. 失败应解除 pending 标记，并展示可读的失败信息。

具体代码位置：

- CSS / 选择 / 图标 / Popover JS：`ArticleReaderView.swift` 中 `paper-rss-explained`、`markRange`、`dismissPopover`、`showPopover`、`append`、`resolve`。
- macOS 与 iOS 两套 coordinator 都有：
  `selectionExplanationTask`、`activeSelectionExplanationID`、`pendingSelectionExplanationRequests` 和 `startNextSelectionExplanationIfNeeded()`。
- Swift 回调：`ArticleReaderView.performSelectionRequest(...)` 按类型调用 `AppStore.explainSelection(...)` 或 `AppStore.translateSelection(...)`，再分别进入 `LLMService.explainSelection(...)` / 流式 `translate(...)`。

注意：选区末尾图标状态现在是 WebView DOM 内的会话状态；AI 解释结果本身会持久化为 `AIArtifact` 缓存，但“这段文字在 DOM 的哪个范围”尚未跨文章重载/重启持久化。如果将来要跨重启保留批注图标，需存储段落 ID + 范围（或文本锚点）并在 WebView 加载后重新定位，不能只存字符串。

### 2026-08-01 最新一轮 AI 体验改动

- 首次划词解释不再先调用一次模型生成 `articleContext` 再调用第二次解释；`AppStore.explainSelection` 改为用 `ArticleChunker.contextualArticle` 构造本地的开头/选区附近/结尾上下文，并以 `.articleContext` 本地缓存。首次只走一次网络请求，重复提问继续命中解释缓存或复用上下文。
- `LLMService.explainSelection` 与 `LLMService.translate` 都支持 `onDelta`，解释和选区翻译通过流式接口逐步写入 Popover，用户会先看到正在生成的文字而不是空等完整响应。
- 划词解释同翻译一样强制关闭 DeepSeek hidden thinking；它是交互式短解释，隐藏 reasoning 会延迟首个可见 delta，却不会提升读者体验。
- 选区操作按钮改用 `Selection.focusNode/focusOffset` 的 caret rect 定位，因此多行选择时按钮跟随用户拖动的光标端点，不再固定出现在整段 bounding box 的最右侧。
- 解释标记不再使用 `text-decoration`、背景或底色，避免与网页原生链接样式重叠；只在选区末尾插入 Lucide 风格的内联 SVG 批注图标。
- 选区操作栏改为两个 Apple 风格的轻量图标按钮：AI 解释、选区翻译；两者都在原文附近打开可滚动 Popover，Popover 关闭不取消请求。
- 移除原生右侧批注栏和 `paperRssSelectionAnnotation` 桥接消息；Popover、流式增量、完成/失败状态全部在 WebView 内闭环处理。
- 选区翻译复用已有 content-addressed translation memory；同一选区、模型、目标语言和提示词版本命中本地缓存，不重复消耗 API。

本轮验证：

- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test`：21/21 通过。
- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project PaperRss.xcodeproj -scheme PaperRss -configuration Debug build`：`BUILD SUCCEEDED`。

### 2026-08-01 解释与对照翻译体验补丁

- 划词解释提示词改为短回答约束：只解释选中内容在上下文中的作用，区分原文事实和推断，不重复引文、不扩展背景；中文最多约 120 字，英文约 70 词。提示词版本已升为 4，旧缓存不会误复用。
- 解释 Popover 最大高度收敛到约 340px，并按下方、上方、右侧、左侧的顺序选择不遮挡视口的位置；Popover 内部仍可滚动。关闭 Popover 不会取消已提交的请求。
- Popover 打开后会记录批注图标作为锚点，正文滚动时重新读取图标的视口位置，避免固定旧坐标导致遮挡或漂移。
- 解释完成后，选区末尾保留 Lucide 风格批注图标，点击图标可再次打开已缓存解释；生成中图标使用低透明度 pending 状态，失败时移除标记并显示错误。
- 解释结果现在额外保存文章内容哈希、段落 ID、段落内 UTF-16 起止偏移和选中文本；文章切换、WebView 重载或应用重新打开后，会按锚点恢复批注图标。跨段落选择无法安全锚定时仍保留当前会话标记，但不强行错位恢复。
- 旧版本已经缓存的解释结果在再次命中时会补写新的锚点字段，不需要重新调用模型；如果旧结果没有可用的段落锚点，则只保留内容缓存，不会把图标错误放到别处。
- 当前选区翻译与逐段对照翻译均支持 SSE 流式回调。逐段模式按视口逐段请求，首段先显示，已完成段落独立持久化并进入内容哈希缓存。
- 对照翻译图标已改为段落开头的 inline-flex 元素，译文写入同一段落的文本节点，不会另起一行，也不会因流式更新而替换掉图标。
- 已重新通过 WebView selectionScript 的 JavaScript 语法检查：15,147 字符脚本可编译。

## 已知问题 / 推荐下一步

### HTTP Feed 兼容性（2026-08-01）

- 用户输入的 `http://` Feed 之前被系统 ATS 拦截，错误码表现为“requires the use of a secure connection”；`NSAllowsLocalNetworking` 只覆盖本地网络，不覆盖公网 IP Feed。
- macOS 与 iOS 两个目标现在都使用各自的 Info.plist，并启用 `NSAppTransportSecurity.NSAllowsArbitraryLoads`，因此旧式 HTTP RSS/Atom/JSON Feed 可以像 NetNewsWire 一样抓取。
- 另外为用户当前的公网 Feed `47.251.82.23` 增加了精确的 `NSExceptionDomains` / `NSExceptionAllowsInsecureHTTPLoads` 例外，避免系统版本对全局例外处理不一致。
- 添加订阅时，HTTP 地址会显示橙色“不安全 HTTP”提示；HTTPS 仍是推荐方式。AI API 层仍由 `LLMService` 单独拒绝 HTTP，除非用户明确开启局域网 HTTP 选项。
- 这项 ATS 例外会影响应用内的 URL Loading System，属于个人自用取舍；若未来做公开分发，应改为 HTTPS 或尽量收窄到明确的 `NSExceptionDomains`。

按优先级：

1. **真机/真实 API 验收最新划词解释与选区翻译**：重启 Xcode 运行新版后，选中文本，点击解释或翻译，立即点空白关闭 Popover，等待流式完成，再点击末尾图标/重新选中同句；确认 loading / complete / error / 多请求队列状态。不要在未明确授权下反复发送付费 DeepSeek 请求。
2. **统一 AI 请求调度**：当前划词解释在 reader coordinator 内排队，但 `AppStore` 仍保留一个全局 `activeAIRequest`。如果摘要、翻译与解释真的并行，解释仍可能得到 `requestInProgress`。最稳妥的后续改法是 AppStore 统一优先级队列（用户当前划词 > 当前视口翻译 > 预加载翻译 > 自动摘要），而不是取消已提交请求。
3. **WebView 稳定性**：用户曾贴出 macOS 27 beta + Xcode debugger 的 `EXC_BREAKPOINT/SIGTRAP` 报告，崩溃线程在 CoreAnalytics 退出路径，报告没有应用代码栈，不能直接归因 PaperRss。应在非调试启动、开启 Zombie/Address Sanitizer 或用 Instruments 做复现；不要凭此报告宣称应用逻辑崩溃已修好。
4. **图片回归测试**：快速切换阮一峰多篇含图文章、来回切源、离线后再次打开。若仍出 broken image，记录具体原 URL/HTTP 状态；不要仅凭显示的蓝色问号判断是渲染还是远端防盗链。
5. **性能测量优先于继续猜测**：用 Instruments 的 Time Profiler、SwiftUI Instruments 与 Allocations 分别测量“切订阅源”“切文章”“滚动长文”“AI 请求完成回填”。重点检查 WebView 是否被重建、HTML 是否大范围 replace、图片是否重复下载、主线程是否做 HTML/字符串处理。
6. **可访问性与双端差异**：后续每次改 Mac WebView bridge 都需要核对 iOS coordinator 的同等实现，保持 Dynamic Type、VoiceOver 和键盘焦点不退化。

## 工作方式与约束

- 项目当前未发现可用的 git 工作树；不要假设可通过 `git diff` 获得变更。
- 编辑使用 `apply_patch`，避免通过 `cat` / 脚本直接覆写文件。
- 搜索优先 `rg`；构建必须显式指定 Xcode beta 的 `DEVELOPER_DIR`。
- 保留用户已有未提交改动；不要使用 `git reset --hard`、`git checkout --` 或删除 DerivedData。
- 用户偏好“先做并验证”，完成时必须说明已实际构建/测试过什么；不要把设计建议说成已实现。
