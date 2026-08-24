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
        XCTAssertTrue(articleReader.contains("if isLoading && !displaysMemoizedArticle"))
        XCTAssertTrue(articleReader.contains("let memoizedPrepared = store.memoizedPreparedArticle(for: requestedEntry)"))
        XCTAssertTrue(articleReader.contains("displaysMemoizedArticle = (memoizedPrepared != nil)"))
        XCTAssertTrue(articleReader.contains("if let memoizedPrepared {"))
        XCTAssertTrue(articleReader.contains("prepared = await store.prepareArticle(for: requestedEntry)"))
        // 连击合并与 markRead 延迟（macOS/iOS 双 coordinator 对称）
        XCTAssertTrue(articleReader.contains("private var scheduledNavigationEntryID: String?"))
        XCTAssertEqual(articleReader.components(separatedBy: "performDocumentLoad(entryID: requestedEntryID, in: webView)").count - 1, 2)
        XCTAssertTrue(articleReader.contains("guard scheduledNavigationEntryID == entryID,\n                  parent.entry.id == entryID else { return }"))
        XCTAssertTrue(articleReader.contains("Task { @MainActor in\n                store.markRead(requestedEntry)\n            }"))
        // 翻译更新只走批量同步脚本（单次 DOM 变更 + 单次滚动补偿），不得逐段 evaluateJavaScript
        XCTAssertFalse(articleReader.contains("updateInlineTranslationInWebView"))
        XCTAssertFalse(articleReader.contains("paperRssSelectionAssistant?.updateInlineTranslation"))
        // macOS/iOS 均在视图更新时同步字号 CSS 变量
        XCTAssertEqual(articleReader.components(separatedBy: "setProperty('--paper-font-size'").count - 1, 2)
        XCTAssertTrue(articleReader.contains("if memoizedPrepared == nil {"))
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
        let translationInsertion = try XCTUnwrap(articleReader.range(of: "ArticleExtractor.insertingInlineTranslations(", range: identityCheck..<articleReader.endIndex)?.lowerBound)
        XCTAssertLessThan(identityCheck, translationInsertion)
        XCTAssertTrue(articleReader.contains("loadedText.htmlEscaped"))
        XCTAssertTrue(articleReader.contains("private var hasReaderContent: Bool { preparedArticle != nil }"))
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
        XCTAssertTrue(appStore.contains("if !Task.isCancelled,\n           permitsMemoryCaching,\n           prepared.source != .fallback,\n           result.cacheState == .current,\n           generationAtStart == preparedArticleMemoryCache.generation {\n            preparedArticleMemoryCache.store(prepared, entryID: entry.id, contentFingerprint: fingerprint)\n        }"))
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
