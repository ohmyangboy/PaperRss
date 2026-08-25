#if os(macOS)
import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
import PaperRssUpdateSupport
#endif

/// 左下角更新胶囊：应用内唯一的普通/critical 更新入口。
/// 两段式：可用态点击开始下载；就绪态点击重启安装。
/// 无标准 Sparkle 窗口、无关闭/忽略按钮、无永久 skip。
struct UpdateCapsule: View {
    @ObservedObject var coordinator: UpdateCoordinator
    @State private var showsUpToDateToast = false
    @State private var upToDateToastTask: Task<Void, Never>?

    var body: some View {
        content
            .onChange(of: coordinator.lastUpToDateNoticeAt) { _, noticeAt in
                guard noticeAt != nil else { return }
                showToast()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.state {
        case .idle:
            EmptyView()
        case .checking:
            capsule(emphasized: false) {
                ProgressView()
                    .controlSize(.mini)
            }
        case .upToDate:
            if showsUpToDateToast {
                capsule(emphasized: false) {
                    Image(systemName: "checkmark.circle")
                    Text(I18N.shared.localized("已是最新版本", "You're up to date"))
                }
            } else {
                EmptyView()
            }
        case let .updateAvailable(release):
            capsule(emphasized: release.isCritical) {
                actionButton(
                    title: release.isCritical
                        ? I18N.shared.localized("重要更新", "Critical Update")
                        : I18N.shared.localized("更新", "Update"),
                    systemImage: release.isCritical ? "exclamationmark.arrow.circlepath" : "arrow.down.circle.fill"
                ) {
                    coordinator.beginDownload()
                }
                .help(I18N.shared.localizedFormat("更新 %@ 可用", release.displayVersion))
            }
        case let .downloading(progress):
            capsule(emphasized: false) {
                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 44)
                    Text(I18N.shared.localizedFormat("%lld%%", Int((fraction * 100).rounded())))
                        .monospacedDigit()
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        case let .preparing(preparation):
            capsule(emphasized: false) {
                ProgressView(value: preparation.fractionCompleted)
                    .progressViewStyle(.linear)
                    .frame(width: 44)
            }
        case .readyToInstall:
            capsule(emphasized: true) {
                actionButton(
                    title: I18N.shared.localized("重启", "Restart"),
                    systemImage: "power.circle.fill"
                ) {
                    coordinator.installAndRelaunch()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        case .installing, .relaunching:
            capsule(emphasized: true) {
                ProgressView()
                    .controlSize(.mini)
            }
        case .deferredUntilQuit:
            capsule(emphasized: false) {
                Image(systemName: "tray.and.arrow.down")
                Text(I18N.shared.localized("退出安装", "Install on Quit"))
            }
        case let .failed(failure):
            capsule(emphasized: false) {
                actionButton(
                    title: I18N.shared.localized("重试", "Retry"),
                    systemImage: "arrow.clockwise.circle"
                ) {
                    coordinator.checkForUpdates()
                }
                .help(failure.message)
                Button {
                    coordinator.dismissFailure()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(I18N.shared.localized("关闭", "Close"))
            }
        }
    }

    private func capsule<Content: View>(
        emphasized: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 6) {
            content()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(emphasized ? Color.white : Color.primary.opacity(0.85))
        .padding(.horizontal, 10)
        .frame(minWidth: 28, minHeight: 26)
        .background(
            (emphasized ? Color.accentColor : Color.primary.opacity(0.08)),
            in: Capsule()
        )
        .animation(nil, value: coordinator.state)
        .accessibilityElement(children: .combine)
    }

    private func actionButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title)
            }
        }
        .buttonStyle(.borderless)
    }

    private func showToast() {
        upToDateToastTask?.cancel()
        showsUpToDateToast = true
        upToDateToastTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            showsUpToDateToast = false
        }
    }
}
#endif
