import XCTest
@testable import PaperRssCore

/// Reader API 服务预设（FreshRSS / Miniflux）的端点解析与账号能力测试。
final class ReaderServiceVariantTests: XCTestCase {

    // MARK: - FreshRSS 既有行为（回归保护）

    func testFreshRSSBaseURLCanonicalizationKeepsLegacyBehavior() {
        XCTAssertEqual(
            ReaderAPIClient.canonicalBaseURL(for: URL(string: "https://rss.example.com")!).absoluteString,
            "https://rss.example.com/api/greader.php"
        )
        XCTAssertEqual(
            ReaderAPIClient.canonicalBaseURL(for: URL(string: "https://rss.example.com/")!).absoluteString,
            "https://rss.example.com/api/greader.php"
        )
        XCTAssertEqual(
            ReaderAPIClient.canonicalBaseURL(for: URL(string: "https://rss.example.com/api/greader.php")!).absoluteString,
            "https://rss.example.com/api/greader.php"
        )
        XCTAssertEqual(
            ReaderAPIClient.canonicalBaseURL(for: URL(string: "https://rss.example.com/p/api/greader.php")!).absoluteString,
            "https://rss.example.com/p/api/greader.php"
        )
        XCTAssertEqual(
            ReaderAPIClient.canonicalBaseURL(for: URL(string: "https://rss.example.com/freshrss/")!).absoluteString,
            "https://rss.example.com/freshrss/api/greader.php"
        )
    }

    // MARK: - Miniflux 端点规则

    func testMinifluxBaseURLCanonicalization() {
        let variant = ReaderServiceVariant.miniflux
        XCTAssertEqual(
            ReaderAPIClient.canonicalBaseURL(for: URL(string: "https://rss.example.com")!, variant: variant).absoluteString,
            "https://rss.example.com"
        )
        XCTAssertEqual(
            ReaderAPIClient.canonicalBaseURL(for: URL(string: "https://rss.example.com/")!, variant: variant).absoluteString,
            "https://rss.example.com"
        )
        // 保留部署子路径
        XCTAssertEqual(
            ReaderAPIClient.canonicalBaseURL(for: URL(string: "https://example.com/miniflux/")!, variant: variant).absoluteString,
            "https://example.com/miniflux"
        )
        // 容忍误贴 API 前缀
        XCTAssertEqual(
            ReaderAPIClient.canonicalBaseURL(for: URL(string: "https://rss.example.com/reader/api/0")!, variant: variant).absoluteString,
            "https://rss.example.com"
        )
        XCTAssertEqual(
            ReaderAPIClient.canonicalBaseURL(for: URL(string: "https://example.com/miniflux/reader/api")!, variant: variant).absoluteString,
            "https://example.com/miniflux"
        )
    }

    func testValidatedBaseURLRejectsInvalidInput() {
        let miniflux = ReaderServiceVariant.miniflux

        XCTAssertThrowsError(try ReaderServiceVariant.validatedBaseURL(for: URL(string: "ftp://rss.example.com")!, variant: miniflux))
        XCTAssertThrowsError(try ReaderServiceVariant.validatedBaseURL(for: URL(string: "https://user:pass@rss.example.com")!, variant: miniflux))
        XCTAssertThrowsError(try ReaderServiceVariant.validatedBaseURL(for: URL(string: "https://rss.example.com?x=1")!, variant: miniflux))
        XCTAssertThrowsError(try ReaderServiceVariant.validatedBaseURL(for: URL(string: "https://rss.example.com#frag")!, variant: miniflux))
        XCTAssertThrowsError(try ReaderServiceVariant.validatedBaseURL(for: URL(string: "https:///path")!, variant: miniflux))

        let valid = try? ReaderServiceVariant.validatedBaseURL(for: URL(string: "https://rss.example.com/")!, variant: miniflux)
        XCTAssertEqual(valid?.absoluteString, "https://rss.example.com")
    }

    // MARK: - 账号类型与凭据作用域

    func testAccountTypeDerivedCapabilities() {
        XCTAssertFalse(AccountType.local.isRemote)
        XCTAssertFalse(AccountType.local.syncsRemoteArticleStates)
        XCTAssertNil(AccountType.local.readerVariant)

        XCTAssertTrue(AccountType.freshRSS.isRemote)
        XCTAssertTrue(AccountType.freshRSS.syncsRemoteArticleStates)
        XCTAssertEqual(AccountType.freshRSS.readerVariant, .freshRSS)

        XCTAssertTrue(AccountType.miniflux.isRemote)
        XCTAssertTrue(AccountType.miniflux.syncsRemoteArticleStates)
        XCTAssertEqual(AccountType.miniflux.readerVariant, .miniflux)
    }

    func testCredentialScopesUseIndependentStableKeychainServices() {
        // FreshRSS 必须沿用历史 service 名，升级后无需重新输入密码。
        XCTAssertEqual(CredentialScope.freshRSS.keychainService, "com.paperrss.freshrss")
        XCTAssertEqual(CredentialScope.miniflux.keychainService, "com.paperrss.miniflux.googlereader")
        XCTAssertNotEqual(CredentialScope.freshRSS.keychainService, CredentialScope.miniflux.keychainService)
    }

    func testInMemoryCredentialStoreSeparatesScopes() throws {
        let store = InMemoryCredentialStore()
        try store.savePassword("fresh-pwd", for: .freshRSS, accountID: "acc-1")
        try store.savePassword("miniflux-pwd", for: .miniflux, accountID: "acc-1")

        XCTAssertEqual(try store.password(for: .freshRSS, accountID: "acc-1"), "fresh-pwd")
        XCTAssertEqual(try store.password(for: .miniflux, accountID: "acc-1"), "miniflux-pwd")

        try store.deleteCredentials(for: .miniflux, accountID: "acc-1")
        XCTAssertNil(try store.password(for: .miniflux, accountID: "acc-1"))
        XCTAssertEqual(try store.password(for: .freshRSS, accountID: "acc-1"), "fresh-pwd")
    }
}
