import XCTest
@testable import PaperRssCore

final class UpdateCheckServiceTests: XCTestCase {

    // MARK: - SemanticVersion Parsing Tests

    func testSemanticVersionParsing() {
        let v1 = SemanticVersion("1.3.0")
        XCTAssertNotNil(v1)
        XCTAssertEqual(v1?.major, 1)
        XCTAssertEqual(v1?.minor, 3)
        XCTAssertEqual(v1?.patch, 0)
        XCTAssertFalse(v1?.isPrerelease ?? true)
        XCTAssertEqual(v1?.description, "1.3.0")

        let v2 = SemanticVersion("v1.3.0-beta.1")
        XCTAssertNotNil(v2)
        XCTAssertEqual(v2?.major, 1)
        XCTAssertEqual(v2?.minor, 3)
        XCTAssertEqual(v2?.patch, 0)
        XCTAssertTrue(v2?.isPrerelease ?? false)
        XCTAssertEqual(v2?.prereleaseIdentifiers, ["beta", "1"])
        XCTAssertEqual(v2?.description, "1.3.0-beta.1")

        let v3 = SemanticVersion("V2.0.0-rc.3+build.123")
        XCTAssertNotNil(v3)
        XCTAssertEqual(v3?.major, 2)
        XCTAssertEqual(v3?.minor, 0)
        XCTAssertEqual(v3?.patch, 0)
        XCTAssertTrue(v3?.isPrerelease ?? false)
        XCTAssertEqual(v3?.prereleaseIdentifiers, ["rc", "3"])
        XCTAssertEqual(v3?.buildMetadata, "build.123")

        let v4 = SemanticVersion("1.4")
        XCTAssertNotNil(v4)
        XCTAssertEqual(v4?.major, 1)
        XCTAssertEqual(v4?.minor, 4)
        XCTAssertEqual(v4?.patch, 0)

        let invalid = SemanticVersion("not-a-version")
        XCTAssertNil(invalid)
    }

    // MARK: - SemanticVersion Comparison Tests

    func testSemanticVersionComparison() {
        let v1_2_0 = SemanticVersion("1.2.0")!
        let v1_3_0_beta_1 = SemanticVersion("1.3.0-beta.1")!
        let v1_3_0_beta_2 = SemanticVersion("1.3.0-beta.2")!
        let v1_3_0_rc_1 = SemanticVersion("1.3.0-rc.1")!
        let v1_3_0 = SemanticVersion("1.3.0")!
        let v1_3_1_beta_1 = SemanticVersion("1.3.1-beta.1")!
        let v1_3_1 = SemanticVersion("1.3.1")!
        let v2_0_0 = SemanticVersion("2.0.0")!

        // 基础版本对比
        XCTAssertTrue(v1_2_0 < v1_3_0)
        XCTAssertTrue(v1_3_0 < v1_3_1)
        XCTAssertTrue(v1_3_1 < v2_0_0)

        // 预发布版本递增
        XCTAssertTrue(v1_3_0_beta_1 < v1_3_0_beta_2)
        XCTAssertTrue(v1_3_0_beta_2 < v1_3_0_rc_1)

        // 核心修复点：预发布版本必须小于同版本号的正式版！
        XCTAssertTrue(v1_3_0_beta_1 < v1_3_0)
        XCTAssertTrue(v1_3_0_beta_2 < v1_3_0)
        XCTAssertTrue(v1_3_0_rc_1 < v1_3_0)

        // 跨版本的预发布对比
        XCTAssertTrue(v1_3_0 < v1_3_1_beta_1)
        XCTAssertTrue(v1_3_1_beta_1 < v1_3_1)
    }

    // MARK: - Compare Versions Function Tests

    func testCompareVersionsFunction() {
        XCTAssertEqual(UpdateCheckService.compareVersions(latest: "1.3.0-beta.2", current: "1.3.0-beta.1"), 1)
        XCTAssertEqual(UpdateCheckService.compareVersions(latest: "1.3.0", current: "1.3.0-beta.1"), 1)
        XCTAssertEqual(UpdateCheckService.compareVersions(latest: "1.3.0-beta.1", current: "1.3.0"), -1)
        XCTAssertEqual(UpdateCheckService.compareVersions(latest: "1.3.0", current: "1.3.0"), 0)
        XCTAssertEqual(UpdateCheckService.compareVersions(latest: "v1.4.0", current: "1.3.0"), 1)
    }

    // MARK: - Release Filtering Tests

    func testFindLatestApplicableReleaseForBetaUser() {
        let releases: [AppReleaseInfo] = [
            AppReleaseInfo(
                tagName: "v1.3.0-beta.3",
                htmlURL: URL(string: "https://example.com/beta3")!,
                isPrerelease: true
            ),
            AppReleaseInfo(
                tagName: "v1.3.0-beta.2",
                htmlURL: URL(string: "https://example.com/beta2")!,
                isPrerelease: true
            ),
            AppReleaseInfo(
                tagName: "v1.2.0",
                htmlURL: URL(string: "https://example.com/v1.2.0")!,
                isPrerelease: false
            ),
            AppReleaseInfo(
                tagName: "v1.4.0-draft",
                htmlURL: URL(string: "https://example.com/draft")!,
                isPrerelease: true,
                isDraft: true
            )
        ]

        // 当前用户处于 1.3.0-beta.1，应自动识别到最高的 1.3.0-beta.3（草稿被忽略）
        let match = UpdateCheckService.findLatestApplicableRelease(
            releases: releases,
            currentVersion: "1.3.0-beta.1"
        )
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.tagName, "v1.3.0-beta.3")

        // 若当前已经是 1.3.0-beta.3，应返回 nil
        let matchLatest = UpdateCheckService.findLatestApplicableRelease(
            releases: releases,
            currentVersion: "1.3.0-beta.3"
        )
        XCTAssertNil(matchLatest)
    }

    func testFindLatestApplicableReleaseForReleaseUser() {
        let releases: [AppReleaseInfo] = [
            AppReleaseInfo(
                tagName: "v1.4.0-beta.1",
                htmlURL: URL(string: "https://example.com/beta")!,
                isPrerelease: true
            ),
            AppReleaseInfo(
                tagName: "v1.3.1",
                htmlURL: URL(string: "https://example.com/v1.3.1")!,
                isPrerelease: false
            ),
            AppReleaseInfo(
                tagName: "v1.3.0",
                htmlURL: URL(string: "https://example.com/v1.3.0")!,
                isPrerelease: false
            )
        ]

        // 当前用户处于 1.3.0（正式版），默认不接收 beta，应匹配到 1.3.1 正式版
        let match = UpdateCheckService.findLatestApplicableRelease(
            releases: releases,
            currentVersion: "1.3.0"
        )
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.tagName, "v1.3.1")

        // 若显式允许 prerelease，则应匹配到 1.4.0-beta.1
        let betaMatch = UpdateCheckService.findLatestApplicableRelease(
            releases: releases,
            currentVersion: "1.3.0",
            allowPrerelease: true
        )
        XCTAssertNotNil(betaMatch)
        XCTAssertEqual(betaMatch?.tagName, "v1.4.0-beta.1")
    }

    // MARK: - JSON Decoding Tests

    func testAppReleaseInfoJSONDecoding() throws {
        let json = """
        {
            "tag_name": "v1.3.0-beta.2",
            "name": "PaperRss 1.3.0 Beta 2",
            "html_url": "https://github.com/ohmyangboy/PaperRss/releases/tag/v1.3.0-beta.2",
            "body": "Fixed update check logic",
            "published_at": "2026-08-23T12:00:00Z",
            "prerelease": true,
            "draft": false
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(AppReleaseInfo.self, from: json)
        XCTAssertEqual(release.tagName, "v1.3.0-beta.2")
        XCTAssertEqual(release.version, "1.3.0-beta.2")
        XCTAssertEqual(release.name, "PaperRss 1.3.0 Beta 2")
        XCTAssertEqual(release.htmlURL.absoluteString, "https://github.com/ohmyangboy/PaperRss/releases/tag/v1.3.0-beta.2")
        XCTAssertEqual(release.body, "Fixed update check logic")
        XCTAssertTrue(release.isPrerelease)
        XCTAssertFalse(release.isDraft)
        XCTAssertNotNil(release.publishedAt)
    }
}
