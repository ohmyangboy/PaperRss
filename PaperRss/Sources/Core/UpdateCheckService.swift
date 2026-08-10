import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

public struct AppReleaseInfo: Codable, Sendable, Equatable {
    public let tagName: String
    public let version: String
    public let htmlURL: URL
    public let body: String?
    public let publishedAt: Date?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case publishedAt = "published_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        version = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
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

public struct UpdateCheckService: Sendable {
    public static let githubRepositoryURL = URL(string: "https://github.com/ohmyangboy/PaperRss")!
    public static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/ohmyangboy/PaperRss/releases/latest")!

    public static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.1"
    }

    public static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    public static func checkForUpdates() async throws -> (hasUpdate: Bool, release: AppReleaseInfo?) {
        try await withThrowingTaskGroup(of: (hasUpdate: Bool, release: AppReleaseInfo?).self) { group in
            group.addTask {
                var request = URLRequest(url: latestReleaseAPIURL)
                request.timeoutInterval = 15
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("PaperRss/\(currentVersion)", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NSError(domain: "UpdateCheckService", code: 1, userInfo: [NSLocalizedDescriptionKey: "无效的网络响应"])
                }

                guard httpResponse.statusCode == 200 else {
                    if httpResponse.statusCode == 404 {
                        return (false, nil)
                    }
                    throw NSError(domain: "UpdateCheckService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "GitHub Release API 返回状态码 \(httpResponse.statusCode)"])
                }

                let release = try JSONDecoder().decode(AppReleaseInfo.self, from: data)
                let isNewer = compareVersions(latest: release.version, current: currentVersion) > 0
                return (isNewer, isNewer ? release : nil)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw NSError(domain: "UpdateCheckService", code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: "检查更新超时（超过 15 秒）"])
            }

            guard let result = try await group.next() else {
                throw NSError(domain: "UpdateCheckService", code: NSURLErrorUnknown, userInfo: [NSLocalizedDescriptionKey: "未知错误"])
            }
            group.cancelAll()
            return result
        }
    }

    public static func compareVersions(latest: String, current: String) -> Int {
        let parse: (String) -> [Int] = { str in
            let clean = str.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            return clean.split(separator: ".").compactMap { Int($0) }
        }
        let v1 = parse(latest)
        let v2 = parse(current)
        let maxLen = max(v1.count, v2.count)
        for i in 0..<maxLen {
            let num1 = i < v1.count ? v1[i] : 0
            let num2 = i < v2.count ? v2[i] : 0
            if num1 != num2 {
                return num1 > num2 ? 1 : -1
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
