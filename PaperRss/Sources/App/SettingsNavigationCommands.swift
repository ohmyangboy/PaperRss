#if os(macOS)
import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import PaperRssCore
#endif

private struct OpenPaperSettingsKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct PaperReaderActiveKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var paperReaderActive: Bool? {
        get { self[PaperReaderActiveKey.self] }
        set { self[PaperReaderActiveKey.self] = newValue }
    }
    var openPaperSettings: (() -> Void)? {
        get { self[OpenPaperSettingsKey.self] }
        set { self[OpenPaperSettingsKey.self] = newValue }
    }
}

struct SettingsNavigationCommands: Commands {
    @FocusedValue(\.openPaperSettings) private var openCurrentSettings
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var navigation: AppNavigationModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(I18N.shared.localized("设置…", "Settings…")) {
                if SettingsWindowRoute.openCurrent() { }
                else if let openCurrentSettings { openCurrentSettings() }
                else {
                    navigation.opensSettingsOnNextWindow = true
                    openWindow(id: "main")
                }
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

/// AppKit-backed reader windows do not always publish SwiftUI focus values.
/// Keep the route attached to its actual window rather than a global reader.
struct SettingsWindowRoute: NSViewRepresentable {
    var open: () -> Void

    final class RouteView: NSView {
        static let routes = NSMapTable<NSWindow, RouteView>.weakToWeakObjects()
        var open: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { Self.routes.setObject(self, forKey: window) }
        }
    }

    func makeNSView(context: Context) -> RouteView {
        let view = RouteView()
        view.open = open
        return view
    }

    func updateNSView(_ view: RouteView, context: Context) { view.open = open }

    static func openCurrent() -> Bool {
        let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows
        for window in candidates where window.isVisible {
            guard let route = RouteView.routes.object(forKey: window), let open = route.open else { continue }
            window.makeKeyAndOrderFront(nil)
            open()
            return true
        }
        return false
    }
}
#endif
