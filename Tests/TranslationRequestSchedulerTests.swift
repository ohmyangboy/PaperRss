import Foundation
import XCTest
@testable import PaperRssCore

private actor TranslationSchedulePort: AIModelPort {
    private var responses: [AIModelHTTPResponse]
    private var starts: [ContinuousClock.Instant] = []

    init(_ responses: [AIModelHTTPResponse]) { self.responses = responses }

    func data(for request: URLRequest) async throws -> AIModelHTTPResponse {
        starts.append(.now)
        return responses.removeFirst()
    }

    func events(for request: URLRequest) async throws -> AIModelEventResponse {
        throw LLMServiceError.invalidResponse
    }

    func capturedStarts() -> [ContinuousClock.Instant] { starts }
}

private actor TranslationAttemptRecorder {
    var starts: [ContinuousClock.Instant] = []
    var active = 0
    var peak = 0
    func attempt(rateLimited: Bool = false) async throws -> String {
        starts.append(.now)
        if rateLimited { throw LLMServiceError.rateLimitedWithRetryAfter(0.04) }
        active += 1
        peak = max(peak, active)
        try await Task.sleep(for: .milliseconds(50))
        active -= 1
        return "译文"
    }
    func snapshot() -> (starts: [ContinuousClock.Instant], peak: Int) { (starts, peak) }

    /// 停在请求里，直到另一个模型也进入。固定睡眠会在慢速调度下先结束，peak 只能记到 1。
    func holdUntilPeerArrives() async -> String {
        active += 1
        peak = max(peak, active)
        if let waitingForPeer {
            self.waitingForPeer = nil
            peerWaitID = nil
            waitingForPeer.resume()
        } else {
            let id = UUID()
            peerWaitID = id
            await withCheckedContinuation { continuation in
                waitingForPeer = continuation
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    Task { await self.abandonPeerWait(id) }
                }
            }
        }
        active -= 1
        return "译文"
    }

    private var waitingForPeer: CheckedContinuation<Void, Never>?
    private var peerWaitID: UUID?

    private func abandonPeerWait(_ id: UUID) {
        guard peerWaitID == id, let waitingForPeer else { return }
        self.waitingForPeer = nil
        peerWaitID = nil
        waitingForPeer.resume()
    }
}

final class TranslationRequestSchedulerTests: XCTestCase {
    private func response(_ status: Int = 200, text: String = "译文", code: String? = nil, headers: [String: String] = [:]) throws -> AIModelHTTPResponse {
        let payload: [String: Any] = code.map { ["error": ["code": $0]] }
            ?? ["choices": [["message": ["content": text]]]]
        return AIModelHTTPResponse(statusCode: status, data: try JSONSerialization.data(withJSONObject: payload), headers: headers)
    }

    func testQwenTranslationFeaturesShareOnePacedBudget() async throws {
        let port = TranslationSchedulePort(try [response(), response(), response()])
        let service = LLMService(port: port)
        let configuration = LLMConfiguration(baseURL: "https://example.test/v1", model: "qwen-mt-lite", temperature: 0.2, targetLanguage: "简体中文", allowInsecureLocalEndpoint: false)
        async let body = service.translateBatch(paragraphs: ["body"], configuration: configuration, apiKey: "")
        async let title = service.translateBatch(paragraphs: ["title"], configuration: configuration, apiKey: "")
        async let selection = service.translate(paragraph: "selection", configuration: configuration, apiKey: "")
        _ = try await (body, title, selection)
        let starts = await port.capturedStarts()
        XCTAssertEqual(starts.count, 3)
        for (a, b) in zip(starts, starts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a.duration(to: b), .milliseconds(950))
        }
        XCTAssertLessThan(starts[0].duration(to: starts[2]), .milliseconds(2_500),
                          "无服务端延迟时三次请求不应额外退避")
    }

    func testHealthyGenericTranslationsDoNotPayAnArtificialInterval() async throws {
        let port = TranslationSchedulePort(try [response(), response(), response()])
        let service = LLMService(port: port)
        for _ in 0..<3 {
            _ = try await service.translate(paragraph: "hello", configuration: .deepSeek, apiKey: "")
        }
        let starts = await port.capturedStarts()
        XCTAssertLessThan(starts[0].duration(to: starts[2]), .milliseconds(200),
                          "健康请求不应额外累计每次 150ms 的固定延迟")
    }

    func testRecoveredRateLimitDoesNotPermanentlyThrottleLaterArticles() async throws {
        let port = TranslationSchedulePort(try [response(429), response(), response(), response(), response(), response()])
        let scheduler = TranslationRequestScheduler(baseRetryDelay: .milliseconds(500))
        let service = LLMService(port: port, translationScheduler: scheduler)
        for _ in 0..<5 {
            _ = try await service.translate(paragraph: "hello", configuration: .deepSeek, apiKey: "")
        }
        let starts = await port.capturedStarts()
        XCTAssertEqual(starts.count, 6)
        XCTAssertGreaterThanOrEqual(starts[0].duration(to: starts[1]), .milliseconds(480))
        XCTAssertLessThan(starts[3].duration(to: starts[5]), .milliseconds(100),
                          "成功恢复后不能永久保留限流时的额外间隔")
    }

    func testSchedulerBoundsConcurrencyAndDoesNotSerializeDifferentModels() async throws {
        let scheduler = TranslationRequestScheduler()
        let recorder = TranslationAttemptRecorder()
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try await scheduler.run(key: "same-model", minimumInterval: .milliseconds(20)) {
                        try await recorder.attempt()
                    }
                }
            }
            for try await value in group { XCTAssertEqual(value, "译文") }
        }
        let sameModel = await recorder.snapshot()
        XCTAssertEqual(sameModel.starts.count, 5)
        XCTAssertEqual(sameModel.peak, 2)
        for (a, b) in zip(sameModel.starts, sameModel.starts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a.duration(to: b), .milliseconds(18))
        }
        let independent = TranslationAttemptRecorder()
        async let first = scheduler.run(key: "model-A", minimumInterval: .seconds(10)) { await independent.holdUntilPeerArrives() }
        async let second = scheduler.run(key: "model-B", minimumInterval: .seconds(10)) { await independent.holdUntilPeerArrives() }
        _ = try await (first, second)
        let differentModels = await independent.snapshot()
        XCTAssertEqual(differentModels.peak, 2)
    }

    func testRateLimitPausesSiblingsAndStopsTheRetryStorm() async throws {
        let scheduler = TranslationRequestScheduler(baseRetryDelay: .milliseconds(10), failureCooldown: .milliseconds(100))
        let recorder = TranslationAttemptRecorder()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    do {
                        _ = try await scheduler.run(key: "model", minimumInterval: .milliseconds(5)) {
                            try await recorder.attempt(rateLimited: true)
                        }
                        XCTFail("限流未恢复不能返回成功")
                    } catch {}
                }
            }
        }
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.starts.count, 3, "重试预算由同模型共享，不能每个段落各重试三次")
        for (a, b) in zip(snapshot.starts, snapshot.starts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a.duration(to: b), .milliseconds(38), "遵循 Retry-After")
        }
        do {
            _ = try await scheduler.run(key: "model", minimumInterval: .zero) { try await recorder.attempt() }
            XCTFail("冷却期间不能继续付费请求")
        } catch {}
        let afterCooldownAttempt = await recorder.snapshot()
        XCTAssertEqual(afterCooldownAttempt.starts.count, 3)
    }

    func testTransientRateLimitRecoversWithoutShowingAnError() async throws {
        let port = TranslationSchedulePort(try [response(429, headers: ["Retry-After": "0.03"]), response()])
        let scheduler = TranslationRequestScheduler(baseRetryDelay: .milliseconds(10))
        let service = LLMService(port: port, translationScheduler: scheduler)
        let result = try await service.translate(paragraph: "hello", configuration: .deepSeek, apiKey: "")
        XCTAssertEqual(result, "译文")
        let starts = await port.capturedStarts()
        XCTAssertEqual(starts.count, 2)
        XCTAssertGreaterThanOrEqual(starts[0].duration(to: starts[1]), .milliseconds(28))
    }

    func testQuotaExhaustionDoesNotRetryOrDispatchWaitingParagraphs() async throws {
        let port = TranslationSchedulePort(try [response(429, code: "insufficient_quota")])
        let service = LLMService(port: port)
        for _ in 0..<3 {
            do {
                _ = try await service.translate(paragraph: "hello", configuration: .deepSeek, apiKey: "")
                XCTFail("额度耗尽不能成功")
            } catch LLMServiceError.quotaExceeded {} catch { XCTFail("\(error)") }
        }
        let starts = await port.capturedStarts()
        XCTAssertEqual(starts.count, 1)
    }

    func testCancelledWaiterNeverMakesAnHTTPCallAndReleasesQueue() async throws {
        let scheduler = TranslationRequestScheduler()
        let recorder = TranslationAttemptRecorder()
        _ = try await scheduler.run(key: "model", minimumInterval: .milliseconds(200)) { try await recorder.attempt() }
        let waiting = Task {
            try await scheduler.run(key: "model", minimumInterval: .milliseconds(10)) { try await recorder.attempt() }
        }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("取消后不能发请求") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        _ = try await scheduler.run(key: "model", minimumInterval: .zero) { try await recorder.attempt() }
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.starts.count, 2)
    }

    func testRetryAfterSupportsHTTPDatesAndRejectsInvalidNumbers() {
        let now = Date(timeIntervalSince1970: 0)
        if case let .rateLimitedWithRetryAfter(delay) = LLMService.rateLimitError(headers: ["Retry-After": "Thu, 01 Jan 1970 00:00:05 GMT"], now: now) {
            XCTAssertEqual(delay, 5)
        } else { XCTFail("HTTP-date 未解析") }
        for value in ["-1", "nan", "garbage"] {
            guard case .rateLimited = LLMService.rateLimitError(headers: ["retry-after": value]) else { return XCTFail("无效值不能用于等待") }
        }
    }
}
