import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// App 层版本与链接工具。GitHub Release API 检查已由 Sparkle 取代；
/// 此处只保留与更新无关的通用能力。
public enum AppInfo {
    public static let githubRepositoryURL = URL(string: "https://github.com/ohmyangboy/PaperRss")!
    public static let releasesPageURL = URL(string: "https://github.com/ohmyangboy/PaperRss/releases")!

    public static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    public static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
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
