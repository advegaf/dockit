import AppKit
import SwiftUI

enum DockitWindowSize {
    static let editor = NSSize(width: 620, height: 252)
    /// The first-run screen: icon, headline, blurb, login toggle, save button.
    /// Taller than the editor so nothing scrolls; the window animates back to
    /// the editor size once the first profile exists.
    static let setup = NSSize(width: 620, height: 440)
    static let settings = NSSize(width: 620, height: 620)
    static let settingsMinimum = NSSize(width: 520, height: 480)
}

@main
@MainActor
struct DockitApp: App {
    @NSApplicationDelegateAdaptor(DockitAppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("dockit", id: "management") {
            DockitRootView(model: model, appDelegate: appDelegate)
        }
        .defaultSize(width: DockitWindowSize.editor.width, height: DockitWindowSize.editor.height)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            DockitCommands(model: model)
        }

        Window("dockit settings", id: "preferences") {
            SettingsView(model: model)
        }
        .defaultSize(width: DockitWindowSize.settings.width, height: DockitWindowSize.settings.height)
    }
}

private struct DockitRootView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: AppModel
    let appDelegate: DockitAppDelegate

    var body: some View {
        ContentView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .windowResizeBehavior(.disabled)
            .windowFullScreenBehavior(.disabled)
            .background(EditorWindowLayout(size: model.library.profiles.isEmpty && !model.isLoading && !model.storageUnavailable
                ? DockitWindowSize.setup
                : DockitWindowSize.editor))
            .onAppear {
                appDelegate.setWindowPresenter {
                    openWindow(id: "management")
                }
                appDelegate.setSettingsWindowPresenter {
                    openWindow(id: "preferences")
                }
            }
    }
}

struct EditorWindowLayout: NSViewRepresentable {
    var size: NSSize = DockitWindowSize.editor

    func makeNSView(context: Context) -> WindowLayoutView {
        let view = WindowLayoutView()
        view.size = size
        return view
    }

    func updateNSView(_ view: WindowLayoutView, context: Context) {
        view.size = size
    }

    final class WindowLayoutView: NSView {
        /// The one size this window may have right now. Changing it resizes
        /// the window in place, keeping its top left corner where it is.
        var size: NSSize = DockitWindowSize.editor {
            didSet { if size != oldValue { apply(animated: true) } }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.remove(.resizable)
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
            window.titlebarSeparatorStyle = .none
            window.titlebarAppearsTransparent = true
            apply(animated: false)
        }

        private func apply(animated: Bool) {
            guard let window else { return }
            window.minSize = size
            window.maxSize = size
            let frame = NSRect(
                x: window.frame.minX,
                y: window.frame.maxY - size.height,
                width: size.width,
                height: size.height
            )
            guard window.frame != frame else { return }
            window.setFrame(frame, display: true, animate: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }
}
