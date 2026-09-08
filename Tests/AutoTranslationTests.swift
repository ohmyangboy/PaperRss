import XCTest
import GRDB
@testable import PaperRssCore

private struct FixtureLanguageRecognizer: ArticleLanguageRecognizing {
    func candidates(for text: String) -> [String: Double] {
        if text.contains("uncertain") { return ["en": 0.70, "fr": 0.30] }
        if text.contains("中文") { return ["zh-Hans": 0.99, "ja": 0.01] }
        return ["en": 0.99, "fr": 0.01]
    }
}

private struct LanguageHintPageLoader: ArticlePageLoading {
    let page: LoadedArticlePage
    func loadPage(for url: URL) async throws -> LoadedArticlePage? { page }
}

final class AutoTranslationTests: XCTestCase {
    private let english = String(repeating: "The article explains how a reader can understand a story and its background. ", count: 6)
    private let chinese = String(repeating: "中文文章详细解释阅读器的功能和使用方法，并且介绍开发过程中的问题与解决方案。", count: 10)

    private func article(_ html: String, hints: [ArticleLanguageHint] = []) -> PreparedArticle {
        .init(text: html.plainText, html: html, imageURLs: [], baseURL: nil, source: .feed, languageHints: hints)
    }

    func testForeignAndTargetLanguageDecisionsIgnoreContradictoryDeclarations() async {
        let service = LanguageDetectionService(recognizer: FixtureLanguageRecognizer())
        let analysis = await service.analyze(article("<p>\(chinese)</p>", hints: [.init(language: "en", scope: "rss:channel")]))
        XCTAssertEqual(analysis.dominantLanguage, "zh")
        XCTAssertEqual(AIAutomationPolicy.evaluate(analysis: analysis, targetLanguage: "简体中文", enabled: true, exempt: false, available: true), .sameLanguage)
        XCTAssertEqual(AIAutomationPolicy.evaluate(analysis: analysis, targetLanguage: "English", enabled: true, exempt: false, available: true), .translate)
    }

    func testMixedShortAndUncertainArticlesAreNotSingleLanguage() async {
        let service = LanguageDetectionService(recognizer: FixtureLanguageRecognizer())
        let mixed = await service.analyze(article("<p>\(chinese)</p><p>\(english)</p><p>\(chinese)</p>"))
        XCTAssertEqual(mixed.status, .mixed)
        let short = await service.analyze(article("<p>New release</p>", hints: [.init(language: "en", scope: "article")]))
        XCTAssertEqual(short.status, .unknown)
        let uncertain = await service.analyze(article("<p>uncertain \(english)</p>"))
        XCTAssertEqual(uncertain.status, .unknown)
    }

    func testDetectionExcludesCodeMathAndURLsAndBoundsSamples() {
        let samples = LanguageDetectionService.samples(html: "<p>\(chinese)</p><pre>\(english)</pre><math>\(english)</math><button>\(english)</button><p>https://example.com/english</p>", fallback: "")
        XCTAssertFalse(samples.joined().contains("The article"))
        XCTAssertFalse(samples.joined().contains("https"))
        let long = LanguageDetectionService.samples(html: "<p>\(String(repeating: english, count: 100))</p>", fallback: "")
        XCTAssertLessThanOrEqual(long.count, 3)
        XCTAssertTrue(long.allSatisfy { $0.count <= 2_000 })
        XCTAssertLessThanOrEqual(long.reduce(0) { $0 + $1.count }, 6_000)
    }

    func testSystemRecognizerReadsRealProseOnDevice() async {
        let service = LanguageDetectionService()
        let en = await service.analyze(article("<p>\(english)</p>"))
        let zh = await service.analyze(article("<p>\(chinese)</p><pre>\(english)</pre>"))
        XCTAssertEqual(en.dominantLanguage, "en")
        XCTAssertEqual(zh.dominantLanguage, "zh")
    }

    func testAnalysisContentVersionAndHintsNeverLeakFromCache() async {
        let service = LanguageDetectionService(recognizer: FixtureLanguageRecognizer(), capacity: 1)
        let first = await service.analyze(article("<p>\(english)</p>"))
        let second = await service.analyze(article("<p>\(chinese)</p>"))
        XCTAssertNotEqual(first.contentHash, second.contentHash)
        let hinted = await service.analyze(article("<p>\(english)</p>", hints: [.init(language: "fr", scope: "feed")]))
        XCTAssertEqual(hinted.evidence.first?.language, "fr")
        XCTAssertEqual(hinted.dominantLanguage, "en")
    }

    func testTargetLanguageNormalizationAndSafetyGates() {
        for value in ["en-US", "en_GB", "English"] { XCTAssertEqual(AIAutomationPolicy.baseLanguage(value), "en") }
        for value in ["zh-Hans", "zh-Hant", "繁體中文"] { XCTAssertEqual(AIAutomationPolicy.baseLanguage(value), "zh") }
        XCTAssertNil(AIAutomationPolicy.baseLanguage("Please translate casually"))
        let analysis = ArticleLanguageAnalysis(contentHash: "hash", detectorVersion: 1, status: .single, dominantLanguage: "en", candidateScores: [], evidence: [])
        XCTAssertEqual(AIAutomationPolicy.evaluate(analysis: analysis, targetLanguage: "中文", enabled: true, exempt: true, available: true), .exempt)
        XCTAssertEqual(AIAutomationPolicy.evaluate(analysis: analysis, targetLanguage: "中文", enabled: true, exempt: false, available: false), .unavailable)
        XCTAssertEqual(AIAutomationPolicy.evaluate(analysis: analysis, targetLanguage: "custom prose", enabled: true, exempt: false, available: true), .unsupportedTarget)
    }

    func testOldPreferencesRemainOffAndDisplayResetPreservesAutomation() throws {
        var features = try JSONDecoder().decode(AIFeaturePreferences.self, from: Data("{}".utf8))
        XCTAssertFalse(features.automaticallyTranslate)
        features.automaticallyTranslate = true
        features.translationPreferences = .default
        let restored = try JSONDecoder().decode(AIFeaturePreferences.self, from: JSONEncoder().encode(features))
        XCTAssertTrue(restored.automaticallyTranslate)
    }

    func testFeedLanguageParsingWithAtomScopesAndJSONItemOverride() throws {
        let url = URL(string: "https://example.com/feed")!
        let rss = try FeedParser.parse(data: Data("<rss><channel><language>en-US</language><item><title>Test</title><description>body</description></item></channel></rss>".utf8), baseURL: url)
        XCTAssertEqual(rss.languageHints.first?.language, "en-US")
        let atom = try FeedParser.parse(data: Data("<feed xml:lang='en'><entry xml:lang='zh'><id>1</id><content xml:lang='ja'>body</content></entry><entry><id>2</id><content>other</content></entry></feed>".utf8), baseURL: url)
        XCTAssertEqual(atom.languageHints.first?.language, "en")
        XCTAssertTrue(atom.entries[0].languageHints.contains(.init(language: "ja", scope: "atom:content")))
        XCTAssertEqual(atom.entries[1].languageHints.last?.language, "en")
        let json = try FeedParser.parse(data: Data(#"{"version":"https://jsonfeed.org/version/1.1","language":"en","items":[{"id":"1","language":"zh-Hans","content_text":"正文"}]}"#.utf8), baseURL: url)
        XCTAssertEqual(json.languageHints.first?.language, "en")
        XCTAssertEqual(json.entries.first?.languageHints.first?.language, "zh-Hans")
    }

    func testPreparedCacheUsesItsOwnHintsWithoutFeedContamination() async {
        let entry = Entry(id: "a", feedID: UUID(), title: "中文标题", contentHTML: "<p>\(english)</p>")
        let cache = ArticleCache(entryID: entry.id, text: chinese, html: "<p>\(chinese)</p>", isSanitized: true, languageHints: [.init(language: "zh", scope: "web:http")])
        let result = await ArticlePreparationEngine().prepare(entry: entry, cached: cache, policy: .localOnly,
            feedLanguageHints: [.init(language: "en", scope: "rss:channel")])
        XCTAssertEqual(result.prepared.source, .cache)
        XCTAssertEqual(result.prepared.languageHints, cache.languageHints)
    }

    func testWebUpgradePreservesOnlyWebDeclarations() async {
        let url = URL(string: "https://example.com/article")!
        let entry = Entry(id: "web", feedID: UUID(), title: "中文标题", url: url, summary: "Short preview")
        let page = LoadedArticlePage(html: "<HTML LANG='en'><body><article><p lang='en-US'>\(english)</p><p>\(english)</p><p>\(english)</p></article></body></HTML>", finalURL: url, contentLanguage: "en-GB")
        let result = await ArticlePreparationEngine(pageLoader: LanguageHintPageLoader(page: page)).prepare(
            entry: entry, cached: nil, policy: .foregroundRefresh,
            feedLanguageHints: [.init(language: "zh", scope: "rss:channel")])
        XCTAssertEqual(result.prepared.source, .web)
        XCTAssertTrue(result.prepared.languageHints.contains(.init(language: "en", scope: "html:html")))
        XCTAssertTrue(result.prepared.languageHints.contains(.init(language: "en-GB", scope: "web:http")))
        XCTAssertFalse(result.prepared.languageHints.contains { $0.scope == "rss:channel" })
        XCTAssertEqual(result.updatedCache?.languageHints, result.prepared.languageHints)
    }

    func testV6UpgradePreservesReadingDataAndOldCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let pool = try DatabasePool(path: url.path)
        try DatabaseMigrations.migrator.migrate(pool, upTo: "v6-canonicalize-current-ai-summaries")
        try pool.write { db in
            try db.execute(sql: "INSERT INTO accounts(id, type, display_name, created_at, updated_at) VALUES ('local-default', 'local', 'Local', 0, 0)")
            try db.execute(sql: "INSERT INTO feeds(id, account_id, title, feed_url, updated_at) VALUES ('feed', 'local-default', 'Feed', 'https://example.com/feed', 0)")
            try db.execute(sql: "INSERT INTO items(id, account_id, external_id, feed_id, created_at, updated_at) VALUES ('item', 'local-default', 'item', 'feed', 0, 0)")
            try db.execute(sql: "INSERT INTO article_states(item_id, is_read, is_starred, date_arrived, updated_at) VALUES ('item', 1, 1, 0, 0)")
            try db.execute(sql: "INSERT INTO article_caches(item_id, text, fetched_at, is_sanitized, normalization_revision) VALUES ('item', '原文缓存', 0, 1, 4)")
        }
        try DatabaseMigrations.migrator.migrate(pool)
        try pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT is_starred FROM article_states WHERE item_id = 'item'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT is_read FROM article_states WHERE item_id = 'item'"), 1)
            let cache = try XCTUnwrap(ArticleCacheRecord.fetchOne(db, key: "item"))
            XCTAssertEqual(cache.text, "原文缓存")
            XCTAssertNil(cache.languageHintsJSON)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM translation_feed_lists"), 0)
        }
    }

    @MainActor
    func testStoreManualSuppressionAndAutomaticModeHaveSeparateLifecycles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(databaseURL: root.appendingPathComponent("library.sqlite"), persistenceURL: root.appendingPathComponent("library.json"))
        let feed = try store.localProvider.addFeed(title: "Test", feedURL: URL(string: "https://example.com/feed")!)
        let entries = try store.libraryDatabase.write { db in
            try store.localProvider.articleRepository.mergeParsedEntries(feedID: feed.id.uuidString,
                parsedEntries: [.init(id: "test", title: "Test", summary: "", contentHTML: "<p>body</p>")], in: db)
        }
        store.reloadState()
        let entry = try XCTUnwrap(entries.first)
        store.applyAutoTranslation(.translate, entryID: entry.id)
        XCTAssertTrue(store.isBilingualActive(for: entry.id))
        store.toggleBilingualMode(for: entry.id)
        XCTAssertFalse(store.isBilingualActive(for: entry.id))
        XCTAssertTrue(try store.autoTranslationRepository.isExempt(entry: entry))
        store.toggleBilingualMode(for: entry.id)
        XCTAssertFalse(try store.autoTranslationRepository.isExempt(entry: entry))
        store.applyAutoTranslation(.disabled, entryID: entry.id)
        XCTAssertTrue(store.isBilingualActive(for: entry.id), "规则关闭不能关闭手动开启的翻译")
        store.toggleBilingualMode(for: entry.id)
        let reopened = AppStore(databaseURL: root.appendingPathComponent("library.sqlite"), persistenceURL: root.appendingPathComponent("library.json"))
        XCTAssertTrue(try reopened.autoTranslationRepository.isExempt(entry: entry))
        XCTAssertFalse(reopened.isBilingualActive(for: entry.id))
    }

    @MainActor
    func testWorkspaceDiscardsOldContentAndTargetResults() async throws {
        let workspace = ArticleAIWorkspace()
        let generation = workspace.attach(.init(entryID: "a", text: "old"))
        workspace.setTranslationContext(entryID: "a", text: "old", targetLanguage: "中文")
        let stream = AsyncStream.makeStream(of: String.self)
        try workspace.submit(.bilingual(paragraphIDs: ["p0"]), in: generation) { emit in
            for await value in stream.stream { await emit(.bilingual(paragraphID: "p0", text: value)) }
        }
        stream.continuation.yield("旧译文")
        for _ in 0..<100 where workspace.projection.bilingualTranslations.isEmpty { await Task.yield() }
        XCTAssertEqual(workspace.projection.bilingualTranslations["p0"], "旧译文")
        workspace.setTranslationContext(entryID: "a", text: "new", targetLanguage: "中文")
        stream.continuation.yield("迟到译文")
        stream.continuation.finish()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(workspace.projection.bilingualTranslations.isEmpty)
        XCTAssertFalse(workspace.isTranslationContextCurrent(entryID: "a", text: "old", targetLanguage: "中文"))
        workspace.setTranslationContext(entryID: "a", text: "new", targetLanguage: "English")
        XCTAssertFalse(workspace.isTranslationContextCurrent(entryID: "a", text: "new", targetLanguage: "中文"))
    }
}
