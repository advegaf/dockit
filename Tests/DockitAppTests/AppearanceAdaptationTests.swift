import AppKit
import DockitCore
import SwiftUI
import Testing
@testable import dockit

@Suite(.serialized)
@MainActor
struct AppearanceAdaptationTests {
    @Test
    func existingPickerAndReopenedMenusFollowAppearanceWithoutProfileChanges() async throws {
        try #require(ProcessInfo.processInfo.environment["DOCKIT_DEMO"] == "1")
        try #require(ProcessInfo.processInfo.environment["DOCKIT_TEST_HOST"] == "1")
        let originalAppearance = NSApp.appearance
        let libraryURL = FileManager.default.temporaryDirectory
            .appending(path: "dockit-appearance-\(UUID().uuidString)")
            .appending(path: "library.json")
        let model = AppModel(
            environment: ["DOCKIT_DEMO": "1"],
            store: DockLibraryStore(fileURL: libraryURL),
            integratesWithSystem: false
        )
        let record = try #require(model.library.profiles.first { $0.profile.color == .green })
        model.selectedProfileID = record.id
        let unchangedLibrary = model.library
        NSApp.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 180, width: 620, height: 252),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            NSApp.appearance = originalAppearance
        }
        window.contentViewController = NSHostingController(
            rootView: NativeProfileToolbarPicker(model: model)
                .frame(width: 340, height: 40)
        )
        window.orderFront(nil)
        let button = try await requirePicker(in: window)
        let pickerMenu = try #require(button.menu)
        let menuCoordinator = DockMenuCoordinator(applicationMenu: { nil }, makeStatusItem: { nil })
        menuCoordinator.update(
            profiles: model.library.profiles.map(\.profile),
            activeID: model.library.activeProfile?.profileID,
            applyingID: nil
        ) { _ in }
        let activationMenu = menuCoordinator.makeMenu()

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            NSApp.appearance = NSAppearance(named: appearanceName)
            let expected = appearanceName == .darkAqua
                ? record.profile.color.darkIdentityColor
                : record.profile.color.identityColor
            let actual = try await waitForSwatch(expected, button: button, window: window)
            #expect(matches(actual, expected), "appearance=\(appearanceName.rawValue), actual=\(actual)")
            #expect(findPicker(in: window.contentView?.superview) === button)
            #expect(model.library == unchangedLibrary)

            pickerMenu.delegate?.menuNeedsUpdate?(pickerMenu)
            let pickerEntry = try #require(pickerMenu.item(withTitle: record.profile.name))
            #expect(matches(try centerColor(of: #require(pickerEntry.image)), expected))
            let colorMenu = try #require(pickerMenu.item(withTitle: "color")?.submenu)
            let colorEntry = try #require(colorMenu.item(withTitle: record.profile.color.rawValue))
            #expect(matches(try centerColor(of: #require(colorEntry.image)), expected))

            activationMenu.delegate?.menuWillOpen?(activationMenu)
            let activationEntry = try #require(activationMenu.item(withTitle: record.profile.name))
            #expect(matches(try centerColor(of: #require(activationEntry.image)), expected))
        }
        #expect(model.library == unchangedLibrary)
        #expect(!FileManager.default.fileExists(atPath: libraryURL.path))
    }

    private func requirePicker(in window: NSWindow) async throws -> NativeProfilePopUpButton {
        for _ in 0..<200 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if let picker = findPicker(in: window.contentView?.superview) {
                return picker
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(findPicker(in: window.contentView?.superview))
    }

    private func findPicker(in view: NSView?) -> NativeProfilePopUpButton? {
        guard let view else { return nil }
        if let picker = view as? NativeProfilePopUpButton { return picker }
        for child in view.subviews {
            if let picker = findPicker(in: child) { return picker }
        }
        return nil
    }

    private func waitForSwatch(
        _ expected: ProfileIdentityColor,
        button: NativeProfilePopUpButton,
        window: NSWindow
    ) async throws -> NSColor {
        for _ in 0..<200 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let color = try centerColor(of: #require(button.displayedMenuItem?.image))
            if matches(color, expected) { return color }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try centerColor(of: #require(button.displayedMenuItem?.image))
    }

    private func centerColor(of image: NSImage) throws -> NSColor {
        let side = Int(image.size.width.rounded())
        try #require(side > 0)
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: side * 4,
            bitsPerPixel: 32
        ))
        let pixels = try #require(bitmap.bitmapData)
        pixels.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                   from: .zero, operation: .copy, fraction: 1)
        return try #require(bitmap.colorAt(x: side / 2, y: side / 2)?.usingColorSpace(.sRGB))
    }

    private func matches(_ actual: NSColor, _ expected: ProfileIdentityColor) -> Bool {
        let rgb = expected.sRGB
        let tolerance = 3.0 / 255
        return actual.alphaComponent >= 0.99
            && abs(actual.redComponent - rgb.red) <= tolerance
            && abs(actual.greenComponent - rgb.green) <= tolerance
            && abs(actual.blueComponent - rgb.blue) <= tolerance
    }
}
