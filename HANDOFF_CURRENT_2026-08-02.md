# PaperRss 当前交接上下文（2026-08-02）

> 给下一位 Agent：先读本文件；它覆盖旧版 `HANDOFF.md` 中与构建产物、WebView 图片实现、测试结果相关的过时描述。旧文件仍保留作历史背景。

## 1. 当前目标与用户状态

- 项目：`/Users/yangbukun/Desktop/code/websiteProjects/PaperRss`
- 产品：macOS/iPhone 原生 SwiftUI RSS 阅读器，Mac 三栏阅读，右侧正文使用只读 `WKWebView`。
- 视觉方向：柔和纸张、低干扰、暖白背景、正文优先；交互参考 NetNewsWire。
- AI：用户配置 OpenAI 兼容 Chat Completions/DeepSeek，摘要、逐段翻译、选区翻译、选区解释均手动或按设置触发；请求需要流式、缓存和取消/恢复反馈。
- 用户最近的问题是：RSSHub Twitter 图片显示问号/空白。用户现在已确认图片恢复，可以收尾，不要继续无目的改动。

## 2. 最近一次已完成的图片修复

### 根因

1. 机器上曾同时存在两个相同 bundle id（`com.yangbukun.PaperRss`）的应用实例。
2. 用户实际启动的旧 App 位于：
   `/Users/yangbukun/Desktop/code/myapp/PaperRss 2026-07-31 20-03-41/PaperRss.app`
3. 旧 App 仍是 ATS 受限版本，访问 `http://47.251.82.23:1200/...` 时会出现：
   `The resource could not be loaded because the App Transport Security policy requires the use of a secure connection.`
4. Twitter/RSSHub 正文里还有 `pbs.twimg.com` 图片 URL，部分 URL 带 HTML/XML 实体或 `format=webp`；旧缓存和 WKWebView 延迟加载会让首屏看起来像空白/问号。
5. 动态 X 状态页本身是复杂 Web App 壳，直接 Readability 提取会产生重复头像、空容器和混乱排版；RSSHub feed 自带正文更适合作为阅读内容。

### 已落地的代码修复

文件：`PaperRss/Sources/Core/ArticleExtractor.swift`

- `safeRemoteURL`：
  - 多轮解码 `&amp;`、`&quot;` 等安全 allow-list 实体；
  - 只接受 `http/https`；
  - `pbs.twimg.com/media/...` 的 `format=webp` 规范化为 `format=jpg`，提高 macOS WKWebView 解码兼容性；
  - 保留其他站点原始格式，不全局强制改图。
- `sanitizedHTML`：
  - 清除脚本、表单、iframe、危险标签和危险属性；
  - 前两张图片写入 `loading="eager"`，后续图片写入 `loading="lazy"`；
  - 所有图片加 `decoding="async"`；
  - 这样首屏图片更快出现，长文章后续图片仍按需加载。

文件：`PaperRss/Sources/Core/AppStore.swift`

- `preferredFeedContent(for:)` 识别 RSSHub Twitter/X feed（feed path 含 `/twitter/` 或 `/x/`，或 RSSHub + x.com/twitter.com 状态 URL）。
- 对这些条目优先使用 Feed 自带正文，不再抓取动态 X 页面壳。
- `articleHTML(for:)` / `articleText(for:)` 会懒迁移旧缓存：重新清理 HTML、刷新图片 URL、写回本地缓存，不需要重新下载正文。

文件：`PaperRss/Sources/App/ArticleReaderView.swift`

- WebView 使用安全清理后的 HTML，CSP 的图片源允许 `http:` / `https:`。
- `PaperReaderBridge.imageRecoveryScript` 只对失败图片做有限重试（最多两次、退避、cache-busting），避免快速切换文章时图片被 WebKit 取消后永久问号。
- 当前方案使用直接 HTTPS 图片 URL；不要轻易重新引入自定义 `WKURLSchemeHandler`，除非先做完整的 macOS+iOS 回归。旧版交接文档中关于自定义 `paperrss-image://` 仓库的描述已过时。

## 3. 实际安装/启动状态

已将最新可运行版本安装到用户真正启动的路径：

`/Users/yangbukun/Desktop/code/myapp/PaperRss 2026-07-31 20-03-41/PaperRss.app`

替换前版本保存在：

`/Users/yangbukun/Desktop/code/myapp/PaperRss 2026-07-31 20-03-41/PaperRss.app.pre-eager-20260802`

这是可恢复备份，没有删除用户数据。

安装版本保留了原有 `Info.plist`：

- `NSAllowsArbitraryLoads = true`（个人自用，为兼容旧式 HTTP Feed）；
- `NSAllowsLocalNetworking = true`；
- `47.251.82.23` 有精确的 `NSExceptionAllowsInsecureHTTPLoads = true`。

当前安装 App 使用同一源码的 Swift Package 可执行文件封装进 App Bundle，已进行 ad-hoc codesign 并通过：

```sh
codesign --verify --deep --strict "/Users/yangbukun/Desktop/code/myapp/PaperRss 2026-07-31 20-03-41/PaperRss.app"
```

## 4. 最终运行态验证证据

使用 Computer Use 启动了上述实际 App 路径，并完成：

1. 打开侧边栏 `Twitter @DeepSeek`；
2. 打开首篇 `We are making our discount permanent! ...`；
3. Accessibility tree 正文中出现两张 `image` 节点；
4. 实际用户随后确认图片已经可以显示。

当前库文件：

`/Users/yangbukun/Library/Application Support/PaperRss/library.json`

其中 RSSHub Twitter 首篇缓存已被修复为：

- 第一、第二张图片：`loading="eager"`；
- URL 使用 `https://pbs.twimg.com/...?...format=jpg...`；
- 没有重复的动态 X 页面头像壳。

## 5. 测试与构建

### 已通过

```sh
cd /Users/yangbukun/Desktop/code/websiteProjects/PaperRss
swift test
```

结果：**24 个测试，0 failures**。新增/相关回归包括：

- `testSanitizerEagerLoadsOnlyInitialImages`
- `testHTMLReaderSanitizerPreservesDocumentOrderWithoutExecutableContent`
- `testArticleImageExtractionKeepsRelativeAndSecureURLs`
- `testRSSHubTwitterFeedBodyStaysCompactAndKeepsTextOrder`

Swift Package 同时成功编译 `PaperRssDesktop`：

```sh
swift build --product PaperRssDesktop
```

### Xcode Beta 注意事项

本轮用 Xcode Beta 直接 `xcodebuild` 时，工具链自身出现：

`SwiftUIMacros.StateMacro ... swift-plugin-server produced malformed response`

这是 Xcode Beta/SwiftUI 宏插件错误，不是本轮图片代码的编译错误。为让用户继续使用，采用 Swift Package 产物封装到现有 App Bundle。若下一位 Agent 要修 Xcode Run 流程，应先清理/重建 Xcode Beta 的 Swift explicit module/cache，再单独验证，不要把这个宏插件错误误判成图片逻辑回归。

## 6. 现有重要功能约束（不要回退）

### 阅读/性能

- 列表行只使用标题、摘要、来源、日期；不要把全文 HTML 绑定到每一行。
- 正文 WebView 应在切换文章时重用/最小化重建；阮一峰长文切换曾有 1–2 秒卡顿。
- SwiftUI `List` 已提供惰性复用；长列表卡顿更多来自全文字符串复制、WebView 重建和图片请求，而不是缺少“虚拟滚动”。
- 删除订阅源时要级联删除该源文章、阅读状态和本地缓存；不要恢复旧文章。

### AI 与缓存

- API Key 是用户自己的本地配置，不要重新引入必须输入钥匙串登录密码的无缝体验破坏。
- AI 不应自动上传全文，除非用户开启自动摘要/自动解释；操作前要有可理解的状态反馈。
- 翻译为原文下方逐段插入中文，不替换全文；视口内/即将进入视口的小批量懒加载；支持 SSE 流式。
- 缓存键至少包含文章内容哈希、操作类型、模型、提示词版本、目标语言和段落/选区内容；相同请求必须命中缓存。
- 解释/选区翻译 Popover 关闭只隐藏 UI，不能取消已发出的请求；请求完成后必须能重新查看结果。
- 当前选区解释使用“选中文本 + 邻近段落 + 压缩全文上下文”，避免每次重复发送整篇文章。
- 同一 WebView coordinator 的选区请求串行排队，避免重复提示“已有 AI 任务进行中”。

### UI

- 顶部控件采用统一的 Apple 风格图标和 active/inactive 状态；不要恢复搜索、浏览器等已移除控件。
- AI 摘要点按后默认展开；自动摘要/手动摘要开关归类在“AI 服务”设置。
- 选区解释不保留原文下划线，使用轻量批注图标；Popover 要有最大高度和内部滚动，避免遮挡正文。

## 7. 下一位 Agent 如需继续，推荐顺序

1. 先启动实际路径 App，验证用户当前仍能看到图片；不要先改代码。
2. 若回归失败，读取 `library.json` 中具体条目的 `contentHTML`、缓存 HTML 和图片 URL，记录 HTTP 状态，再判断是 URL、ATS、WebKit 解码还是布局问题。
3. 需要重新构建时优先 `swift test` / `swift build --product PaperRssDesktop`；Xcode Beta 直构遇到 `SwiftUIMacros` malformed response 时，先处理工具链缓存问题。
4. 任何图片方案改动都必须回归：RSSHub Twitter、阮一峰含图长文、快速切换文章、快速切换订阅源、断网后重新打开。
5. 用户已经确认本轮图片问题解决；除非出现新证据，不要继续扩大修改范围。

## 8. 工作约束

- 编辑使用 `apply_patch`；搜索优先 `rg`。
- 不要使用 `git reset --hard`、`git checkout --` 或删除用户数据/缓存。
- 不要在日志、数据库、导出文件中输出 API Key、Authorization Header 或完整请求。
- 报告完成时区分“代码测试通过”“实际 App 已启动验证”“Xcode Beta 构建器异常”，不要把其中一项冒充另一项。
