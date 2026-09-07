import AppKit
import DockitCore
import ImageIO
import ScreenCaptureKit
import os

/// Keeps the wallpaper on screen while the Dock restarts.
///
/// On macOS 26 the Dock process owns the desktop wallpaper window, so killing
/// the Dock blanks every display to black for about 70 ms until the new Dock
/// draws the wallpaper again. That flash is what people notice most about a
/// profile switch. The cover is one borderless window per screen at the desktop
/// window level, showing the same image macOS shows, above the Dock's wallpaper
/// window and below desktop icons. For a still wallpaper from a file it stays
/// up for as long as dockit runs, so a restart has no transition at all. For
/// anything else (a dynamic desktop, a captured aerial frame) it goes up just
/// before the kill and comes down once the new Dock has its own wallpaper
/// window on screen. The Dock strip itself still disappears and returns;
/// nothing here imitates that.
///
/// The image comes from the wallpaper file macOS reports for each screen, or
/// from the copy macOS keeps of every file wallpaper when the original is gone.
/// When neither reads (an aerial, a dynamic set) and the user has not granted
/// Screen Recording, the screen gets no cover and keeps its short black flash.
/// Images are decoded off the main thread at launch, and again after a switch
/// when the wallpaper store changed, so the cover's first frame costs nothing
/// at switch time. `DOCKIT_COVER_IMAGE=<path>` overrides the image for every
/// screen; it exists for recordings.
@MainActor
final class DockRestartCover {
    static let shared = DockRestartCover()

    private struct Decoded {
        var image: CGImage
        var fillColor: NSColor
        var gravity: CALayerContentsGravity
        /// A single still frame from a file. Only those can stay up for good;
        /// a dynamic desktop or a captured aerial frame would freeze the
        /// wallpaper, so those covers come down after each restart.
        var isStill: Bool
    }

    private struct ScreenSource: Sendable {
        var number: NSNumber
        var candidates: [URL]
        var fillColor: NSColor
        var gravity: CALayerContentsGravity
    }

    private var decoded: [NSNumber: Decoded] = [:]
    private var windows: [NSWindow] = []
    private var decodedFor: (screens: [NSNumber], store: Date?, reported: [String])?
    private var generation = 0
    private var watcher: Timer?
    private static let log = Logger(subsystem: "com.advegaf.dockit", category: "cover")

    /// Reads and decodes the wallpaper for every screen, unless the screens
    /// and the wallpaper store are unchanged since the last decode. Call at
    /// launch, on screen changes, and after each Dock reload.
    func preload() {
        let screens = NSScreen.screens
        let numbers = screens.compactMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber }
        let storeDate = WallpaperStore.indexModificationDate()
        let reported = screens.map { NSWorkspace.shared.desktopImageURL(for: $0)?.path ?? "" }
        if let decodedFor, decodedFor.screens == numbers, decodedFor.store == storeDate, decodedFor.reported == reported { return }
        decodedFor = (numbers, storeDate, reported)
        generation += 1
        let thisGeneration = generation
        if watcher == nil {
            // A wallpaper change touches the store index or the reported
            // file; either makes the next tick decode again.
            watcher = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.preload() }
            }
        }

        let override = ProcessInfo.processInfo.environment["DOCKIT_COVER_IMAGE"].map { URL(fileURLWithPath: $0) }
        let storeData = try? Data(contentsOf: WallpaperStore.extensionPreferencesURL)
        var sources: [ScreenSource] = []
        var uncovered: [NSScreen] = []
        for screen in screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            var candidates: [URL] = []
            if let override { candidates.append(override) }
            if let reported = NSWorkspace.shared.desktopImageURL(for: screen) {
                candidates.append(reported)
                if let storeData, let entry = WallpaperStore.entry(for: reported, in: storeData) {
                    if let copy = entry.copyURL { candidates.append(copy) }
                    if let bookmark = entry.bookmark {
                        var stale = false
                        if let original = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale) {
                            candidates.append(original)
                        }
                    }
                }
            }
            candidates = candidates.filter { FileManager.default.isReadableFile(atPath: $0.path) }
            if candidates.isEmpty { uncovered.append(screen) }
            sources.append(ScreenSource(
                number: number,
                candidates: candidates,
                fillColor: (options[.fillColor] as? NSColor) ?? .black,
                gravity: Self.gravity(for: options)
            ))
        }

        Task.detached(priority: .utility) { [sources] in
            var fresh: [NSNumber: Decoded] = [:]
            for source in sources {
                for url in source.candidates {
                    if let image = NSImage(contentsOf: url),
                       let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    {
                        let frames = CGImageSourceCreateWithURL(url as CFURL, nil).map(CGImageSourceGetCount) ?? 0
                        fresh[source.number] = Decoded(
                            image: cgImage, fillColor: source.fillColor, gravity: source.gravity, isStill: frames == 1
                        )
                        break
                    }
                }
            }
            let result = fresh
            await MainActor.run { [weak self] in
                guard let self, self.generation == thisGeneration else { return }
                self.decoded = result
                self.rebuildWindows()
                for number in sources.map(\.number) where result[number] == nil {
                    Self.log.debug("no readable wallpaper for screen \(number); cover falls back to capture or nothing")
                }
            }
        }

        for screen in uncovered {
            guard let key = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            Task { @MainActor [weak self] in
                guard let captured = await Self.captureWallpaper(of: screen) else { return }
                guard let self, self.generation == thisGeneration, self.decoded[key] == nil else { return }
                self.decoded[key] = Decoded(image: captured, fillColor: .black, gravity: .resize, isStill: false)
                self.rebuildWindows()
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

    /// Diagnostic override for the cover's window level (`DOCKIT_COVER_LEVEL`).
    private static let level: Int = ProcessInfo.processInfo.environment["DOCKIT_COVER_LEVEL"].flatMap(Int.init)
        ?? Int(CGWindowLevelForKey(.desktopWindow))

    var coversAnyScreen: Bool { !windows.isEmpty }

    /// Still wallpapers keep the cover up for as long as dockit runs. Then a
    /// restart has nothing to show or hide, so there is no transition at all;
    /// the Dock's own wallpaper window just comes and goes underneath.
    var isPersistent: Bool {
        !decoded.isEmpty && decoded.values.allSatisfy(\.isStill)
    }

    /// The windows exist before they are needed. Creating one at switch time
    /// costs tens of milliseconds, and with SIGKILL the Dock is gone in under
    /// ten, so a window built on demand reached the screen after the flash.
    private func rebuildWindows() {
        let previous = windows
        windows.removeAll()
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let wallpaper = decoded[number] else { continue }
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = NSWindow.Level(rawValue: Self.level)
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
            windows.append(window)
        }
        // New windows go up before the old ones come down, so a persistent
        // cover never shows what is underneath while it is replaced.
        if isPersistent { show() }
        for window in previous {
            window.orderOut(nil)
        }
    }

    func show() {
        for window in windows {
            window.orderFrontRegardless()
        }
    }

    /// True once the window server lists every cover window as on screen.
    /// Ordering a window front returns before it is composited; the kill has
    /// to wait for the frame that actually shows the cover.
    var isOnScreen: Bool {
        guard !windows.isEmpty else { return false }
        let onScreen = Set(
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                .compactMap { $0[kCGWindowNumber as String] as? Int }
        )
        return windows.allSatisfy { onScreen.contains($0.windowNumber) }
    }

    func hide() {
        guard !isPersistent else { return }
        for window in windows {
            window.orderOut(nil)
        }
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
        if await MainActor.run(body: { cover.value.isPersistent }) {
            // The cover is already up and stays up. Nothing to time.
            let result = try await inner.reload()
            await MainActor.run { cover.value.preload() }
            return result
        }
        let covering = await MainActor.run { () -> Bool in
            cover.value.show()
            return cover.value.coversAnyScreen
        }
        if covering {
            // Wait for the window server to show the cover, then let the menu
            // bar backdrop settle on it before the Dock dies.
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .milliseconds(300))
            while clock.now < deadline, await !MainActor.run(body: { cover.value.isOnScreen }) {
                try? await Task.sleep(for: .milliseconds(4))
            }
            try? await Task.sleep(for: .milliseconds(Self.settleMilliseconds))
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
        await MainActor.run { cover.value.preload() }
        return result
    }

    /// How long the cover stays up before the kill once it is on screen. The
    /// menu bar's translucent backdrop crossfades to whatever sits under it
    /// over about 150 ms; killed sooner than that, the Dock's wallpaper window
    /// vanishes mid-crossfade and the menu bar dims for two frames. Measured:
    /// 20 ms dims it by a third, 200 ms leaves no frame off. Diagnostic
    /// override: `DOCKIT_COVER_SETTLE_MS`.
    private static let settleMilliseconds: Int = ProcessInfo.processInfo.environment["DOCKIT_COVER_SETTLE_MS"].flatMap(Int.init) ?? 200

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

/// Where macOS keeps its own copy of every wallpaper chosen from a file.
///
/// The wallpaper extension records each choice in its container preferences
/// under `ChoiceRequests.ImageFiles` (a flat key, the dot is literal): an array
/// of binary plists with the original URL, a bookmark to it, and the copy it
/// made under `Data/Library/Caches`. The copy is what macOS renders, and it
/// survives the original being moved or deleted. Reading it never prompts.
enum WallpaperStore {
    struct Entry: Equatable {
        var copyURL: URL?
        var bookmark: Data?
    }

    static let extensionPreferencesURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Containers/com.apple.wallpaper.extension.image/Data/Library/Preferences/com.apple.wallpaper.extension.image.plist")

    /// The current-wallpaper index. Its modification date changes whenever a
    /// wallpaper is set, which is a cheap signal to decode again.
    static let indexURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")

    static func indexModificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: indexURL.path))?[.modificationDate] as? Date
    }

    /// The newest record for `reported`, from the extension preferences bytes.
    /// Garbage or an unexpected layout reads as no record.
    static func entry(for reported: URL, in preferences: Data) -> Entry? {
        guard let root = try? PropertyListSerialization.propertyList(from: preferences, format: nil) as? [String: Any],
              let records = root["ChoiceRequests.ImageFiles"] as? [Data]
        else { return nil }
        let wanted = comparablePath(reported)
        var best: (date: Date, entry: Entry)?
        for record in records {
            guard let fields = try? PropertyListSerialization.propertyList(from: record, format: nil) as? [String: Any],
                  let original = (fields["originalURL"] as? [String: Any])?["relative"] as? String,
                  let originalURL = URL(string: original),
                  comparablePath(originalURL) == wanted
            else { continue }
            let date = fields["dateAdded"] as? Date ?? .distantPast
            if let best, best.date > date { continue }
            let copy = ((fields["copyURL"] as? [String: Any])?["relative"] as? String).flatMap(URL.init(string:))
            best = (date, Entry(copyURL: copy, bookmark: fields["originalURLBookmarkData"] as? Data))
        }
        return best?.entry
    }

    private static func comparablePath(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }
}
