import XCTest
import CoreGraphics
@testable import PaperRssCore

/// FeedIconStore 回归：同步查询语义、磁盘缓存往返、索引持久化、失败记忆。
final class FeedIconStoreTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedIconStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: 工具

    /// 生成一张纯色 PNG（8x8），用于 file:// 通道的加载与落盘验证。
    private func makePNGData(red: UInt8 = 200) -> Data {
        let width = 8, height = 8
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: CGFloat(red) / 255, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        return FeedIconStore.pngData(for: image)!
    }

    @MainActor
    private func makeStore(_ session: URLSession = .shared) -> FeedIconStore {
        FeedIconStore(directory: tempRoot.appendingPathComponent("icons"), session: session)
    }

    /// 等待 revision 变化（后台加载完成回填主线程）。
    @MainActor
    private func waitForRevisionChange(of store: FeedIconStore, from baseline: UInt64) async {
        for _ in 0..<200 where store.revision == baseline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotEqual(store.revision, baseline, "预热未在 2s 内回填")
    }

    // MARK: 同步查询语义

    @MainActor
    func testCachedImageIsPureLookupBeforeWarmUp() {
        let store = makeStore()
        XCTAssertNil(store.cachedImage(feedID: UUID()))
        XCTAssertFalse(store.hasIconSource(feedID: UUID()))
        XCTAssertEqual(store.revision, 0)
    }

    // MARK: 磁盘缓存管线

    @MainActor
    func testWarmUpLoadsFromLocalURLAndPersistsToDisk() async throws {
        let store = makeStore()
        let sourcePNG = tempRoot.appendingPathComponent("source.png")
        try makePNGData().write(to: sourcePNG)

        let feedID = UUID()
        let baseline = store.revision
        store.warmUp(feedID: feedID, iconURL: sourcePNG)
        await waitForRevisionChange(of: store, from: baseline)

        guard let image = store.cachedImage(feedID: feedID) else {
            return XCTFail("同步查询应命中已就绪图标")
        }
        XCTAssertLessThanOrEqual(max(image.width, image.height), Int(FeedIconStore.maxPixelSize))

        // 字节应按 md5(url).png 落盘，重启后无需网络即可恢复
        let diskFile = FeedIconStore.diskFileURL(for: sourcePNG, in: tempRoot.appendingPathComponent("icons"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: diskFile.path))
    }

    @MainActor
    func testUpdatedIconURLSupersedesAnInFlightOlderRequest() async throws {
        let store = makeStore()
        let fallbackPNG = tempRoot.appendingPathComponent("fallback.png")
        let avatarPNG = tempRoot.appendingPathComponent("avatar.png")
        try makePNGData(red: 200).write(to: fallbackPNG)
        try makePNGData(red: 40).write(to: avatarPNG)

        let feedID = UUID()
        store.warmUp(feedID: feedID, iconURL: fallbackPNG)
        // 模拟新 Feed 首次渲染先登记默认 favicon，随后刷新结果返回用户头像。
        // 两次调用之间没有让出主 actor，因此旧 URL 必然仍处于 in-flight。
        store.warmUp(feedID: feedID, iconURL: avatarPNG)

        for _ in 0..<200 where !store.inFlightFeedIDs.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let avatarDiskFile = FeedIconStore.diskFileURL(
            for: avatarPNG,
            in: tempRoot.appendingPathComponent("icons")
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: avatarDiskFile.path),
            "更新后的头像 URL 不应被旧的 in-flight 请求吞掉"
        )

        guard let actual = store.cachedImage(feedID: feedID),
              let expected = FeedIconStore.decodeIcon(from: try Data(contentsOf: avatarPNG)),
              let actualData = actual.dataProvider?.data as Data?,
              let expectedData = expected.dataProvider?.data as Data? else {
            return XCTFail("更新后的用户头像应成为当前图标")
        }
        XCTAssertEqual(actualData, expectedData)
    }

    @MainActor
    func testDiskCacheSurvivesAcrossInstancesWithoutNetwork() async throws {
        let iconsDir = tempRoot.appendingPathComponent("icons")
        let sourcePNG = tempRoot.appendingPathComponent("source.png")
        try makePNGData(red: 90).write(to: sourcePNG)

        let first = FeedIconStore(directory: iconsDir)
        first.warmUp(feedID: UUID(), iconURL: sourcePNG)
        await waitForRevisionChange(of: first, from: 0)

        // 模拟冷启动：新实例 + 指向已被删除的源 URL（file:// 404 等价物）
        try FileManager.default.removeItem(at: sourcePNG)
        let feedID = UUID()
        let second = FeedIconStore(directory: iconsDir)
        second.warmUp(feedID: feedID, iconURL: sourcePNG)
        await waitForRevisionChange(of: second, from: 0)

        XCTAssertNotNil(second.cachedImage(feedID: feedID), "磁盘缓存应在无网络/源失效时命中")
    }

    // MARK: 索引持久化

    @MainActor
    func testIndexAndFailureStatePersistAcrossInstances() async throws {
        let store = makeStore()
        let iconURL = URL(string: "https://example.com/icon.png")!
        // 直接登记映射（不经 warmUp，避免测试期发起真实网络请求）
        store.iconURLByFeedID[UUID()] = iconURL
        // warmUp 会登记 iconURLByFeedID；失败表手动注入以验证持久化路径
        store.failures[iconURL.absoluteString] = Date()

        // 强制把内存态写入 index.json
        let persisted = store.indexFileURL
        store.scheduleIndexPersistForTesting()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: persisted.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.iconURLByFeedID.values.first?.absoluteString, iconURL.absoluteString)
        XCTAssertTrue(reloaded.failures.keys.contains(iconURL.absoluteString))
    }

    // MARK: 失败记忆

    @MainActor
    func testFailureWindowBlocksNewAttempts() async throws {
        let store = makeStore()
        let iconURL = URL(string: "https://example.com/broken.png")!
        let feedID = UUID()
        // 先注入失败记录（今天刚失败），warmUp 必须被失败窗拦截
        store.failures[iconURL.absoluteString] = Date()

        store.warmUp(feedID: feedID, iconURL: iconURL)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(store.inFlightFeedIDs.isEmpty, "失败窗内的 URL 不应产生新的加载任务")
        XCTAssertNil(store.cachedImage(feedID: feedID))
    }

    @MainActor
    func testExpiredFailureAllowsRetry() {
        let store = makeStore()
        let key = "https://expired.example/icon.png"
        store.failures[key] = Date(timeIntervalSinceNow: -(FeedIconStore.failureRetryInterval + 60))
        XCTAssertFalse(store.isBlockedByFailure(URL(string: key)!))
    }

    func testTransientErrorClassification() {
        XCTAssertTrue(FeedIconStore.isTransientURLError(.notConnectedToInternet))
        XCTAssertTrue(FeedIconStore.isTransientURLError(.timedOut))
        XCTAssertTrue(FeedIconStore.isTransientURLError(.dnsLookupFailed))
        // 判定不了的一律按永久处理，防止坏 URL 造成反复闪烁
        XCTAssertFalse(FeedIconStore.isTransientURLError(.badURL))
        XCTAssertFalse(FeedIconStore.isTransientURLError(.httpTooManyRedirects))
    }

    func testDiskFileNameIsStableMD5() {
        let dir = URL(fileURLWithPath: "/tmp/icons")
        let a = FeedIconStore.diskFileURL(for: URL(string: "https://a.example/i.png")!, in: dir)
        let b = FeedIconStore.diskFileURL(for: URL(string: "https://a.example/i.png")!, in: dir)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.lastPathComponent.hasSuffix(".png"))
    }
}
