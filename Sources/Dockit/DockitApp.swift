import AppKit
import SwiftUI

enum DockitWindowSize {
    static let editor = NSSize(width: 620, height: 252)
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
            .background(EditorWindowLayout())
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
    func makeNSView(context: Context) -> WindowLayoutView {
        WindowLayoutView()
    }

    func updateNSView(_ view: WindowLayoutView, context: Context) {}

    final class WindowLayoutView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.remove(.resizable)
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
            window.titlebarSeparatorStyle = .none
            window.titlebarAppearsTransparent = true
            window.minSize = DockitWindowSize.editor
            window.maxSize = DockitWindowSize.editor
            let frame = NSRect(
                x: window.frame.minX,
                y: window.frame.maxY - DockitWindowSize.editor.height,
                width: DockitWindowSize.editor.width,
                height: DockitWindowSize.editor.height
            )
            window.setFrame(frame, display: false)
        }
    }
}
