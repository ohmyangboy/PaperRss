import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif
#if os(macOS)
import AppKit
import Darwin
#endif

#if os(macOS)

@MainActor
enum FeedbackDiagnosticsProvider {
    static func makeSnapshot(
        appLanguage: AppLanguage,
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo,
        screen: NSScreen? = NSScreen.main
    ) -> FeedbackDiagnosticSnapshot {
        let operatingSystemVersion = processInfo.operatingSystemVersion
        let osVersion = [
            operatingSystemVersion.majorVersion,
            operatingSystemVersion.minorVersion,
            operatingSystemVersion.patchVersion,
        ]
        .map(String.init)
        .joined(separator: ".")

        let displayResolution = screen.map { screen in
            "\(Int(screen.frame.width.rounded())) × \(Int(screen.frame.height.rounded()))"
        }

        return FeedbackDiagnosticSnapshot(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未读取",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未读取",
            osVersion: osVersion,
            osBuild: systemValue("kern.osversion"),
            deviceModel: systemValue("hw.model"),
            architecture: systemValue("hw.machine") ?? "未读取",
            processorCount: processInfo.processorCount,
            appLanguage: appLanguage.resolvedLocalization().rawValue,
            systemRegion: Locale.current.identifier,
            displayResolution: displayResolution,
            displayScale: screen.map { Double($0.backingScaleFactor) },
            recentError: nil
        )
    }

    private static func systemValue(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }

        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        let utf8Bytes = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: utf8Bytes, as: UTF8.self)
    }
}

struct FeedbackPopoverView: View {
    @ObservedObject var store: AppStore
    var onDismiss: () -> Void = {}
    @State private var notice: String?

    private var language: AppLanguage { store.appLanguage }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(I18N.shared.localized("遇到问题了？", "Have a problem?"))
                        .font(.system(size: 19, weight: .semibold, design: .rounded))

                    Text(I18N.shared.localized(
                        "随时反馈，让 PaperRss 更好",
                        "Send feedback anytime to make PaperRss better"
                    ))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 8) {
                    actionRow(
                        icon: "bubble.left.and.bubble.right",
                        title: I18N.shared.localized("GitHub Issue", "GitHub Issue"),
                        subtitle: I18N.shared.localized("Bug 报告与功能建议", "Bug reports and feature requests"),
                        actionTitle: I18N.shared.localized("公开反馈", "Open Issue"),
                        isProminent: true
                    ) {
                        openFeedback(.issue)
                    }

                    actionRow(
                        icon: "envelope",
                        title: I18N.shared.localized("发送邮件", "Send Email"),
                        subtitle: FeedbackComposer.emailAddress,
                        actionTitle: I18N.shared.localized("打开 Mail", "Open Mail"),
                        isProminent: false
                    ) {
                        openFeedback(.email)
                    }
                }

                if let notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(I18N.shared.localized(
                    "反馈会自动带入版本与设备环境信息，不包含文章、订阅地址、API Key 或本机路径。发送截图前请先移除私人素材。",
                    "Feedback includes app and device environment details, but not articles, feed URLs, API keys, or local paths. Remove private content before attaching screenshots."
                ))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                Divider().opacity(0.35)

                VStack(alignment: .leading, spacing: 8) {
                    Text(I18N.shared.localized(
                        "关注社交媒体，支持 PaperRss 开发",
                        "Follow on social media or support PaperRss development"
                    ))
                        .font(.system(size: 13, weight: .semibold))

                    HStack(alignment: .top, spacing: 10) {
                        socialCard(
                            imageName: "XiaohongshuContact",
                            title: I18N.shared.localized("小红书", "Xiaohongshu"),
                            detail: I18N.shared.localized("oi一页风\n小红书号：95393080312", "oi一页风\nID: 95393080312"),
                            imageSize: CGSize(width: 128, height: 174)
                        )

                        socialCard(
                            imageName: "SponsorQR",
                            title: I18N.shared.localized("微信赞赏", "WeChat Support"),
                            detail: I18N.shared.localized("微信扫一扫，感谢支持", "Scan with WeChat to support the project"),
                            imageSize: CGSize(width: 128, height: 128)
                        )
                    }
                }

            }
            .padding(18)
        .frame(width: 410, height: 560)
    }

    private func actionRow(
        icon: String,
        title: String,
        subtitle: String,
        actionTitle: String,
        isProminent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(isProminent ? Color.accentColor : .secondary)
                    .frame(width: 27)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Text(actionTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isProminent ? Color.accentColor : .secondary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isProminent ? Color.accentColor.opacity(0.11) : Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isProminent ? Color.accentColor.opacity(0.42) : Color.primary.opacity(0.13),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func socialCard(
        imageName: String,
        title: String,
        detail: String,
        imageSize: CGSize
    ) -> some View {
        VStack(spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))

            Image(imageName, bundle: nil)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: imageSize.width, height: imageSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.vertical, 10)
        .padding(.horizontal, 7)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    private func currentSnapshot() -> FeedbackDiagnosticSnapshot {
        var snapshot = FeedbackDiagnosticsProvider.makeSnapshot(appLanguage: language)
        if let error = store.latestFeedbackError {
            snapshot = FeedbackDiagnosticSnapshot(
                appVersion: snapshot.appVersion,
                appBuild: snapshot.appBuild,
                osVersion: snapshot.osVersion,
                osBuild: snapshot.osBuild,
                deviceModel: snapshot.deviceModel,
                architecture: snapshot.architecture,
                processorCount: snapshot.processorCount,
                appLanguage: snapshot.appLanguage,
                systemRegion: snapshot.systemRegion,
                displayResolution: snapshot.displayResolution,
                displayScale: snapshot.displayScale,
                recentError: error
            )
        }
        return snapshot
    }

    private func openFeedback(_ channel: FeedbackChannel) {
        let snapshot = currentSnapshot()
        guard let url = FeedbackComposer.url(for: channel, snapshot: snapshot, language: language) else {
            notice = I18N.shared.localized("无法生成反馈链接。", "Unable to create the feedback link.")
            return
        }

        #if os(macOS)
        if channel == .email {
            AppInfo.openMailURL(url) { didOpen in
                if didOpen {
                    onDismiss()
                } else {
                    copyFeedback()
                    notice = I18N.shared.localized(
                        "无法打开 Mail，完整反馈已复制到剪贴板。",
                        "Mail could not be opened. Complete feedback was copied to the clipboard."
                    )
                }
            }
            return
        }
        #endif

        if AppInfo.openURL(url) {
            onDismiss()
        } else {
            copyFeedback()
            notice = I18N.shared.localized(
                "无法打开外部应用，完整反馈已复制到剪贴板。",
                "The external app could not be opened. Complete feedback was copied to the clipboard."
            )
        }
    }

    private func copyFeedback() {
        let draft = FeedbackComposer.draft(for: .issue, snapshot: currentSnapshot(), language: language)
        AppInfo.copyToClipboard("\(draft.subject)\n\n\(draft.body)")
        notice = I18N.shared.localized("完整反馈已复制。", "Complete feedback copied.")
    }
}

#endif
