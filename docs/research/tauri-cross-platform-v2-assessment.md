# PaperRss V2 跨平台版本：Tauri 可行性评估

- **Status**: planned
- **评估日期**: 2026-08-29
- **目标平台**: Windows、Linux；macOS 继续保留现有 SwiftUI 版本
- **候选技术**: Tauri 2 + Web UI + Rust 应用层

## 结论

迁移到 Tauri 可行，但不是把现有 SwiftUI 应用直接换成跨平台外壳。可行路径是新建 Windows/Linux 实现，复用 PaperRss 的产品行为、数据库规范、Reader 资源、AI prompt 和行为测试；UI、应用状态层、GRDB 数据访问和 Apple 专属服务需要重新实现。

综合判断：

| 项目 | 判断 |
| --- | --- |
| Windows 版本 | 较高可行性 |
| Linux 版本 | 中等可行性，Reader 兼容性是主要风险 |
| Swift 源码原样复用 | 较低可行性 |
| 业务规则、数据模型和测试复用 | 较高可行性 |
| 与当前 macOS 版本完全功能对齐 | 可行，但属于高投入项目 |

## 当前架构证据

- [Package.swift](../../Package.swift) 当前只声明 macOS 14，桌面产品依赖 SwiftUI/AppKit、Sparkle 和 Apple 资源。
- [AppStore.swift](../../PaperRss/Sources/Core/AppStore.swift) 是超过 2,400 行的应用状态与业务编排对象，覆盖账户、时间线、刷新、缓存、AI 和设置等多个职责，是迁移前最需要拆分的模块。
- [ArticleReaderView.swift](../../PaperRss/Sources/App/ArticleReaderView.swift) 将 SwiftUI、WKWebView、AppKit/UIKit、HTML/CSS/JavaScript、MathJax 和选区交互放在同一 Reader 链路中。HTML/CSS/JavaScript 和资源可复用，WKWebView bridge 必须重写。
- [DatabaseMigrations.swift](../../PaperRss/Sources/Core/Persistence/DatabaseMigrations.swift) 集中定义 SQLite schema/migration。表结构、迁移语义和 fixtures 可复用，GRDB repository 不能直接复用到 Rust。
- `CredentialStore`、`CloudSyncService`、Sparkle 和 AppKit 窗口/通知能力属于 Apple 平台适配器；CloudKit 不应列入 Windows/Linux MVP。

## 推荐架构

```text
macOS: SwiftUI → Swift application modules → GRDB / Keychain / Sparkle / CloudKit

Windows/Linux: Tauri Web UI → commands/events → Rust application modules
                                      → SQLite / HTTP / keyring / updater

共享契约：数据库规范、JSON 消息协议、Reader 资源、AI prompt、行为 fixtures
```

建议先建立以下深模块和小接口，再分别实现 macOS 与 Tauri adapter：

- `LibraryModule`：时间线、文章状态、缓存和数据库事务
- `FeedSyncModule`：订阅源、账户、刷新和 OPML
- `ArticlePreparationModule`：正文提取、规范化和缓存
- `AIModule`：摘要、翻译、问答和流式事件
- `ReaderDocumentModule`：Reader 文档生成及消息协议
- `CredentialPort`、`UpdaterPort`：凭据和更新的系统适配

不要把 `AppStore` 的现有方法逐个暴露成 Tauri command；前端应依赖状态快照、少量命令和事件流。

## 首个垂直原型

V2 的第一个验收目标是“Reader + SQLite + 一个 RSS 源”，而不是一次性迁移完整产品：

- 在 Windows WebView2 和 Linux WebKitGTK 中渲染文章。
- 验证 MathJax、代码高亮、选择文本、目录、滚动同步、视频和 CSP。
- 创建数据库并执行迁移，导入一组现有 fixtures。
- 拉取、解析并展示一个 RSS 源。
- 验证安装包、凭据存储和更新流程的最小闭环。

若 Linux Reader 需要大量 WebKitGTK 特殊分支，应重新比较 Electron 的统一 Chromium 运行时成本。

## V2 待办

- [ ] 每周跟进：推进一次 Tauri 垂直原型，记录 Reader、数据库和打包验证结果。
- [ ] 抽取 Reader HTML/CSS/JavaScript 资源及 JSON 消息协议。
- [ ] 为数据库 schema、迁移和核心行为建立跨实现 fixtures。
- [ ] 将 `AppStore` 拆为平台中立 module 与系统 adapter。
- [ ] 明确 Windows/Linux 凭据、更新、通知和后台刷新策略。

## 边界与未决问题

- 本文是可行性评估，不代表已开始迁移，也不代表任何 Tauri 版本已经通过 PaperRss 的真实运行验收。
- 不建议以 Swift sidecar 或 Swift FFI 作为最终方案：当前 Core 仍依赖 SwiftUI/Combine、GRDB、Security、CloudKit 等 Apple 生态能力，sidecar 会增加 IPC、进程生命周期、打包和升级复杂度。
- macOS 原生体验、CloudKit 同步和 iOS 范围不属于第一阶段跨平台 MVP。

## 参考

- Tauri 官方架构说明：<https://v2.tauri.app/concept/architecture/>
- Tauri 官方分发说明：<https://v2.tauri.app/distribute/>

