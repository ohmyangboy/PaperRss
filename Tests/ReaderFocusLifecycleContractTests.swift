import Foundation
import XCTest

final class ReaderFocusLifecycleContractTests: XCTestCase {
    func testArticleSwitchKeepsReaderWebViewMountedToPreserveFocus() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let articleReader = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PaperRss/Sources/App/ArticleReaderView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(articleReader.contains("@State private var displayedEntry: Entry?"))
        XCTAssertFalse(articleReader.contains("preparedArticle = nil"))
        XCTAssertTrue(articleReader.contains("if usesNativeHTMLScroller, let preparedArticle, let displayedEntry"))
        XCTAssertTrue(articleReader.contains("entry: displayedEntry"))
        XCTAssertTrue(articleReader.contains("isInteractive: isDisplayedDocumentInteractive"))
        XCTAssertTrue(articleReader.contains("window.paperRssReaderInteractive === false"))
        XCTAssertTrue(articleReader.contains("guard parent.allowsNavigationWhenInactive else { return }"))
        XCTAssertTrue(articleReader.contains("if needsLoadingCover"))
        XCTAssertTrue(articleReader.contains("!displaysMemoizedArticle || showsLoadingIndicator || onScreenDocumentEntryID == nil"))
        XCTAssertTrue(articleReader.contains("let wasWaitingForDocument = isLoading && activeLoadEntryID != nil"))
        XCTAssertTrue(articleReader.contains("showsLoadingIndicator = wasWaitingForDocument"))
        XCTAssertTrue(articleReader.contains("let memoizedPrepared = store.memoizedPreparedArticle(for: requestedEntry)"))
        XCTAssertTrue(articleReader.contains("displaysMemoizedArticle = (memoizedPrepared != nil)"))
        XCTAssertTrue(articleReader.contains("if let memoizedPrepared {"))
        XCTAssertTrue(articleReader.contains("prepared = await store.prepareArticle(for: requestedEntry)"))
        // 连击合并与 markRead 延迟（macOS/iOS 双 coordinator 对称）
        XCTAssertTrue(articleReader.contains("private var scheduledNavigationEntryID: String?"))
        XCTAssertEqual(articleReader.components(separatedBy: "performDocumentLoad(entryID: requestedEntryID, in: webView)").count - 1, 2)
        XCTAssertTrue(articleReader.contains("guard scheduledNavigationEntryID == entryID,\n                  parent.entry.id == entryID else { return }"))
        XCTAssertTrue(articleReader.contains("guard activeLoadEntryID == requestedEntry.id,\n                      articleLoadSession == requestedLoadSession,\n                      !requestedEntry.isRead else { return }\n                store.markRead(requestedEntry)"))
        // 翻译更新只走批量同步脚本（单次 DOM 变更 + 单次滚动补偿），不得逐段 evaluateJavaScript
        XCTAssertFalse(articleReader.contains("updateInlineTranslationInWebView"))
        XCTAssertFalse(articleReader.contains("paperRssSelectionAssistant?.updateInlineTranslation"))
        // macOS/iOS 均在视图更新时同步字号 CSS 变量
        XCTAssertEqual(articleReader.components(separatedBy: "setProperty('--paper-font-size'").count - 1, 2)
        XCTAssertTrue(articleReader.contains("if showsLoadingIndicator"))
        XCTAssertTrue(articleReader.contains("Task.sleep(nanoseconds: 150_000_000)"))
        XCTAssertFalse(articleReader.contains("hasPresentedDocument"))
        XCTAssertTrue(articleReader.contains("pendingScrollOffset = 0"))
        XCTAssertTrue(articleReader.contains("pendingContentOffset = .zero"))
        XCTAssertTrue(articleReader.contains("onDocumentReady: { loadedEntryID in"))
        XCTAssertTrue(articleReader.contains("guard isLoading, activeLoadEntryID == loadedEntryID else { return false }"))
        XCTAssertTrue(articleReader.contains("navigationLoads[ObjectIdentifier(navigation)] = ("))
        XCTAssertTrue(articleReader.contains("navigationLoads.removeValue(forKey: ObjectIdentifier(navigation))"))
        XCTAssertTrue(articleReader.contains("completedArticleKey == renderSignature"))
        XCTAssertTrue(articleReader.contains("guard self.parent.onDocumentReady(entryID) else { return }"))
        XCTAssertTrue(articleReader.contains("handleLoadFailure("))
        XCTAssertTrue(articleReader.contains("parent.onDocumentLoadFailed(entryID)"))
        let identityCheck = try XCTUnwrap(articleReader.range(of: "if loadedDocumentIdentity == parent.entry.id")?.lowerBound)
        let translationInsertion = try XCTUnwrap(articleReader.range(of: "ReaderDocumentRenderer.renderDocument(", range: identityCheck..<articleReader.endIndex)?.lowerBound)
        XCTAssertLessThan(identityCheck, translationInsertion)
        XCTAssertTrue(articleReader.contains("loadedText.htmlEscaped"))
        XCTAssertTrue(articleReader.contains("private var hasReaderContent: Bool { preparedArticle != nil }"))
    }

    /// 杂志/卡片路由在浏览态把阅读器整栏折叠（WKWebView 保留上一篇文档），
    /// 重新呈现时必须先盖不透明遮罩，并且要等新文档首帧上屏（DOM ready 后两次 rAF）才揭开；
    /// 列表模式不折叠阅读器，顺序阅读的无缝旧文档过渡保持不变。
    func testMagazineRouteCoversStaleDocumentBeforeRevealingReader() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let articleReader = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PaperRss/Sources/App/ArticleReaderView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(articleReader.contains("@State private var coversStaleDocument = false"))
        XCTAssertTrue(articleReader.contains(".onChange(of: isReaderCollapsed) { _, collapsed in"))
        XCTAssertTrue(articleReader.contains("coversStaleDocument = true"))
        XCTAssertTrue(articleReader.contains("} else if onScreenDocumentEntryID == entry.id {"))
        // DOM 就绪只作为兜底起点；首帧信号缺失时也必须揭盖。
        XCTAssertTrue(articleReader.contains("scheduleStaleDocumentCoverReleaseFallback(entryID: loadedEntryID)"))
        XCTAssertTrue(articleReader.contains("guard coversStaleDocument, activeLoadEntryID == entryID else { return }"))
        // 揭盖路径：兜底、首帧回调、macOS/iOS 失败回调、重新呈现、声明。
        XCTAssertEqual(articleReader.components(separatedBy: "coversStaleDocument = false").count - 1, 6)
        // 首帧上屏信号：DOM ready 后再两次 rAF + 宏任务上报。
        XCTAssertTrue(articleReader.contains("static let documentPaintedMessageName = \"paperRssDocumentPainted\""))
        XCTAssertTrue(articleReader.contains("requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(notifyPainted, 0)))"))
        XCTAssertTrue(articleReader.contains("onDocumentPainted: { paintedEntryID in"))
        XCTAssertTrue(articleReader.contains("parent.onDocumentPainted(entryID)"))
        // didFinish 会消费 navigationLoads，首帧信号需能回退到最近一次 DOM 就绪的加载。
        XCTAssertTrue(articleReader.contains("private var lastCompletedLoad: (entryID: String, generation: Int)?"))
        XCTAssertTrue(articleReader.contains("?? (lastCompletedLoad?.generation == generation ? lastCompletedLoad?.entryID : nil)"))
        XCTAssertTrue(articleReader.contains("self.lastCompletedLoad = (load.entryID, load.generation)"))

        let rootView = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PaperRss/Sources/App/RootView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(rootView.contains("isReaderCollapsed: timelineStyle != .list && isTimelineBrowsing && !isZenMode"))
    }

    func testMemoizedInstantSwitchAndNeighborPrefetchWiring() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let appStore = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PaperRss/Sources/Core/AppStore.swift"),
            encoding: .utf8
        )
        // prepareArticle 必须先查内存 LRU；取消的任务不写入缓存；
        // 重抓与清空磁盘缓存时同步失效内存结果。
        XCTAssertTrue(appStore.contains("if let memoized = preparedArticleMemoryCache.article(for: entry.id, contentFingerprint: fingerprint)"))
        XCTAssertTrue(appStore.contains("if !Task.isCancelled,\n           permitsMemoryCaching,\n           prepared.source != .fallback,\n           result.cacheState == .current,\n           !result.isProvisionalLocal,\n           generationAtStart == preparedArticleMemoryCache.generation {\n            preparedArticleMemoryCache.store(prepared, entryID: entry.id, contentFingerprint: fingerprint)\n        }"))
        XCTAssertTrue(appStore.contains("preparedArticleMemoryCache.invalidate(entryID: entry.id)"))
        XCTAssertTrue(appStore.contains("preparedArticleMemoryCache.removeAll()"))
        XCTAssertTrue(appStore.contains("public func scheduleNeighborPrefetch("))
        XCTAssertTrue(appStore.contains("guard !Task.isCancelled, let self else { return }"))
        XCTAssertTrue(appStore.contains("prepareArticle(for: neighbor, policy: .localOnly)"))

        let rootView = try String(
            contentsOf: repositoryRoot.appendingPathComponent("PaperRss/Sources/App/RootView.swift"),
            encoding: .utf8
        )
        // 选中变化即调度相邻预取，保证 Space/nn/bb 命中内存缓存
        XCTAssertTrue(rootView.contains("if let newID {\n                    scheduleNeighborPrefetch(from: newID)\n                }"))
    }
}
