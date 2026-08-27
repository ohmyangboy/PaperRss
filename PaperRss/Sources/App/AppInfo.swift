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
    @discardableResult
    public static func openURL(_ url: URL) -> Bool {
        #if os(macOS)
        return NSWorkspace.shared.open(url)
        #elseif os(iOS)
        UIApplication.shared.open(url)
        return true
        #endif
    }

    #if os(macOS)
    /// 使用系统 Mail.app 打开预填充的邮件，而不是交给默认浏览器处理 mailto:。
    @MainActor
    public static func openMailURL(_ url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        guard let mailURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") else {
            completion(false)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: mailURL,
            configuration: configuration
        ) { _, error in
            let didOpen = error == nil
            DispatchQueue.main.async {
                completion(didOpen)
            }
        }
    }
    #endif

    @MainActor
    public static func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}
