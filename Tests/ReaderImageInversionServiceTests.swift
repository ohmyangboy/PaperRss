import Foundation
import XCTest
@testable import PaperRssCore

private actor InversionLoaderProbe {
    private(set) var requestedURLs: [URL] = []
    private(set) var referers: [String?] = []
    private(set) var active = 0
    private(set) var peak = 0

    private let lineArt: Data
    private let photo: Data
    private let delay: Duration
    private let failingPaths: Set<String>

    init(lineArt: Data, photo: Data, delay: Duration = .milliseconds(40), failingPaths: Set<String> = []) {
        self.lineArt = lineArt
        self.photo = photo
        self.delay = delay
        self.failingPaths = failingPaths
    }

    var calls: Int { requestedURLs.count }

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        guard let url = request.url else { throw URLError(.badURL) }
        requestedURLs.append(url)
        referers.append(request.value(forHTTPHeaderField: "Referer"))
        try await Task.sleep(for: delay)
        guard !failingPaths.contains(url.path) else { throw URLError(.cannotConnectToHost) }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
        ) else { throw URLError(.badServerResponse) }
        return (url.path.contains("line") ? lineArt : photo, response)
    }
}

final class ReaderImageInversionServiceTests: XCTestCase {
    private func makeProbe(
        failingPaths: Set<String> = [],
        delay: Duration = .milliseconds(40)
    ) throws -> InversionLoaderProbe {
        InversionLoaderProbe(
            lineArt: try ReaderImageInversionFixtures.transparentLineArtPNG(),
            photo: try ReaderImageInversionFixtures.gradientPNG(),
            delay: delay,
            failingPaths: failingPaths
        )
    }

    private func lineURLs(_ count: Int) -> [URL] {
        (0..<count).map { URL(string: "https://cdn.example.com/line-\($0).png")! }
    }

    func testOnlyTheFirstTwelveCandidatesAreRequestedWhenLimited() async throws {
        let probe = try makeProbe()
        let service = ReaderImageInversionService(loader: { try await probe.load($0) }, limit: 12)
        let input = lineURLs(20)

        let result = await service.invertibleURLs(for: input, referer: nil)

        let calls = await probe.calls
        XCTAssertEqual(result, Array(input.prefix(12)), "按正文顺序返回预算内的图片")
        XCTAssertEqual(calls, 12)
    }

    func testDefaultBudgetCoversLongTechnicalArticles() async throws {
        // colah 的 Visual Information Theory 一篇 55 张图：预算必须覆盖到文章末尾的插图。
        let probe = try makeProbe()
        let service = ReaderImageInversionService(loader: { try await probe.load($0) })
        let input = lineURLs(80)

        let result = await service.invertibleURLs(for: input, referer: nil)

        let calls = await probe.calls
        XCTAssertEqual(result, Array(input.prefix(64)))
        XCTAssertEqual(calls, 64)
    }

    func testVerdictsFollowDocumentOrderAndSkipPhotos() async throws {
        let probe = try makeProbe()
        let service = ReaderImageInversionService(loader: { try await probe.load($0) })
        let line = URL(string: "https://cdn.example.com/line-1.png")!
        let photo = URL(string: "https://cdn.example.com/photo-2.png")!
        let secondLine = URL(string: "https://cdn.example.com/line-3.png")!

        let result = await service.invertibleURLs(for: [line, photo, secondLine], referer: nil)

        XCTAssertEqual(result, [line, secondLine], "照片不反相，线稿保持输入顺序")
    }

    func testSecondCallReusesSessionVerdicts() async throws {
        let probe = try makeProbe()
        let service = ReaderImageInversionService(loader: { try await probe.load($0) })
        let input = lineURLs(3)

        _ = await service.invertibleURLs(for: input, referer: nil)
        let second = await service.invertibleURLs(for: input, referer: nil)

        let calls = await probe.calls
        XCTAssertEqual(second, input)
        XCTAssertEqual(calls, 3, "同一 URL 的判定必须复用会话缓存")
    }

    func testSingleFailureDoesNotAffectOtherVerdicts() async throws {
        let probe = try makeProbe(failingPaths: ["/line-1.png"])
        let service = ReaderImageInversionService(loader: { try await probe.load($0) })
        let failing = URL(string: "https://cdn.example.com/line-1.png")!
        let ok = URL(string: "https://cdn.example.com/line-2.png")!

        let result = await service.invertibleURLs(for: [failing, ok], referer: nil)

        XCTAssertEqual(result, [ok], "取不到字节的图片按不反相处理，不影响其它图片")
    }

    func testConcurrencyWindowIsBounded() async throws {
        let probe = try makeProbe()
        let service = ReaderImageInversionService(loader: { try await probe.load($0) })

        _ = await service.invertibleURLs(for: lineURLs(12), referer: nil)

        let peak = await probe.peak
        XCTAssertLessThanOrEqual(peak, 4, "并发窗口不得超过 4")
        XCTAssertGreaterThan(peak, 1, "判定必须并行取字节")
    }

    func testRequestsCarryRefererAndUserAgent() async throws {
        let probe = try makeProbe()
        let service = ReaderImageInversionService(loader: { try await probe.load($0) })

        _ = await service.invertibleURLs(
            for: lineURLs(2),
            referer: URL(string: "https://example.com/articles/1")
        )

        let referers = await probe.referers
        XCTAssertEqual(referers, ["https://example.com/articles/1", "https://example.com/articles/1"])
    }

    func testDecorativeURLsAreSkippedWithoutConsumingBudget() async throws {
        let probe = try makeProbe()
        let service = ReaderImageInversionService(loader: { try await probe.load($0) }, limit: 12)
        let emoji = URL(string: "https://cdn.example.com/emoji/party.png")!
        let avatar = URL(string: "https://gravatar.com/avatar/abc")!
        let input = [emoji] + lineURLs(12) + [avatar]

        let result = await service.invertibleURLs(for: input, referer: nil)

        let calls = await probe.calls
        let requested = await probe.requestedURLs
        XCTAssertEqual(result, lineURLs(12), "表情/头像不占图片预算")
        XCTAssertEqual(calls, 12)
        XCTAssertFalse(requested.contains(emoji))
        XCTAssertFalse(requested.contains(avatar))
    }
}
