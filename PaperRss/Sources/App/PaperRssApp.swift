import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif
#if os(macOS)
#if SWIFT_PACKAGE
import PaperRssUpdateSupport
#endif
import AppKit
#endif

@main
struct PaperRssApp: App {
    @StateObject private var store: AppStore
    @StateObject private var navigation: AppNavigationModel
    #if os(macOS)
    @StateObject private var attention: MacSystemAttentionController
    @StateObject private var updateCoordinator: UpdateCoordinator
    #endif

    init() {
        let store = AppStore()
        let navigation = AppNavigationModel()
        _store = StateObject(wrappedValue: store)
        _navigation = StateObject(wrappedValue: navigation)
        #if os(macOS)
        _attention = StateObject(wrappedValue: MacSystemAttentionController(store: store, navigation: navigation))
        _updateCoordinator = StateObject(wrappedValue: UpdateCoordinatorFactory.make())
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            RootView(store: store, navigation: navigation, updateCoordinator: updateCoordinator)
                .onAppear {
                    let application = NSApplication.shared
                    attention.start(application: application)
                    application.activate(ignoringOtherApps: true)
                    updateCoordinator.start()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    updateCoordinator.applicationDidBecomeActive()
                }
            #else
            RootView(store: store, navigation: navigation)
            #endif
        }
        .environment(\.locale, Locale(identifier: store.appLanguage.localeIdentifier))
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
                Button(I18N.localized("刷新全部订阅")) { Task { await store.refresh() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textFormatting) {
                Button(I18N.localized("放大正文字号")) {
                    store.increaseArticleFontSize()
                }
                .keyboardShortcut("=", modifiers: .command)

                Button(I18N.localized("放大正文字号")) {
                    store.increaseArticleFontSize()
                }
                .keyboardShortcut("+", modifiers: .command)

                Button(I18N.localized("缩小正文字号")) {
                    store.decreaseArticleFontSize()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button(I18N.localized("默认正文字号")) {
                    store.resetArticleFontSize()
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            #if os(macOS)
            CommandGroup(after: .appInfo) {
                Button(I18N.localized("检查更新", englishFallback: "Check for Updates")) {
                    updateCoordinator.checkForUpdates()
                }
                .disabled({
                    if case .checking = updateCoordinator.state { return true }
                    return false
                }())
            }

            KeyboardShortcutHelpCommands()
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        #endif

        #if os(macOS)
        Window(I18N.localized("键盘快捷键", englishFallback: "Keyboard Shortcuts"), id: KeyboardShortcutHelpWindow.id) {
            KeyboardShortcutHelpView()
                .environment(\.locale, Locale(identifier: store.appLanguage.localeIdentifier))
        }
        .defaultSize(width: 560, height: 620)

        Settings {
            SettingsView(store: store, attention: attention, updateCoordinator: updateCoordinator)
                .environment(\.locale, Locale(identifier: store.appLanguage.localeIdentifier))
        }
        #endif
    }
}
