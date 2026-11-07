#if os(macOS)
import AppKit
import CoreImage.CIFilterBuiltins
import PaperRssAITransfer
import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

struct SubscriptionTransferContent: View {
    @ObservedObject var store: AppStore
    @StateObject private var server = PairingServer()
    @State private var selectedAccountID: String
    @State private var offer: PairingOffer?
    @State private var qrImage: NSImage?
    @State private var failure = false
    @State private var isPreparing = false
    @State private var isConsumed = false
    @State private var isEmpty = false
    @State private var feedCount = 0
    @State private var folderCount = 0
    @State private var retryCount = 0

    init(store: AppStore, initialAccountID: String? = nil) {
        self.store = store
        let preferred = initialAccountID ?? store.activeAccountID
        _selectedAccountID = State(initialValue: store.enabledAccounts.contains(where: { $0.id == preferred })
                                  ? preferred : store.enabledAccounts.first?.id ?? "local-default")
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                if store.enabledAccounts.isEmpty {
                    Text(I18N.shared.localized("未启用账号", "No enabled accounts"))
                        .foregroundStyle(.secondary)
                } else {
                    Picker(I18N.shared.localized("来源账号", "Source account"), selection: $selectedAccountID) {
                        ForEach(store.enabledAccounts) { account in
                            Text(account.displayName).tag(account.id)
                        }
                    }
                    .labelsHidden()
                    .disabled(isPreparing)
                    .accessibilityIdentifier("subscriptions.transfer.account")
                    Spacer(minLength: 0)
                    Text(String(format: I18N.shared.localized("%lld 个订阅 · %lld 个分组", "%lld feeds · %lld folders"), feedCount, folderCount))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .frame(height: 32)

            VStack(spacing: 16) {
                if isConsumed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text(I18N.shared.localized("已发送，请在 iPhone 上确认", "Sent. Confirm on your iPhone."))
                        .accessibilityIdentifier("subscriptions.transfer.sent")
                } else if let offer, let qrImage {
                    IPhoneTransferCode(
                        image: qrImage, expiresAt: offer.expiresAt,
                        instruction: I18N.shared.localized("用 Papery 扫码导入", "Scan with Papery to import"),
                        onExpire: invalidateCode
                    )
                } else if isPreparing {
                    ProgressView().frame(height: 244)
                } else if isEmpty {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text(store.enabledAccounts.isEmpty
                         ? I18N.shared.localized("在设置中启用账号后导入订阅", "Enable an account in Settings to import subscriptions")
                         : I18N.shared.localized("暂无订阅或分组", "No subscriptions or folders yet"))
                        .multilineTextAlignment(.center)
                } else {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text(failure
                         ? I18N.shared.localized("配对未能开始，请确认 Mac 已连接局域网后重试。", "Pairing could not start. Check your local network connection and retry.")
                         : I18N.shared.localized("二维码已失效", "QR code expired."))
                        .multilineTextAlignment(.center)
                    Button(I18N.shared.localized("重新生成", "Generate again")) {
                        retryCount += 1
                    }
                    .disabled(isPreparing)
                    .accessibilityIdentifier("subscriptions.transfer.retry")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: [selectedAccountID, String(retryCount)]) { await prepare() }
        .onChange(of: store.accounts) { _, _ in
            if !store.enabledAccounts.contains(where: { $0.id == selectedAccountID }) {
                selectedAccountID = store.enabledAccounts.first?.id ?? "local-default"
                invalidateCode()
            }
        }
        .onDisappear {
            server.onConsumed = nil
            server.onInvalidated = nil
            invalidateCode()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            invalidateCode()
        }
    }

    private func invalidateCode() {
        server.stop()
        offer = nil
        qrImage = nil
    }

    @MainActor
    private func prepare() async {
        guard !isPreparing else { return }
        isPreparing = true
        failure = false
        isConsumed = false
        isEmpty = false
        invalidateCode()
        defer { isPreparing = false }
        guard let account = store.enabledAccounts.first(where: { $0.id == selectedAccountID }) else {
            feedCount = 0
            folderCount = 0
            isEmpty = true
            return
        }
        let snapshot = SubscriptionTransferSnapshot.make(
            accountID: account.id, feedsByAccount: store.feedsByAccount, foldersByAccount: store.foldersByAccount,
            sourceID: AISettingsTransferSnapshot.sourceID(),
            sourceName: Host.current().localizedName ?? "PaperRss Mac", accountName: account.displayName
        )
        feedCount = snapshot.feeds.count
        folderCount = snapshot.folders.count
        guard feedCount > 0 || folderCount > 0 else { isEmpty = true; return }
        server.onConsumed = {
            isConsumed = true
            offer = nil
            qrImage = nil
        }
        server.onInvalidated = {
            offer = nil
            qrImage = nil
        }
        do {
            let newOffer = try await server.start(subscriptions: snapshot)
            try Task.checkCancellation()
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(try newOffer.encodedQRCode().utf8)
            filter.correctionLevel = "M"
            guard let output = filter.outputImage,
                  let image = CIContext().createCGImage(output, from: output.extent) else {
                failure = true
                server.stop()
                return
            }
            qrImage = NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
            offer = newOffer
        } catch is CancellationError {
            invalidateCode()
        } catch {
            invalidateCode()
            failure = true
        }
    }
}
#endif
