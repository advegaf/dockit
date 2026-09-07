import AppKit
import DockitCore
import ScreenCaptureKit

/// Keeps the wallpaper on screen while the Dock restarts.
///
/// On macOS 26 the Dock process owns the desktop wallpaper window, so killing
/// the Dock blanks every display to black for about 70 ms until the new Dock
/// draws the wallpaper again. That flash is what people notice most about a
/// profile switch. The cover is one borderless window per screen at the desktop
/// window level, showing the same image macOS shows, above the Dock's wallpaper
/// window and below desktop icons. It goes up just before the kill and comes
/// down once the new Dock has its own wallpaper window on screen. The Dock
/// strip itself still disappears and returns; nothing here imitates that.
///
/// The image comes from the wallpaper file macOS reports for each screen. When
/// that file cannot be read (deleted after it was chosen, an aerial, a folder
/// the app may not read) and the user has not granted Screen Recording, the
/// screen gets no cover and keeps its short black flash. Images are decoded once at launch so the cover's first frame costs
/// nothing at switch time. `DOCKIT_COVER_IMAGE=<path>` overrides the image for
/// every screen; it exists for recordings on machines whose wallpaper file is
/// gone.
@MainActor
final class DockRestartCover {
    static let shared = DockRestartCover()

    private struct Decoded {
        var image: CGImage
        var fillColor: NSColor
        var gravity: CALayerContentsGravity
    }

    private var decoded: [NSNumber: Decoded] = [:]
    private var windows: [NSWindow] = []

    /// Reads and decodes the wallpaper for every screen. Call once at launch
    /// and again whenever the screen configuration changes.
    func preload() {
        decoded.removeAll()
        let override = ProcessInfo.processInfo.environment["DOCKIT_COVER_IMAGE"].map { URL(fileURLWithPath: $0) }
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            if let url = override ?? NSWorkspace.shared.desktopImageURL(for: screen),
               let image = NSImage(contentsOf: url),
               let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            {
                decoded[number] = Decoded(
                    image: cgImage,
                    fillColor: (options[.fillColor] as? NSColor) ?? .black,
                    gravity: Self.gravity(for: options)
                )
            } else {
                let key = number
                Task { @MainActor [weak self] in
                    guard let captured = await Self.captureWallpaper(of: screen) else { return }
                    self?.decoded[key] = Decoded(image: captured, fillColor: .black, gravity: .resize)
                }
            }
        }
    }

    /// Copies the wallpaper as it is on screen, for wallpapers with no readable
    /// file (deleted after being chosen, aerials, dynamic sets). Only when the
    /// user has already granted dockit Screen Recording; this never asks for it.
    private static func captureWallpaper(of screen: NSScreen) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: {
                  $0.displayID == (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
              }),
              let wallpaper = content.windows.first(where: {
                  $0.owningApplication?.bundleIdentifier == "com.apple.dock"
                      && $0.windowLayer <= Int(CGWindowLevelForKey(.desktopWindow))
                      && $0.frame.intersects(display.frame)
              })
        else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: wallpaper)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(display.frame.width * screen.backingScaleFactor)
        configuration.height = Int(display.frame.height * screen.backingScaleFactor)
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    var coversAnyScreen: Bool { !decoded.isEmpty }

    func show() {
        hide()
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let wallpaper = decoded[number] else { continue }
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.isOpaque = true
            window.isReleasedWhenClosed = false
            window.backgroundColor = wallpaper.fillColor
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            view.layer?.contents = wallpaper.image
            view.layer?.contentsGravity = wallpaper.gravity
            view.layer?.backgroundColor = wallpaper.fillColor.cgColor
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func hide() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private static func gravity(for options: [NSWorkspace.DesktopImageOptionKey: Any]) -> CALayerContentsGravity {
        let scaling = (options[.imageScaling] as? UInt).flatMap(NSImageScaling.init(rawValue:)) ?? .scaleProportionallyUpOrDown
        let clips = (options[.allowClipping] as? Bool) ?? true
        switch scaling {
        case .scaleAxesIndependently: return .resize
        case .scaleNone: return .center
        default: return clips ? .resizeAspectFill : .resizeAspect
        }
    }
}

/// Wraps the product reloader with the wallpaper cover.
final class CoveringDockReloader: DockReloading {
    private let inner: any DockReloading
    private let cover: MainActorBox<DockRestartCover>

    init(_ inner: any DockReloading, cover: DockRestartCover) {
        self.inner = inner
        self.cover = MainActorBox(cover)
    }

    func dockProcessIdentifier() async -> Int32? {
        await inner.dockProcessIdentifier()
    }

    func reload() async throws -> DockReloadResult {
        let covering = await MainActor.run { () -> Bool in
            cover.value.show()
            return cover.value.coversAnyScreen
        }
        if covering {
            // Two frames, so the cover is composited before the Dock dies.
            try? await Task.sleep(for: .milliseconds(34))
        }
        defer {
            if covering { Task { @MainActor in cover.value.hide() } }
        }
        let result = try await inner.reload()
        if covering {
            // Past this the cover is more likely stale than helpful, so it
            // comes down even if the wallpaper window was never seen.
            await Self.waitForWallpaperWindow(ownedBy: result.currentProcessIdentifier, timeout: .milliseconds(1200))
            // The window exists a little before its first frame lands.
            try? await Task.sleep(for: .milliseconds(150))
        }
        return result
    }

    /// The Dock creates its wallpaper window early in launch. Waiting for it
    /// keeps the cover up through the black gap without guessing a duration.
    private static func waitForWallpaperWindow(ownedBy processIdentifier: Int32, timeout: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            // Any window of the new Dock at or below the desktop level: the
            // wallpaper window sits one level under kCGDesktopWindowLevel today,
            // and this stays correct if that shifts by a level.
            let found = windows.contains {
                ($0[kCGWindowOwnerPID as String] as? Int32) == processIdentifier
                    && (($0[kCGWindowLayer as String] as? Int32) ?? 0) <= CGWindowLevelForKey(.desktopWindow)
            }
            if found { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Lets a Sendable wrapper hold a main-actor object it only touches on the main actor.
private final class MainActorBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
