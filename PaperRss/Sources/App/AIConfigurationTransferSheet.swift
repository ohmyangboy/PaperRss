#if os(macOS)
import AppKit
import CoreImage.CIFilterBuiltins
import PaperRssAITransfer
import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

/// A foreground-only, one-time transfer. No QR or credential is exported to disk.
struct AIConfigurationTransferContent: View {
    @ObservedObject var store: AppStore
    @StateObject private var server = PairingServer()
    @State private var offer: PairingOffer?
    @State private var qrImage: NSImage?
    @State private var failure = false
    @State private var isPreparing = false
    @State private var isConsumed = false
    @State private var retryCount = 0

    var body: some View {
        VStack(spacing: 16) {
            Text(I18N.shared.localized("供应商、模型、提示词与 API Key", "Providers, models, prompts & API keys"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(height: 32)

            VStack(spacing: 16) {
                if isConsumed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text(I18N.shared.localized("已发送，请在 iPhone 上确认", "Sent. Confirm on your iPhone."))
                        .accessibilityIdentifier("settings.aiTransfer.sent")
                } else if let offer, let qrImage {
                    IPhoneTransferCode(
                        image: qrImage, expiresAt: offer.expiresAt,
                        instruction: I18N.shared.localized("Papery「模型与 API Key」→「从 Mac 导入」", "Papery: Models & API Key → Import from Mac"),
                        onExpire: invalidateCode
                    )
                } else if isPreparing {
                    ProgressView()
                        .frame(height: 244)
                } else {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(failure
                         ? I18N.shared.localized("配对未能开始，请确认 Mac 已连接局域网后重试。", "Pairing could not start. Check your local network connection and retry.")
                         : I18N.shared.localized("二维码已失效", "QR code expired."))
                        .multilineTextAlignment(.center)
                    Button(I18N.shared.localized("重新生成", "Generate again")) {
                        retryCount += 1
                    }
                    .accessibilityIdentifier("settings.aiTransfer.retry")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: retryCount) { await prepare() }
        .onDisappear {
            // The callbacks capture this view and its StateObject; release them on dismissal.
            server.onConsumed = nil
            server.onInvalidated = nil
            server.stop()
            offer = nil
            qrImage = nil
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            server.stop()
            offer = nil
            qrImage = nil
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
        offer = nil
        qrImage = nil
        server.stop()
        server.onConsumed = {
            isConsumed = true
            offer = nil
            qrImage = nil
        }
        server.onInvalidated = {
            offer = nil
            qrImage = nil
        }
        defer { isPreparing = false }
        do {
            // Read only committed settings. The settings editor's drafts are not transferred.
            let snapshot = try AISettingsTransferSnapshot.make(
                settings: store.aiSettings,
                sourceID: AISettingsTransferSnapshot.sourceID(),
                sourceName: Host.current().localizedName ?? "PaperRss Mac",
                keyForProvider: { store.apiKey(for: $0) }
            )
            let newOffer = try await server.start(snapshot: snapshot)
            try Task.checkCancellation()
            let code = try newOffer.encodedQRCode()
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(code.utf8)
            filter.correctionLevel = "M"
            guard let output = filter.outputImage,
                  let cgImage = CIContext().createCGImage(output, from: output.extent) else {
                server.stop()
                failure = true
                return
            }
            qrImage = NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
            offer = newOffer
        } catch is CancellationError {
            server.stop()
        } catch {
            // Avoid displaying raw protocol errors or QR pairing material.
            server.stop()
            failure = true
        }
    }
}
#endif
