import AppKit

/// Screenshot support. `DOCKIT_WINDOW_HOLD=editor|settings|guide` opens that
/// surface, prints `windownumber=<n>` on stdout once it is on screen and
/// settled, and keeps the app alive so `Tools/Screenshots/window-shot.sh` can
/// capture it through the window server with `screencapture -l`.
///
/// The app reports its own window number because resolving it from outside by
/// owner name picks the largest window of any dockit process, and a leftover
/// instance or one still animating shut wins that race. Every shot runs with
/// `DOCKIT_DEMO=1`, so the real Dock is never touched.
@MainActor
enum WindowSnapshot {
    enum Surface: String {
        case editor
        case settings
        /// The quick guide sheet over the editor. Only the sheet is reported,
        /// so the shot is the guide card on its own.
        case guide
    }

    static var requestedSurface: Surface? {
        ProcessInfo.processInfo.environment["DOCKIT_WINDOW_HOLD"].flatMap(Surface.init(rawValue:))
    }

    /// Called from `applicationDidFinishLaunching`, after the SwiftUI window
    /// presenters are installed.
    static func holdIfRequested(delegate: DockitAppDelegate) {
        guard let surface = requestedSurface else { return }
        switch surface {
        case .editor:
            delegate.showMainWindow()
            report(windowIdentifier: "management")
        case .settings:
            delegate.showSettingsWindow()
            // The editor opens on launch too; move it out so it does not sit
            // behind the settings shot.
            for window in NSApplication.shared.windows where window.identifier?.rawValue == "management" {
                window.orderOut(nil)
            }
            report(windowIdentifier: "preferences")
        case .guide:
            delegate.showMainWindow()
            AppModel.shared.quickGuidePresented = true
            report(sheetOver: "management")
        }
    }

    /// A SwiftUI sheet has no identifier of its own; find it by its parent.
    private static func report(sheetOver parentIdentifier: String, attempt: Int = 0) {
        let sheet = NSApplication.shared.windows.first {
            $0.sheetParent?.identifier?.rawValue == parentIdentifier
        }
        if let sheet, sheet.isVisible, sheet.windowNumber > 0 {
            NSApplication.shared.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                FileHandle.standardOutput.write(Data("windownumber=\(sheet.windowNumber)\n".utf8))
            }
            return
        }
        guard attempt < 100 else {
            FileHandle.standardError.write(Data("DOCKIT_WINDOW_HOLD: no sheet appeared over \(parentIdentifier)\n".utf8))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            report(sheetOver: parentIdentifier, attempt: attempt + 1)
        }
    }

    /// Polls until the window is on screen with a real number, then waits for
    /// its entrance to finish before reporting, so there is something settled
    /// to shoot.
    private static func report(windowIdentifier: String, attempt: Int = 0) {
        let window = NSApplication.shared.windows.first { $0.identifier?.rawValue == windowIdentifier }
        if let window, window.isVisible, window.windowNumber > 0 {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                FileHandle.standardOutput.write(Data("windownumber=\(window.windowNumber)\n".utf8))
            }
            return
        }
        guard attempt < 100 else {
            FileHandle.standardError.write(Data("DOCKIT_WINDOW_HOLD: no \(windowIdentifier) window appeared\n".utf8))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            report(windowIdentifier: windowIdentifier, attempt: attempt + 1)
        }
    }
}
