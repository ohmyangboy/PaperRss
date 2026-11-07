#if os(macOS)
import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

struct IPhoneImportSheet: View {
    @ObservedObject var store: AppStore
    var initialAccountID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var selection: ImportTab = .subscriptions

    private enum ImportTab: Hashable {
        case subscriptions, aiConfiguration
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .top) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "iphone")
                        .font(.title2.weight(.semibold))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(I18N.shared.localized("在 iPhone 上导入", "Import on iPhone"))
                                .font(.title2.weight(.semibold))
                            BetaBadge()
                        }
                        Text(I18N.shared.localized("（iOS 正在开发中）", "(iOS in development)"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(I18N.shared.localized("关闭", "Close"))
                .accessibilityIdentifier("iphoneImport.close")
            }

            Picker(I18N.shared.localized("导入内容", "Import content"), selection: $selection) {
                Text(I18N.shared.localized("导入订阅", "Subscriptions")).tag(ImportTab.subscriptions)
                Text(I18N.shared.localized("导入 AI 配置", "AI Configuration")).tag(ImportTab.aiConfiguration)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("iphoneImport.tabs")

            Group {
                switch selection {
                case .subscriptions:
                    SubscriptionTransferContent(store: store, initialAccountID: initialAccountID)
                case .aiConfiguration:
                    AIConfigurationTransferContent(store: store)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 394, alignment: .top)
        }
        .padding(24)
        .frame(width: 440)
    }
}

/// Shared presentation only; each tab owns and invalidates its own pairing session.
struct IPhoneTransferCode: View {
    let image: NSImage
    let expiresAt: Date
    let instruction: String
    let onExpire: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 244, height: 244)
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel(I18N.shared.localized("Papery 导入二维码", "Papery import QR code"))

            Text(instruction)
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(expiresAt.timeIntervalSince(context.date).rounded(.up)))
                HStack(spacing: 18) {
                    Label(I18N.shared.localized("同一局域网", "Same local network"), systemImage: "wifi")
                    Label(String(format: "%d:%02d", remaining / 60, remaining % 60), systemImage: "timer")
                        .monospacedDigit()
                        .accessibilityLabel(I18N.shared.localized("二维码剩余有效时间：", "QR code expires in: ") + "\(remaining)s")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .onChange(of: remaining) { _, seconds in
                    if seconds == 0 { onExpire() }
                }
            }
        }
    }
}
#endif
