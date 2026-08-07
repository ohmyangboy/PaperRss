import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

@main
struct PaperRssApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                #if os(macOS)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                #endif
        }
        #if os(iOS)
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            if await store.refreshInterval != .manual {
                await store.refresh(reportErrors: false)
            }
            BackgroundRefresh.schedule(interval: await store.refreshInterval)
        }
        #endif
        .commands {
            CommandGroup(after: .newItem) {
                Button("刷新全部订阅") { Task { await store.refresh() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textFormatting) {
                Button("放大正文字号") {
                    store.increaseArticleFontSize()
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("放大正文字号") {
                    store.increaseArticleFontSize()
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("缩小正文字号") {
                    store.decreaseArticleFontSize()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("默认正文字号") {
                    store.resetArticleFontSize()
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        #if os(macOS)
        Settings {
            SettingsView(store: store)
        }
        #endif
    }
}
