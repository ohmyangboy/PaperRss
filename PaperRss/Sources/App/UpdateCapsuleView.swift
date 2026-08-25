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
                Text(I18N.shared.localized("检查更新…", "Checking for Updates…"))
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
                        ? I18N.shared.localizedFormat("重要更新 %@ 可用", release.displayVersion)
                        : I18N.shared.localizedFormat("更新 %@ 可用", release.displayVersion),
                    systemImage: release.isCritical ? "exclamationmark.arrow.circlepath" : "arrow.down.circle.fill"
                ) {
                    coordinator.beginDownload()
                }
            }
        case let .downloading(progress):
            capsule(emphasized: false) {
                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 56)
                    Text(I18N.shared.localizedFormat("下载中 %lld%%", Int((fraction * 100).rounded())))
                } else {
                    ProgressView()
                        .controlSize(.mini)
                    Text(I18N.shared.localized("下载中…", "Downloading…"))
                }
            }
        case let .preparing(preparation):
            capsule(emphasized: false) {
                ProgressView(value: preparation.fractionCompleted)
                    .progressViewStyle(.linear)
                    .frame(width: 56)
                Text(I18N.shared.localized("正在准备更新…", "Preparing Update…"))
            }
        case .readyToInstall:
            capsule(emphasized: true) {
                actionButton(
                    title: I18N.shared.localized("重启更新", "Restart to Update"),
                    systemImage: "power.circle.fill"
                ) {
                    coordinator.installAndRelaunch()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        case let .installing(release):
            capsule(emphasized: true) {
                ProgressView()
                    .controlSize(.mini)
                Text(I18N.shared.localizedFormat("正在安装更新 %@", release.displayVersion))
            }
        case .relaunching:
            capsule(emphasized: true) {
                ProgressView()
                    .controlSize(.mini)
                Text(I18N.shared.localized("正在重启…", "Relaunching…"))
            }
        case let .deferredUntilQuit(release):
            capsule(emphasized: false) {
                Image(systemName: "tray.and.arrow.down")
                Text(I18N.shared.localizedFormat("更新 %@ 将在退出时安装", release.displayVersion))
            }
        case let .failed(failure):
            capsule(emphasized: false) {
                actionButton(
                    title: I18N.shared.localized("更新失败 · 重试", "Update failed · Retry"),
                    systemImage: "arrow.clockwise.circle"
                ) {
                    coordinator.checkForUpdates()
                }
                .help(failure.message)
                Button {
                    AppInfo.openURL(failure.fallbackURL)
                } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.borderless)
                .help(I18N.shared.localized("打开发布页手动下载", "Open the releases page"))
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
        .padding(.vertical, 5)
        .background(
            (emphasized ? Color.accentColor : Color.primary.opacity(0.08)),
            in: Capsule()
        )
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
