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
        }
        #if os(iOS)
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await store.refresh()
            BackgroundRefresh.schedule()
        }
        #endif
        .commands {
            CommandGroup(after: .newItem) {
                Button("刷新全部订阅") { Task { await store.refresh() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        #if os(macOS)
        Settings {
            SettingsView(store: store)
        }
        #endif
    }
}
