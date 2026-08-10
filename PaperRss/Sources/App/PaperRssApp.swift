import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

@main
struct PaperRssApp: App {
    @StateObject private var store: AppStore
    @StateObject private var navigation: AppNavigationModel
    #if os(macOS)
    @StateObject private var attention: MacSystemAttentionController
    #endif

    init() {
        let store = AppStore()
        let navigation = AppNavigationModel()
        _store = StateObject(wrappedValue: store)
        _navigation = StateObject(wrappedValue: navigation)
        #if os(macOS)
        _attention = StateObject(wrappedValue: MacSystemAttentionController(store: store, navigation: navigation))
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store, navigation: navigation)
                #if os(macOS)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                #endif
        }
        #if os(iOS)
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            if await store.refreshInterval != .manual {
                await store.refresh(reportErrors: false, origin: .systemBackground)
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
            SettingsView(store: store, attention: attention)
        }
        #endif
    }
}
