import AppKit
import DockitCore
import SwiftUI

@MainActor
final class DockMenuCoordinator: NSObject, NSMenuDelegate {
    static let shared = DockMenuCoordinator()

    enum MenuKind {
        case statusBar, application, dock
    }

    private final class ProfileMenu: NSMenu {
        var kind = MenuKind.statusBar
    }

    private var profiles: [DockProfile] = []
    private var activeID: UUID?
    private var applyingID: UUID?
    private var activationActionsDisabled = false
    private var activate: ((UUID) -> Void)?
    private var showMainWindow: (() -> Void)?
    private var showSettingsWindow: (() -> Void)?
    private var statusItem: NSStatusItem?
    private let applicationMenu: @MainActor () -> NSMenu?
    private let makeStatusItem: @MainActor () -> NSStatusItem?
    private var closeWindows: (() -> Void)?
    private var observesApplicationMenu = false
    private var menuRepairScheduled = false
    private var isRepairingMenu = false

    init(
        applicationMenu: @escaping @MainActor () -> NSMenu? = { NSApplication.shared.mainMenu },
        makeStatusItem: @escaping @MainActor () -> NSStatusItem? = {
            NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        }
    ) {
        self.applicationMenu = applicationMenu
        self.makeStatusItem = makeStatusItem
        super.init()
    }

    func update(
        profiles: [DockProfile],
        activeID: UUID?,
        applyingID: UUID?,
        activationActionsDisabled: Bool = false,
        activate: @escaping (UUID) -> Void
    ) {
        self.profiles = profiles
        self.activeID = activeID
        self.applyingID = applyingID
        self.activationActionsDisabled = activationActionsDisabled
        self.activate = activate
        updateStatusItem()
    }

    func setCloseWindowsHandler(_ handler: @escaping () -> Void) {
        closeWindows = handler
    }

    @objc func closeAllWindows() {
        closeWindows?()
    }

    func setWindowPresenter(_ showMainWindow: @escaping () -> Void) {
        self.showMainWindow = showMainWindow
    }

    func setSettingsWindowPresenter(_ showSettingsWindow: @escaping () -> Void) {
        self.showSettingsWindow = showSettingsWindow
    }

    func presentSettingsWindow() {
        showSettingsWindow?()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func presentMainWindow() {
        showMainWindow?()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func makeMenu(kind: MenuKind = .statusBar) -> NSMenu {
        let menu = ProfileMenu(title: "docks")
        menu.kind = kind
        menu.autoenablesItems = false
        menu.delegate = self
        populate(menu)
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        populate(menu)
    }

    func observeApplicationMenuChanges() {
        guard !observesApplicationMenu else { return }
        observesApplicationMenu = true
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification, NSMenu.didRemoveItemNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(menuContentsDidChange(_:)), name: name, object: nil)
        }
        repairApplicationMenu()
    }

    @objc private func menuContentsDidChange(_ notification: Notification) {
        guard !isRepairingMenu, !menuRepairScheduled else { return }
        menuRepairScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.menuRepairScheduled = false
            self.repairApplicationMenu()
        }
    }

    func repairApplicationMenu() {
        guard !isRepairingMenu, let mainMenu = applicationMenu() else { return }
        isRepairingMenu = true
        defer { isRepairingMenu = false }
        installApplicationMenu(in: mainMenu)
        for item in mainMenu.items where Self.standardMenuTitles.contains(item.title.lowercased()) {
            setLowercaseTitle(item)
            guard let menu = item.submenu else { continue }
            if menu.title != item.title { menu.title = item.title }
            lowercaseStandardCommands(in: menu)
        }
    }

    private func installApplicationMenu(in mainMenu: NSMenu) {
        guard !mainMenu.items.contains(where: { $0.identifier?.rawValue == "dockit.profiles" }) else { return }
        let item = NSMenuItem(title: "docks", action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("dockit.profiles")
        item.submenu = makeMenu(kind: .application)
        mainMenu.insertItem(item, at: min(3, mainMenu.numberOfItems))
    }

    private static let standardMenuTitles: Set<String> = ["dockit", "file", "edit", "view", "window", "help"]
    private static let standardCommandTitles: Set<String> = [
        "about dockit", "services", "hide dockit", "hide others", "show all", "quit dockit",
        "settings...", "settings…", "preferences...", "preferences…", "new", "new window",
        "open...", "open…", "open recent", "close", "close window", "undo", "redo", "cut", "copy",
        "paste", "paste and match style", "delete", "select all", "find", "find...", "find…",
        "find next", "find previous", "use selection for find", "jump to selection",
        "spelling and grammar", "show spelling and grammar", "check spelling",
        "check spelling while typing", "check grammar with spelling", "correct spelling automatically",
        "substitutions", "show substitutions", "smart copy/paste", "smart quotes", "smart dashes",
        "smart links", "data detectors", "text replacement", "transformations", "make upper case",
        "make lower case", "capitalize", "speech", "start speaking", "stop speaking",
        "start dictation...", "start dictation…", "emoji & symbols", "enter full screen", "exit full screen",
        "show toolbar", "hide toolbar", "customize toolbar...", "customize toolbar…", "show sidebar", "hide sidebar",
        "minimize", "zoom", "move & resize", "center", "fill", "full screen", "left", "right", "top", "bottom",
        "bring all to front", "show tab bar", "hide tab bar", "show all tabs", "merge all windows",
        "move tab to new window", "select next tab", "select previous tab", "dockit help"
    ]

    private func lowercaseStandardCommands(in menu: NSMenu) {
        for item in menu.items {
            guard item.representedObject == nil, item.target as? NSWindow == nil else { continue }
            if item.action == #selector(NSApplication.terminate(_:)) {
                item.title = "close dockit windows"
                item.action = #selector(closeAllWindows)
                item.target = self
                item.keyEquivalent = "q"
                item.keyEquivalentModifierMask = .command
                continue
            }
            if let action = item.action, ["undo:", "redo:"].contains(NSStringFromSelector(action)),
               let firstSpace = item.title.firstIndex(of: " ") {
                let verb = item.title[..<firstSpace]
                if verb == "Undo" || verb == "Redo" {
                    item.title = verb.lowercased() + item.title[firstSpace...]
                }
                continue
            }
            let title = item.title.lowercased()
            guard Self.standardCommandTitles.contains(title) else { continue }
            setLowercaseTitle(item)
            if let submenu = item.submenu, !["services", "open recent"].contains(title) {
                lowercaseStandardCommands(in: submenu)
            }
        }
    }

    private func setLowercaseTitle(_ item: NSMenuItem) {
        let title = item.title.lowercased()
        if item.title != title { item.title = title }
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let heading = NSMenuItem(title: "docks", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        if profiles.isEmpty {
            let item = NSMenuItem(title: "no saved docks", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for profile in profiles {
            let item = NSMenuItem(
                title: profile.name,
                action: #selector(activateProfile(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile.id
            item.image = profile.color.menuSwatchImage
            item.state = profile.id == activeID ? .on : .off
            item.isEnabled = !activationActionsDisabled && profile.id != applyingID
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let manageItem = NSMenuItem(title: "manage docks...", action: #selector(manageDocks), keyEquivalent: "")
        manageItem.target = self
        manageItem.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: nil)
        manageItem.image?.isTemplate = true
        menu.addItem(manageItem)
        addAction("settings...", selector: #selector(openSettings), to: menu)
        if (menu as? ProfileMenu)?.kind == .statusBar {
            menu.addItem(.separator())
            addAction("quit dockit", selector: #selector(quit), to: menu)
        }
    }

    private func addAction(_ title: String, selector: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func updateStatusItem() {
        if statusItem == nil {
            statusItem = makeStatusItem()
        }
        let assetName = NSStatusBar.system.thickness <= 22 ? "MenuBarIcon16" : "MenuBarIcon"
        let image = NSImage(named: assetName)?.copy() as? NSImage
            ?? NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "dockit")
        image?.isTemplate = true
        image?.size = NSSize(width: assetName == "MenuBarIcon16" ? 16 : 18, height: assetName == "MenuBarIcon16" ? 16 : 18)
        statusItem?.button?.image = image
        statusItem?.button?.setAccessibilityLabel("dockit")
        statusItem?.button?.toolTip = "dockit"
        statusItem?.menu = makeMenu()
    }

    @objc private func manageDocks() {
        presentMainWindow()
    }

    @objc private func openSettings() {
        presentSettingsWindow()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func activateProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        activate?(id)
    }
}

@MainActor
final class DockitAppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: AppModel?
    private var openMainWindow: (() -> Void)?
    private var openSettingsWindow: (() -> Void)?
    private var fallbackWindowController: NSWindowController?
    private var fallbackSettingsWindowController: NSWindowController?
    private var terminationInFlight = false
    private var launchedAsLoginItem = false

    enum Presence: Equatable {
        case background, windows

        var activationPolicy: NSApplication.ActivationPolicy {
            self == .windows ? .regular : .accessory
        }

        static func current(in windows: [NSWindow]) -> Self {
            windows.contains {
                $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized)
            } ? .windows : .background
        }

        static func atLaunch(isLoginItem: Bool, windows: [NSWindow]) -> Self {
            // SwiftUI may create the initial window after didFinishLaunching.
            isLoginItem ? current(in: windows) : .windows
        }
    }

    private var currentEventIsLoginLaunch: Bool {
        NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAELaunchedAsLogInItem)?.booleanValue == true
    }

    private func setPresence(_ presence: Presence) {
        guard ProcessInfo.processInfo.environment["DOCKIT_TEST_HOST"] != "1" else { return }
        let application = NSApplication.shared
        if application.activationPolicy() != presence.activationPolicy {
            application.setActivationPolicy(presence.activationPolicy)
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.setPresence(Presence.current(in: NSApplication.shared.windows))
        }
    }

    func closeAllWindows() {
        Self.closeWindows(NSApplication.shared.windows)
        setPresence(Presence.current(in: NSApplication.shared.windows))
    }

    static func closeWindows(_ windows: [NSWindow]) {
        for window in windows where window.sheetParent == nil && window.styleMask.contains(.titled) {
            if let panel = window as? NSSavePanel {
                panel.cancel(nil)
                continue
            }
            if let sheet = window.attachedSheet {
                window.endSheet(sheet, returnCode: .cancel)
                sheet.orderOut(nil)
            }
            window.performClose(nil)
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        model = AppModel.shared
        launchedAsLoginItem = currentEventIsLoginLaunch
        if ProcessInfo.processInfo.environment["DOCKIT_DEMO"] == "1" {
            switch ProcessInfo.processInfo.environment["DOCKIT_DEMO_APPEARANCE"] {
            case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
            case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            default: break
            }
        }
        DockMenuCoordinator.shared.setWindowPresenter { [weak self] in
            self?.showMainWindow()
        }
        DockMenuCoordinator.shared.setSettingsWindowPresenter { [weak self] in
            self?.showSettingsWindow()
        }
        DockMenuCoordinator.shared.setCloseWindowsHandler { [weak self] in
            self?.closeAllWindows()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil
        )
        AppModel.shared.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockMenuCoordinator.shared.observeApplicationMenuChanges()
        launchedAsLoginItem = launchedAsLoginItem || currentEventIsLoginLaunch
        setPresence(Presence.atLaunch(isLoginItem: launchedAsLoginItem, windows: NSApplication.shared.windows))
        WindowSnapshot.holdIfRequested(delegate: self)
        DockRestartCover.shared.preload()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { DockRestartCover.shared.preload() }
        }
        if let seconds = ProcessInfo.processInfo.environment["DOCKIT_COVER_HOLD"].flatMap(Double.init) {
            // Diagnostic: keep the wallpaper cover up for a while so a recording
            // can show whether it hides the Dock restart's black frame.
            DockRestartCover.shared.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { DockRestartCover.shared.hide() }
        }
    }

    func applicationDidUpdate(_ notification: Notification) {
        DockMenuCoordinator.shared.repairApplicationMenu()
        if Presence.current(in: NSApplication.shared.windows) == .windows {
            setPresence(.windows)
        }
    }

    func setSettingsWindowPresenter(_ openSettingsWindow: @escaping () -> Void) {
        self.openSettingsWindow = openSettingsWindow
    }

    func setWindowPresenter(_ openMainWindow: @escaping () -> Void) {
        self.openMainWindow = openMainWindow
        fallbackWindowController?.close()
        fallbackWindowController = nil
    }

    func showMainWindow() {
        setPresence(.windows)
        if let fallbackWindowController {
            fallbackWindowController.showWindow(nil)
            fallbackWindowController.window?.makeKeyAndOrderFront(nil)
        } else if let existingWindow = NSApplication.shared.windows.first(where: isManagementWindow) {
            existingWindow.makeKeyAndOrderFront(nil)
        } else if let openMainWindow {
            openMainWindow()
        } else if let model {
            let content = ContentView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(EditorWindowLayout())
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: DockitWindowSize.editor),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "dockit"
            window.identifier = NSUserInterfaceItemIdentifier("management")
            window.toolbarStyle = .unifiedCompact
            window.isReleasedWhenClosed = false
            window.center()
            window.contentViewController = NSHostingController(rootView: content)
            let controller = NSWindowController(window: window)
            fallbackWindowController = controller
            controller.showWindow(nil)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func showSettingsWindow() {
        setPresence(.windows)
        if let existing = NSApplication.shared.windows.first(where: {
            $0.identifier?.rawValue == "preferences" || $0.title == "dockit settings"
        }) {
            existing.makeKeyAndOrderFront(nil)
        } else if let openSettingsWindow {
            openSettingsWindow()
        } else if let model {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: DockitWindowSize.settings),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "dockit settings"
            window.identifier = NSUserInterfaceItemIdentifier("preferences")
            window.contentMinSize = DockitWindowSize.settingsMinimum
            window.isReleasedWhenClosed = false
            window.center()
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            let controller = NSWindowController(window: window)
            fallbackSettingsWindowController = controller
            controller.showWindow(nil)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func isManagementWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == "management" || window.title == "dockit"
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        DockMenuCoordinator.shared.makeMenu(kind: .dock)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model?.refreshLaunchAtLoginStatus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        setPresence(.background)
        return false
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        launchedAsLoginItem = launchedAsLoginItem || currentEventIsLoginLaunch
        return !launchedAsLoginItem
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminationInFlight else { return .terminateLater }
        terminationInFlight = true
        Task { @MainActor [weak self] in
            let shouldTerminate = await model.flushBeforeTermination()
            self?.terminationInFlight = false
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
            if !shouldTerminate {
                self?.showMainWindow()
            }
        }
        return .terminateLater
    }
}
