import AppKit
import DockitCore
import SwiftUI
import Testing
@testable import dockit

private actor FirstSetupPreferences: DockPreferencesServing {
    let snapshot: DockSnapshot
    let failRead: Bool
    private(set) var writeCount = 0

    init(snapshot: DockSnapshot, failRead: Bool = false) {
        self.snapshot = snapshot
        self.failRead = failRead
    }

    func assertMutable() {}
    func readPersistentApps() throws -> DockSnapshot {
        if failRead { throw CocoaError(.fileReadUnknown) }
        return snapshot
    }
    func writePersistentApps(_ snapshot: DockSnapshot) { writeCount += 1 }
}

@Suite(.serialized)
@MainActor
struct EditorWindowLayoutTests {
    @Test
    func verifiedMatchingMenuApplyDoesNotStartFeedbackPresentation() throws {
        let model = AppModel(environment: ["DOCKIT_DEMO": "1"], integratesWithSystem: false)
        let id = try #require(model.library.activeProfile?.profileID)
        model.selectedProfileID = id
        model.applyingProfileID = id
        let record = try #require(model.selectedRecord)
        let view = ProfileDetailView(model: model, record: record)
        #expect(!view.hasApplyingRequest)
        model.library.activeProfile?.appliedLayout = DockLayout(items: [])
        #expect(view.hasApplyingRequest)
    }
    @Test
    func appliedEditorActionRequiresAMatchingVerifiedBaseline() throws {
        let model = AppModel(environment: ["DOCKIT_DEMO": "1"], integratesWithSystem: false)
        let activeID = try #require(model.library.activeProfile?.profileID)
        let inactiveID = try #require(model.selectedProfileID)
        #expect(model.editorShowsApplied(for: activeID))
        #expect(!model.editorShowsApplied(for: inactiveID))
        #expect(!model.activationDisabled(for: activeID), "menus must still apply the checked profile")
        model.saveFailureMessage = "saving failed"
        #expect(!model.editorShowsApplied(for: activeID))
        model.saveFailureMessage = nil
        model.reconciliation = .init(kind: .changedWhileClosed)
        #expect(!model.editorShowsApplied(for: activeID))
        model.reconciliation = nil
        let baseline = model.library.activeProfile?.appliedLayout
        model.library.activeProfile?.appliedLayout = nil
        #expect(!model.editorShowsApplied(for: activeID))
        model.library.activeProfile?.appliedLayout = baseline
        model.library.profiles[0].profile.name = "renamed"
        model.library.profiles[0].profile.color = .purple
        #expect(model.editorShowsApplied(for: activeID))
        model.library.profiles[0].profile.items.append(DockItem(kind: .spacer(.small)))
        #expect(!model.editorShowsApplied(for: activeID))
    }

    @Test
    func appliedEditorLabelKeepsTheActionWidthStable() {
        let ready = NSHostingView(rootView: DockApplyActionLabel(isApplied: false)
            .font(.system(size: 12, weight: .semibold)))
        let applied = NSHostingView(rootView: DockApplyActionLabel(isApplied: true)
            .font(.system(size: 12, weight: .semibold)))
        #expect(ready.fittingSize == applied.fittingSize)
        #expect(ready.fittingSize.width > 60)
    }

    @Test
    func quickApplyDoesNotFlashTheApplyingLabel() throws {
        let model = AppModel(environment: ["DOCKIT_DEMO": "1"], integratesWithSystem: false)
        let record = try #require(model.selectedRecord)
        model.applyingProfileID = record.id
        let view = ProfileDetailView(model: model, record: record)
        #expect(view.feedback == .normal)
    }

    @Test
    func quickApplyKeepsPendingFeedbackUntilThereIsVisibleProgress() throws {
        let model = AppModel(environment: ["DOCKIT_DEMO": "1"], integratesWithSystem: false)
        let activeID = try #require(model.library.activeProfile?.profileID)
        model.selectedProfileID = activeID
        model.library.activeProfile?.appliedLayout = DockLayout(items: [])
        let record = try #require(model.selectedRecord)
        model.applyingProfileID = record.id
        let view = ProfileDetailView(model: model, record: record)
        #expect(view.feedback == .pending)
        model.saveFailureMessage = "saving failed"
        #expect(view.feedback == .saveFailure)
        model.saveFailureMessage = nil
        model.reconciliation = .init(kind: .changedWhileClosed)
        #expect(view.feedback == .reconciliation)
    }

    @Test
    func activationFeedbackDoesNotChangeEditorContentHeight() throws {
        let model = AppModel(environment: ["DOCKIT_DEMO": "1"], integratesWithSystem: false)
        let record = try #require(model.selectedRecord)
        func height() -> CGFloat {
            NSHostingView(rootView: ProfileDetailView(model: model, record: record)
                .frame(width: 620)).fittingSize.height
        }
        let normal = height()
        model.applyingProfileID = record.id
        #expect(height() == normal)
        model.applyingProfileID = nil
        model.saveFailureMessage = "the library could not be saved"
        #expect(height() == normal)
        model.saveFailureMessage = nil
        model.reconciliation = .init(kind: .changedWhileClosed)
        #expect(height() == normal)
        model.reconciliation = nil
        model.library.activeProfile?.appliedLayout = DockLayout(items: [])
        #expect(height() == normal)
    }

    @Test
    func fastAndCancelledApplicationsNeverRevealDelayedProgress() async throws {
        let progress = ApplyProgressPresentation()
        let task = Task { await progress.follow(isApplying: true) }
        try await Task.sleep(for: .milliseconds(40))
        #expect(!progress.isVisible)
        task.cancel()
        await task.value
        await progress.follow(isApplying: false)
        try await Task.sleep(for: .milliseconds(170))
        #expect(!progress.isVisible)
    }

    @Test
    func slowApplicationProgressEndsImmediatelyWithTheOperation() async throws {
        let progress = ApplyProgressPresentation()
        await progress.follow(isApplying: true)
        #expect(progress.isVisible)
        await progress.follow(isApplying: false)
        #expect(!progress.isVisible)
    }

    @Test
    func quickGuideFollowsFirstSuccessfulSetupAndRemembersDismissal() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "dockit-guide-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let snapshot = try DockSnapshot(rawTiles: [["tile-type": "spacer-tile"]])
        let preferences = FirstSetupPreferences(snapshot: snapshot)
        let store = DockLibraryStore(fileURL: directory.appending(path: "library.json"))
        let model = AppModel(environment: [:],
            store: store, preferences: preferences,
            integratesWithSystem: false, guideDefaults: defaults)
        #expect(!model.quickGuidePresented, "existing profiles must not trigger a guide")
        #expect(model.library.profiles.isEmpty, "a real launch must not seed sample profiles")
        await model.createFirst(launchAtLogin: false)
        #expect(model.library.profiles.count == 1)
        #expect(model.library.profiles.first?.profile.name == "current dock")
        #expect(model.library.profiles.first?.profile.items.count == 1)
        #expect(model.library.lastKnownDock == snapshot)
        #expect(model.quickGuidePresented)
        let beforeDismissal = model.library
        model.completeQuickGuide()
        #expect(!model.quickGuidePresented)
        #expect(defaults.bool(forKey: "quickGuideCompleted"))
        #expect(model.library == beforeDismissal)
        model.quickGuidePresented = true
        #expect(model.quickGuidePresented, "help may reopen a completed guide")
        model.completeQuickGuide()
        let existingLibrary = model.library
        await model.createFirst(launchAtLogin: false)
        #expect(!model.quickGuidePresented)
        #expect(model.library == existingLibrary)
        let reinstalled = AppModel(environment: [:], store: store, preferences: preferences,
            integratesWithSystem: false, guideDefaults: defaults)
        await reinstalled.load()
        #expect(reinstalled.library == existingLibrary)
        #expect(!reinstalled.quickGuidePresented)
        model.library = DockLibrary()
        await model.createFirst(launchAtLogin: false)
        #expect(model.quickGuidePresented, "an orphaned completion preference must not suppress fresh setup")
        #expect(await preferences.writeCount == 0)
    }

    @Test
    func quickGuideDoesNotAppearAfterFailedSetup() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blockingFile = directory.appending(path: "not-a-folder")
        try Data().write(to: blockingFile)
        let model = AppModel(environment: [:],
            store: DockLibraryStore(fileURL: blockingFile.appending(path: "library.json")),
            preferences: FirstSetupPreferences(snapshot: try DockSnapshot(rawTiles: [])),
            integratesWithSystem: false)
        model.library = DockLibrary()
        await model.createFirst(launchAtLogin: false)
        #expect(model.library.profiles.isEmpty)
        #expect(!model.quickGuidePresented)
        #expect(model.presentedError != nil)
    }

    @Test
    func failedFirstCaptureLeavesLibraryEmptyAndDoesNotShowGuide() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DockLibraryStore(fileURL: directory.appending(path: "library.json"))
        let preferences = FirstSetupPreferences(snapshot: try DockSnapshot(rawTiles: []), failRead: true)
        let model = AppModel(environment: [:], store: store, preferences: preferences, integratesWithSystem: false)
        await model.createFirst(launchAtLogin: false)
        #expect(model.library.profiles.isEmpty)
        #expect(!model.quickGuidePresented)
        #expect(model.presentedError != nil)
        #expect(try await store.load() == nil)
        #expect(await preferences.writeCount == 0)
    }

    @Test
    func quickGuideFitsItsContentsInBothAppearances() async throws {
        let model = AppModel(environment: ["DOCKIT_DEMO": "1"], integratesWithSystem: false)
        for scheme in [ColorScheme.light, .dark] {
            let view = NSHostingView(rootView: QuickGuideView(model: model)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
            #expect(view.fittingSize.width == 460)
            #expect(view.fittingSize.height > 300)
            #expect(view.fittingSize.height < 520)
            try await captureIfRequested(view, name: "quick-guide-\(scheme)", scheme: scheme)
            let games = try #require(model.library.profiles.first { $0.profile.name == "games" })
            model.selectedProfileID = games.id
            model.reviewUnavailableApps()
            let request = try #require(model.missingAppActivation)
            let missing = NSHostingView(rootView: MissingAppsView(model: model, request: request)
                .frame(width: 520).background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme))
            try await captureIfRequested(missing, name: "missing-apps-\(scheme)", scheme: scheme)
            model.missingAppActivation = nil
        }
    }

    private func captureIfRequested(_ view: NSView, name: String, scheme: ColorScheme) async throws {
        guard let directory = ProcessInfo.processInfo.environment["DOCKIT_TEST_CAPTURE_DIR"] else { return }
        let window = makeWindow()
        defer { window.close() }
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        view.appearance = window.appearance
        window.contentView = view
        window.setContentSize(view.fittingSize)
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try png.write(to: destination.appending(path: "\(name)-hosted.png"))
    }

    @Test
    func shortRecoveryAndExportSheetsFitTheirContents() throws {
        let model = AppModel(environment: ["DOCKIT_DEMO": "1"], integratesWithSystem: false)
        let games = try #require(model.library.profiles.first { $0.profile.name == "games" })
        model.selectedProfileID = games.id
        model.reviewUnavailableApps()
        let request = try #require(model.missingAppActivation)
        let recovery = NSHostingView(rootView: MissingAppsView(model: model, request: request).frame(width: 520))
        let export = NSHostingView(rootView: ExportProfilesView(model: model).frame(width: 520))

        #expect(recovery.fittingSize.height > 150)
        #expect(recovery.fittingSize.height < 360, "recovery size: \(recovery.fittingSize)")
        #expect(export.fittingSize.height > 150)
        #expect(export.fittingSize.height < 360, "export size: \(export.fittingSize)")
    }

    @Test
    func informationSheetsDoNotReserveEmptySpace() throws {
        let model = AppModel(environment: ["DOCKIT_DEMO": "1"], integratesWithSystem: false)
        let profile = try #require(model.selectedRecord?.profile)
        let details = NSHostingView(rootView: DockDetailsView(model: model, profileID: profile.id).frame(width: 560))
        let saved = NSHostingView(rootView: SaveFailureDetailsView(model: model).frame(width: 520))
        let reconciliation = NSHostingView(rootView: ReconciliationView(
            model: model, reconciliation: .init(kind: .changedWhileClosed)
        ).frame(width: 560))

        #expect(details.fittingSize.height < 440)
        #expect(saved.fittingSize.height < 180)
        #expect(reconciliation.fittingSize.height < 360)
    }

    @Test
    func longExportListCapsItsHeightWithoutGrowingTheSheet() throws {
        let model = AppModel(environment: ["DOCKIT_DEMO": "1"], integratesWithSystem: false)
        let seed = try #require(model.library.profiles.first)
        model.library.profiles = (0..<60).map { index in
            var record = seed
            record.profile.id = UUID()
            record.profile.name = "saved profile \(index)"
            return record
        }
        let export = NSHostingView(rootView: ExportProfilesView(model: model).frame(width: 520))
        #expect(export.fittingSize.height >= 400)
        #expect(export.fittingSize.height < 520, "long export size: \(export.fittingSize)")
        let window = makeWindow()
        defer { window.close() }
        window.contentView = export
        window.setContentSize(export.fittingSize)
        export.layoutSubtreeIfNeeded()
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        let scroll = try #require(scrollViews(in: export).first)
        #expect(scroll.bounds.height <= 320, "scroll viewport: \(scroll.bounds)")
        #expect((scroll.documentView?.bounds.height ?? 0) > scroll.bounds.height)
    }

    @Test
    func attachmentLocksTheOuterFrameWithoutAddingTitlebarHeight() {
        let window = makeWindow()
        defer { window.close() }
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)

        window.contentView = EditorWindowLayout.WindowLayoutView()

        #expect(window.frame.size == NSSize(width: 620, height: 252))
        #expect(window.frame.minX == topLeft.x)
        #expect(window.frame.maxY == topLeft.y)
        #expect(window.minSize == window.frame.size)
        #expect(window.maxSize == window.frame.size)
        #expect(!window.styleMask.contains(.resizable))
        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(window.styleMask.contains(.miniaturizable))
        #expect(window.collectionBehavior.contains(.fullScreenNone))
        #expect(!window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(window.titlebarSeparatorStyle == .none)
        #expect(window.titlebarAppearsTransparent)
    }

    @Test
    func reattachingLayoutDoesNotMoveOrGrowTheEditor() {
        let window = makeWindow()
        defer { window.close() }
        let view = EditorWindowLayout.WindowLayoutView()
        window.contentView = view
        let fixedFrame = window.frame

        window.contentView = NSView()
        window.contentView = view

        #expect(window.frame == fixedFrame)
        #expect(window.frame.size == DockitWindowSize.editor)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 180, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        return window
    }
}
