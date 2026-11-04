import XCTest
@testable import PaperRssCore

@MainActor
final class ArticleFetchPreferenceTests: XCTestCase {
    private func fixture() -> (Feed, Entry) {
        let feed = Feed(title: "FreshRSS fixture", feedURL: URL(string: "https://example.test/feed")!)
        let entry = Entry(id: "short-article", feedID: feed.id, title: "Short article",
                          url: URL(string: "https://example.test/article"),
                          summary: "订阅摘要", contentHTML: "<p>服务端已经抓取的短正文。</p>")
        return (feed, entry)
    }

    private func store(_ feed: Feed, _ entry: Entry, loader: MockPageLoader,
                       preferences: UserDefaults? = nil, cache: ArticleCache? = nil) -> AppStore {
        AppStore(testDatabase: AppDatabase(feeds: [feed], entries: [entry],
            articleCaches: cache.map { [entry.id: $0] } ?? [:], readingStates: [:],
            artifacts: [], llmConfiguration: .default),
            pageLoader: loader, articleFetchPreferences: preferences)
    }

    private func fullPage() -> String {
        "<html><body><article><p>" + String(repeating: "Fetched full article with detailed evidence and background. ", count: 40) + "</p></article></body></html>"
    }

    func testPreferenceDefaultsOnAndPersistsInIsolatedDefaults() throws {
        let name = "ArticleFetchPreferenceTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let (feed, entry) = fixture()
        let first = store(feed, entry, loader: MockPageLoader(), preferences: preferences)
        XCTAssertTrue(first.automaticallyFetchArticleContent)
        first.setAutomaticallyFetchArticleContent(false)
        let second = store(feed, entry, loader: MockPageLoader(), preferences: preferences)
        XCTAssertFalse(second.automaticallyFetchArticleContent)
    }

    func testDisabledReadingPrefetchAndAIUseFeedWithoutFetchingOrWritingCache() async throws {
        let (feed, entry) = fixture()
        let loader = MockPageLoader()
        loader.responseMap[entry.url!] = fullPage()
        let subject = store(feed, entry, loader: loader)
        subject.setAutomaticallyFetchArticleContent(false)
        let prefetched = await subject.prepareArticle(for: entry, policy: .localOnly)
        let prepared = await subject.prepareArticle(for: entry)
        let aiText = try await subject.articleText(for: entry)
        XCTAssertEqual(prefetched.source, .feed)
        XCTAssertEqual(prepared.source, .feed)
        XCTAssertTrue(aiText.contains("服务端已经抓取的短正文"))
        XCTAssertEqual(loader.requestCount, 0)
        XCTAssertNil(try subject.localProvider.fetchCache(entryID: entry.id))
    }

    func testReenablingInvalidatesShortMemoryPreviewAndFetchesFullArticle() async {
        let (feed, entry) = fixture()
        let loader = MockPageLoader()
        loader.responseMap[entry.url!] = fullPage()
        let subject = store(feed, entry, loader: loader)
        subject.setAutomaticallyFetchArticleContent(false)
        _ = await subject.prepareArticle(for: entry)
        XCTAssertNotNil(subject.memoizedPreparedArticle(for: entry))
        subject.setAutomaticallyFetchArticleContent(true)
        XCTAssertNil(subject.memoizedPreparedArticle(for: entry))
        let result = await subject.prepareArticle(for: entry)
        XCTAssertEqual(result.source, .web)
        XCTAssertEqual(loader.requestCount, 1)
    }

    func testDisabledPolicyRetainsLegacyCacheWithoutNetworkOrRevisionWrite() async throws {
        let (feed, entry) = fixture()
        let loader = MockPageLoader()
        let text = String(repeating: "Previously fetched full content. ", count: 40)
        let cache = ArticleCache(entryID: entry.id, text: text, html: "<p>\(text)</p>",
                                 fetchedAt: .now, sourceURL: entry.url, isSanitized: true, normalizationRevision: 0)
        let subject = store(feed, entry, loader: loader, cache: cache)
        subject.setAutomaticallyFetchArticleContent(false)
        let result = await subject.prepareArticle(for: entry)
        XCTAssertEqual(result.source, .cache)
        XCTAssertTrue(result.text.contains("Previously fetched"))
        XCTAssertEqual(loader.requestCount, 0)
        XCTAssertEqual(try subject.localProvider.fetchCache(entryID: entry.id)?.normalizationRevision, 0)
    }

    func testManualRefetchStillWorksWhenAutomaticFetchIsDisabled() async {
        let (feed, entry) = fixture()
        let loader = MockPageLoader()
        loader.responseMap[entry.url!] = fullPage()
        let subject = store(feed, entry, loader: loader)
        subject.setAutomaticallyFetchArticleContent(false)
        let refreshed = await subject.refetchArticle(for: entry)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(loader.requestCount, 1)
        let prepared = await subject.prepareArticle(for: entry)
        XCTAssertTrue(prepared.text.contains("Fetched full article"))
        XCTAssertEqual(loader.requestCount, 1)
    }

    func testDisablingDuringFetchDiscardsOldResponseAndCacheWrite() async throws {
        let (feed, entry) = fixture()
        let loader = MockPageLoader()
        loader.responseMap[entry.url!] = fullPage()
        loader.delay = 0.1
        let subject = store(feed, entry, loader: loader)
        let request = Task { await subject.prepareArticle(for: entry) }
        // Yield until the mock has entered its suspended network request.
        for _ in 0..<100 where loader.requestCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(loader.requestCount, 1)
        subject.setAutomaticallyFetchArticleContent(false)
        let prepared = await request.value
        XCTAssertEqual(prepared.source, .feed)
        XCTAssertNil(try subject.localProvider.fetchCache(entryID: entry.id))
        XCTAssertEqual(subject.memoizedPreparedArticle(for: entry)?.source, .feed)
    }

    func testDisabledPolicyWithNoContentDoesNotFetch() async {
        let (feed, original) = fixture()
        let entry = Entry(id: original.id, feedID: feed.id, title: "Title only", url: original.url)
        let loader = MockPageLoader()
        let result = await ArticlePreparationEngine(pageLoader: loader).prepare(
            entry: entry, cached: nil, policy: .storedContent)
        XCTAssertEqual(loader.requestCount, 0)
        XCTAssertNil(result.updatedCache)
        XCTAssertEqual(result.prepared.source, .fallback)
    }

    func testInitialDisplayReturnsReadablePreviewWithoutStartingSlowNetwork() async throws {
        let (feed, entry) = fixture()
        let loader = MockPageLoader()
        loader.delay = 60
        loader.responseMap[entry.url!] = fullPage()
        let subject = store(feed, entry, loader: loader)

        let initial = await subject.prepareInitialArticle(for: entry)

        XCTAssertEqual(loader.requestCount, 0)
        XCTAssertTrue(initial.prepared.text.contains("服务端已经抓取的短正文"))
        XCTAssertTrue(initial.needsBackgroundRefresh)
        XCTAssertNotNil(initial.prepared.readerParagraphs)
        XCTAssertNotNil(initial.prepared.annotatedHTML)
        XCTAssertNil(subject.memoizedPreparedArticle(for: entry), "预览不能冒充最终全文缓存")
        XCTAssertNil(try subject.localProvider.fetchCache(entryID: entry.id))
    }

    func testBackgroundFullContentUpdatesCacheWithoutReloadingCurrentDocument() async throws {
        let (feed, entry) = fixture()
        let loader = MockPageLoader()
        loader.responseMap[entry.url!] = fullPage()
        let subject = store(feed, entry, loader: loader)
        let initial = await subject.prepareInitialArticle(for: entry)

        let refreshed = await subject.refreshArticleInBackground(for: entry)

        XCTAssertEqual(loader.requestCount, 1)
        XCTAssertEqual(refreshed?.source, .web)
        XCTAssertTrue(refreshed?.text.contains("Fetched full article") == true)
        XCTAssertNotNil(refreshed?.readerParagraphs)
        XCTAssertNotNil(refreshed?.annotatedHTML)
        XCTAssertNil(subject.articleRefreshSignal)
        XCTAssertTrue(initial.prepared.text.contains("服务端已经抓取的短正文"), "已显示值不能被后台结果修改")
        XCTAssertTrue(try subject.localProvider.fetchCache(entryID: entry.id)?.text.contains("Fetched full article") == true)
        let reopened = await subject.prepareInitialArticle(for: entry)
        XCTAssertFalse(reopened.needsBackgroundRefresh)
        XCTAssertEqual(reopened.prepared, refreshed)
        XCTAssertEqual(loader.requestCount, 1)
    }

    func testStaleCacheBackgroundUpgradeDoesNotPublishReaderReloadSignal() async throws {
        let (feed, entry) = fixture()
        let loader = MockPageLoader()
        // The stale-cache repair path rejects explicit "full article" links as
        // truncation signals; this fixture represents an actual complete page.
        loader.responseMap[entry.url!] = fullPage().replacingOccurrences(of: "full article", with: "complete story")
        let text = String(repeating: "旧缓存提供离线可读内容。", count: 35)
        let cache = ArticleCache(entryID: entry.id, text: text, html: "<p>\(text)</p>",
                                 sourceURL: entry.url, isSanitized: true, normalizationRevision: 0)
        let subject = store(feed, entry, loader: loader, cache: cache)

        let initial = await subject.prepareInitialArticle(for: entry)
        XCTAssertEqual(initial.prepared.source, .cache)
        XCTAssertTrue(initial.needsBackgroundRefresh)
        XCTAssertEqual(loader.requestCount, 0)
        let refreshed = await subject.refreshArticleInBackground(for: entry)

        XCTAssertEqual(loader.requestCount, 1)
        XCTAssertEqual(refreshed?.source, .web)
        XCTAssertNil(subject.articleRefreshSignal, "旧 revision 升级也不能自动重载阅读器")
        XCTAssertEqual(try subject.localProvider.fetchCache(entryID: entry.id)?.normalizationRevision,
                       ArticleCache.currentNormalizationRevision)
        XCTAssertEqual(subject.memoizedPreparedArticle(for: entry), refreshed)
    }

    func testFailedBackgroundFetchKeepsPreviewAndRemainsRetryable() async throws {
        let (feed, entry) = fixture()
        let loader = MockPageLoader()
        loader.errorMap[entry.url!] = URLError(.notConnectedToInternet)
        let subject = store(feed, entry, loader: loader)
        let initial = await subject.prepareInitialArticle(for: entry)

        let refreshed = await subject.refreshArticleInBackground(for: entry)
        let reopened = await subject.prepareInitialArticle(for: entry)

        XCTAssertNil(refreshed)
        XCTAssertEqual(initial.prepared, reopened.prepared)
        XCTAssertTrue(reopened.needsBackgroundRefresh)
        XCTAssertNil(subject.memoizedPreparedArticle(for: entry))
        XCTAssertNil(try subject.localProvider.fetchCache(entryID: entry.id))
        XCTAssertNil(subject.articleRefreshSignal)
    }

    func testDisablingDuringBackgroundFetchDiscardsResponseWithoutWriteOrReload() async throws {
        let (feed, entry) = fixture()
        let loader = MockPageLoader()
        loader.delay = 0.1
        loader.responseMap[entry.url!] = fullPage()
        let subject = store(feed, entry, loader: loader)
        let task = Task { await subject.refreshArticleInBackground(for: entry) }
        for _ in 0..<100 where loader.requestCount == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(loader.requestCount, 1)
        subject.setAutomaticallyFetchArticleContent(false)

        let result = await task.value

        XCTAssertNil(result)
        XCTAssertNil(try subject.localProvider.fetchCache(entryID: entry.id))
        XCTAssertNil(subject.articleRefreshSignal)
        let initial = await subject.prepareInitialArticle(for: entry)
        XCTAssertFalse(initial.needsBackgroundRefresh)
        XCTAssertEqual(initial.prepared.source, .feed)
        XCTAssertEqual(loader.requestCount, 1)
    }

    func testInvalidationDuringBackgroundFetchPreventsStaleCacheWrite() async throws {
        let (feed, entry) = fixture()
        let loader = MockPageLoader()
        loader.delay = 0.05
        loader.responseMap[entry.url!] = fullPage()
        let subject = store(feed, entry, loader: loader)
        let task = Task { await subject.refreshArticleInBackground(for: entry) }
        for _ in 0..<100 where loader.requestCount == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(loader.requestCount, 1)
        subject.preparedArticleMemoryCache.invalidate(entryID: entry.id)

        let result = await task.value

        XCTAssertNil(result)
        XCTAssertNil(try subject.localProvider.fetchCache(entryID: entry.id))
        XCTAssertNil(subject.memoizedPreparedArticle(for: entry))
        XCTAssertNil(subject.articleRefreshSignal)
    }

    func testCancelledBackgroundFetchDoesNotWriteFallbackOrReload() async throws {
        let (feed, entry) = fixture()
        let loader = MockPageLoader()
        loader.delay = 0.1
        loader.responseMap[entry.url!] = fullPage()
        let subject = store(feed, entry, loader: loader)
        let task = Task { await subject.refreshArticleInBackground(for: entry) }
        for _ in 0..<100 where loader.requestCount == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()

        let result = await task.value

        XCTAssertNil(result)
        XCTAssertNil(try subject.localProvider.fetchCache(entryID: entry.id))
        XCTAssertNil(subject.memoizedPreparedArticle(for: entry))
        XCTAssertNil(subject.articleRefreshSignal)
    }

    func testBackgroundOffersCompleteCachePreparedByAnotherConsumer() async throws {
        let (feed, entry) = fixture()
        let loader = MockPageLoader()
        loader.responseMap[entry.url!] = fullPage().replacingOccurrences(of: "full article", with: "complete story")
        let subject = store(feed, entry, loader: loader)
        let initial = await subject.prepareInitialArticle(for: entry)
        XCTAssertTrue(initial.needsBackgroundRefresh)
        XCTAssertEqual(loader.requestCount, 0)

        // A different feature completes the webpage while the reader keeps
        // displaying its initial value, before its own background task starts.
        let otherConsumer = await subject.prepareArticle(for: entry)
        XCTAssertEqual(otherConsumer.source, .web)
        let offered = await subject.refreshArticleInBackground(for: entry)

        XCTAssertEqual(offered?.source, .cache)
        XCTAssertEqual(offered?.text, otherConsumer.text)
        XCTAssertEqual(loader.requestCount, 1, "The existing complete cache must not fetch the page again")
        XCTAssertNil(subject.articleRefreshSignal)
        XCTAssertTrue(initial.prepared.text.contains("服务端已经抓取的短正文"))
    }

    func testWeakCachedFallbackDoesNotBecomeAFullContentOffer() async {
        let (feed, entry) = fixture()
        let loader = MockPageLoader()
        loader.errorMap[entry.url!] = URLError(.notConnectedToInternet)
        let cache = ArticleCache(entryID: entry.id, text: "Cached short preview……", html: "<p>Cached short preview……</p>",
                                 sourceURL: entry.url, isSanitized: true)
        let subject = store(feed, entry, loader: loader, cache: cache)

        let initial = await subject.prepareInitialArticle(for: entry)
        XCTAssertTrue(initial.needsBackgroundRefresh)
        let offered = await subject.refreshArticleInBackground(for: entry)

        XCTAssertNil(offered)
        XCTAssertEqual(loader.requestCount, 1)
        XCTAssertNil(subject.articleRefreshSignal)
        XCTAssertNil(subject.memoizedPreparedArticle(for: entry))
    }
}
