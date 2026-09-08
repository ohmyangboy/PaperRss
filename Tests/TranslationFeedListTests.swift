import XCTest
import GRDB
@testable import PaperRssCore

final class TranslationFeedListTests: XCTestCase {
    func testWhitelistAlwaysTranslatesAndBlacklistAlwaysSkips() {
        for status in [ArticleLanguageAnalysis.Status.single, .mixed, .unknown] {
            let analysis = ArticleLanguageAnalysis(contentHash: "", detectorVersion: 2, status: status, dominantLanguage: "zh", candidateScores: [], evidence: [])
            func result(_ list: TranslationFeedList?, enabled: Bool = true, exempt: Bool = false, available: Bool = true) -> AutoTranslationDecision {
                AIAutomationPolicy.evaluate(analysis: analysis, targetLanguage: "中文", enabled: enabled, exempt: exempt, available: available, list: list)
            }
            XCTAssertEqual(result(.whitelist), .translate)
            XCTAssertEqual(result(.blacklist), .blacklisted)
            XCTAssertNotEqual(result(nil), .translate)
            XCTAssertEqual(result(.whitelist, enabled: false), .disabled)
            XCTAssertEqual(result(.whitelist, exempt: true), .exempt)
            XCTAssertEqual(result(.whitelist, available: false), .unavailable)
        }
    }

    func testFeedMembershipSurvivesRenameAndMoveAndIsAccountScoped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("test.sqlite")
        let db = try LibraryDatabase(databaseURL: url)
        let provider = LocalAccountProvider(accountID: "local-default", database: db)
        try provider.ensureAccountExists()
        let feed = try provider.addFeed(title: "React", feedURL: URL(string: "https://example.com/feed")!, folder: "Tech")
        let repo = AutoTranslationRepository(database: db)
        try repo.setList(.whitelist, feedID: feed.id, accountID: "local-default")
        try provider.renameFolder(oldName: "Tech", newName: "Science")
        try provider.setFeedFolder(feedID: feed.id, folderName: nil)
        let other = LocalAccountProvider(accountID: "other", database: db)
        try other.ensureAccountExists()
        let second = try other.addFeed(title: "React", feedURL: URL(string: "https://example.org/feed")!)
        try repo.setList(.blacklist, feedID: feed.id, accountID: "other")
        XCTAssertEqual(try repo.feedLists()[feed.id], .whitelist)
        XCTAssertNil(try repo.feedLists()[second.id])
        try repo.setList(.blacklist, feedID: feed.id, accountID: "local-default")
        let reopened = AutoTranslationRepository(database: try LibraryDatabase(databaseURL: url))
        XCTAssertEqual(try reopened.feedLists(), [feed.id: .blacklist])
        try reopened.setList(nil, feedID: feed.id, accountID: "local-default")
        XCTAssertTrue(try reopened.feedLists().isEmpty)
    }

    func testRetiredPreferencesAreIgnored() throws {
        let data = Data(#"{"automaticallyTranslate":true,"autoTranslationMatchingMode":"whitelistOnly"}"#.utf8)
        let prefs = try JSONDecoder().decode(AIFeaturePreferences.self, from: data)
        XCTAssertTrue(prefs.automaticallyTranslate)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(prefs), as: UTF8.self).contains("autoTranslationMatchingMode"))
    }

    func testV8MigrationRemovesRulesAndPreservesArticleExemption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = try DatabasePool(path: root.appendingPathComponent("test.sqlite").path)
        try DatabaseMigrations.migrator.migrate(pool, upTo: "v8-auto-translation-name-rules")
        try pool.write { db in
            try db.execute(sql: "INSERT INTO accounts(id,type,display_name,created_at,updated_at) VALUES ('a','local','Local',0,0)")
            try db.execute(sql: "INSERT INTO auto_translation_rules VALUES ('a','article','item','off'),('a','folder','folder','foreignLanguage')")
            try db.execute(sql: "INSERT INTO auto_translation_name_rules VALUES ('old','a','{}')")
        }
        try DatabaseMigrations.migrator.migrate(pool)
        try pool.read { db in
            XCTAssertFalse(try db.tableExists("auto_translation_rules"))
            XCTAssertFalse(try db.tableExists("auto_translation_name_rules"))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT item_id FROM translation_article_exemptions"), "item")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM translation_feed_lists"), 0)
        }
    }

    func testSamplingIncludesProseInsteadOfThreeMetadataBlocks() async {
        let prose = String(repeating: "The framework helps developers build user interfaces and explains how components work together. ", count: 6)
        let html = "<p>April 23, 2025 by John Smith</p><p>\(prose)</p><div>Home.js</div><p>\(prose)</p><p>Thanks to Ana, Leo, Dan, Matt, John and Jo.</p>"
        let samples = LanguageDetectionService.samples(html: html, fallback: "")
        XCTAssertFalse(samples.contains { $0 == "Home.js" })
        XCTAssertGreaterThan(samples.joined().count, 500)
        let result = await LanguageDetectionService().analyze(.init(text: html.plainText, html: html, imageURLs: [], baseURL: nil, source: .feed))
        XCTAssertEqual(result.dominantLanguage, "en")
        XCTAssertEqual(result.status, .single)
    }
}
