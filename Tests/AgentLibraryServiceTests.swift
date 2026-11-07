import Foundation
import XCTest
import GRDB
import PaperRssAgentProtocol
@testable import PaperRssCore

@MainActor
final class AgentLibraryServiceTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let database: LibraryDatabase
        let provider: LocalAccountProvider
        let feed: Feed

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentLibraryTests-\(UUID().uuidString)")
            database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
            provider = LocalAccountProvider(database: database)
            try provider.ensureAccountExists()
            feed = try provider.addFeed(title: "Fixture feed", feedURL: URL(string: "https://example.org/feed?token=private")!)
            try database.write { db in
                for (index, id) in ["a", "b", "c"].enumerated() {
                    let timestamp = 1_700_000_000.0 + Double(index)
                    try ItemRecord(id: id, accountID: "local-default", externalID: id,
                        feedID: feed.id.uuidString, createdAt: timestamp, updatedAt: timestamp).insert(db)
                    try ArticleRecord(itemID: id, title: id == "a" ? "Swift concurrency" : "Article \(id)",
                        author: id == "a" ? "Fixture author" : nil,
                        url: id == "a" ? "https://example.org/a?token=secret" : "https://example.org/\(id)",
                        publishedAt: timestamp, summary: id == "a" ? "Actor metadata summary" : "Short summary",
                        contentHTML: "<p>BODY_ONLY_SENTINEL \(id)</p>", contentUpdatedAt: timestamp).insert(db)
                    try ArticleStateRecord(itemID: id, isRead: id == "c", isStarred: id == "c",
                        dateArrived: timestamp, updatedAt: timestamp).insert(db)
                }
            }
        }

        func service(enabled: Bool = true, starred: Bool = false, writes: Bool = true,
                     budget: Int = 100_000, loader: MockPageLoader = MockPageLoader(),
                     clock: @escaping @Sendable () -> Date = { Date() }) -> AgentLibraryService {
            AgentLibraryService(database: database,
                policy: AgentAccessPolicy(enabled: enabled, accountIDs: ["local-default"],
                    allowStarred: starred, allowStateChanges: writes, outputCharacterBudget: budget),
                engine: ArticlePreparationEngine(pageLoader: loader), clock: clock)
        }

        func state(_ id: String) throws -> ArticleStateRecord {
            try database.read { db in
                try XCTUnwrap(provider.stateRepository.fetchState(itemID: id, in: db))
            }
        }
        func remove() throws { try FileManager.default.removeItem(at: directory) }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_800_000_000)
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
    }

    private let account: AgentJSON = .string("local-default")
    private var unread: [String: AgentJSON] { ["account_id": account, "scope": .string("unread")] }

    private func expectFailure(_ code: String, file: StaticString = #filePath, line: UInt = #line,
                               _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected \(code)", file: file, line: line)
        } catch let error as AgentFailure {
            XCTAssertEqual(error.code, code, file: file, line: line)
        } catch {
            XCTFail("Expected AgentFailure \(code), got \(error)", file: file, line: line)
        }
    }

    private func makePlan(_ service: AgentLibraryService, ids: [String] = ["a", "b"], field: String = "read") async throws -> String {
        let result = try await service.call(tool: "paperrss_plan_state_change", arguments: [
            "account_id": account, "article_ids": .array(ids.map { .string($0) }),
            "field": .string(field), "value": .bool(true)
        ])
        return try XCTUnwrap(result["plan_id"]?.stringValue)
    }

    private func applyArguments(plan: String, approval: String, key: String = "test-request") -> [String: AgentJSON] {
        ["plan_id": .string(plan), "approval_id": .string(approval), "idempotency_key": .string(key)]
    }

    func testDefaultOffRejectsLibraryAccessAndHidesAccounts() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = AgentLibraryService(database: fixture.database)
        let status = try await service.call(tool: "paperrss_status", arguments: [:])
        XCTAssertEqual(status["enabled"], .bool(false))
        XCTAssertEqual(status["accounts"], .array([]))
        await expectFailure("NOT_ENABLED") {
            _ = try await service.call(tool: "paperrss_list_articles", arguments: unread)
        }
        await expectFailure("NOT_ENABLED") {
            _ = try await service.authorizeContent(accountID: "local-default", articleIDs: ["a"])
        }
    }

    func testMetadataDoesNotReturnBodyRefreshOrMarkReadAndRedactsSensitiveURL() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let loader = MockPageLoader()
        let service = fixture.service(loader: loader)
        let before = try fixture.state("a")
        let result = try await service.call(tool: "paperrss_list_articles", arguments: unread)
        let articles = try XCTUnwrap(result["articles"]?.arrayValue)
        XCTAssertEqual(Set(articles.compactMap { $0["id"]?.stringValue }), ["a", "b"])
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(encoded.contains("BODY_ONLY_SENTINEL"))
        XCTAssertFalse(encoded.contains("token=secret"))
        let article = try XCTUnwrap(articles.first { $0["id"] == .string("a") })
        XCTAssertEqual(article["content_available"], .bool(true))
        XCTAssertEqual(article["authors"], .array([.string("Fixture author")]))
        XCTAssertEqual(article["source_url_unavailable_reason"], .string("missing_or_sensitive_url"))
        XCTAssertNil(article["text"])
        XCTAssertEqual(try fixture.state("a"), before)
        XCTAssertEqual(loader.requestCount, 0)
        let feeds = try await service.call(tool: "paperrss_list_feeds", arguments: ["account_id": account])
        XCTAssertEqual(feeds["feeds"]?.arrayValue?.first?["unread_count"], .number(2))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(feeds), as: UTF8.self).contains("private"))
    }

    func testMetadataSearchOnlyUsesTitleAndExcerptAndRespectsFeedAndTime() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service()
        var query = unread
        query["query"] = .string("Actor metadata")
        query["feed_id"] = .string(fixture.feed.id.uuidString)
        query["since"] = .string("2023-11-14T00:00:00Z")
        let matching = try await service.call(tool: "paperrss_list_articles", arguments: query)
        XCTAssertEqual(matching["articles"]?.arrayValue?.map { $0["id"] }, [.string("a")])
        query["query"] = .string("BODY_ONLY_SENTINEL")
        let bodyOnly = try await service.call(tool: "paperrss_list_articles", arguments: query)
        XCTAssertEqual(bodyOnly["articles"], .array([]))
        query["query"] = .string("Swift")
        query["since"] = .string("2024-01-01T00:00:00Z")
        let tooOld = try await service.call(tool: "paperrss_list_articles", arguments: query)
        XCTAssertEqual(tooOld["articles"], .array([]))
    }

    func testPaginationCursorIsBoundToQueryAndCannotCrossSessions() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service()
        var query = unread; query["limit"] = .number(1)
        let first = try await service.call(tool: "paperrss_list_articles", arguments: query)
        let cursor = try XCTUnwrap(first["next_cursor"]?.stringValue)
        query["cursor"] = .string(cursor)
        let second = try await service.call(tool: "paperrss_list_articles", arguments: query)
        XCTAssertNotEqual(first["articles"], second["articles"])
        XCTAssertEqual(second["next_cursor"], .null)
        var changed = query; changed["query"] = .string("Swift")
        await expectFailure("UNAUTHORIZED") {
            _ = try await service.call(tool: "paperrss_list_articles", arguments: changed)
        }
        let anotherSession = fixture.service()
        await expectFailure("CONFLICT") {
            _ = try await anotherSession.call(tool: "paperrss_list_articles", arguments: query)
        }
    }

    func testScopeAndAccountCannotBeExpandedByClient() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service()
        await expectFailure("UNAUTHORIZED") {
            _ = try await service.call(tool: "paperrss_list_articles", arguments: ["account_id": .string("other-account"), "scope": .string("unread")])
        }
        await expectFailure("UNAUTHORIZED") {
            _ = try await service.call(tool: "paperrss_list_articles", arguments: ["account_id": account, "scope": .string("starred")])
        }
        await expectFailure("INVALID_ARGUMENT") {
            _ = try await service.call(tool: "paperrss_list_articles", arguments: ["account_id": account, "scope": .string("all")])
        }
        await expectFailure("UNAUTHORIZED") {
            _ = try await service.call(tool: "paperrss_get_article", arguments: ["account_id": account, "article_id": .string("c")])
        }
        let selection = try await service.authorizeContent(accountID: "local-default", articleIDs: ["c"])
        let selected = try await service.call(tool: "paperrss_list_articles", arguments: [
            "account_id": account, "scope": .string("selection"), "selection_id": .string(selection)
        ])
        XCTAssertEqual(selected["articles"]?.arrayValue?.map { $0["id"] }, [.string("c")])
    }

    func testContentRequiresExactSelectionAndUsesStoredFeedWithoutNetworkOrCacheWrite() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let loader = MockPageLoader()
        let service = fixture.service(loader: loader)
        let selection = try await service.authorizeContent(accountID: "local-default", articleIDs: ["b"])
        let args: [String: AgentJSON] = ["account_id": account, "article_id": .string("b"), "selection_id": .string(selection), "max_chars": .number(10)]
        let before = try fixture.state("b")
        let result = try await service.call(tool: "paperrss_get_content", arguments: args)
        XCTAssertEqual(result["untrusted"], .bool(true))
        XCTAssertLessThanOrEqual(try XCTUnwrap(result["text"]?.stringValue).unicodeScalars.count, 10)
        XCTAssertEqual(loader.requestCount, 0)
        XCTAssertNil(try fixture.provider.fetchCache(entryID: "b"))
        XCTAssertEqual(try fixture.state("b"), before)
        var wrong = args; wrong["article_id"] = .string("a")
        await expectFailure("UNAUTHORIZED") { _ = try await service.call(tool: "paperrss_get_content", arguments: wrong) }
    }

    func testStaleStoredCacheIsNotUpgradedOrRewritten() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let loader = MockPageLoader()
        let prose = String(repeating: "Cached scientific article discusses measurements and their implications. ", count: 40)
        let cache = ArticleCache(entryID: "b", text: prose, html: "<article><p>\(prose)</p></article>",
            fetchedAt: Date(timeIntervalSince1970: 1_600_000_000), sourceURL: URL(string: "https://example.org/b"),
            isSanitized: true, normalizationRevision: 0)
        try fixture.provider.saveCache(cache)
        let service = fixture.service(loader: loader)
        let selection = try await service.authorizeContent(accountID: "local-default", articleIDs: ["b"])
        let result = try await service.call(tool: "paperrss_get_content", arguments: [
            "account_id": account, "article_id": .string("b"), "selection_id": .string(selection)
        ])
        XCTAssertEqual(result["content_source"], .string("web_cache"))
        XCTAssertTrue(result["text"]?.stringValue?.contains("Cached scientific article") == true)
        XCTAssertEqual(loader.requestCount, 0)
        XCTAssertEqual(try fixture.provider.fetchCache(entryID: "b"), cache)
    }

    func testSharedOutputBudgetCannotBeBypassedByChangingTool() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service(budget: 100)
        let selection = try await service.authorizeContent(accountID: "local-default", articleIDs: ["b"])
        _ = try await service.call(tool: "paperrss_get_article", arguments: ["account_id": account, "article_id": .string("a")])
        await expectFailure("CONTENT_BUDGET_EXCEEDED") {
            _ = try await service.call(tool: "paperrss_get_content", arguments: [
                "account_id": account, "article_id": .string("b"), "selection_id": .string(selection)
            ])
        }
    }

    func testFailedMultiArticleResponseDoesNotConsumeOutputBudget() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        // Either article fits alone, but the two-article response exceeds the session allowance.
        let service = fixture.service(budget: 80)
        let before = try await service.call(tool: "paperrss_status", arguments: [:])
        XCTAssertEqual(before["remaining_characters"], .number(80))
        await expectFailure("CONTENT_BUDGET_EXCEEDED") {
            _ = try await service.call(tool: "paperrss_list_articles", arguments: unread)
        }
        let after = try await service.call(tool: "paperrss_status", arguments: [:])
        XCTAssertEqual(after["remaining_characters"], before["remaining_characters"],
                       "A rejected whole response must not charge an undelivered first article")
    }

    func testFailedContentResponseDoesNotChargeUndeliveredMetadata() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        // Metadata fits, while the same response's metadata plus stored text does not.
        let service = fixture.service(budget: 40)
        let selection = try await service.authorizeContent(accountID: "local-default", articleIDs: ["b"])
        let before = try await service.call(tool: "paperrss_status", arguments: [:])
        XCTAssertEqual(before["remaining_characters"], .number(40))
        await expectFailure("CONTENT_BUDGET_EXCEEDED") {
            _ = try await service.call(tool: "paperrss_get_content", arguments: [
                "account_id": account, "article_id": .string("b"), "selection_id": .string(selection)
            ])
        }
        let after = try await service.call(tool: "paperrss_status", arguments: [:])
        XCTAssertEqual(after["remaining_characters"], before["remaining_characters"],
                       "Metadata and body must reserve their output allowance together")
    }

    func testSelectionAndPlansExpireAndRevocationRejectsExistingAccess() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let clock = TestClock()
        let service = fixture.service(clock: { clock.now() })
        let selection = try await service.authorizeContent(accountID: "local-default", articleIDs: ["a"])
        let plan = try await makePlan(service)
        let approval = try await service.approve(planID: plan)
        clock.advance(901)
        await expectFailure("UNAUTHORIZED") {
            _ = try await service.call(tool: "paperrss_get_content", arguments: [
                "account_id": account, "article_id": .string("a"), "selection_id": .string(selection)
            ])
        }
        await expectFailure("CONFLICT") {
            _ = try await service.call(tool: "paperrss_apply_state_change", arguments: applyArguments(plan: plan, approval: approval))
        }
        await service.revoke()
        await expectFailure("NOT_ENABLED") { _ = try await service.call(tool: "paperrss_list_articles", arguments: unread) }
        XCTAssertFalse(try fixture.state("a").isRead)
    }

    func testPlanHasNoSideEffectsAndApplyRequiresAppApproval() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service()
        let beforeA = try fixture.state("a"), beforeB = try fixture.state("b")
        let plan = try await makePlan(service)
        XCTAssertEqual(try fixture.state("a"), beforeA)
        XCTAssertEqual(try fixture.state("b"), beforeB)
        await expectFailure("CONFIRMATION_REQUIRED") {
            _ = try await service.call(tool: "paperrss_apply_state_change", arguments: applyArguments(plan: plan, approval: "self-signed"))
        }
        let approval = try await service.approve(planID: plan)
        let receipt = try await service.call(tool: "paperrss_apply_state_change", arguments: applyArguments(plan: plan, approval: approval))
        XCTAssertEqual(receipt["local_commit"], .string("committed"))
        XCTAssertEqual(receipt["sync"], .string("local_only"))
        XCTAssertEqual(receipt["applied_count"], .number(2))
        XCTAssertTrue(try fixture.state("a").isRead)
        XCTAssertTrue(try fixture.state("b").isRead)
    }

    func testAlreadyReadArticlesAreSkippedAtApply() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service()
        let plan = try await makePlan(service)
        let approval = try await service.approve(planID: plan)
        try fixture.provider.markRead(entryID: "b", read: true)
        let receipt = try await service.call(tool: "paperrss_apply_plan", arguments: applyArguments(plan: plan, approval: approval))
        XCTAssertEqual(receipt["applied_count"], .number(1))
        XCTAssertEqual(receipt["skipped_count"], .number(1))
        XCTAssertTrue(try fixture.state("a").isRead)
        XCTAssertTrue(try fixture.state("b").isRead)
    }

    func testIdempotencyReturnsSameReceiptAndRejectsRebinding() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let clock = TestClock()
        let service = fixture.service(clock: { clock.now() })
        let plan = try await makePlan(service, field: "starred")
        let approval = try await service.approve(planID: plan)
        let args = applyArguments(plan: plan, approval: approval)
        let first = try await service.call(tool: "paperrss_apply_state_change", arguments: args)
        let committed = try fixture.state("a")
        clock.advance(901)
        let replay = try await service.call(tool: "paperrss_apply_state_change", arguments: args)
        XCTAssertEqual(first, replay)
        XCTAssertEqual(try fixture.state("a"), committed)
        await expectFailure("CONFLICT") {
            _ = try await service.call(tool: "paperrss_apply_state_change", arguments: applyArguments(plan: "another-plan", approval: approval))
        }
        let status = try await service.call(tool: "paperrss_status", arguments: ["operation_id": try XCTUnwrap(first["operation_id"])])
        XCTAssertEqual(status["receipt"], first)
    }

    func testDatabaseFailureRollsBackAndDoesNotProduceReceipt() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service()
        let plan = try await makePlan(service)
        let approval = try await service.approve(planID: plan)
        try fixture.database.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER agent_fixture_write_failure BEFORE UPDATE ON article_states
                WHEN NEW.item_id = 'b'
                BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;
                """)
        }
        do {
            _ = try await service.call(tool: "paperrss_apply_state_change", arguments: applyArguments(plan: plan, approval: approval))
            XCTFail("Database errors must propagate, never become a successful receipt")
        } catch is DatabaseError {
            // The transport converts this into a generic internal error without leaking SQL.
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(try fixture.state("a").isRead)
        XCTAssertFalse(try fixture.state("b").isRead)
        let status = try await service.call(tool: "paperrss_status", arguments: ["plan_id": .string(plan)])
        XCTAssertNil(status["receipt"])
        XCTAssertEqual(status["plan_state"], .string("approved"))
        try fixture.database.write { db in try db.execute(sql: "DROP TRIGGER agent_fixture_write_failure;") }
        let retry = try await service.call(tool: "paperrss_apply_state_change", arguments: applyArguments(plan: plan, approval: approval))
        XCTAssertEqual(retry["local_commit"], .string("committed"))
    }

    func testReadsUseEveryEnabledAccountWithoutRelaxingContentOrWrites() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service()
        var allowed: Set<String> = ["local-default"]
        for type in [AccountType.iCloud, .freshRSS, .miniflux] {
            let id = "fixture-" + type.rawValue
            let provider = LocalAccountProvider(accountID: id, database: fixture.database)
            try provider.ensureAccountExists()
            try fixture.database.write { db in
                try db.execute(sql: "UPDATE accounts SET type = ? WHERE id = ?", arguments: [type.rawValue, id])
            }
            let feed = try provider.addFeed(title: type.rawValue, feedURL: URL(string: "https://example.org/" + id)!)
            let article = id + "-article"
            try fixture.database.write { db in
                try ItemRecord(id: article, accountID: id, externalID: article, feedID: feed.id.uuidString,
                               createdAt: 1, updatedAt: 1).insert(db)
                try ArticleRecord(itemID: article, title: "Remote metadata", summary: "Summary").insert(db)
                try ArticleStateRecord(itemID: article, isRead: false, isStarred: false,
                                       dateArrived: 1, updatedAt: 1).insert(db)
            }
            allowed.insert(id)
            await service.updateAccountIDs(allowed)
            let feeds = try await service.call(tool: "paperrss_list_feeds", arguments: ["account_id": .string(id)])
            XCTAssertEqual(feeds["feeds"]?.arrayValue?.map { $0["id"] }, [.string(feed.id.uuidString)])
            XCTAssertEqual(feeds["feeds"]?.arrayValue?.first?["unread_count"], .number(1))
            let articles = try await service.call(tool: "paperrss_list_articles", arguments: ["account_id": .string(id), "scope": .string("unread")])
            XCTAssertEqual(articles["articles"]?.arrayValue?.map { $0["id"] }, [.string(article)])
            let metadata = try await service.call(tool: "paperrss_get_article", arguments: ["account_id": .string(id), "article_id": .string(article)])
            XCTAssertEqual(metadata["account_id"], .string(id))
            await expectFailure("UNAUTHORIZED") {
                _ = try await service.call(tool: "paperrss_get_content", arguments: ["account_id": .string(id), "article_id": .string(article), "selection_id": .string("self-approved")])
            }
            await expectFailure("UNSUPPORTED") {
                _ = try await service.call(tool: "paperrss_plan_state_change", arguments: ["account_id": .string(id), "article_ids": .array([.string(article)]), "field": .string("read"), "value": .bool(true)])
            }
            try fixture.database.write { db in
                try db.execute(sql: "UPDATE accounts SET is_enabled = 0 WHERE id = ?", arguments: [id])
            }
            await expectFailure("NOT_FOUND") {
                _ = try await service.call(tool: "paperrss_list_feeds", arguments: ["account_id": .string(id)])
            }
        }
        let local = try await service.call(tool: "paperrss_list_feeds", arguments: ["account_id": account])
        XCTAssertEqual(local["feeds"]?.arrayValue?.count, 1)
    }

    func testOpenCallsInjectedUIWithOwnedIDsWithoutChangingReadState() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        var requests: [AgentOpenRequest] = []
        let service = AgentLibraryService(database: fixture.database,
            policy: AgentAccessPolicy(enabled: true, accountIDs: ["local-default"]),
            opener: { requests.append($0) })
        let before = try fixture.state("a")
        let article = try await service.call(tool: "paperrss_open", arguments: ["account_id": account, "article_id": .string("a")])
        XCTAssertEqual(article["opened"], .string("article"))
        XCTAssertEqual(article["id"], .string("a"))
        XCTAssertEqual(article["title"], .string("Swift concurrency"))
        XCTAssertEqual(article["feed_title"], .string("Fixture feed"))
        XCTAssertEqual(try fixture.state("a"), before)
        let feed = try await service.call(tool: "paperrss_open", arguments: ["account_id": account, "feed_id": .string(fixture.feed.id.uuidString)])
        XCTAssertEqual(feed["opened"], .string("feed"))
        XCTAssertEqual(requests, [AgentOpenRequest(accountID: "local-default", feedID: fixture.feed.id, articleID: "a"),
                                  AgentOpenRequest(accountID: "local-default", feedID: fixture.feed.id)])
        // Read articles outside metadata scope may still be located without granting content.
        _ = try await service.call(tool: "paperrss_open", arguments: ["account_id": account, "article_id": .string("c")])
        XCTAssertTrue(try fixture.state("c").isRead)
    }

    func testOpenReservesBudgetBeforeUIAndRefundsFailedNavigation() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        var attempts = 0
        let small = AgentLibraryService(database: fixture.database,
            policy: AgentAccessPolicy(enabled: true, accountIDs: ["local-default"], outputCharacterBudget: 1),
            opener: { _ in attempts += 1 })
        let arguments: [String: AgentJSON] = ["account_id": account, "article_id": .string("a")]
        await expectFailure("CONTENT_BUDGET_EXCEEDED") {
            _ = try await small.call(tool: "paperrss_open", arguments: arguments)
        }
        XCTAssertEqual(attempts, 0)
        let failing = AgentLibraryService(database: fixture.database,
            policy: AgentAccessPolicy(enabled: true, accountIDs: ["local-default"], outputCharacterBudget: 100),
            opener: { _ in attempts += 1; throw AgentFailure("NOT_FOUND", "Fixture navigation failed.") })
        await expectFailure("NOT_FOUND") {
            _ = try await failing.call(tool: "paperrss_open", arguments: arguments)
        }
        XCTAssertEqual(attempts, 1)
        let status = try await failing.call(tool: "paperrss_status", arguments: [:])
        XCTAssertEqual(status["remaining_characters"], .number(100))
        XCTAssertFalse(try fixture.state("a").isRead)
    }

    func testOpenRejectsInvalidTargetsDisabledAndForeignAccountsBeforeUI() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        var requests: [AgentOpenRequest] = []
        let service = AgentLibraryService(database: fixture.database,
            policy: AgentAccessPolicy(enabled: true, accountIDs: ["local-default", "other"]),
            opener: { requests.append($0) })
        for args: [String: AgentJSON] in [
            ["account_id": account], ["account_id": account, "article_id": .string("a"), "feed_id": .string("f")],
            ["account_id": account, "article_id": .null], ["account_id": account, "feed_id": .string("")]
        ] {
            await expectFailure("INVALID_ARGUMENT") { _ = try await service.call(tool: "paperrss_open", arguments: args) }
        }
        let other = LocalAccountProvider(accountID: "other", database: fixture.database)
        try other.ensureAccountExists()
        for args: [String: AgentJSON] in [
            ["account_id": .string("other"), "article_id": .string("a")],
            ["account_id": .string("other"), "feed_id": .string(fixture.feed.id.uuidString)],
            ["account_id": .string("unknown"), "article_id": .string("a")],
            ["account_id": account, "article_id": .string("missing")],
            ["account_id": account, "feed_id": .string(UUID().uuidString)]
        ] {
            await expectFailure("NOT_FOUND") { _ = try await service.call(tool: "paperrss_open", arguments: args) }
        }
        try fixture.database.write { db in
            try db.execute(sql: "UPDATE accounts SET is_enabled = 0 WHERE id = ?", arguments: ["local-default"])
        }
        await expectFailure("NOT_FOUND") {
            _ = try await service.call(tool: "paperrss_open", arguments: ["account_id": account, "article_id": .string("a")])
        }
        XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(try fixture.state("a").isRead)
    }

    func testStateCapabilityAndSyncedAccountsAreRejected() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let readOnly = fixture.service(writes: false)
        await expectFailure("UNAUTHORIZED") { _ = try await makePlan(readOnly) }
        let service = fixture.service()
        try fixture.database.write { db in
            try db.execute(sql: "UPDATE accounts SET type = ? WHERE id = ?", arguments: [AccountType.iCloud.rawValue, "local-default"])
        }
        await expectFailure("UNSUPPORTED") { _ = try await makePlan(service) }
    }

    func testMarkReadSnapshotExcludesLaterArrivalsAndSupportsBefore() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service()
        let result = try await service.call(tool: "paperrss_plan_mark_read", arguments: [
            "account_id": account, "scope": .string("feed"), "feed_id": .string(fixture.feed.id.uuidString),
            "before": .string("2023-11-14T22:13:21Z")])
        XCTAssertEqual(result["article_ids"], .array([.string("a")]))
        XCTAssertEqual(result["affected_feeds"], .array([
            .object(["id": .string(fixture.feed.id.uuidString), "title": .string("Fixture feed")])]))
        let id = try XCTUnwrap(result["plan_id"]?.stringValue)
        try fixture.database.write { db in
            try ItemRecord(id: "later", accountID: "local-default", externalID: "later", feedID: fixture.feed.id.uuidString,
                           createdAt: 1, updatedAt: 1).insert(db)
            try ArticleRecord(itemID: "later", title: "Later arrival", publishedAt: 1).insert(db)
            try ArticleStateRecord(itemID: "later", dateArrived: 1, updatedAt: 1).insert(db)
        }
        let approval = try await service.approve(planID: id)
        let receipt = try await service.call(tool: "paperrss_apply_plan", arguments: applyArguments(plan: id, approval: approval))
        XCTAssertEqual(receipt["applied_count"], .number(1))
        XCTAssertFalse(try fixture.state("later").isRead)
        XCTAssertFalse(try fixture.state("b").isRead)
    }

    func testMarkReadFolderAndAccountScopesAndCap() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        try fixture.database.write { db in
            try FolderRecord(id: "folder", accountID: "local-default", name: "Science", updatedAt: 1).insert(db)
            try FeedFolderRecord(feedID: fixture.feed.id.uuidString, folderID: "folder").insert(db)
        }
        let service = fixture.service()
        for folder in ["folder", "Science"] {
            let plan = try await service.call(tool: "paperrss_plan_mark_read", arguments: [
                "account_id": account, "scope": .string("folder"), "folder": .string(folder)])
            XCTAssertEqual(plan["article_ids"], .array([.string("a"), .string("b")]))
            XCTAssertEqual(plan["affected_feeds"]?.arrayValue?.map { $0["id"] }, [.string(fixture.feed.id.uuidString)])
        }
        let plan = try await service.call(tool: "paperrss_plan_mark_read", arguments: ["account_id": account, "scope": .string("account")])
        XCTAssertEqual(plan["affected_count"], .number(2))
        try fixture.database.write { db in
            for index in 0..<4999 {
                let id = "cap-\(index)"
                try ItemRecord(id: id, accountID: "local-default", externalID: id, feedID: fixture.feed.id.uuidString, createdAt: 1, updatedAt: 1).insert(db)
                try ArticleRecord(itemID: id, title: "Cap fixture").insert(db)
                try ArticleStateRecord(itemID: id, dateArrived: 1, updatedAt: 1).insert(db)
            }
        }
        await expectFailure("INVALID_ARGUMENT") {
            _ = try await service.call(tool: "paperrss_plan_mark_read", arguments: ["account_id": account, "scope": .string("account")])
        }
    }

    func testSnapshotApplyRejectsRemovedArticleWithoutPartialCommit() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service()
        let plan = try await service.call(tool: "paperrss_plan_mark_read", arguments: ["account_id": account, "scope": .string("account")])
        let id = try XCTUnwrap(plan["plan_id"]?.stringValue)
        await expectFailure("CONFIRMATION_REQUIRED") {
            _ = try await service.call(tool: "paperrss_apply_plan", arguments: applyArguments(plan: id, approval: "client-issued"))
        }
        let approval = try await service.approve(planID: id)
        try fixture.database.write { db in try db.execute(sql: "DELETE FROM items WHERE id = 'b'") }
        await expectFailure("NOT_FOUND") {
            _ = try await service.call(tool: "paperrss_apply_plan", arguments: applyArguments(plan: id, approval: approval))
        }
        XCTAssertFalse(try fixture.state("a").isRead)
    }

    func testDeniedAndCrossSessionApprovalCannotWriteAndExpiryStaysVisible() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let clock = TestClock(), service = fixture.service()
        let id = try await makePlan(service)
        let other = fixture.service()
        await expectFailure("CONFLICT") { _ = try await other.approve(planID: id) }
        try await service.deny(planID: id)
        let status = try await service.call(tool: "paperrss_status", arguments: ["plan_id": .string(id)])
        XCTAssertEqual(status["plan_state"], .string("denied"))
        XCTAssertEqual(status["pending_approvals"], .number(0))
        XCTAssertNil(status["approval_id"])
        await expectFailure("DENIED") { _ = try await service.approve(planID: id) }
        await expectFailure("DENIED") {
            _ = try await service.call(tool: "paperrss_apply_plan", arguments: applyArguments(plan: id, approval: "fake"))
        }
        let expiring = fixture.service(clock: { clock.now() })
        let expiredID = try await makePlan(expiring)
        clock.advance(901)
        _ = try await expiring.call(tool: "paperrss_list_feeds", arguments: ["account_id": account])
        let expired = try await expiring.call(tool: "paperrss_status", arguments: ["plan_id": .string(expiredID)])
        XCTAssertEqual(expired["plan_state"], .string("expired"))
        XCTAssertEqual(expired["pending_approvals"], .number(0))
    }

    private actor RecordingExecutor: AgentWriteExecutor {
        var calls: [[String]] = []
        func execute(accountID: String, articleIDs: [String], field: AgentStateField, value: Bool, expiresAt: Date) async throws -> AgentWriteResult {
            calls.append([accountID] + articleIDs)
            return AgentWriteResult(appliedCount: articleIDs.count, skippedCount: 0, sync: "queued_for_sync")
        }
    }

    func testRemoteAccountExecutorReceivesExactSnapshotAndReplayDoesNotExecuteAgain() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        for type in [AccountType.iCloud, .freshRSS, .miniflux] {
            try fixture.database.write { db in
                try db.execute(sql: "UPDATE accounts SET type = ? WHERE id = 'local-default'", arguments: [type.rawValue])
            }
            let executor = RecordingExecutor()
            let service = AgentLibraryService(database: fixture.database,
                policy: AgentAccessPolicy(enabled: true, accountIDs: ["local-default"], allowStateChanges: true), writeExecutor: executor)
            let plan = try await service.call(tool: "paperrss_plan_mark_read", arguments: ["account_id": account, "scope": .string("account")])
            let id = try XCTUnwrap(plan["plan_id"]?.stringValue)
            let approval = try await service.approve(planID: id)
            let args = applyArguments(plan: id, approval: approval)
            let receipt = try await service.call(tool: "paperrss_apply_plan", arguments: args)
            XCTAssertEqual(receipt["sync"], .string("queued_for_sync"))
            let replay = try await service.call(tool: "paperrss_apply_state_change", arguments: args)
            XCTAssertEqual(receipt, replay)
            let calls = await executor.calls
            XCTAssertEqual(calls, [["local-default", "a", "b"]])
            let status = try await service.call(tool: "paperrss_status", arguments: ["plan_id": .string(id)])
            XCTAssertEqual(status["plan_state"], .string("committed"))
            XCTAssertNil(status["approval_id"])
        }
    }

    func testMixedBatchRequiresApprovalAndReplaysEveryResult() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let renamed = try fixture.provider.addFeed(title: "Old", feedURL: URL(string: "https://example.org/rename")!)
        let service = fixture.service()
        let plan = try await service.call(tool: "paperrss_plan_manage_feeds", arguments: ["account_id": account, "operations": .array([
            .object(["action": .string("add_feed"), "url": .string("https://example.org/new"), "title": .string("New"), "folder": .string("Tech")]),
            .object(["action": .string("rename_feed"), "feed_id": .string(renamed.id.uuidString), "title": .string("Renamed")]),
            .object(["action": .string("remove_feed"), "feed_id": .string(fixture.feed.id.uuidString)])])])
        let id = try XCTUnwrap(plan["plan_id"]?.stringValue)
        XCTAssertEqual(plan["destructive_hint"], .bool(true))
        XCTAssertEqual(plan["affected_count"], .number(3))
        XCTAssertEqual(plan["feed_changes"]?.arrayValue?.count, 3)
        XCTAssertEqual(try fixture.provider.fetchFeeds().count, 2)
        await expectFailure("CONFIRMATION_REQUIRED") {
            _ = try await service.call(tool: "paperrss_apply_plan", arguments: applyArguments(plan: id, approval: "forged"))
        }
        let approval = try await service.approve(planID: id)
        let receipt = try await service.call(tool: "paperrss_apply_plan", arguments: applyArguments(plan: id, approval: approval))
        XCTAssertEqual(receipt["applied_count"], .number(3))
        XCTAssertEqual(receipt["failed_count"], .number(0))
        XCTAssertEqual(receipt["results"]?.arrayValue?.count, 3)
        let replay = try await service.call(tool: "paperrss_apply_plan", arguments: applyArguments(plan: id, approval: approval, key: "another-key"))
        XCTAssertEqual(receipt, replay)
        let feeds = try fixture.provider.fetchFeeds()
        XCTAssertEqual(feeds.count, 2)
        XCTAssertEqual(feeds.first { $0.id == renamed.id }?.title, "Renamed")
        XCTAssertEqual(feeds.first { $0.title == "New" }?.folder, "Tech")
        XCTAssertFalse(feeds.contains { $0.id == fixture.feed.id })
    }

    func testBatchRevalidatesAtApplyAndRecordsPartialFailureWithoutRepeatingSuccess() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service()
        let plan = try await service.call(tool: "paperrss_plan_manage_feeds", arguments: ["account_id": account, "operations": .array([
            .object(["action": .string("add_feed"), "url": .string("https://example.org/concurrent")]),
            .object(["action": .string("rename_feed"), "feed_id": .string(fixture.feed.id.uuidString), "title": .string("Renamed")])])])
        _ = try fixture.provider.addFeed(title: "Concurrent", feedURL: URL(string: "https://example.org/concurrent")!)
        let id = try XCTUnwrap(plan["plan_id"]?.stringValue)
        let approval = try await service.approve(planID: id)
        let receipt = try await service.call(tool: "paperrss_apply_plan", arguments: applyArguments(plan: id, approval: approval))
        XCTAssertEqual(receipt["local_commit"], .string("partial"))
        XCTAssertEqual(receipt["applied_count"], .number(1))
        XCTAssertEqual(receipt["failed_count"], .number(1))
        XCTAssertEqual(receipt["results"]?.arrayValue?.first?["error_code"], .string("CONFLICT"))
        let replay = try await service.call(tool: "paperrss_apply_plan", arguments: applyArguments(plan: id, approval: approval))
        XCTAssertEqual(receipt, replay)
        XCTAssertEqual(try fixture.provider.fetchFeeds().count, 2)
    }

    private actor PartiallyFailingFeedExecutor: AgentWriteExecutor {
        private(set) var count = 0
        func execute(accountID: String, articleIDs: [String], field: AgentStateField, value: Bool, expiresAt: Date) async throws -> AgentWriteResult {
            throw AgentFailure("UNSUPPORTED", "Feed-only fixture")
        }
        func executeFeed(_ mutation: AgentFeedMutation, expiresAt: Date) async throws -> AgentFeedWriteResult {
            count += 1
            if mutation.url?.contains("/fail") == true {
                throw NSError(domain: "private", code: 1, userInfo: [NSLocalizedDescriptionKey: "SECRET_SENTINEL"])
            }
            return AgentFeedWriteResult(feedID: "created", title: mutation.title, sync: "server_committed")
        }
    }

    func testBatchProviderFailureIsRedactedAndReplayDoesNotExecuteAgain() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let executor = PartiallyFailingFeedExecutor()
        let service = AgentLibraryService(database: fixture.database,
            policy: AgentAccessPolicy(enabled: true, accountIDs: ["local-default"], allowStateChanges: true), writeExecutor: executor)
        let plan = try await service.call(tool: "paperrss_plan_manage_feeds", arguments: ["account_id": account, "operations": .array([
            .object(["action": .string("add_feed"), "url": .string("https://example.org/ok")]),
            .object(["action": .string("add_feed"), "url": .string("https://example.org/fail")])])])
        let id = try XCTUnwrap(plan["plan_id"]?.stringValue)
        let approval = try await service.approve(planID: id)
        let receipt = try await service.call(tool: "paperrss_apply_plan", arguments: applyArguments(plan: id, approval: approval))
        XCTAssertEqual(receipt["failed_count"], .number(1))
        XCTAssertEqual(receipt["results"]?.arrayValue?.last?["error_code"], .string("INTERNAL_ERROR"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self).contains("SECRET_SENTINEL"))
        _ = try await service.call(tool: "paperrss_apply_plan", arguments: applyArguments(plan: id, approval: approval, key: "new-key"))
        let count = await executor.count
        XCTAssertEqual(count, 2)
    }

    func testInvalidBatchDoesNotLeavePlansOrWriteOtherOperations() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service()
        let valid: AgentJSON = .object(["action": .string("add_feed"), "url": .string("https://example.org/new")])
        for bad in [valid, .object(["action": .string("remove_feed"), "feed_id": .string(UUID().uuidString)]),
                    .object(["action": .string("remove_feed"), "feed_id": .string(fixture.feed.id.uuidString), "account_id": .string("other")])] {
            do {
                _ = try await service.call(tool: "paperrss_plan_manage_feeds", arguments: ["account_id": account, "operations": .array([valid, bad])])
                XCTFail("Invalid batch should fail before creating a plan")
            } catch is AgentFailure {}
        }
        let status = try await service.call(tool: "paperrss_status", arguments: [:])
        XCTAssertEqual(status["pending_approvals"], .number(0))
        XCTAssertEqual(try fixture.provider.fetchFeeds().count, 1)
    }

    func testFeedAliasesCreatePlansWithoutWritesAndRemovalWarnsAboutStarredHistory() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service()
        let cases: [(String, [String: AgentJSON])] = [
            ("add_feed", ["account_id": account, "url": .string("https://example.org/new")]),
            ("rename_feed", ["account_id": account, "feed_id": .string(fixture.feed.id.uuidString), "title": .string("Renamed")]),
            ("remove_feed", ["account_id": account, "feed_id": .string(fixture.feed.id.uuidString)])
        ]
        for (kind, args) in cases {
            for name in ["paperrss_" + kind, "paperrss_plan_" + kind] {
                let plan = try await service.call(tool: name, arguments: args)
                XCTAssertEqual(plan["approval"], .string("pending"))
                XCTAssertEqual(plan["action_kind"], .string(kind))
                XCTAssertEqual(plan["affected_feeds"], .array(kind == "add_feed" ? [] : [
                    .object(["id": .string(fixture.feed.id.uuidString), "title": .string("Fixture feed")])]))
                XCTAssertEqual(plan["untrusted"], .bool(true))
                if kind == "remove_feed" {
                    XCTAssertEqual(plan["affected_count"], .number(3))
                    XCTAssertEqual(plan["destructive_hint"], .bool(true))
                    XCTAssertTrue(plan["summary_en"]?.stringValue?.contains("1 starred") == true)
                    XCTAssertTrue(plan["retention_notice"]?.stringValue?.contains("No undo") == true)
                }
            }
        }
        let feeds = try fixture.provider.fetchFeeds()
        XCTAssertEqual(feeds.count, 1)
        XCTAssertEqual(feeds.first?.title, "Fixture feed")
        XCTAssertTrue(try fixture.state("c").isStarred)
    }

    func testLocalFeedLifecycleRequiresApprovalAndReturnsAddReceipt() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service()
        let plan = try await service.call(tool: "paperrss_plan_add_feed", arguments: [
            "account_id": account, "url": .string("https://example.org/new"), "title": .string("New feed"), "folder": .string("Science")])
        let id = try XCTUnwrap(plan["plan_id"]?.stringValue)
        await expectFailure("CONFIRMATION_REQUIRED") {
            _ = try await service.call(tool: "paperrss_apply_plan", arguments: applyArguments(plan: id, approval: "forged"))
        }
        XCTAssertEqual(try fixture.provider.fetchFeeds().count, 1)
        let approval = try await service.approve(planID: id)
        let args = applyArguments(plan: id, approval: approval)
        let receipt = try await service.call(tool: "paperrss_apply_plan", arguments: args)
        let feedID = try XCTUnwrap(receipt["feed_id"]?.stringValue)
        XCTAssertEqual(receipt["feed_title"], .string("New feed"))
        XCTAssertEqual(receipt["sync"], .string("local_only"))
        let replay = try await service.call(tool: "paperrss_apply_plan", arguments: args)
        XCTAssertEqual(replay, receipt)
        XCTAssertEqual(try fixture.provider.fetchFeeds().count, 2)
        for (index, kind) in ["rename_feed", "remove_feed"].enumerated() {
            var arguments: [String: AgentJSON] = ["account_id": account, "feed_id": .string(feedID)]
            if kind == "rename_feed" { arguments["title"] = .string("Renamed") }
            let plan = try await service.call(tool: "paperrss_plan_" + kind, arguments: arguments)
            let id = try XCTUnwrap(plan["plan_id"]?.stringValue)
            let approval = try await service.approve(planID: id)
            _ = try await service.call(tool: "paperrss_apply_plan", arguments: applyArguments(plan: id, approval: approval, key: "lifecycle-\(index)"))
            let feeds = try fixture.provider.fetchFeeds()
            if kind == "rename_feed" { XCTAssertEqual(feeds.first { $0.id.uuidString == feedID }?.title, "Renamed") }
            else { XCTAssertNil(feeds.first { $0.id.uuidString == feedID }) }
        }
    }

    func testFeedPlanURLTitleDuplicateAndOwnershipValidation() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let other = LocalAccountProvider(accountID: "other", database: fixture.database)
        try other.ensureAccountExists()
        let service = AgentLibraryService(database: fixture.database,
            policy: AgentAccessPolicy(enabled: true, accountIDs: ["local-default", "other"], allowStateChanges: true))
        for url in ["file:///tmp/feed", "ftp://example.org/feed", "https://user:password@example.org/feed", "https:///", "not a URL"] {
            await expectFailure("INVALID_ARGUMENT") {
                _ = try await service.call(tool: "paperrss_plan_add_feed", arguments: ["account_id": account, "url": .string(url)])
            }
        }
        await expectFailure("CONFLICT") {
            _ = try await service.call(tool: "paperrss_plan_add_feed", arguments: ["account_id": account, "url": .string(fixture.feed.feedURL.absoluteString)])
        }
        for title in ["", "  ", String(repeating: "x", count: 201)] {
            await expectFailure("INVALID_ARGUMENT") {
                _ = try await service.call(tool: "paperrss_plan_rename_feed", arguments: ["account_id": account, "feed_id": .string(fixture.feed.id.uuidString), "title": .string(title)])
            }
        }
        await expectFailure("NOT_FOUND") {
            _ = try await service.call(tool: "paperrss_plan_remove_feed", arguments: ["account_id": .string("other"), "feed_id": .string(fixture.feed.id.uuidString)])
        }
        await expectFailure("INVALID_ARGUMENT") {
            _ = try await service.call(tool: "paperrss_add_feed", arguments: ["account_id": account, "url": .string("https://example.org/new"), "approval_id": .string("forged")])
        }
        let secretPlan = try await service.call(tool: "paperrss_plan_add_feed", arguments: ["account_id": account, "url": .string("https://example.org/new?token=SECRET_SENTINEL")])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(secretPlan), as: UTF8.self).contains("SECRET_SENTINEL"))
    }

    func testFeedApplyRechecksDuplicateOwnershipDenialAndExpiry() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let clock = TestClock(), service = fixture.service(clock: { clock.now() })
        let args: [String: AgentJSON] = ["account_id": account, "url": .string("https://example.org/new")]
        let plan = try await service.call(tool: "paperrss_plan_add_feed", arguments: args)
        let id = try XCTUnwrap(plan["plan_id"]?.stringValue)
        let approval = try await service.approve(planID: id)
        _ = try fixture.provider.addFeed(title: "Concurrent subscription", feedURL: URL(string: "https://example.org/new")!)
        await expectFailure("CONFLICT") {
            _ = try await service.call(tool: "paperrss_apply_plan", arguments: applyArguments(plan: id, approval: approval))
        }
        for mode in ["denied", "expired", "removed"] {
            let plan = try await service.call(tool: "paperrss_plan_remove_feed", arguments: ["account_id": account, "feed_id": .string(fixture.feed.id.uuidString)])
            let id = try XCTUnwrap(plan["plan_id"]?.stringValue)
            let approval = try await service.approve(planID: id)
            if mode == "denied" { try await service.deny(planID: id) }
            if mode == "expired" { clock.advance(901) }
            if mode == "removed" { try await fixture.provider.deleteFeed(feedID: fixture.feed.id) }
            await expectFailure(mode == "denied" ? "DENIED" : mode == "expired" ? "CONFLICT" : "NOT_FOUND") {
                _ = try await service.call(tool: "paperrss_apply_plan", arguments: applyArguments(plan: id, approval: approval, key: mode))
            }
        }
    }

    private actor FeedRecordingExecutor: AgentWriteExecutor {
        var calls: [AgentFeedMutation] = []
        func execute(accountID: String, articleIDs: [String], field: AgentStateField, value: Bool, expiresAt: Date) async throws -> AgentWriteResult {
            throw AgentFailure("UNSUPPORTED", "Only feed fixture writes are supported.")
        }
        func executeFeed(_ mutation: AgentFeedMutation, expiresAt: Date) async throws -> AgentFeedWriteResult {
            calls.append(mutation)
            return AgentFeedWriteResult(feedID: mutation.feedID ?? "fake-added-feed", title: mutation.title ?? "Server title", sync: "synced")
        }
    }

    func testEveryAccountFeedMutationUsesFakeExecutorAndReplayDoesNotRepeat() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        for type in [AccountType.local, .iCloud, .freshRSS, .miniflux] {
            try fixture.database.write { db in
                try db.execute(sql: "UPDATE accounts SET type = ? WHERE id = 'local-default'", arguments: [type.rawValue])
            }
            let executor = FeedRecordingExecutor()
            let service = AgentLibraryService(database: fixture.database,
                policy: AgentAccessPolicy(enabled: true, accountIDs: ["local-default"], allowStateChanges: true), writeExecutor: executor)
            let status = try await service.call(tool: "paperrss_status", arguments: [:])
            XCTAssertTrue(status["accounts"]?.arrayValue?.first?["capabilities"]?.arrayValue?.contains(.string("feeds.manage.approval")) == true)
            for kind in ["add_feed", "rename_feed", "remove_feed"] {
                var args: [String: AgentJSON] = ["account_id": account]
                if kind == "add_feed" { args["url"] = .string("https://example.org/new"); args["folder"] = .string("Science") }
                else { args["feed_id"] = .string(fixture.feed.id.uuidString) }
                if kind != "remove_feed" { args["title"] = .string("Requested title") }
                let plan = try await service.call(tool: "paperrss_plan_" + kind, arguments: args)
                let id = try XCTUnwrap(plan["plan_id"]?.stringValue)
                let approval = try await service.approve(planID: id)
                let apply = applyArguments(plan: id, approval: approval, key: kind)
                let receipt = try await service.call(tool: "paperrss_apply_plan", arguments: apply)
                XCTAssertEqual(receipt["sync"], .string("synced"))
                if kind == "add_feed" { XCTAssertEqual(receipt["feed_id"], .string("fake-added-feed")); XCTAssertEqual(receipt["feed_title"], .string("Requested title")) }
                let replay = try await service.call(tool: "paperrss_apply_plan", arguments: apply)
                XCTAssertEqual(receipt, replay)
            }
            let calls = await executor.calls
            XCTAssertEqual(calls.map(\.kind), ["add_feed", "rename_feed", "remove_feed"])
            XCTAssertEqual(calls.map(\.accountID), Array(repeating: "local-default", count: 3))
            XCTAssertEqual(calls.first?.folder, "Science")
            XCTAssertEqual(try fixture.provider.fetchFeeds().count, 1)
        }
    }

    func testFeedUnsupportedExecutorFailsWithoutSuccessReceipt() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = AgentLibraryService(database: fixture.database,
            policy: AgentAccessPolicy(enabled: true, accountIDs: ["local-default"], allowStateChanges: true), writeExecutor: RecordingExecutor())
        let plan = try await service.call(tool: "paperrss_plan_add_feed", arguments: ["account_id": account, "url": .string("https://example.org/new")])
        let id = try XCTUnwrap(plan["plan_id"]?.stringValue)
        let approval = try await service.approve(planID: id)
        await expectFailure("UNSUPPORTED") {
            _ = try await service.call(tool: "paperrss_apply_plan", arguments: applyArguments(plan: id, approval: approval))
        }
        let status = try await service.call(tool: "paperrss_status", arguments: ["plan_id": .string(id)])
        XCTAssertEqual(status["plan_state"], .string("approved"))
        XCTAssertNil(status["receipt"])
        XCTAssertEqual(try fixture.provider.fetchFeeds().count, 1)
    }
}

extension AgentLibraryServiceTests {
    func testAppApproveAppliesAndReplaysReceiptWithoutClientApply() async throws {
        let fixture = try Fixture()
        defer { try? fixture.remove() }
        let service = fixture.service()
        let id = try await makePlan(service)
        let approval = try await service.approveAndApply(planID: id)
        XCTAssertTrue(try fixture.state("a").isRead)
        let status = try await service.call(tool: "paperrss_status", arguments: ["plan_id": .string(id)])
        XCTAssertEqual(status["plan_state"], .string("committed"))
        XCTAssertNotNil(status["receipt"])
        let repeated = try await service.approveAndApply(planID: id)
        XCTAssertEqual(repeated, approval)
        let replay = try await service.call(tool: "paperrss_apply_plan", arguments: applyArguments(plan: id, approval: approval, key: "client-retry"))
        XCTAssertEqual(replay, status["receipt"])
        await expectFailure("CONFLICT") {
            _ = try await service.call(tool: "paperrss_apply_plan", arguments: applyArguments(plan: "another-plan", approval: approval, key: "client-retry"))
        }
        await expectFailure("CONFIRMATION_REQUIRED") {
            _ = try await service.call(tool: "paperrss_apply_plan", arguments: applyArguments(plan: id, approval: "forged", key: "forged"))
        }
    }
}

extension AgentLibraryServiceTests {
    func testFeedPreviewsDeduplicateBoundAndDecodeLegacyPlans() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service()
        let state = try await service.call(tool: "paperrss_plan_state_change", arguments: [
            "account_id": account, "article_ids": .array([.string("a"), .string("b")]),
            "field": .string("read"), "value": .bool(true)])
        XCTAssertEqual(state["affected_feeds"]?.arrayValue?.count, 1)
        let data = try JSONEncoder().encode(state)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dto = try decoder.decode(AgentStatePlan.self, from: data)
        XCTAssertEqual(dto.affected_feeds, [AgentFeedPreview(id: fixture.feed.id.uuidString, title: "Fixture feed")])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "affected_feeds")
        let old = try decoder.decode(AgentStatePlan.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(old.affected_feeds, [])

        for index in 0..<14 {
            let feed = try fixture.provider.addFeed(title: "Feed \(index)", feedURL: URL(string: "https://example.org/\(index)")!)
            try fixture.database.write { db in
                let id = "extra-\(index)"
                try ItemRecord(id: id, accountID: "local-default", externalID: id, feedID: feed.id.uuidString, createdAt: 1, updatedAt: 1).insert(db)
                try ArticleRecord(itemID: id, title: "Extra").insert(db)
                try ArticleStateRecord(itemID: id, isRead: false, dateArrived: 1, updatedAt: 1).insert(db)
            }
        }
        let all = try await service.call(tool: "paperrss_plan_mark_read", arguments: ["account_id": account, "scope": .string("account")])
        let previews = try XCTUnwrap(all["affected_feeds"]?.arrayValue)
        XCTAssertEqual(previews.count, 12)
        XCTAssertEqual(Set(previews.compactMap { $0["id"]?.stringValue }).count, 12)
        XCTAssertEqual(all["affected_count"], .number(16))
    }

    func testEmptyFeedMarkReadStillPreviewsSubscription() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        try fixture.provider.markRead(entryID: "a", read: true)
        try fixture.provider.markRead(entryID: "b", read: true)
        let plan = try await fixture.service().call(tool: "paperrss_plan_mark_read", arguments: [
            "account_id": account, "scope": .string("feed"), "feed_id": .string(fixture.feed.id.uuidString)])
        XCTAssertEqual(plan["affected_count"], .number(0))
        XCTAssertEqual(plan["affected_feeds"]?.arrayValue?.first?["id"], .string(fixture.feed.id.uuidString))
    }
}
