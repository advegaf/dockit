import AppKit
import DockitCore
import SwiftUI
import Testing
@testable import dockit

@Suite(.serialized)
@MainActor
struct MenuLifecycleTests {
    @Test
    func normalLaunchKeepsRegularPresenceBeforeSwiftUIShowsItsWindow() {
        #expect(DockitAppDelegate.Presence.atLaunch(isLoginItem: false, windows: []) == .windows)
        #expect(DockitAppDelegate.Presence.atLaunch(isLoginItem: true, windows: []) == .background)
    }

    @Test
    func quitIsOnlyInTheStatusMenuAndApplicationShortcutClosesWindows() throws {
        let mainMenu = makeStandardMenu()
        let application = try #require(mainMenu.items.first?.submenu)
        application.addItem(NSMenuItem(title: "Quit dockit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let coordinator = DockMenuCoordinator(applicationMenu: { mainMenu }, makeStatusItem: { nil })
        var closeRequests = 0
        coordinator.setCloseWindowsHandler { closeRequests += 1 }
        coordinator.repairApplicationMenu()
        let close = try #require(application.item(withTitle: "close dockit windows"))
        #expect(close.action == NSSelectorFromString("closeAllWindows"))
        #expect(close.keyEquivalent == "q")
        #expect(close.keyEquivalentModifierMask == .command)
        coordinator.closeAllWindows()
        #expect(closeRequests == 1)
        for kind in [DockMenuCoordinator.MenuKind.application, .dock] {
            let menu = coordinator.makeMenu(kind: kind)
            coordinator.menuWillOpen(menu)
            #expect(menu.item(withTitle: "quit dockit") == nil)
        }
        let status = coordinator.makeMenu(kind: .statusBar)
        coordinator.menuWillOpen(status)
        #expect(status.item(withTitle: "quit dockit")?.action == NSSelectorFromString("quit"))
        #expect(status.item(withTitle: "quit dockit")?.keyEquivalent == "")
    }

    @Test
    func closingWindowsLeavesBackgroundPresenceWithoutVetoingSystemTermination() {
        let windows = (0..<2).map { _ in
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 100),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }
        defer { windows.forEach { $0.close() } }
        #expect(DockitAppDelegate.Presence.current(in: windows) == .background)
        #expect(DockitAppDelegate.Presence.background.activationPolicy == .accessory)
        windows.forEach { $0.orderFront(nil) }
        #expect(DockitAppDelegate.Presence.current(in: windows) == .windows)
        #expect(DockitAppDelegate.Presence.windows.activationPolicy == .regular)
        DockitAppDelegate.closeWindows(windows)
        #expect(windows.allSatisfy { !$0.isVisible })
        #expect(DockitAppDelegate.Presence.current(in: windows) == .background)
        let delegate = DockitAppDelegate()
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
    }

    @Test
    func applicationDocksMenuDoesNotOfferProcessQuit() throws {
        let menu = makeStandardMenu()
        let coordinator = DockMenuCoordinator(applicationMenu: { menu })
        coordinator.repairApplicationMenu()
        let docks = try #require(menu.item(withTitle: "docks")?.submenu)
        #expect(docks.item(withTitle: "quit dockit") == nil)
    }

    @Test
    func manageDocksKeepsNativeTemplateIconWhenMenuReopens() throws {
        try requireSafeHost()
        let coordinator = DockMenuCoordinator(applicationMenu: { nil })
        let menu = coordinator.makeMenu()
        for _ in 0..<2 {
            let item = try #require(menu.item(withTitle: "manage docks..."))
            let image = try #require(item.image)
            #expect(image.isTemplate)
            #expect(!image.representations.isEmpty)
            #expect(item.isEnabled)
            #expect(item.action == NSSelectorFromString("manageDocks"))
            #expect(item.target === coordinator)
            coordinator.menuWillOpen(menu)
        }
    }

    @Test(arguments: ["MenuBarIcon16", "MenuBarIcon"])
    func miniatureDockAssetsLoadAsTemplateImages(_ name: String) throws {
        let image = try #require(NSImage(named: name))
        #expect(image.isTemplate)
        #expect(!image.representations.isEmpty)
        #expect(image.size.width > 0)
        #expect(image.size.width == image.size.height)
    }

    @Test(arguments: ["MenuBarIcon16", "MenuBarIcon"])
    func miniatureDockAssetsRenderPaintedAndTransparentPixels(_ name: String) throws {
        try requireSafeHost()
        let image = try #require(NSImage(named: name))
        let side = name == "MenuBarIcon16" ? 16 : 18
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
        image.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side),
            from: .zero,
            operation: .copy,
            fraction: 1
        )

        var alpha: [CGFloat] = []
        for y in 0..<side {
            for x in 0..<side {
                let color = try #require(bitmap.colorAt(x: x, y: y))
                alpha.append(color.alphaComponent)
            }
        }
        #expect(alpha.contains { $0 >= 0.95 })
        #expect(alpha.contains { $0 == 0 })
    }

    @Test
    func statusItemIsAlwaysCreatedAndReused() throws {
        try requireSafeHost()
        var createdItems: [NSStatusItem] = []
        let coordinator = DockMenuCoordinator(
            applicationMenu: { nil },
            makeStatusItem: {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                createdItems.append(item)
                return item
            }
        )
        defer {
            for item in createdItems {
                NSStatusBar.system.removeStatusItem(item)
            }
        }
        let profile = DockProfile(name: "My Work", color: .blue, items: [])

        coordinator.update(profiles: [profile], activeID: profile.id, applyingID: nil) { _ in }
        let firstItem = try #require(createdItems.first)
        let button = try #require(firstItem.button)
        let image = try #require(button.image)
        let menu = try #require(firstItem.menu)
        #expect(createdItems.count == 1)
        #expect(image.isTemplate)
        #expect(!image.representations.isEmpty)
        #expect(image.size.width == image.size.height)
        #expect([CGFloat(16), CGFloat(18)].contains(image.size.width))
        #expect(button.accessibilityLabel() == "dockit")
        #expect(menu.item(withTitle: profile.name)?.state == .on)
        #expect(menu.item(withTitle: "settings...") != nil)

        coordinator.update(profiles: [profile], activeID: nil, applyingID: nil) { _ in }
        #expect(createdItems.count == 1)
        #expect(createdItems.last === firstItem)
        #expect(firstItem.menu?.item(withTitle: profile.name)?.state == .off)

        coordinator.update(profiles: [profile], activeID: profile.id, applyingID: nil) { _ in }
        #expect(createdItems.count == 1)
        #expect(firstItem.menu?.item(withTitle: profile.name)?.state == .on)
    }

    @Test
    func replacementMenuIsRepairedAfterNativeItemNotifications() async throws {
        try requireSafeHost()
        let host = MenuTestHost(menu: makeStandardMenu())
        let coordinator = DockMenuCoordinator(applicationMenu: { host.menu })
        coordinator.observeApplicationMenuChanges()
        #expect(host.menu.items.map(\.title) == ["dockit", "file", "edit", "docks", "view", "window", "help"])

        let replacement = makeStandardMenu()
        host.menu = replacement
        await drainMainQueue()
        #expect(replacement.items.map(\.title) == ["dockit", "file", "edit", "docks", "view", "window", "help"])

        let edit = try #require(replacement.item(withTitle: "edit"))
        edit.title = "Edit"
        await drainMainQueue()
        #expect(edit.title == "edit")
        #expect(replacement.items.filter { $0.identifier?.rawValue == "dockit.profiles" }.count == 1)
    }

    @Test
    func repairPreservesActionsShortcutsAndExternalText() throws {
        try requireSafeHost()
        let mainMenu = makeStandardMenu()
        let edit = try #require(mainMenu.item(withTitle: "Edit")?.submenu)
        let copyAction = NSSelectorFromString("copy:")
        let copy = NSMenuItem(title: "Copy", action: copyAction, keyEquivalent: "c")
        copy.keyEquivalentModifierMask = .command
        edit.addItem(copy)
        let undo = NSMenuItem(title: "Undo Rename My Report", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        edit.addItem(undo)
        let external = NSMenuItem(title: "My Report.PDF", action: NSSelectorFromString("openDocument:"), keyEquivalent: "")
        edit.addItem(external)
        let represented = NSMenuItem(title: "Copy", action: copyAction, keyEquivalent: "")
        represented.representedObject = URL(fileURLWithPath: "/tmp/My File.txt")
        edit.addItem(represented)
        let file = try #require(mainMenu.item(withTitle: "File")?.submenu)
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recent.submenu = NSMenu(title: "Open Recent")
        recent.submenu?.addItem(NSMenuItem(title: "Copy", action: NSSelectorFromString("openDocument:"), keyEquivalent: ""))
        file.addItem(recent)
        let app = try #require(mainMenu.item(withTitle: "dockit")?.submenu)
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        services.submenu?.addItem(NSMenuItem(title: "Copy", action: copyAction, keyEquivalent: ""))
        app.addItem(services)

        let coordinator = DockMenuCoordinator(applicationMenu: { mainMenu }, makeStatusItem: { nil })
        let profile = DockProfile(name: "My Work", color: .blue, items: [])
        coordinator.update(profiles: [profile], activeID: profile.id, applyingID: nil) { _ in }
        coordinator.repairApplicationMenu()
        coordinator.repairApplicationMenu()

        #expect(copy.title == "copy")
        #expect(copy.action == copyAction)
        #expect(copy.keyEquivalent == "c")
        #expect(copy.keyEquivalentModifierMask == .command)
        #expect(undo.title == "undo Rename My Report")
        #expect(external.title == "My Report.PDF")
        #expect(represented.title == "Copy")
        #expect(recent.title == "open recent")
        #expect(recent.submenu?.items.first?.title == "Copy")
        #expect(services.title == "services")
        #expect(services.submenu?.items.first?.title == "Copy")
        let profiles = try #require(mainMenu.item(withTitle: "docks")?.submenu)
        #expect(profiles.items.contains { $0.title == "My Work" && $0.state == .on })
        #expect(mainMenu.items.filter { $0.identifier?.rawValue == "dockit.profiles" }.count == 1)
    }

    @Test
    func postUpdateRepairRestoresMenuAfterSilentRemoveAllItems() throws {
        try requireSafeHost()
        let mainMenu = makeStandardMenu()
        let coordinator = DockMenuCoordinator(applicationMenu: { mainMenu })
        coordinator.repairApplicationMenu()
        mainMenu.removeAllItems()
        coordinator.repairApplicationMenu()
        #expect(mainMenu.items.count == 1)
        #expect(mainMenu.items.first?.identifier?.rawValue == "dockit.profiles")
    }

    private func makeStandardMenu() -> NSMenu {
        let menu = NSMenu(title: "main")
        for title in ["dockit", "File", "Edit", "View", "Window", "Help"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            menu.addItem(item)
        }
        return menu
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func requireSafeHost() throws {
        try #require(ProcessInfo.processInfo.environment["DOCKIT_DEMO"] == "1")
    }
}

@MainActor
private final class MenuTestHost {
    var menu: NSMenu

    init(menu: NSMenu) { self.menu = menu }
}

@Suite(.serialized)
@MainActor
struct ProfileColorStyleTests {
    @Test
    func darkIdentityPaletteStaysInGamutAndPreservesHue() {
        for color in ProfileColor.allCases {
            #expect(color.darkIdentityColor.isInSRGBGamut)
            #expect(color.darkIdentityColor.hue == color.identityColor.hue)
            #expect(color.darkIdentityColor.lightness >= 0.62)
            #expect(color.darkIdentityColor.lightness <= 0.74)
            #expect(color.darkIdentityColor.chroma <= color.identityColor.chroma)
        }
    }

    @Test
    func identityPaletteStaysInSRGBGamut() {
        for color in ProfileColor.allCases {
            let identity = color.identityColor
            #expect(identity.isInSRGBGamut)
        }
    }

    @Test
    func observedProfileColorsMatchOriginalVideoSamples() {
        let samples: [(ProfileColor, [Double])] = [
            (.blue, [13, 144, 245]),
            (.green, [65, 223, 94]),
            (.purple, [96, 73, 237])
        ]
        for (color, expected) in samples {
            let rgb = color.identityColor.sRGB
            let actual = [rgb.red, rgb.green, rgb.blue]
            for (component, sample) in zip(actual, expected) {
                #expect(abs(component * 255 - sample) < 0.01)
            }
        }
    }

    @Test
    func swatchRenderersPreserveTheirLogicalSizes() throws {
        for color in ProfileColor.allCases {
            #expect(color.menuSwatchImage.size == NSSize(width: 12, height: 12))
            #expect(color.toolbarSwatchImage.size == NSSize(width: 16, height: 16))
            let badge = ImageRenderer(content: ProfileIdentityBadge(color: color, size: 42))
            #expect(try #require(badge.nsImage).size == NSSize(width: 42, height: 42))
        }
    }

}
