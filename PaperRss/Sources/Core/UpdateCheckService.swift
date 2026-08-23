import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Semantic Version (SemVer 2.0.0)

public struct SemanticVersion: Comparable, CustomStringConvertible, Codable, Sendable, Equatable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prereleaseIdentifiers: [String]
    public let buildMetadata: String?

    public var isPrerelease: Bool {
        !prereleaseIdentifiers.isEmpty
    }

    public var description: String {
        var result = "\(major).\(minor).\(patch)"
        if !prereleaseIdentifiers.isEmpty {
            result += "-\(prereleaseIdentifiers.joined(separator: "."))"
        }
        if let buildMetadata, !buildMetadata.isEmpty {
            result += "+\(buildMetadata)"
        }
        return result
    }

    public init(major: Int, minor: Int, patch: Int, prereleaseIdentifiers: [String] = [], buildMetadata: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prereleaseIdentifiers = prereleaseIdentifiers
        self.buildMetadata = buildMetadata
    }

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 去掉可能的前缀 'v' 或 'V'
        var text = trimmed
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }

        // 分离 Build Metadata (+)
        let buildParts = text.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: true)
        let buildMeta = buildParts.count > 1 ? String(buildParts[1]) : nil
        let versionWithoutBuild = String(buildParts[0])

        // 分离 Prerelease (-)
        let prereleaseParts = versionWithoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        let coreVersionPart = String(prereleaseParts[0])

        var prereleaseIds: [String] = []
        if prereleaseParts.count > 1 {
            let prereleaseString = String(prereleaseParts[1])
            prereleaseIds = prereleaseString.split(separator: ".").map(String.init)
        }

        // 解析 Major.Minor.Patch
        let coreSegments = coreVersionPart.split(separator: ".")
        guard !coreSegments.isEmpty, let maj = Int(coreSegments[0]) else {
            return nil
        }
        let min = coreSegments.count > 1 ? (Int(coreSegments[1]) ?? 0) : 0
        let pat = coreSegments.count > 2 ? (Int(coreSegments[2]) ?? 0) : 0

        self.major = maj
        self.minor = min
        self.patch = pat
        self.prereleaseIdentifiers = prereleaseIds
        self.buildMetadata = buildMeta
    }

    // MARK: - Comparable (SemVer 2.0.0 Specification)

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // SemVer 规范：正式版（无预发布标识）的优先级高于同版本的预发布版
        // 例如：1.3.0-beta.1 < 1.3.0
        if lhs.isPrerelease && !rhs.isPrerelease {
            return true
        }
        if !lhs.isPrerelease && rhs.isPrerelease {
            return false
        }
        if !lhs.isPrerelease && !rhs.isPrerelease {
            return false
        }

        // 两者均包含预发布标识，按 identifier 逐段对比
        let minCount = min(lhs.prereleaseIdentifiers.count, rhs.prereleaseIdentifiers.count)
        for i in 0..<minCount {
            let id1 = lhs.prereleaseIdentifiers[i]
            let id2 = rhs.prereleaseIdentifiers[i]
            if id1 == id2 { continue }

            let num1 = Int(id1)
            let num2 = Int(id2)

            switch (num1, num2) {
            case let (.some(n1), .some(n2)):
                // 纯数字段：按数值大小比较
                return n1 < n2
            case (.some, .none):
                // 纯数字标识符优先级低于包含字符的标识符
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                // 文本标识符：按 ASCII 字典序比较
                return id1.compare(id2, options: .literal) == .orderedAscending
            }
        }

        // 若前面的标识符完全一致，标识符数量较少的版本优先级较低
        // 例如：1.0.0-alpha < 1.0.0-alpha.1
        return lhs.prereleaseIdentifiers.count < rhs.prereleaseIdentifiers.count
    }
}

// MARK: - App Release Info

public struct AppReleaseInfo: Codable, Sendable, Equatable {
    public let tagName: String
    public let name: String?
    public let version: String
    public let htmlURL: URL
    public let body: String?
    public let publishedAt: Date?
    public let isPrerelease: Bool
    public let isDraft: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case body
        case publishedAt = "published_at"
        case isPrerelease = "prerelease"
        case isDraft = "draft"
    }

    public init(
        tagName: String,
        name: String? = nil,
        version: String? = nil,
        htmlURL: URL,
        body: String? = nil,
        publishedAt: Date? = nil,
        isPrerelease: Bool = false,
        isDraft: Bool = false
    ) {
        self.tagName = tagName
        self.name = name
        let rawClean = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        self.version = version ?? (SemanticVersion(rawClean)?.description ?? rawClean)
        self.htmlURL = htmlURL
        self.body = body
        self.publishedAt = publishedAt
        self.isPrerelease = isPrerelease
        self.isDraft = isDraft
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        let clean = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        version = SemanticVersion(clean)?.description ?? clean

        let urlString = try container.decode(String.self, forKey: .htmlURL)
        htmlURL = URL(string: urlString) ?? URL(string: "https://github.com/ohmyangboy/PaperRss/releases")!
        body = try container.decodeIfPresent(String.self, forKey: .body)

        if let dateString = try container.decodeIfPresent(String.self, forKey: .publishedAt) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            publishedAt = formatter.date(from: dateString) ?? ISO8601DateFormatter().date(from: dateString)
        } else {
            publishedAt = nil
        }

        isPrerelease = try container.decodeIfPresent(Bool.self, forKey: .isPrerelease) ?? false
        isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
    }
}

public enum UpdateCheckStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case hasUpdate(release: AppReleaseInfo, checkedAt: Date)
    case failed(message: String)

    public var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }

    public var hasNewVersion: Bool {
        if case .hasUpdate = self { return true }
        return false
    }
}

// MARK: - Update Check Service

public struct UpdateCheckService: Sendable {
    public static let githubRepositoryURL = URL(string: "https://github.com/ohmyangboy/PaperRss")!
    public static let releasesAPIURL = URL(string: "https://api.github.com/repos/ohmyangboy/PaperRss/releases?per_page=20")!
    public static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/ohmyangboy/PaperRss/releases/latest")!

    public static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.0-beta.2"
    }

    public static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    public static func checkForUpdates(
        allowPrerelease: Bool? = nil,
        currentVersionString: String = currentVersion
    ) async throws -> (hasUpdate: Bool, release: AppReleaseInfo?) {
        try await withThrowingTaskGroup(of: (hasUpdate: Bool, release: AppReleaseInfo?).self) { group in
            group.addTask {
                var request = URLRequest(url: releasesAPIURL)
                request.timeoutInterval = 15
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("PaperRss/\(currentVersionString)", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NSError(domain: "UpdateCheckService", code: 1, userInfo: [NSLocalizedDescriptionKey: I18N.localized("无效的网络响应")])
                }

                guard httpResponse.statusCode == 200 else {
                    if httpResponse.statusCode == 404 {
                        return (false, nil)
                    }
                    throw NSError(domain: "UpdateCheckService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: I18N.localizedFormat("GitHub Release API 返回状态码 %lld", arguments: [httpResponse.statusCode])])
                }

                let releases = try JSONDecoder().decode([AppReleaseInfo].self, from: data)
                let bestRelease = findLatestApplicableRelease(
                    releases: releases,
                    currentVersion: currentVersionString,
                    allowPrerelease: allowPrerelease
                )

                if let bestRelease {
                    return (true, bestRelease)
                } else {
                    return (false, nil)
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw NSError(domain: "UpdateCheckService", code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: I18N.localized("检查更新超时（超过 15 秒）")])
            }

            guard let result = try await group.next() else {
                throw NSError(domain: "UpdateCheckService", code: NSURLErrorUnknown, userInfo: [NSLocalizedDescriptionKey: I18N.localized("未知错误")])
            }
            group.cancelAll()
            return result
        }
    }

    /// 根据当前版本通道筛选适用的最新 Release
    public static func findLatestApplicableRelease(
        releases: [AppReleaseInfo],
        currentVersion: String,
        allowPrerelease: Bool? = nil
    ) -> AppReleaseInfo? {
        let currentSemVer = SemanticVersion(currentVersion)
        // 若未显式指定 allowPrerelease，则当当前版本为 pre-release（如 beta）时自动开启测试通道
        let shouldAllowPrerelease = allowPrerelease ?? (currentSemVer?.isPrerelease == true)

        let candidates = releases.filter { release in
            // 过滤草稿
            if release.isDraft { return false }
            // 若不允许 pre-release，过滤 pre-release
            if !shouldAllowPrerelease && release.isPrerelease { return false }
            return true
        }

        // 筛选出大于 currentVersion 的最高版本
        var highestCandidate: (release: AppReleaseInfo, semVer: SemanticVersion)?

        for release in candidates {
            guard let releaseSemVer = SemanticVersion(release.version) ?? SemanticVersion(release.tagName) else {
                // 如果无法解析 SemVer，退化比对
                if compareVersions(latest: release.version, current: currentVersion) > 0 {
                    if highestCandidate == nil {
                        highestCandidate = (release, SemanticVersion(major: 0, minor: 0, patch: 0))
                    }
                }
                continue
            }

            if let currentSemVer {
                if releaseSemVer > currentSemVer {
                    if let existing = highestCandidate {
                        if releaseSemVer > existing.semVer {
                            highestCandidate = (release, releaseSemVer)
                        }
                    } else {
                        highestCandidate = (release, releaseSemVer)
                    }
                }
            } else {
                // 当前版本无法解析为 SemVer 时，使用通用比对
                if compareVersions(latest: release.version, current: currentVersion) > 0 {
                    if highestCandidate == nil {
                        highestCandidate = (release, releaseSemVer)
                    }
                }
            }
        }

        return highestCandidate?.release
    }

    /// 比较两个版本字符串大小。返回值: 1 (latest > current), -1 (latest < current), 0 (相等)
    public static func compareVersions(latest: String, current: String) -> Int {
        if let v1 = SemanticVersion(latest), let v2 = SemanticVersion(current) {
            if v1 > v2 { return 1 }
            if v1 < v2 { return -1 }
            return 0
        }

        // Fallback: 简易数字与段落比对
        let parse: (String) -> [String] = { str in
            let clean = str.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            return clean.split(separator: ".").map(String.init)
        }
        let v1 = parse(latest)
        let v2 = parse(current)
        let maxLen = max(v1.count, v2.count)
        for i in 0..<maxLen {
            let seg1 = i < v1.count ? v1[i] : "0"
            let seg2 = i < v2.count ? v2[i] : "0"
            if let n1 = Int(seg1), let n2 = Int(seg2) {
                if n1 != n2 { return n1 > n2 ? 1 : -1 }
            } else {
                let comp = seg1.compare(seg2, options: .literal)
                if comp == .orderedDescending { return 1 }
                if comp == .orderedAscending { return -1 }
            }
        }
        return 0
    }

    @MainActor
    public static func openURL(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #elseif os(iOS)
        UIApplication.shared.open(url)
        #endif
    }
}
