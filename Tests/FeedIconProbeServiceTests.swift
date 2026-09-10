import XCTest
import GRDB
@testable import PaperRssCore

final class FeedIconProbeServiceTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private var database: LibraryDatabase!
    private var cacheFileURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedIconProbeServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("library.sqlite")
        database = try LibraryDatabase(databaseURL: dbURL)
        cacheFileURL = tempDir.appendingPathComponent("probe_cache.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 1. 轻量剪枝图标提取器测试 (Lightweight Icon Extractor)

    func testExtractRSSChannelImageURL() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>My Cool Blog</title>
            <link>https://example.com</link>
            <description>Thoughts</description>
            <image>
              <url>https://example.com/assets/channel-logo.png</url>
              <title>My Cool Blog</title>
              <link>https://example.com</link>
            </image>
            <item>
              <title>Article 1</title>
              <link>https://example.com/p1</link>
              <description>Body 1</description>
            </item>
          </channel>
        </rss>
        """
        let data = xml.data(using: .utf8)!
        let baseURL = URL(string: "https://example.com/feed.xml")!
        let extracted = FeedIconProbeService.extractIcon(from: data, baseURL: baseURL)
        XCTAssertEqual(extracted, URL(string: "https://example.com/assets/channel-logo.png"))
    }

    func testExtractAtomIconAndLogoURL() {
        let atomIconXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Atom Feed</title>
          <icon>https://atom.example.com/icon.png</icon>
          <entry>
            <title>Entry 1</title>
            <link href="https://atom.example.com/1"/>
          </entry>
        </feed>
        """
        let atomLogoXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Atom Feed 2</title>
          <logo>https://atom.example.com/logo.png</logo>
          <entry>
            <title>Entry 2</title>
            <link href="https://atom.example.com/2"/>
          </entry>
        </feed>
        """
        let baseURL = URL(string: "https://atom.example.com/feed.atom")!
        let icon = FeedIconProbeService.extractIcon(from: atomIconXML.data(using: .utf8)!, baseURL: baseURL)
        let logo = FeedIconProbeService.extractIcon(from: atomLogoXML.data(using: .utf8)!, baseURL: baseURL)

        XCTAssertEqual(icon, URL(string: "https://atom.example.com/icon.png"))
        XCTAssertEqual(logo, URL(string: "https://atom.example.com/logo.png"))
    }

    func testExtractResolvesRelativeURL() {
        let xml = """
        <rss version="2.0">
          <channel>
            <title>Relative Site</title>
            <image>
              <url>/static/icons/logo.png</url>
            </image>
          </channel>
        </rss>
        """
        let baseURL = URL(string: "https://relative.example.com/sub/rss.xml")!
        let extracted = FeedIconProbeService.extractIcon(from: xml.data(using: .utf8)!, baseURL: baseURL)
        XCTAssertEqual(extracted, URL(string: "https://relative.example.com/static/icons/logo.png"))
    }

    func testExtractIgnoresItemLevelImageWhenChannelHasNoImage() {
        // 当源未声明 channel image 时，即使第一篇文章内含有 <image><url>，
        // 也必须因为在 <item> 处提前剪枝终止而绝对不误把文章配图当做订阅源头像
        let xml = """
        <rss version="2.0">
          <channel>
            <title>No Icon Feed</title>
            <link>https://example.com</link>
            <item>
              <title>Article with image</title>
              <image>
                <url>https://example.com/wrong-item-photo.jpg</url>
              </image>
            </item>
          </channel>
        </rss>
        """
        let baseURL = URL(string: "https://example.com/rss.xml")!
        let extracted = FeedIconProbeService.extractIcon(from: xml.data(using: .utf8)!, baseURL: baseURL)
        XCTAssertNil(extracted, "必须在首个 <item> 处剪枝中止，绝不可误读 item 内的配图")
    }

    func testExtractFiltersFreshRSSPlaceholderFPHP() {
        let xml = """
        <rss version="2.0">
          <channel>
            <title>Placeholder Feed</title>
            <image>
              <url>https://freshrss.example.com/f.php?feed=123</url>
            </image>
          </channel>
        </rss>
        """
        let extracted = FeedIconProbeService.extractIcon(
            from: xml.data(using: .utf8)!,
            baseURL: URL(string: "https://freshrss.example.com/feed.xml")!
        )
        XCTAssertNil(extracted, "f.php 占位图必须被过滤拒绝")
    }

    func testExtractJSONFeedIconAndFavicon() {
        let jsonWithIcon = """
        {
          "version": "https://jsonfeed.org/version/1.1",
          "title": "JSON Feed",
          "icon": "https://json.example.com/icon.png",
          "items": [
            {"id": "1", "title": "Large article list..."}
          ]
        }
        """
        let jsonWithFavicon = """
        {
          "version": "https://jsonfeed.org/version/1.1",
          "title": "JSON Feed 2",
          "favicon": "https://json.example.com/fav.ico",
          "items": []
        }
        """
        let baseURL = URL(string: "https://json.example.com/feed.json")!
        let icon = FeedIconProbeService.extractIcon(from: jsonWithIcon.data(using: .utf8)!, baseURL: baseURL)
        let favicon = FeedIconProbeService.extractIcon(from: jsonWithFavicon.data(using: .utf8)!, baseURL: baseURL)

        XCTAssertEqual(icon, URL(string: "https://json.example.com/icon.png"))
        XCTAssertEqual(favicon, URL(string: "https://json.example.com/fav.ico"))
    }

    func testExtractHandlesMalformedAndGarbageDataSafely() {
        let garbage = "Not XML or JSON at all! <<<<< ???".data(using: .utf8)!
        let baseURL = URL(string: "https://garbage.example.com")!
        let extracted = FeedIconProbeService.extractIcon(from: garbage, baseURL: baseURL)
        XCTAssertNil(extracted)
    }

    // MARK: - 2. 持久化失败记忆与冷却窗测试 (Failure Persistence & Cooldown)

    func testFailurePersistenceSurvivesServiceRecreation() async throws {
        let mockSession = makeMockSession { request in
            // 模拟 404
            let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        let service1 = FeedIconProbeService(
            cacheFileURL: cacheFileURL,
            session: mockSession,
            maxConcurrentProbes: 2
        )

        let feedURL = URL(string: "https://missing-icon.example.com/rss.xml")!
        let feed = Feed(
            id: UUID(),
            title: "Missing Icon Feed",
            siteURL: nil,
            feedURL: feedURL,
            storedIconURL: nil
        )

        // 首次探测前无冷却
        let beforeCooldown = await service1.isBlockedByCooldown(feedURL)
        XCTAssertFalse(beforeCooldown)

        // 探测一个会返回 nil 的源
        await service1.probeMissingIcons(for: [feed], database: database)

        // 等待探测任务执行并落入冷却窗
        for _ in 0..<50 {
            if await service1.isBlockedByCooldown(feedURL) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let inCooldown = await service1.isBlockedByCooldown(feedURL)
        XCTAssertTrue(inCooldown, "探测失败或无图的源必须记录进冷却记忆")

        // 立即落盘
        await service1.flushCacheForTesting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFileURL.path))

        // 重启模拟：使用新实例加载同一 probe_cache.json
        let service2 = FeedIconProbeService(
            cacheFileURL: cacheFileURL,
            session: mockSession,
            maxConcurrentProbes: 2
        )

        let persistedCooldown = await service2.isBlockedByCooldown(feedURL)
        XCTAssertTrue(persistedCooldown, "重启后必须从磁盘保留失败记忆，绝不可再次发起重复网络请求")

        // 验证强制标志可以穿透冷却窗
        final class Counter: @unchecked Sendable {
            var count = 0
        }
        let counter = Counter()
        let countingSession = makeMockSession { request in
            counter.count += 1
            let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let service3 = FeedIconProbeService(
            cacheFileURL: cacheFileURL,
            session: countingSession,
            maxConcurrentProbes: 2
        )
        // 普通探测：被冷却拦截，计数为 0
        await service3.probeMissingIcons(for: [feed], database: database, force: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(counter.count, 0, "冷却期内普通探测必须被拦截，不能发生任何网络调用")

        // 强制探测：穿透冷却
        await service3.probeMissingIcons(for: [feed], database: database, force: true)
        for _ in 0..<50 where counter.count == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(counter.count, 1, "force: true 必须能够穿透冷却窗")
    }

    // MARK: - 3. 数据库回写与跨账号共享测试 (Database Writeback & Sharing)

    func testSuccessfulProbeUpdatesDatabaseAndWarmsUpStore() async throws {
        let feedURL = URL(string: "https://success.example.com/rss.xml")!
        let realIconURL = "https://success.example.com/icons/logo.png"

        let xml = """
        <rss version="2.0">
          <channel>
            <title>Success Feed</title>
            <image>
              <url>\(realIconURL)</url>
            </image>
            <item><title>Item 1</title></item>
          </channel>
        </rss>
        """

        let mockSession = makeMockSession { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, xml.data(using: .utf8)!)
        }

        // 预置数据库：2 个账号（Local 与 FreshRSS）订阅同一 feed_url，均无头像
        let localFeedID = UUID()
        let remoteFeedID = UUID()
        try database.write { db in
            let acc1 = AccountRecord(id: "local-default", type: "local", displayName: "Local", endpointURL: nil, username: nil, isEnabled: true, createdAt: 0, updatedAt: 0)
            let acc2 = AccountRecord(id: "freshrss-1", type: "freshRSS", displayName: "FreshRSS", endpointURL: "https://fr.test", username: "u", isEnabled: true, createdAt: 0, updatedAt: 0)
            try acc1.save(db)
            try acc2.save(db)

            let f1 = FeedRecord(id: localFeedID.uuidString, accountID: "local-default", title: "Feed 1", siteURL: nil, feedURL: feedURL.absoluteString, isDeleted: false, updatedAt: 0, storedIconURL: nil, sortOrder: 0)
            let f2 = FeedRecord(id: remoteFeedID.uuidString, accountID: "freshrss-1", title: "Feed 2", siteURL: nil, feedURL: feedURL.absoluteString, isDeleted: false, updatedAt: 0, storedIconURL: "https://fr.test/f.php?test", sortOrder: 1)
            try f1.save(db)
            try f2.save(db)
        }

        let iconsDir = tempDir.appendingPathComponent("icons")
        let iconStore = await MainActor.run {
            FeedIconStore(directory: iconsDir, session: mockSession)
        }

        let service = FeedIconProbeService(
            cacheFileURL: cacheFileURL,
            session: mockSession,
            maxConcurrentProbes: 2
        )

        let feedToProbe = Feed(
            id: localFeedID,
            title: "Feed 1",
            siteURL: nil,
            feedURL: feedURL,
            storedIconURL: nil
        )

        await service.probeMissingIcons(for: [feedToProbe], database: database, iconStore: iconStore)

        // 等待数据库回写完成
        for _ in 0..<100 {
            let updated = try database.read { db -> Bool in
                let r1 = try FeedRecord.fetchOne(db, key: localFeedID.uuidString)
                let r2 = try FeedRecord.fetchOne(db, key: remoteFeedID.uuidString)
                return r1?.storedIconURL == realIconURL && r2?.storedIconURL == realIconURL
            }
            if updated { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        try database.read { db in
            let r1 = try FeedRecord.fetchOne(db, key: localFeedID.uuidString)
            let r2 = try FeedRecord.fetchOne(db, key: remoteFeedID.uuidString)
            XCTAssertEqual(r1?.storedIconURL, realIconURL, "本地账号无图源成功回写真实图标")
            XCTAssertEqual(r2?.storedIconURL, realIconURL, "同 feed_url 的 FreshRSS 账号被同时自愈为真实图标")
        }
    }

    // MARK: - 4. 并发上限与队列化测试 (Bounded Concurrency & Queue)

    func testConcurrencyIsStrictlyBounded() async throws {
        final class ConcurrencyTracker: @unchecked Sendable {
            private let lock = NSLock()
            var currentActive = 0
            var maxActiveObserved = 0
            var completedCount = 0

            func enter() {
                lock.lock()
                currentActive += 1
                if currentActive > maxActiveObserved {
                    maxActiveObserved = currentActive
                }
                lock.unlock()
            }

            func exit() {
                lock.lock()
                currentActive -= 1
                completedCount += 1
                lock.unlock()
            }
        }

        let tracker = ConcurrencyTracker()
        let session = makeMockSession { request in
            tracker.enter()
            defer { tracker.exit() }
            Thread.sleep(forTimeInterval: 0.03) // 模拟网络延迟
            let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        let service = FeedIconProbeService(
            cacheFileURL: cacheFileURL,
            session: session,
            maxConcurrentProbes: 2
        )

        // 构造 6 个无图 Feed
        let feeds = (0..<6).map { idx in
            Feed(
                id: UUID(),
                title: "Feed \(idx)",
                siteURL: nil,
                feedURL: URL(string: "https://concurrency.test/feed\(idx).xml")!,
                storedIconURL: nil
            )
        }

        await service.probeMissingIcons(for: feeds, database: database)

        // 等待所有 6 个 Feed 探测完成
        for _ in 0..<100 {
            let done = tracker.completedCount >= 6
            if done { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(tracker.completedCount, 6, "所有 6 个待探测源必须全部被消费完成")
        XCTAssertLessThanOrEqual(tracker.maxActiveObserved, 2, "最大并发请求数必须严格被限制在 maxConcurrentProbes(2) 以内，绝不可打满并发池")
    }

    // MARK: - 5. 属性图标与扩展提取测试 (Attribute Icons & Callbacks)

    func testExtractAttributeBasedIcons() {
        // 1. 测试 iTunes Podcast 专属图片标签
        let podcastXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" version="2.0">
          <channel>
            <title>Tech Podcast</title>
            <itunes:image href="https://podcast.example.com/cover.jpg"/>
            <item><title>Episode 1</title></item>
          </channel>
        </rss>
        """
        let podcastURL = URL(string: "https://podcast.example.com/feed.xml")!
        let podcastIcon = FeedIconProbeService.extractIcon(from: podcastXML.data(using: .utf8)!, baseURL: podcastURL)
        XCTAssertEqual(podcastIcon, URL(string: "https://podcast.example.com/cover.jpg"))

        // 2. 测试 Atom <link rel="icon" href="...">
        let atomLinkXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Atom With Link Icon</title>
          <link rel="icon" href="/favicon.png"/>
          <entry><title>1</title></entry>
        </feed>
        """
        let atomURL = URL(string: "https://atomlink.example.com/atom.xml")!
        let atomIcon = FeedIconProbeService.extractIcon(from: atomLinkXML.data(using: .utf8)!, baseURL: atomURL)
        XCTAssertEqual(atomIcon, URL(string: "https://atomlink.example.com/favicon.png"))

        // 3. 测试 RSS <image href="...">
        let imageHrefXML = """
        <rss version="2.0">
          <channel>
            <title>Image Href Feed</title>
            <image href="https://img.example.com/feed-logo.png" />
            <item><title>1</title></item>
          </channel>
        </rss>
        """
        let imgFeedURL = URL(string: "https://img.example.com/rss.xml")!
        let imgIcon = FeedIconProbeService.extractIcon(from: imageHrefXML.data(using: .utf8)!, baseURL: imgFeedURL)
        XCTAssertEqual(imgIcon, URL(string: "https://img.example.com/feed-logo.png"))
    }

    func testClearCacheCancelsDanglingPersistenceTask() async throws {
        let mockSession = makeMockSession { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        let service = FeedIconProbeService(
            cacheFileURL: cacheFileURL,
            session: mockSession,
            maxConcurrentProbes: 2
        )

        let feed = Feed(
            id: UUID(),
            title: "Test Feed",
            siteURL: nil,
            feedURL: URL(string: "https://cleartest.example.com/rss.xml")!,
            storedIconURL: nil
        )

        await service.probeMissingIcons(for: [feed], database: database)
        // 等待探测进入并记录
        for _ in 0..<50 {
            if await service.isBlockedByCooldown(feed.feedURL) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        // 调用 clearCache
        await service.clearCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFileURL.path))

        // 等待超过防抖写入窗口（100ms），验证绝无僵尸写入任务复活已删除缓存文件
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cacheFileURL.path),
            "clearCache 后被取消的防抖落盘任务绝不可再次复活并写入 probe_cache.json"
        )
    }

    func testOnIconDiscoveredCallbackNotifiesCaller() async throws {
        let feedURL = URL(string: "https://callback.example.com/rss.xml")!
        let realIconURL = "https://callback.example.com/logo.png"
        let xml = """
        <rss version="2.0">
          <channel>
            <title>Callback Feed</title>
            <image><url>\(realIconURL)</url></image>
            <item><title>1</title></item>
          </channel>
        </rss>
        """
        let mockSession = makeMockSession { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, xml.data(using: .utf8)!)
        }

        let feedID = UUID()
        try database.write { db in
            let acc = AccountRecord(id: "local-default", type: "local", displayName: "Local", endpointURL: nil, username: nil, isEnabled: true, createdAt: 0, updatedAt: 0)
            try acc.save(db)
            let f = FeedRecord(id: feedID.uuidString, accountID: "local-default", title: "Feed", siteURL: nil, feedURL: feedURL.absoluteString, isDeleted: false, updatedAt: 0, storedIconURL: nil, sortOrder: 0)
            try f.save(db)
        }

        final class CallbackBox: @unchecked Sendable {
            var receivedFeedIDs: [UUID]?
            var receivedURL: URL?
        }
        let box = CallbackBox()

        let service = FeedIconProbeService(
            cacheFileURL: cacheFileURL,
            session: mockSession,
            maxConcurrentProbes: 2
        )

        let feed = Feed(
            id: feedID,
            title: "Feed",
            siteURL: nil,
            feedURL: feedURL,
            storedIconURL: nil
        )

        await service.probeMissingIcons(
            for: [feed],
            database: database,
            onIconDiscovered: { ids, url in
                box.receivedFeedIDs = ids
                box.receivedURL = url
            }
        )

        for _ in 0..<50 {
            if box.receivedURL != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(box.receivedFeedIDs, [feedID])
        XCTAssertEqual(box.receivedURL, URL(string: realIconURL))
    }

    @MainActor
    func testAppStoreUpdateFeedIconUpdatesInMemoryFeeds() {
        let store = AppStore(testDatabase: .empty) { _ in fatalError("Unused") }
        let feedID = UUID()
        let feedURL = URL(string: "https://example.com/feed.xml")!
        let initialFeed = Feed(id: feedID, title: "Initial Feed", siteURL: nil, feedURL: feedURL, folder: "Tech", storedIconURL: nil)
        store.feedsByAccount = ["local-default": [initialFeed]]

        let newIconURL = URL(string: "https://example.com/discovered-logo.png")!
        store.updateFeedIcon(feedIDs: [feedID], iconURL: newIconURL)

        XCTAssertEqual(store.feedsByAccount["local-default"]?.first?.storedIconURL, newIconURL, "feedsByAccount 中的 feed 必须更新 storedIconURL")
        XCTAssertEqual(store.feeds(for: "local-default").first?.storedIconURL, newIconURL, "feeds(for:) 必须返回更新后的 storedIconURL")
    }

    // MARK: - 辅助 Mock 工具

    private func makeMockSession(handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
        ProbeMockURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProbeMockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private final class ProbeMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
