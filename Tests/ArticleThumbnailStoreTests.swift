import XCTest
import CoreGraphics
import ImageIO
@testable import PaperRssCore

private actor ThumbnailLoaderProbe {
    private(set) var calls = 0
    private(set) var active = 0
    private(set) var peak = 0
    let data: Data
    let delay: Duration
    init(data: Data, delay: Duration = .milliseconds(40)) { self.data = data; self.delay = delay }
    func load(_ request: ArticleThumbnailRequest) async throws -> Data {
        calls += 1
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: delay)
        return data
    }
}

@MainActor
final class ArticleThumbnailStoreTests: XCTestCase {
    private func png(width: Int = 800, height: Int = 400) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ArticleThumbnailTests-\(UUID())")
    }
    private func request(_ suffix: String = "image", account: String = "local", size: Int = 120) -> ArticleThumbnailRequest {
        .init(accountID: account, url: URL(string: "https://cdn.example/\(suffix).png")!, pixelSize: size)
    }
    private func waitForCalls(_ count: Int, probe: ThumbnailLoaderProbe) async throws {
        for _ in 0..<200 {
            if await probe.calls >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for the deterministic test loader")
    }

    func testVisibleDuplicateRequestsCoalesceAndMemoryHitsAreSynchronous() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = ThumbnailLoaderProbe(data: try png())
        let store = ArticleThumbnailStore(directory: directory, loader: { try await probe.load($0) })
        let request = request()
        async let first = store.image(for: request)
        async let second = store.image(for: request)
        let (a, b) = try await (first, second)
        XCTAssertTrue(a === b)
        XCTAssertLessThanOrEqual(max(a.image.width, a.image.height), 160)
        XCTAssertTrue(store.cachedImage(for: request) === a)
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
    }

    func testAccountAndSizeKeysAreIsolated() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = ThumbnailLoaderProbe(data: try png())
        let store = ArticleThumbnailStore(directory: directory, loader: { try await probe.load($0) })
        _ = try await store.image(for: request(account: "one"))
        XCTAssertNil(store.cachedImage(for: request(account: "two")))
        _ = try await store.image(for: request(account: "two"))
        _ = try await store.image(for: request(account: "one", size: 500))
        let calls = await probe.calls
        XCTAssertEqual(calls, 3)
        XCTAssertNotEqual(request(account: "one").cacheKey, request(account: "two").cacheKey)
    }

    func testDiskHitAfterRestartDoesNotNeedTheNetwork() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = ThumbnailLoaderProbe(data: try png())
        let request = request()
        let store = ArticleThumbnailStore(directory: directory, loader: { try await probe.load($0) })
        _ = try await store.image(for: request)
        let restarted = ArticleThumbnailStore(directory: directory, loader: { _ in
            XCTFail("Decoded disk entry should have been used")
            throw URLError(.notConnectedToInternet)
        })
        let image = try await restarted.image(for: request)
        XCTAssertLessThanOrEqual(image.image.width, 160)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasSuffix(".jpg"))
    }

    func testConcurrentDownloadsAreBounded() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = ThumbnailLoaderProbe(data: try png(), delay: .milliseconds(50))
        let store = ArticleThumbnailStore(directory: directory, maximumConcurrent: 2, loader: { try await probe.load($0) })
        let requests = (0..<10).map { request("image-\($0)") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for request in requests { group.addTask { _ = try await store.image(for: request) } }
            try await group.waitForAll()
        }
        let peak = await probe.peak
        let calls = await probe.calls
        XCTAssertLessThanOrEqual(peak, 2)
        XCTAssertEqual(calls, 10)
    }

    func testDisableCancelsQueuedRequestsAndDoesNotPoisonFutureLoads() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = ThumbnailLoaderProbe(data: try png(), delay: .milliseconds(150))
        let store = ArticleThumbnailStore(directory: directory, maximumConcurrent: 1, loader: { try await probe.load($0) })
        let firstRequest = request("first"), queuedRequest = request("queued")
        let first = Task { try await store.image(for: firstRequest) }
        try await waitForCalls(1, probe: probe)
        let queued = Task { try await store.image(for: queuedRequest) }
        // Let the second subscriber enter the gate, not the downloader.
        for _ in 0..<20 { await Task.yield() }
        await store.cancelAll()
        first.cancel()
        queued.cancel()
        do { _ = try await first.value; XCTFail("Active request was not cancelled") } catch {}
        do { _ = try await queued.value; XCTFail("Queued request was not cancelled") } catch {}
        let before = await probe.calls
        XCTAssertEqual(before, 1)
        _ = try await store.image(for: firstRequest)
        let after = await probe.calls
        XCTAssertEqual(after, 2, "Cancellation must not create a negative cache entry")
    }

    func testFailureMemoryAvoidsRepeatedBrokenImageRequests() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = ThumbnailLoaderProbe(data: Data("not an image".utf8))
        let store = ArticleThumbnailStore(directory: directory, loader: { try await probe.load($0) })
        for _ in 0..<2 {
            do { _ = try await store.image(for: request()); XCTFail("Invalid image accepted") } catch {}
        }
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
        XCTAssertNil(store.cachedImage(for: request()))
    }

    func testUnsafeURLNeverReachesLoader() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ArticleThumbnailStore(directory: directory, loader: { _ in
            XCTFail("Unsafe URL reached the network loader")
            return Data()
        })
        for raw in ["file:///etc/passwd", "https://username:password@example.com/photo"] {
            let request = ArticleThumbnailRequest(accountID: "local", url: URL(string: raw)!, pixelSize: 80)
            do { _ = try await store.image(for: request); XCTFail("Unsafe URL accepted") } catch {}
        }
    }

    func testDecodeRejectsOversizeAndTrackingPixel() throws {
        XCTAssertThrowsError(try ArticleThumbnailStore.decode(Data(count: ArticleThumbnailStore.maximumDownloadBytes + 1), pixelSize: 160))
        XCTAssertThrowsError(try ArticleThumbnailStore.decode(png(width: 1, height: 1), pixelSize: 160))
        XCTAssertThrowsError(try ArticleThumbnailStore.decode(Data("<html>Not image</html>".utf8), pixelSize: 160))
    }
}
