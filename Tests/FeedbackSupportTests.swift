import Foundation
import XCTest
@testable import PaperRssCore

final class FeedbackSupportTests: XCTestCase {
    func testDiagnosticTextContainsOnlyTheProvidedPublicEnvironmentFields() {
        let snapshot = FeedbackDiagnosticSnapshot(
            appVersion: "1.2.3",
            appBuild: "7",
            osVersion: "26.0.1",
            osBuild: "25A123",
            deviceModel: "Mac14,6",
            architecture: "arm64",
            processorCount: 10,
            appLanguage: "zh-Hans",
            systemRegion: "zh_CN",
            displayResolution: "1470 × 956",
            displayScale: 2,
            recentError: FeedbackErrorSnapshot(
                module: .reader,
                message: "加载 https://private.example/article 失败，路径 /Users/yangbukun/private.txt",
                occurredAt: Date(timeIntervalSince1970: 1_756_000_000)
            )
        )

        let text = snapshot.renderedDiagnosticText(language: .zhHans)

        XCTAssertTrue(text.contains("应用版本: PaperRss v1.2.3 (7)"))
        XCTAssertTrue(text.contains("操作系统: macOS 26.0.1 (25A123)"))
        XCTAssertTrue(text.contains("设备型号: Mac14,6"))
        XCTAssertTrue(text.contains("处理器: arm64, 10 核"))
        XCTAssertTrue(text.contains("主显示器: 1470 × 956 (@2x)"))
        XCTAssertTrue(text.contains("最近错误: [阅读器] 加载 <url> 失败，路径 <path>"))
        XCTAssertFalse(text.contains("private.example"))
        XCTAssertFalse(text.contains("/Users/yangbukun"))
    }

    func testIssueURLUsesPrefilledNewIssuePageAndKeepsDiagnosticValues() throws {
        let snapshot = makeSnapshot()

        let url = try XCTUnwrap(FeedbackComposer.url(for: .issue, snapshot: snapshot, language: .zhHans))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.path, "/ohmyangboy/PaperRss/issues/new")
        XCTAssertEqual(query["title"], "[反馈] PaperRss v1.2.3")
        XCTAssertTrue(query["body"]?.contains("Mac14,6") == true)
        XCTAssertTrue(query["body"]?.contains("### 问题描述 / 建议") == true)
        XCTAssertFalse(query["body"]?.contains("https://private.example") == true)
        XCTAssertFalse(query["body"]?.contains("/Users/yangbukun") == true)
    }

    func testEmailURLUsesMailtoAndCarriesTheSameSanitizedDraft() throws {
        let snapshot = makeSnapshot()

        let url = try XCTUnwrap(FeedbackComposer.url(for: .email, snapshot: snapshot, language: .zhHans))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.scheme, "mailto")
        XCTAssertEqual(components.path, FeedbackComposer.emailAddress)
        XCTAssertEqual(query["subject"], "[PaperRss v1.2.3] 反馈")
        XCTAssertTrue(query["body"]?.contains("设备与环境诊断信息") == true)
        XCTAssertFalse(query["body"]?.contains("secret-token") == true)
    }

    func testEnglishDraftUsesEnglishLabelsWithoutChangingTheDiagnosticPayload() throws {
        let snapshot = makeSnapshot()

        let draft = FeedbackComposer.draft(for: .issue, snapshot: snapshot, language: .en)

        XCTAssertEqual(draft.subject, "[Feedback] PaperRss v1.2.3")
        XCTAssertTrue(draft.body.contains("### Problem / Suggestion"))
        XCTAssertTrue(draft.body.contains("Environment Diagnostics"))
        XCTAssertTrue(draft.body.contains("Device model: Mac14,6"))
    }

    private func makeSnapshot() -> FeedbackDiagnosticSnapshot {
        FeedbackDiagnosticSnapshot(
            appVersion: "1.2.3",
            appBuild: "7",
            osVersion: "26.0.1",
            osBuild: "25A123",
            deviceModel: "Mac14,6",
            architecture: "arm64",
            processorCount: 10,
            appLanguage: "zh-Hans",
            systemRegion: "zh_CN",
            displayResolution: "1470 × 956",
            displayScale: 2,
            recentError: FeedbackErrorSnapshot(
                module: .refresh,
                message: "request failed: https://private.example/api?token=secret-token",
                occurredAt: Date(timeIntervalSince1970: 1_756_000_000)
            )
        )
    }
}
