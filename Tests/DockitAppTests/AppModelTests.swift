import AppKit
import DockitCore
import Foundation
import SwiftUI
import Testing
@testable import dockit

@Suite(.serialized)
@MainActor
struct AppModelTests {
    @Test
    func focusQueuedAfterMenuApplyDoesNotTakeEditorSelection() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            await fixture.reloader.pauseNextReload()
            let menu = Task { await model.activateFromMenu(fixture.reading.id) }
            try await waitForPausedReload(fixture.reloader)
            let focus = Task { await model.activate(fixture.work.id, source: .focus) }
            await Task.yield()
            await fixture.reloader.resumePausedReload()
            #expect(await menu.value)
            #expect(await focus.value)
            #expect(model.library.activeProfile?.profileID == fixture.work.id)
            #expect(model.selectedProfileID == fixture.reading.id)
        }
    }

    @Test
    func successfulMenuActivationFollowsActiveButFocusDoesNot() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            #expect(await model.activateFromMenu(fixture.reading.id))
            #expect(model.library.activeProfile?.profileID == fixture.reading.id)
            #expect(model.selectedProfileID == fixture.reading.id)
            model.selectedProfileID = fixture.work.id
            #expect(await model.activate(fixture.reading.id, source: .focus))
            #expect(model.selectedProfileID == fixture.work.id)
        }
    }

    @Test
    func failedMenuActivationPreservesSelectionAndActiveProfile() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            fixture.writeControl.rejectWrites = true
            #expect(await model.activateFromMenu(fixture.reading.id) == false)
            #expect(model.selectedProfileID == fixture.work.id)
            #expect(model.library.activeProfile?.profileID == fixture.work.id)
            #expect(await fixture.preferences.writes.isEmpty)
        }
    }

    @Test
    func startupRecoverySaveFailureRetainsPreviousActiveAndPendingTransaction() async throws {
        try await withFixture(pendingRecovery: true, failWritesAfterSeed: true) { fixture in
            let model = fixture.model
            #expect(model.library.activeProfile?.profileID == fixture.work.id)
            #expect(model.library.pendingApply?.profileID == fixture.reading.id)
            #expect(model.reconciliation != nil)
            #expect(!model.reconciliationErrorMessage.isEmpty)
            let persisted = try #require(try await fixture.store.load())
            #expect(persisted.activeProfile?.profileID == fixture.work.id)
            #expect(persisted.pendingApply?.profileID == fixture.reading.id)
        }
    }

    @Test
    func applyingUnavailableAppKeepsSavedEntryAndAppliesAvailableItems() async throws {
        try await withFixture(includesUnavailableApp: true) { fixture in
            let model = fixture.model
            let applied = await model.activate(fixture.reading.id, source: .manual)
            #expect(applied)
            #expect(model.missingAppActivation == nil)
            #expect(model.library.activeProfile?.profileID == fixture.reading.id)
            #expect(model.library.record(id: fixture.reading.id)?.profile.items == fixture.reading.items)
            #expect(model.statusMessage.contains("Missing App"))
            let actual = await fixture.preferences.snapshot
            #expect(actual.hasSameLayout(as: fixture.readingSnapshot))
            let writes = await fixture.preferences.writes
            #expect(writes.count == 1)
        }
    }

    @Test
    func inactiveProfileEditsPersistWithoutChangingDock() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            model.selectedProfileID = fixture.reading.id
            await model.addSpacer(.small)
            let persisted = try #require(try await fixture.store.load())
            #expect(persisted.record(id: fixture.reading.id)?.profile.items.count == 2)
            #expect(persisted.activeProfile?.profileID == fixture.work.id)
            let writes = await fixture.preferences.writes
            let reloads = await fixture.reloader.attempts
            #expect(writes.isEmpty)
            #expect(reloads == 0)
        }
    }

    @Test
    func activeProfileEditsWaitForExplicitApply() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            await model.addSpacer(.regular)
            #expect(model.hasPendingSelectedChanges)
            #expect(model.library.activeProfile?.appliedLayout == DockLayout(profile: fixture.work))
            let writesBeforeApply = await fixture.preferences.writes
            #expect(writesBeforeApply.isEmpty)

            let applied = await model.activate(fixture.work.id, source: .manual)
            #expect(applied)
            #expect(!model.hasPendingSelectedChanges)
            let saved = try #require(model.library.record(id: fixture.work.id)?.profile)
            #expect(model.library.activeProfile?.appliedLayout == DockLayout(profile: saved))
            let actual = await fixture.preferences.snapshot
            let expected = try DockSnapshot.build(profile: saved, localState: DockProfileLocalState()).snapshot
            #expect(actual.hasSameLayout(as: expected))
            let writes = await fixture.preferences.writes
            let reloads = await fixture.reloader.attempts
            #expect(writes.count == 1)
            #expect(reloads == 1)
        }
    }

    @Test
    func staleDropCannotReorderSelectedDuplicateWithSharedItemIDs() async throws {
        try await withFixture(multipleWorkItems: true) { fixture in
            let model = fixture.model
            let startingItems = fixture.work.items
            await model.duplicateProfile(fixture.work.id)
            let duplicateID = try #require(model.selectedProfileID)
            #expect(duplicateID != fixture.work.id)
            #expect(model.selectedRecord?.profile.items == startingItems)
            let original = model.library
            let attempts = fixture.writeControl.writeAttempts

            await model.moveItems([startingItems[0].id], before: nil,
                sourceProfileID: fixture.work.id, expectedItems: startingItems)

            #expect(model.library == original)
            #expect(fixture.writeControl.writeAttempts == attempts)
            let persisted = try #require(try await fixture.store.load())
            #expect(persisted.record(id: duplicateID)?.profile.items == startingItems)
            #expect(await fixture.preferences.writes.isEmpty)
        }
    }

    @Test
    func staleDropCannotReorderChangedSourceLayout() async throws {
        try await withFixture(multipleWorkItems: true) { fixture in
            let model = fixture.model
            let startingItems = fixture.work.items
            await model.addSpacer(.small)
            let original = model.library
            let attempts = fixture.writeControl.writeAttempts

            await model.moveItems([startingItems[0].id], before: nil,
                sourceProfileID: fixture.work.id, expectedItems: startingItems)

            #expect(model.library == original)
            #expect(fixture.writeControl.writeAttempts == attempts)
            #expect(await fixture.preferences.writes.isEmpty)
        }
    }

    @Test(arguments: DropInterruption.allCases)
    func dropRechecksSourceAfterDrainingScheduledSave(_ interruption: DropInterruption) async throws {
        try await withFixture(multipleWorkItems: true) { fixture in
            let model = fixture.model
            let startingItems = fixture.work.items
            fixture.writeControl.pauseNextWrite()
            model.renameProfile(fixture.work.id, to: "updated work")
            try await waitForPausedWrite(fixture.writeControl)
            let drop = Task {
                await model.moveItems([startingItems[0].id], before: nil,
                    sourceProfileID: fixture.work.id, expectedItems: startingItems)
            }
            for _ in 0..<100 where !model.profileActionsDisabled { await Task.yield() }
            try #require(model.profileActionsDisabled)
            switch interruption {
            case .changedLayout:
                var changed = try #require(model.selectedRecord)
                changed.profile.items.append(DockItem(kind: .spacer(.small)))
                try model.library.replace(changed)
            case .changedSelection:
                model.library.selectedProfileID = fixture.reading.id
            case .removedProfile:
                model.library.profiles.removeAll { $0.id == fixture.work.id }
            case .applying:
                model.isApplying = true
            case .reconciling:
                model.reconciliation = AppModel.Reconciliation(kind: .changedWhileClosed)
            case .cancelled:
                drop.cancel()
            }
            defer {
                model.isApplying = false
                model.reconciliation = nil
            }
            let expected = model.library
            let attempts = fixture.writeControl.writeAttempts

            fixture.writeControl.resumePausedWrite()
            await drop.value

            #expect(model.library == expected)
            #expect(fixture.writeControl.writeAttempts == attempts)
            #expect(await fixture.preferences.writes.isEmpty)
        }
    }

    @Test(arguments: InvalidDropRequest.allCases)
    func dropRejectsInvalidRequests(_ invalid: InvalidDropRequest) async throws {
        try await withFixture(multipleWorkItems: true) { fixture in
            let model = fixture.model
            let startingItems = fixture.work.items
            var movingIDs = [startingItems[0].id]
            var targetID: UUID?
            var sourceID = fixture.work.id
            switch invalid {
            case .emptySelection: movingIDs = []
            case .duplicateItem: movingIDs.append(startingItems[0].id)
            case .unknownItem: movingIDs = [UUID()]
            case .partlyUnknownSelection: movingIDs.append(UUID())
            case .unknownTarget: targetID = UUID()
            case .movingTarget: targetID = startingItems[0].id
            case .missingProfile: sourceID = UUID()
            }
            let original = model.library
            let attempts = fixture.writeControl.writeAttempts

            await model.moveItems(movingIDs, before: targetID,
                sourceProfileID: sourceID, expectedItems: startingItems)

            #expect(model.library == original)
            #expect(fixture.writeControl.writeAttempts == attempts)
            #expect(await fixture.preferences.writes.isEmpty)
        }
    }

    @Test
    func cancelledDropDoesNotStartAnEdit() async throws {
        try await withFixture(multipleWorkItems: true) { fixture in
            let model = fixture.model
            let startingItems = fixture.work.items
            let original = model.library
            let attempts = fixture.writeControl.writeAttempts
            let drop = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                await model.moveItems([startingItems[0].id], before: nil,
                    sourceProfileID: fixture.work.id, expectedItems: startingItems)
            }

            await drop.value

            #expect(model.library == original)
            #expect(fixture.writeControl.writeAttempts == attempts)
        }
    }

    @Test
    func dropPreservesMetadataChangedSinceDragStarted() async throws {
        try await withFixture(multipleWorkItems: true) { fixture in
            let model = fixture.model
            let startingItems = fixture.work.items
            model.renameProfile(fixture.work.id, to: "renamed work")

            await model.moveItems([startingItems[0].id], before: nil,
                sourceProfileID: fixture.work.id, expectedItems: startingItems)

            let persisted = try #require(try await fixture.store.load())
            #expect(persisted.record(id: fixture.work.id)?.profile.name == "renamed work")
            #expect(persisted.record(id: fixture.work.id)?.profile.items ==
                Array(startingItems.dropFirst()) + [startingItems[0]])
            #expect(await fixture.preferences.writes.isEmpty)
        }
    }

    @Test
    func groupedDropPersistsSavedOrderWithoutApplyingDock() async throws {
        try await withFixture(multipleWorkItems: true) { fixture in
            let model = fixture.model
            let startingItems = fixture.work.items
            let movingIDs = [startingItems[2].id, startingItems[0].id]
            model.selectedItemIDs = Set(movingIDs)
            let attempts = fixture.writeControl.writeAttempts
            let expected = [startingItems[1], startingItems[0], startingItems[2], startingItems[3]]

            await model.moveItems(movingIDs, before: startingItems[3].id,
                sourceProfileID: fixture.work.id, expectedItems: startingItems)

            #expect(model.selectedRecord?.profile.items == expected)
            #expect(model.selectedItemIDs == Set(movingIDs))
            #expect(fixture.writeControl.writeAttempts == attempts + 1)
            let persisted = try #require(try await fixture.store.load())
            #expect(persisted.record(id: fixture.work.id)?.profile.items == expected)
            #expect(model.hasPendingSelectedChanges)
            #expect(model.library.activeProfile?.appliedLayout == DockLayout(profile: fixture.work))
            #expect(await fixture.preferences.writes.isEmpty)
            #expect(await fixture.reloader.attempts == 0)
        }
    }

    @Test(arguments: [false, true])
    func duplicateDropRequestSavesOnlyOnce(concurrent: Bool) async throws {
        try await withFixture(multipleWorkItems: true) { fixture in
            let model = fixture.model
            let startingItems = fixture.work.items
            let movingIDs = [startingItems[0].id, startingItems[2].id]
            let attempts = fixture.writeControl.writeAttempts

            if concurrent {
                let first = Task {
                    await model.moveItems(movingIDs, before: nil,
                        sourceProfileID: fixture.work.id, expectedItems: startingItems)
                }
                let duplicate = Task {
                    await model.moveItems(movingIDs, before: nil,
                        sourceProfileID: fixture.work.id, expectedItems: startingItems)
                }
                await first.value
                await duplicate.value
            } else {
                await model.moveItems(movingIDs, before: nil,
                    sourceProfileID: fixture.work.id, expectedItems: startingItems)
            }
            let afterFirst = model.library
            await model.moveItems(movingIDs, before: nil,
                sourceProfileID: fixture.work.id, expectedItems: startingItems)

            #expect(model.library == afterFirst)
            #expect(fixture.writeControl.writeAttempts == attempts + 1)
            #expect(model.selectedRecord?.profile.items == [
                startingItems[1], startingItems[3], startingItems[0], startingItems[2]
            ])
        }
    }

    @Test
    func unchangedDropDoesNotResaveOrChangeMetadata() async throws {
        try await withFixture(multipleWorkItems: true) { fixture in
            let model = fixture.model
            let startingItems = fixture.work.items
            let original = model.library
            let attempts = fixture.writeControl.writeAttempts

            await model.moveItems([startingItems[0].id], before: startingItems[1].id,
                sourceProfileID: fixture.work.id, expectedItems: startingItems)

            #expect(model.library == original)
            #expect(fixture.writeControl.writeAttempts == attempts)
        }
    }

    @Test(arguments: [false, true])
    func dropIsRejectedWhileApplyingOrReconciling(applying: Bool) async throws {
        try await withFixture(multipleWorkItems: true) { fixture in
            let model = fixture.model
            let startingItems = fixture.work.items
            if applying {
                model.isApplying = true
            } else {
                model.reconciliation = AppModel.Reconciliation(kind: .changedWhileClosed)
            }
            defer {
                model.isApplying = false
                model.reconciliation = nil
            }
            let original = model.library
            let attempts = fixture.writeControl.writeAttempts

            await model.moveItems([startingItems[0].id], before: nil,
                sourceProfileID: fixture.work.id, expectedItems: startingItems)

            #expect(model.library == original)
            #expect(fixture.writeControl.writeAttempts == attempts)
        }
    }

    @Test
    func dropSaveFailureRetainsReorderedBufferForRetry() async throws {
        try await withFixture(multipleWorkItems: true) { fixture in
            let model = fixture.model
            let startingItems = fixture.work.items
            let expected = Array(startingItems.dropFirst()) + [startingItems[0]]
            fixture.writeControl.rejectWrites = true

            await model.moveItems([startingItems[0].id], before: nil,
                sourceProfileID: fixture.work.id, expectedItems: startingItems)

            #expect(model.selectedRecord?.profile.items == expected)
            #expect(model.saveFailureMessage != nil)
            #expect(model.activationDisabled(for: fixture.work.id))
            let beforeRetry = try #require(try await fixture.store.load())
            #expect(beforeRetry.record(id: fixture.work.id)?.profile.items == startingItems)
            #expect(model.library.activeProfile?.appliedLayout == DockLayout(profile: fixture.work))
            let attemptsAfterFailure = fixture.writeControl.writeAttempts
            await model.moveItems([startingItems[0].id], before: nil,
                sourceProfileID: fixture.work.id, expectedItems: startingItems)
            #expect(fixture.writeControl.writeAttempts == attemptsAfterFailure)
            #expect(model.selectedRecord?.profile.items == expected)
            fixture.writeControl.rejectWrites = false

            await model.retrySave()

            let retried = try #require(try await fixture.store.load())
            #expect(retried.record(id: fixture.work.id)?.profile.items == expected)
            #expect(model.saveFailureMessage == nil)
            #expect(model.hasPendingSelectedChanges)
            #expect(await fixture.preferences.writes.isEmpty)
            #expect(await fixture.reloader.attempts == 0)
        }
    }

    @Test
    func profileSelectionAndActivationStayIndependent() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            model.selectedProfileID = fixture.reading.id
            #expect(model.library.activeProfile?.profileID == fixture.work.id)
            let noOpApplied = await model.activate(fixture.work.id, source: .manual)
            #expect(noOpApplied)
            #expect(model.selectedProfileID == fixture.reading.id)
            let reloads = await fixture.reloader.attempts
            #expect(reloads == 0)

            model.selectedProfileID = fixture.work.id
            let activated = await model.activate(fixture.reading.id, source: .manual)
            #expect(activated)
            #expect(model.library.activeProfile?.profileID == fixture.reading.id)
            #expect(model.selectedProfileID == fixture.work.id)
        }
    }

    @Test
    func nativeProfileMenuProjectsCurrentSelectionAndEveryAction() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            let coordinator = NativeProfileToolbarPicker.Coordinator(model: model)
            let menu = NSMenu(title: "docks")
            let button = NativeProfilePopUpButton(frame: .zero, pullsDown: false)
            button.menu = menu

            coordinator.update(model: model, button: button, environmentEnabled: true, colorScheme: .light)

            coordinator.menuNeedsUpdate(menu)

            #expect(button.title == fixture.work.name)
            #expect(button.image != nil)
            #expect(button.displayedMenuItem?.title == fixture.work.name)
            #expect(button.displayedMenuItem?.image != nil)
            #expect((button.cell as? NSPopUpButtonCell)?.attributedTitle.string == fixture.work.name)
            #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == [
                "work · current",
                "reading",
                "rename...",
                "color",
                "duplicate",
                "delete dock...",
                "capture current dock",
                "new empty dock",
                "import docks...",
                "export docks..."
            ])
            #expect(menu.item(withTitle: "work · current")?.state == .on)
            #expect(menu.item(withTitle: "reading")?.state == .off)
            let colorMenu = try #require(menu.item(withTitle: "color")?.submenu)
            #expect(colorMenu.items.map(\.title) == ProfileColor.allCases.map(\.rawValue))
            #expect(colorMenu.item(withTitle: ProfileColor.blue.rawValue)?.state == .on)

            let wideName = String(repeating: "界", count: DockProfile.maximumNameLength)
            model.renameProfile(fixture.reading.id, to: wideName)
            model.selectedProfileID = fixture.reading.id
            coordinator.menuNeedsUpdate(menu)

            #expect(menu.item(withTitle: "work · current")?.state == .off)
            #expect(menu.item(withTitle: wideName)?.state == .on)
            let refreshedColors = try #require(menu.item(withTitle: "color")?.submenu)
            #expect(refreshedColors.item(withTitle: ProfileColor.green.rawValue)?.state == .on)

            model.reconciliation = AppModel.Reconciliation(kind: .changedWhileClosed)
            coordinator.menuNeedsUpdate(menu)

            #expect(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { !$0.isEnabled })
        }
    }

    @Test
    func profileCommandsTargetTheirStableIdentifierAfterSelectionChanges() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            model.selectedProfileID = fixture.reading.id

            await model.duplicateProfile(fixture.work.id)

            let duplicate = try #require(model.selectedRecord?.profile)
            #expect(duplicate.name == "work copy")
            #expect(duplicate.items == fixture.work.items)
            model.selectedProfileID = fixture.reading.id

            model.askToDeleteProfile(fixture.work.id)

            #expect(model.deleteRequest?.id == fixture.work.id)
            #expect(model.deleteRequest?.profile.name == fixture.work.name)
        }
    }

    @Test
    func staleProfileCommandsDoNotChangeTheLibrary() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            let missingID = UUID()
            let originalLibrary = model.library

            await model.duplicateProfile(missingID)
            model.askToDeleteProfile(missingID)

            #expect(model.library == originalLibrary)
            #expect(model.deleteRequest == nil)
        }
    }

    @Test
    func nativeProfileButtonUsesRoundedRectangleAndWrappingInsteadOfTruncation() {
        let button = NativeProfilePopUpButton(frame: .zero, pullsDown: false)
        button.setDisplayedItem(title: "work", image: nil)
        let shortSize = button.measuredSize()
        let wideName = String(repeating: "界", count: DockProfile.maximumNameLength)
        button.setDisplayedItem(title: wideName, image: nil)
        let wideSize = button.measuredSize()
        let titleWidth = (wideName as NSString).size(withAttributes: [
            .font: button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ]).width

        #expect(button.bezelStyle == .flexiblePush)
        #expect(button.borderShape == .roundedRectangle)
        #expect(!button.showsBorderOnlyWhileMouseInside)
        #expect(!button.isBordered)
        #expect(button.cell?.isBordered == false)
        #expect(!button.pullsDown)
        #expect(!button.usesItemFromMenu)
        #expect(!button.usesSingleLineMode)
        #expect(button.lineBreakMode == .byCharWrapping)
        #expect(button.cell?.wraps == true)
        #expect(button.cell?.truncatesLastVisibleLine == false)
        #expect(shortSize.width >= NativeProfilePopUpButton.minimumWidth)
        #expect(titleWidth > NativeProfilePopUpButton.maximumWidth)
        #expect(wideSize.width <= NativeProfilePopUpButton.maximumWidth)
        #expect(wideSize.height >= shortSize.height)
    }

    @Test
    func saveFailureKeepsEditingBufferAndBlocksApplyUntilRetry() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            fixture.writeControl.rejectWrites = true
            await model.addSpacer(.regular)
            #expect(model.selectedRecord?.profile.items.count == 2)
            #expect(model.saveFailureMessage != nil)
            #expect(model.activationDisabled(for: fixture.work.id))
            let persisted = try #require(try await fixture.store.load())
            #expect(persisted.record(id: fixture.work.id)?.profile.items == fixture.work.items)
            let applied = await model.activate(fixture.work.id, source: .manual)
            #expect(!applied)
            let writes = await fixture.preferences.writes
            #expect(writes.isEmpty)

            fixture.writeControl.rejectWrites = false
            await model.retrySave()
            #expect(model.saveFailureMessage == nil)
            let retried = try #require(try await fixture.store.load())
            #expect(retried.record(id: fixture.work.id)?.profile.items.count == 2)
            #expect(model.hasPendingSelectedChanges)
        }
    }

    @Test
    func retrySaveFailureStaysInlineAndSuccessDoesNotPresentStaleAlert() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            let baselineActive = model.library.activeProfile
            let libraryURL = fixture.directory.appending(path: "library.json")
            let baselineBytes = try Data(contentsOf: libraryURL)
            fixture.writeControl.rejectWrites = true
            await model.addSpacer(.regular)
            let bufferedItems = try #require(model.selectedRecord?.profile.items)
            try #require(bufferedItems != fixture.work.items)
            try #require(model.presentedError != nil)
            model.presentedError = nil

            await model.retrySave()

            #expect(model.presentedError == nil, "the recovery view already displays the retry failure")
            #expect(model.saveFailureMessage != nil)
            #expect(model.activationDisabled(for: fixture.work.id))
            #expect(model.selectedRecord?.profile.items == bufferedItems)
            #expect(try Data(contentsOf: libraryURL) == baselineBytes)
            #expect(model.library.activeProfile == baselineActive)

            fixture.writeControl.rejectWrites = false
            await model.retrySave()

            #expect(model.presentedError == nil, "closing recovery must not reveal an obsolete retry alert")
            #expect(model.saveFailureMessage == nil)
            #expect(model.hasPendingSelectedChanges)
            #expect(!model.activationDisabled(for: fixture.work.id))
            #expect(model.library.activeProfile == baselineActive)
            let persisted = try #require(try await fixture.store.load())
            #expect(persisted.record(id: fixture.work.id)?.profile.items == bufferedItems)
            #expect(persisted.activeProfile == baselineActive)
            #expect(await fixture.preferences.writes.isEmpty)
            #expect(await fixture.reloader.attempts == 0)
        }
    }

    @Test
    func missingAppRetryFailureStaysInlineWithoutClosingReview() async throws {
        try await withFixture(includesUnavailableApp: true) { fixture in
            let model = fixture.model
            let baselineActive = model.library.activeProfile
            model.selectedProfileID = fixture.reading.id
            model.reviewUnavailableApps()
            let request = try #require(model.missingAppActivation)
            let itemID = try #require(fixture.reading.items.last?.id)
            let replacement = fixture.directory.appending(path: "Replacement.app", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
            let libraryURL = fixture.directory.appending(path: "library.json")
            let baselineBytes = try Data(contentsOf: libraryURL)
            fixture.writeControl.rejectWrites = true
            await model.saveUnavailableAppReplacement(requestID: request.id, itemID: itemID, url: replacement)
            let bufferedItems = try #require(model.library.record(id: fixture.reading.id)?.profile.items)
            try #require(bufferedItems != fixture.reading.items)
            try #require(model.saveFailureMessage != nil)
            try #require(model.presentedError == nil)

            await model.retrySave()

            #expect(model.presentedError == nil, "missing-app recovery already displays the retry failure")
            #expect(model.saveFailureMessage != nil)
            #expect(!model.missingAppErrorMessage.isEmpty)
            #expect(model.missingAppActivation?.id == request.id)
            #expect(model.activationDisabled(for: fixture.reading.id))
            #expect(model.library.record(id: fixture.reading.id)?.profile.items == bufferedItems)
            #expect(try Data(contentsOf: libraryURL) == baselineBytes)

            fixture.writeControl.rejectWrites = false
            await model.retrySave()

            #expect(model.presentedError == nil)
            #expect(model.saveFailureMessage == nil)
            #expect(model.missingAppErrorMessage.isEmpty)
            #expect(model.missingAppActivation?.id == request.id)
            #expect(model.library.activeProfile == baselineActive)
            let persisted = try #require(try await fixture.store.load())
            #expect(persisted.record(id: fixture.reading.id)?.profile.items == bufferedItems)
            #expect(persisted.activeProfile == baselineActive)
            #expect(await fixture.preferences.writes.isEmpty)
            #expect(await fixture.reloader.attempts == 0)
        }
    }

    @Test
    func replacementSaveFailureRetainsChoiceAndRetryDoesNotApplyOrCloseReview() async throws {
        try await withFixture(includesUnavailableApp: true) { fixture in
            let model = fixture.model
            model.selectedProfileID = fixture.reading.id
            model.reviewUnavailableApps()
            let request = try #require(model.missingAppActivation)
            let itemID = try #require(fixture.reading.items.last?.id)
            let replacement = fixture.directory.appending(path: "Replacement.app", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
            fixture.writeControl.rejectWrites = true

            await model.saveUnavailableAppReplacement(requestID: request.id, itemID: itemID, url: replacement)

            let buffered = try #require(model.library.record(id: fixture.reading.id)?.profile.items.last)
            if case let .application(app) = buffered.kind {
                #expect(app.path == replacement.path)
                #expect(app.displayName == "Replacement")
            } else {
                Issue.record("the replacement must remain an application")
            }
            #expect(model.saveFailureMessage != nil)
            #expect(!model.missingAppErrorMessage.isEmpty)
            #expect(model.missingAppActivation?.id == request.id)
            let replacementError = model.missingAppErrorMessage
            await model.confirmMissingAppActivation(request.id)
            #expect(model.missingAppActivation?.id == request.id)
            #expect(model.missingAppErrorMessage == replacementError)
            #expect(await model.activate(fixture.reading.id, source: .manual) == false)
            let persistedBeforeRetry = try #require(try await fixture.store.load())
            #expect(persistedBeforeRetry.record(id: fixture.reading.id)?.profile.items == fixture.reading.items)
            #expect(await fixture.preferences.writes.isEmpty)

            fixture.writeControl.rejectWrites = false
            await model.retrySave()

            #expect(model.saveFailureMessage == nil)
            #expect(model.missingAppErrorMessage.isEmpty)
            #expect(model.missingAppActivation?.id == request.id)
            let persistedAfterRetry = try #require(try await fixture.store.load())
            #expect(persistedAfterRetry.record(id: fixture.reading.id)?.profile.items.last == buffered)
            #expect(model.library.activeProfile?.profileID == fixture.work.id)
            #expect(await fixture.preferences.writes.isEmpty)
            #expect(await fixture.reloader.attempts == 0)
        }
    }

    @Test
    func duplicateInFlightActivationWaitsForVerificationAndSkipsSecondRestart() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            await fixture.reloader.pauseNextReload()
            let first = Task { await model.activate(fixture.reading.id, source: .manual) }
            try await waitForPausedReload(fixture.reloader)
            let result = ActivationResultProbe()
            let duplicate = Task {
                let value = await model.activate(fixture.reading.id, source: .manual)
                result.value = value
                return value
            }
            await waitForQueuedStatus(model)
            #expect(result.value == nil)
            #expect(model.library.activeProfile?.profileID == fixture.work.id)
            await fixture.reloader.resumePausedReload()
            #expect(await first.value)
            #expect(await duplicate.value)
            #expect(model.library.activeProfile?.profileID == fixture.reading.id)
            #expect(await fixture.reloader.attempts == 1)
        }
    }

    @Test
    func returningToInFlightProfileKeepsCoalescedRequestsPendingUntilVerification() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            await fixture.reloader.pauseNextReload()
            let first = Task { await model.activate(fixture.reading.id, source: .manual) }
            try await waitForPausedReload(fixture.reloader)
            let middleResult = ActivationResultProbe()
            let middle = Task {
                let value = await model.activate(fixture.work.id, source: .manual)
                middleResult.value = value
                return value
            }
            await waitForQueuedStatus(model)
            let finalResult = ActivationResultProbe()
            let final = Task {
                let value = await model.activate(fixture.reading.id, source: .manual)
                finalResult.value = value
                return value
            }
            for _ in 0..<100 { await Task.yield() }
            #expect(middleResult.value == nil)
            #expect(finalResult.value == nil)
            #expect(model.library.activeProfile?.profileID == fixture.work.id)
            await fixture.reloader.resumePausedReload()
            #expect(await first.value)
            #expect(await middle.value)
            #expect(await final.value)
            #expect(model.library.activeProfile?.profileID == fixture.reading.id)
            #expect(await fixture.reloader.attempts == 1)
        }
    }

    @Test
    func manualReapplyDuringDirectFocusActivationPersistsNewestMetadata() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            let focusDate = Date(timeIntervalSince1970: 1_700_000_000)
            let manualDate = focusDate.addingTimeInterval(1)
            let focusID = UUID()
            await fixture.reloader.pauseNextReload()
            let focus = Task {
                await model.activate(fixture.reading.id, source: .focus,
                    requestedAt: focusDate, focusRequestID: focusID)
            }
            try await waitForPausedReload(fixture.reloader)
            let manual = Task {
                await model.activate(fixture.reading.id, source: .manual, requestedAt: manualDate)
            }
            await waitForQueuedStatus(model)
            await fixture.reloader.resumePausedReload()
            #expect(await focus.value)
            #expect(await manual.value)
            let persisted = try #require(try await fixture.store.load())
            #expect(persisted.activeProfile?.source == .manual)
            #expect(persisted.activeProfile?.appliedAt == manualDate)
            #expect(persisted.lastHandledFocusRequest?.requestID == focusID)
            #expect(await fixture.reloader.attempts == 1)
        }
    }

    @Test(arguments: [false, true])
    func duplicateFailedActivationNeverAssumesSuccess(queuesInterveningProfile: Bool) async throws {
        try await withFixture { fixture in
            let model = fixture.model
            await fixture.reloader.failReload(attempt: 1)
            await fixture.reloader.failReload(attempt: 3)
            await fixture.reloader.pauseNextReload()
            let first = Task { await model.activate(fixture.reading.id, source: .manual) }
            try await waitForPausedReload(fixture.reloader)
            let middle: Task<Bool, Never>?
            if queuesInterveningProfile {
                middle = Task { await model.activate(fixture.work.id, source: .manual) }
                await waitForQueuedStatus(model)
            } else {
                middle = nil
            }
            let finalResult = ActivationResultProbe()
            let final = Task {
                let value = await model.activate(fixture.reading.id, source: .manual)
                finalResult.value = value
                return value
            }
            for _ in 0..<100 { await Task.yield() }
            #expect(finalResult.value == nil)
            await fixture.reloader.resumePausedReload()
            #expect(await first.value == false)
            if let middle { #expect(await middle.value == false) }
            #expect(await final.value == false)
            #expect(model.library.activeProfile?.profileID == fixture.work.id)
            #expect(model.library.activeProfile?.appliedLayout == DockLayout(profile: fixture.work))
            #expect(model.library.pendingApply == nil)
            let expected = try DockSnapshot.build(profile: fixture.work, localState: DockProfileLocalState()).snapshot
            #expect(await fixture.preferences.snapshot.hasSameLayout(as: expected))
            #expect(await fixture.preferences.writes.count == 4)
            #expect(await fixture.reloader.attempts == 4)
        }
    }

    @Test
    func externalDockChangePreservesPendingSavedEdits() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            await model.addSpacer(.regular)
            let pendingItems = try #require(model.selectedRecord?.profile.items)
            let external = DockProfile(name: "external", color: .gray, items: [])
            let snapshot = try DockSnapshot.build(profile: external, localState: DockProfileLocalState()).snapshot
            await fixture.preferences.setExternalSnapshot(snapshot)
            let accepted = await model.handleDockChange(snapshot)
            #expect(accepted)
            #expect(model.selectedRecord?.profile.items == pendingItems)
            #expect(model.library.activeProfile?.appliedLayout == DockLayout(profile: fixture.work))
            if case .savedEditsConflict = model.reconciliation?.kind {} else {
                Issue.record("external changes must present the saved-edits conflict")
            }
            #expect(model.activationActionsDisabled)
            let writes = await fixture.preferences.writes
            #expect(writes.isEmpty)
        }
    }

    @Test
    func interruptedRecoveryKeepsCurrentAsNewProfileWithoutReplacingTarget() async throws {
        try await withFixture(pendingRecovery: true, divergedRecovery: true) { fixture in
            let model = fixture.model
            let targetItems = fixture.reading.items
            await model.keepCurrentDockChanges()
            #expect(model.reconciliation == nil)
            #expect(model.library.profiles.count == 3)
            #expect(model.library.record(id: fixture.reading.id)?.profile.items == targetItems)
            #expect(model.library.activeProfile?.profileID != fixture.reading.id)
            #expect(model.library.activeProfile?.profileID != fixture.work.id)
            #expect(model.activeRecord?.profile.items.isEmpty == true)
            let writes = await fixture.preferences.writes
            #expect(writes.isEmpty)
        }
    }

    @Test
    func acceptingClosedDockChangesRetainsUnavailableSavedApps() async throws {
        try await withFixture(activeIncludesUnavailableApp: true, changedWhileClosed: true) { fixture in
            let model = fixture.model
            let missingItem = try #require(fixture.work.items.last)
            if case .changedWhileClosed = model.reconciliation?.kind {} else {
                Issue.record("the fixture must reach ordinary closed-app reconciliation")
            }
            await model.keepCurrentDockChanges()
            #expect(model.reconciliation == nil)
            #expect(model.library.record(id: fixture.work.id)?.profile.items.contains(missingItem) == true)
            let writes = await fixture.preferences.writes
            #expect(writes.isEmpty)
        }
    }

    @Test
    func externalAutosaveFailureKeepsRetryableBufferWithoutRepeatedWrites() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            await fixture.preferences.setExternalSnapshot(fixture.readingSnapshot)
            fixture.writeControl.rejectWrites = true
            _ = await model.handleDockChange(fixture.readingSnapshot)
            #expect(model.saveFailureMessage != nil)
            let buffered = try #require(model.library.record(id: fixture.work.id)?.profile)
            #expect(DockLayout(profile: buffered) == DockLayout(profile: fixture.reading))
            let failedAttempts = fixture.writeControl.writeAttempts
            _ = await model.handleDockChange(fixture.readingSnapshot)
            #expect(fixture.writeControl.writeAttempts == failedAttempts)
            #expect(model.activationActionsDisabled)

            fixture.writeControl.rejectWrites = false
            await model.retrySave()
            let persisted = try #require(try await fixture.store.load())
            let saved = try #require(persisted.record(id: fixture.work.id)?.profile)
            #expect(DockLayout(profile: saved) == DockLayout(profile: fixture.reading))
            #expect(model.saveFailureMessage == nil)
            let writes = await fixture.preferences.writes
            #expect(writes.isEmpty)
        }
    }

    @Test
    func selectionCanChangeDuringActivationWhileItemMutationIsFrozen() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            let activation = Task { await model.activate(fixture.reading.id, source: .focus) }
            try await waitForActivation(model)
            #expect(model.library.activeProfile?.profileID == fixture.work.id)
            model.selectedProfileID = fixture.reading.id
            await model.addSpacer(.small)
            #expect(model.selectedRecord?.profile.items == fixture.reading.items)
            #expect(await activation.value)
            #expect(model.library.activeProfile?.profileID == fixture.reading.id)
            #expect(model.selectedProfileID == fixture.reading.id)
        }
    }

    @Test
    func rapidRequestsCoalesceBeforeRestart() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            let first = Task { await model.activate(fixture.reading.id, source: .manual) }
            try await waitForActivation(model)
            let final = Task { await model.activate(fixture.work.id, source: .manual) }
            #expect(await first.value)
            #expect(await final.value)
            #expect(model.library.activeProfile?.profileID == fixture.work.id)
            let writes = await fixture.preferences.writes
            let reloads = await fixture.reloader.attempts
            #expect(writes.isEmpty)
            #expect(reloads == 0)
        }
    }

    @Test
    func failedReloadRestoresDockAndPreservesSavedEdits() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            model.selectedProfileID = fixture.reading.id
            await model.addSpacer(.small)
            let savedItems = try #require(model.selectedRecord?.profile.items)
            await fixture.reloader.failNextReload()
            #expect(await model.activate(fixture.reading.id, source: .manual) == false)
            #expect(model.library.activeProfile?.profileID == fixture.work.id)
            #expect(model.library.activeProfile?.appliedLayout == DockLayout(profile: fixture.work))
            #expect(model.library.record(id: fixture.reading.id)?.profile.items == savedItems)
            #expect(model.library.pendingApply == nil)
            #expect(model.selectedProfileID == fixture.reading.id)
            let expected = try DockSnapshot.build(profile: fixture.work, localState: DockProfileLocalState()).snapshot
            let actual = await fixture.preferences.snapshot
            #expect(actual.hasSameLayout(as: expected))
            let writes = await fixture.preferences.writes
            let reloads = await fixture.reloader.attempts
            #expect(writes.count == 2)
            #expect(reloads == 2)
        }
    }

    @Test
    func dismissingDemoActivationFailurePreservesPendingActiveDockEdits() async throws {
        try #require(ProcessInfo.processInfo.environment["DOCKIT_DEMO"] == "1",
            "hosted tests must run with DOCKIT_DEMO=1")
        let preferences = ModelTestPreferences(snapshot: try DockSnapshot(rawTiles: []))
        let reloader = ModelTestReloader()
        let model = AppModel(
            environment: ["DOCKIT_DEMO": "1", "DOCKIT_DEMO_FAIL_PROFILE": "games"],
            preferences: preferences,
            reloader: reloader,
            integratesWithSystem: false
        )
        let work = try #require(model.library.profiles.first { $0.profile.name == "work" })
        let games = try #require(model.library.profiles.first { $0.profile.name == "games" })
        let previousActive = try #require(model.library.activeProfile)
        #expect(previousActive.profileID == work.id)
        #expect(previousActive.appliedLayout == DockLayout(profile: work.profile))
        model.selectedProfileID = work.id

        await model.addSpacer(.small)
        let savedItems = try #require(model.selectedRecord?.profile.items)
        let selectedItemIDs = model.selectedItemIDs
        #expect(savedItems.count == work.profile.items.count + 1)
        #expect(savedItems.last?.kind == .spacer(.small))
        #expect(model.hasPendingSelectedChanges)

        #expect(await model.activate(games.id, source: .manual) == false)
        #expect(model.presentedError?.title == "dock could not be switched")
        #expect(model.hasPendingSelectedChanges)
        let libraryBeforeDismissal = model.library
        model.presentedError = nil
        model.presentedErrorHost = nil

        #expect(model.library == libraryBeforeDismissal)
        #expect(model.library.activeProfile == previousActive)
        #expect(model.selectedProfileID == work.id)
        #expect(model.library.record(id: work.id)?.profile.items == savedItems)
        #expect(model.selectedItemIDs == selectedItemIDs)
        #expect(model.hasPendingSelectedChanges)
        #expect(model.saveFailureMessage == nil)
        #expect(!model.isApplying)
        #expect(model.applyingProfileID == nil)
        #expect(await preferences.writes.isEmpty)
        #expect(await reloader.attempts == 0)
    }

    @Test
    func dismissingReloadFailurePreservesPendingActiveDockEdits() async throws {
        try await withFixture(multipleWorkItems: true) { fixture in
            let model = fixture.model
            let previousActive = try #require(model.library.activeProfile)
            model.selectedProfileID = fixture.work.id
            await model.addSpacer(.small)
            let savedItems = try #require(model.selectedRecord?.profile.items)
            let selectedItemIDs = model.selectedItemIDs
            #expect(savedItems.count == fixture.work.items.count + 1)
            #expect(savedItems.last?.kind == .spacer(.small))
            #expect(model.hasPendingSelectedChanges)

            await fixture.reloader.failNextReload()
            #expect(await model.activate(fixture.reading.id, source: .manual) == false)
            #expect(model.presentedError?.title == "dock could not be switched")
            #expect(model.hasPendingSelectedChanges)
            let libraryBeforeDismissal = model.library
            model.presentedError = nil
            model.presentedErrorHost = nil

            #expect(model.library == libraryBeforeDismissal)
            #expect(model.library.activeProfile == previousActive)
            #expect(model.library.activeProfile?.appliedLayout == DockLayout(profile: fixture.work))
            #expect(model.selectedProfileID == fixture.work.id)
            #expect(model.library.record(id: fixture.work.id)?.profile.items == savedItems)
            #expect(model.selectedItemIDs == selectedItemIDs)
            #expect(model.hasPendingSelectedChanges)
            #expect(model.library.pendingApply == nil)
            #expect(model.reconciliation == nil)
            #expect(model.saveFailureMessage == nil)
            #expect(!model.isApplying)
            let persisted = try #require(try await fixture.store.load())
            #expect(persisted.activeProfile == previousActive)
            #expect(persisted.record(id: fixture.work.id)?.profile.items == savedItems)
            #expect(persisted.hasPendingChanges(profileID: fixture.work.id))
            let expected = try DockSnapshot.build(profile: fixture.work, localState: DockProfileLocalState()).snapshot
            #expect(await fixture.preferences.snapshot.hasSameLayout(as: expected))
            #expect(await fixture.preferences.writes.count == 2)
            #expect(await fixture.reloader.attempts == 2)
        }
    }

    @Test
    func unknownAppliedBaselineRequiresReconciliationBeforeActivation() async throws {
        try await withFixture(unknownAppliedBaseline: true) { fixture in
            let model = fixture.model
            if case .savedEditsConflict = model.reconciliation?.kind {} else {
                Issue.record("an unknown applied baseline must require reconciliation")
            }
            #expect(model.library.activeProfile?.appliedLayout == nil)
            #expect(model.library.profiles.count == 2)
            #expect(await model.activate(fixture.reading.id, source: .manual) == false)
            let writes = await fixture.preferences.writes
            #expect(writes.isEmpty)
        }
    }

    @Test
    func focusProcessorAllowsSelectionAndNewerManualActivationWhileMutationsStayFrozen() async throws {
        try await withFixture(usesFocusBridge: true) { fixture in
            let model = fixture.model
            let bridge = try #require(fixture.focusBridge)
            let request = try await bridge.requestActivation(profileID: fixture.reading.id)
            await fixture.reloader.pauseNextReload()
            let processing = Task { await model.processFocusRequests() }
            try await waitForPausedReload(fixture.reloader)

            model.selectedProfileID = fixture.reading.id
            #expect(model.selectedProfileID == fixture.reading.id)
            #expect(model.activationDisabled(for: fixture.work.id) == false)
            await model.addSpacer(.small)
            #expect(model.library.record(id: fixture.reading.id)?.profile.items == fixture.reading.items)
            let manual = Task { await model.activate(fixture.work.id, source: .manual) }
            await waitForQueuedStatus(model)
            #expect(model.statusMessage.contains("will switch next"))
            await fixture.reloader.resumePausedReload()
            #expect(await manual.value)
            await processing.value

            #expect(model.library.activeProfile?.profileID == fixture.work.id)
            #expect(model.library.activeProfile?.source == .manual)
            #expect(model.selectedProfileID == fixture.reading.id)
            #expect(model.library.lastHandledFocusRequest?.requestID == request.id)
            #expect(try await bridge.pendingRequests().isEmpty)
        }
    }

    @Test
    func completedFocusRequestIsAcknowledgedWhenLaterManualActivationRollsBack() async throws {
        try await withFixture(usesFocusBridge: true) { fixture in
            let model = fixture.model
            let bridge = try #require(fixture.focusBridge)
            let request = try await bridge.requestActivation(profileID: fixture.reading.id)
            await fixture.reloader.pauseNextReload()
            await fixture.reloader.failReload(attempt: 2)
            let processing = Task { await model.processFocusRequests() }
            try await waitForPausedReload(fixture.reloader)
            let manual = Task { await model.activate(fixture.work.id, source: .manual) }
            await waitForQueuedStatus(model)
            await fixture.reloader.resumePausedReload()
            #expect(await manual.value == false)
            await processing.value

            #expect(model.library.activeProfile?.profileID == fixture.reading.id)
            #expect(model.library.lastHandledFocusRequest?.requestID == request.id)
            #expect(try await bridge.pendingRequests().isEmpty)
            let reloads = await fixture.reloader.attempts
            #expect(reloads == 3)
            await model.processFocusRequests()
            #expect(await fixture.reloader.attempts == reloads)
        }
    }

    @Test
    func recoveryApprovalDoesNotLeakIntoQueuedManualActivation() async throws {
        try await withFixture(pendingRecovery: true, divergedRecovery: true) { fixture in
            let model = fixture.model
            await fixture.reloader.pauseNextReload()
            let recovery = Task { await model.restoreSavedDock() }
            try await waitForPausedReload(fixture.reloader)
            let manual = Task { await model.activate(fixture.work.id, source: .manual) }
            await waitForQueuedStatus(model)
            #expect(model.statusMessage.contains("will switch next"))
            await fixture.reloader.resumePausedReload()
            #expect(await manual.value)
            await recovery.value
            #expect(model.reconciliation == nil)
            #expect(model.library.activeProfile?.profileID == fixture.work.id)
            let reloads = await fixture.reloader.attempts
            #expect(reloads == 2)
        }
    }

    @Test
    func settingsExportRetainsItsHostUntilSheetDismissalAndReportsSuccess() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            let output = fixture.directory.appending(path: "selected.dockit")
            fixture.filePicker.url = output
            model.presentExport(from: .settings)
            await model.exportProfiles([fixture.work.id])
            #expect(model.exportPresented == false)
            #expect(model.transferPresentationHost == .settings)
            #expect(fixture.filePicker.requests.isEmpty)
            #expect(model.settingsTransferMessage == nil)
            #expect(model.finishTransferSheet(from: .management) == nil)
            let completion = try #require(model.finishTransferSheet(from: .settings))
            await completion.value
            #expect(model.settingsTransferMessage == "exported 1 dock.")
            #expect(fixture.filePicker.requests == [.exportProfiles(defaultName: "work.dockit")])
            let exported = try DockitArchive.decode(Data(contentsOf: output))
            #expect(exported.profiles.map(\.id) == [fixture.work.id])
            model.cancelExport()
            #expect(model.settingsTransferMessage == "exported 1 dock.")
            #expect(model.transferPresentationHost == nil)
            #expect(await fixture.preferences.writes.isEmpty)
        }
    }

    @Test
    func canceledSavePanelKeepsProfileSelectionOpenUntilUserCancelsExport() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            model.presentExport(from: .settings)
            await model.exportProfiles([fixture.work.id])
            #expect(model.exportPresented == false)
            #expect(fixture.filePicker.requests.isEmpty)
            let completion = try #require(model.finishTransferSheet(from: .settings))
            await completion.value
            #expect(model.exportPresented)
            #expect(model.transferPresentationHost == .settings)
            #expect(model.settingsTransferMessage == nil)
            model.cancelExport()
            #expect(model.exportPresented == false)
            #expect(model.settingsTransferMessage == "export canceled.")
            #expect(model.transferPresentationHost == .settings)
            model.finishTransferSheet(from: .settings)
            #expect(model.transferPresentationHost == nil)
            #expect(model.library.profiles.count == 2)
            #expect(await fixture.preferences.writes.isEmpty)
        }
    }

    @Test
    func exportSavePanelCannotStartBeforeDismissalOrStartTwice() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            fixture.filePicker.holdsResponse = true
            model.presentExport(from: .settings)
            await model.exportProfiles([fixture.work.id])
            #expect(fixture.filePicker.requests.isEmpty)
            #expect(model.exportPresented == false)
            let completion = try #require(model.finishTransferSheet(from: .settings))
            for _ in 0..<100 where fixture.filePicker.requests.isEmpty { await Task.yield() }
            #expect(fixture.filePicker.requests.count == 1)
            #expect(model.transferPresentationHost == .settings)
            #expect(model.finishTransferSheet(from: .settings) == nil)
            #expect(model.transferPresentationHost == .settings)
            fixture.filePicker.resume()
            await completion.value
            #expect(model.exportPresented)
            #expect(model.exportSelection == [fixture.work.id])
            model.cancelExport()
            model.finishTransferSheet(from: .settings)
        }
    }

    @Test
    func exportRetryAfterSaveCancellationPreservesCheckboxSelection() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            let selection: Set<UUID> = [fixture.work.id, fixture.reading.id]
            model.presentExport(from: .settings)
            await model.exportProfiles(selection)
            let canceled = try #require(model.finishTransferSheet(from: .settings))
            await canceled.value
            #expect(model.exportPresented)
            #expect(model.exportSelection == selection)

            let output = fixture.directory.appending(path: "retry.dockit")
            fixture.filePicker.url = output
            await model.exportProfiles(model.exportSelection)
            let completed = try #require(model.finishTransferSheet(from: .settings))
            await completed.value
            let archive = try DockitArchive.decode(Data(contentsOf: output))
            #expect(Set(archive.profiles.map(\.id)) == selection)
            #expect(fixture.filePicker.requests.count == 2)
            #expect(model.exportPresented == false)
            #expect(model.transferPresentationHost == nil)
            #expect(model.settingsTransferMessage == "exported 2 docks.")
        }
    }

    @Test
    func exportWriteFailureReopensSelectionWithRetryableInlineError() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            fixture.filePicker.url = fixture.directory.appending(path: "missing-directory/output.dockit")
            model.presentExport(from: .settings)
            await model.exportProfiles([fixture.reading.id])
            let completion = try #require(model.finishTransferSheet(from: .settings))
            await completion.value
            #expect(model.exportPresented)
            #expect(model.exportSelection == [fixture.reading.id])
            #expect(model.exportErrorMessage?.isEmpty == false)
            #expect(model.transferPresentationHost == .settings)
            #expect(model.settingsTransferMessage == nil)
            #expect(model.presentedError == nil)
            model.cancelExport()
            model.finishTransferSheet(from: .settings)
        }
    }

    @Test(arguments: ExportIngressStage.allCases)
    func finderOpenPreservesSettingsExportContext(_ stage: ExportIngressStage) async throws {
        try await withFixture { fixture in
            let model = fixture.model
            let input = fixture.directory.appending(path: "finder-request.dockit")
            try DockitArchive(profiles: [fixture.work]).encoded().write(to: input)
            model.presentExport(from: .settings)
            model.exportSelection = [fixture.reading.id]
            var completion: Task<Void, Never>?
            if stage != .selection {
                await model.exportProfiles(model.exportSelection)
            }
            if stage == .choosingLocation {
                fixture.filePicker.holdsResponse = true
                let panelTask: Task<Void, Never> = try #require(model.finishTransferSheet(from: .settings))
                completion = panelTask
                for _ in 0..<100 where fixture.filePicker.requests.isEmpty { await Task.yield() }
                #expect(fixture.filePicker.requests.count == 1)
            }

            await model.openImportURL(input).value
            #expect(model.transferPresentationHost == .settings)
            #expect(model.exportSelection == [fixture.reading.id])
            #expect(model.importPreview == nil)
            if stage == .awaitingDismissal {
                completion = model.finishTransferSheet(from: .settings)
                #expect(completion != nil)
            }
            fixture.filePicker.resume()
            await completion?.value
            #expect(model.exportPresented)
            model.cancelExport()
            model.finishTransferSheet(from: .settings)
        }
    }

    @Test
    func finderOpenDoesNotReplaceAnExistingSettingsImportPreview() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            let original = fixture.directory.appending(path: "original.dockit")
            let incoming = fixture.directory.appending(path: "incoming.dockit")
            try DockitArchive(profiles: [fixture.reading]).encoded().write(to: original)
            try DockitArchive(profiles: [fixture.work]).encoded().write(to: incoming)
            fixture.filePicker.url = original
            await model.importProfiles(from: .settings)
            let preview = try #require(model.importPreview)
            await model.openImportURL(incoming).value
            #expect(model.transferPresentationHost == .settings)
            #expect(model.importPreview?.id == preview.id)
            #expect(model.importPreview?.fileName == "original.dockit")
            #expect(model.library.profiles.count == 2)
            model.cancelImport()
            model.finishTransferSheet(from: .settings)
        }
    }

    @Test
    func canceledImportPanelReturnsToSettingsWithoutChangingLibrary() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            await model.importProfiles(from: .settings)
            #expect(fixture.filePicker.requests == [.importProfiles])
            #expect(model.importPreview == nil)
            #expect(model.transferPresentationHost == nil)
            #expect(model.settingsTransferMessage == "import canceled.")
            #expect(model.library.profiles.count == 2)
            #expect(await fixture.preferences.writes.isEmpty)
        }
    }

    @Test
    func settingsImportReportsSuccessAfterReviewAndPreservesSavedMissingApps() async throws {
        try await withFixture(includesUnavailableApp: true) { fixture in
            let model = fixture.model
            let name = "Research, writing, and deep work"
            model.renameProfile(fixture.reading.id, to: name)
            let existingBeforeImport = try #require(model.library.record(id: fixture.reading.id))
            let activeBeforeImport = model.library.activeProfile
            let lastKnownDockBeforeImport = model.library.lastKnownDock
            var source = fixture.reading
            source.name = name
            let input = fixture.directory.appending(path: "incoming.dockit")
            try DockitArchive(profiles: [source]).encoded().write(to: input)
            fixture.filePicker.url = input
            await model.importProfiles(from: .settings)
            let preview = try #require(model.importPreview)
            let previewProfile = try #require(preview.profiles.first)
            #expect(name.count == DockProfile.maximumNameLength)
            #expect(previewProfile.source.name == name)
            #expect(previewProfile.importedName == "Research, writing, and deep wo 2")
            #expect(previewProfile.importedName.count == DockProfile.maximumNameLength)
            #expect(previewProfile.source.items == source.items)
            #expect(preview.unavailableAppCount == 1)
            #expect(model.transferPresentationHost == .settings)
            #expect(model.library.record(id: fixture.reading.id) == existingBeforeImport)
            #expect(model.library.activeProfile == activeBeforeImport)
            #expect(model.library.lastKnownDock == lastKnownDockBeforeImport)
            await model.confirmImport(preview.id)
            #expect(model.importPreview == nil)
            #expect(model.transferPresentationHost == .settings)
            #expect(model.settingsTransferMessage == "imported 1 dock.")
            #expect(model.library.profiles.count == 3)
            let imported = try #require(model.library.profiles.last?.profile)
            #expect(imported.name == "Research, writing, and deep wo 2")
            #expect(imported.name.count == DockProfile.maximumNameLength)
            #expect(imported.items == source.items)
            #expect(model.library.record(id: fixture.reading.id) == existingBeforeImport)
            #expect(model.library.activeProfile == activeBeforeImport)
            #expect(model.library.lastKnownDock == lastKnownDockBeforeImport)
            model.cancelImport()
            #expect(model.settingsTransferMessage == "imported 1 dock.")
            model.finishTransferSheet(from: .settings)
            #expect(model.transferPresentationHost == nil)
            #expect(await fixture.preferences.writes.isEmpty)
        }
    }

    @Test
    func canceledImportReviewRetainsSettingsHostUntilDismissal() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            let input = fixture.directory.appending(path: "incoming.dockit")
            try DockitArchive(profiles: [fixture.reading]).encoded().write(to: input)
            fixture.filePicker.url = input
            await model.importProfiles(from: .settings)
            #expect(model.importPreview != nil)
            model.cancelImport()
            #expect(model.importPreview == nil)
            #expect(model.transferPresentationHost == .settings)
            #expect(model.settingsTransferMessage == "import canceled.")
            #expect(model.library.profiles.count == 2)
            model.finishTransferSheet(from: .settings)
            #expect(model.transferPresentationHost == nil)
            #expect(await fixture.preferences.writes.isEmpty)
        }
    }

    private func waitForPausedReload(_ reloader: ModelTestReloader) async throws {
        for _ in 0..<100 {
            if await reloader.isPaused { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await reloader.isPaused, "the fake reload must pause before inspecting the transaction")
    }

    private func waitForPausedWrite(_ control: WriteControl) async throws {
        for _ in 0..<100 {
            if control.isWritePaused { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(control.isWritePaused, "the fixture save must pause before checking reentrant edits")
    }

    private func waitForQueuedStatus(_ model: AppModel) async {
        for _ in 0..<100 where !model.statusMessage.contains("will switch next") { await Task.yield() }
    }

    private func waitForActivation(_ model: AppModel) async throws {
        for _ in 0..<100 where !model.isApplying { await Task.yield() }
        try #require(model.isApplying, "the activation must begin before testing in-flight state")
    }

    private func withFixture(
        pendingRecovery: Bool = false,
        failWritesAfterSeed: Bool = false,
        includesUnavailableApp: Bool = false,
        divergedRecovery: Bool = false,
        activeIncludesUnavailableApp: Bool = false,
        changedWhileClosed: Bool = false,
        unknownAppliedBaseline: Bool = false,
        usesFocusBridge: Bool = false,
        multipleWorkItems: Bool = false,
        _ body: @MainActor (AppModelFixture) async throws -> Void
    ) async throws {
        try #require(ProcessInfo.processInfo.environment["DOCKIT_DEMO"] == "1",
            "hosted tests must run with DOCKIT_DEMO=1")
        let fixture = try await AppModelFixture.make(
            pendingRecovery: pendingRecovery,
            failWritesAfterSeed: failWritesAfterSeed,
            includesUnavailableApp: includesUnavailableApp,
            divergedRecovery: divergedRecovery,
            activeIncludesUnavailableApp: activeIncludesUnavailableApp,
            changedWhileClosed: changedWhileClosed,
            unknownAppliedBaseline: unknownAppliedBaseline,
            usesFocusBridge: usesFocusBridge,
            multipleWorkItems: multipleWorkItems
        )
        do {
            try await body(fixture)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }
}

@Suite(.serialized)
@MainActor
struct InteractiveRecoveryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DOCKIT_INTERACTIVE_RECOVERY"] == "1"))
    func editorSaveFailureCanBeReviewedAndRetried() async throws {
        let environment = ProcessInfo.processInfo.environment
        try #require(environment["DOCKIT_DEMO"] == "1")
        try #require(environment["DOCKIT_TEST_HOST"] == "1")
        let expectedDirectory = URL(fileURLWithPath:
            "/Users/advegaf/Documents/ChatGPT/dockit/artifacts/reference-editor/interactive-recovery",
            isDirectory: true)
        let suppliedPath = try #require(environment["DOCKIT_INTERACTIVE_RECOVERY_DIR"])
        let directory = URL(fileURLWithPath: suppliedPath, isDirectory: true).standardizedFileURL
        try #require(directory.path == expectedDirectory.path)
        try #require(directory.resolvingSymlinksInPath().path == expectedDirectory.path)
        try #require(try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        let reportURL = directory.appending(path: "state.json")
        try #require(!FileManager.default.fileExists(atPath: reportURL.path),
            "archive the previous interactive recovery report before starting a new run")

        DockMenuCoordinator.shared.presentMainWindow()
        let window = try await presentedManagementWindow()
        let originalController = window.contentViewController
        let originalView = window.contentView
        let originalTitle = window.title
        let originalIdentifier = window.identifier
        let originalFrame = window.frame
        let originalAppearance = NSApp.appearance
        let fixture = try await AppModelFixture.make(
            pendingRecovery: false,
            failWritesAfterSeed: true,
            includesUnavailableApp: false,
            divergedRecovery: false,
            activeIncludesUnavailableApp: false,
            changedWhileClosed: false,
            unknownAppliedBaseline: false,
            usesFocusBridge: false,
            multipleWorkItems: true
        )
        let fixtureController = NSHostingController(
            rootView: ContentView(model: fixture.model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(EditorWindowLayout())
        )
        window.title = "dockit recovery test"
        window.identifier = NSUserInterfaceItemIdentifier("management")
        window.contentViewController = fixtureController
        var restoredWindow = false
        func restoreWindow() {
            guard !restoredWindow else { return }
            window.contentViewController = originalController
            if originalController == nil { window.contentView = originalView }
            window.title = originalTitle
            window.identifier = originalIdentifier
            window.setFrame(originalFrame, display: true)
            restoredWindow = true
        }
        defer {
            restoreWindow()
            NSApp.appearance = originalAppearance
        }
        let baseline = fixture.model.library
        let libraryURL = fixture.directory.appending(path: "library.json")
        let signalDirectory = fixture.directory.resolvingSymlinksInPath()
        let allowURL = signalDirectory.appending(path: "allow-writes.signal")
        let finishURL = signalDirectory.appending(path: "finish.signal")
        let token = UUID().uuidString
        var report: RecoveryReport?
        do {
            for url in [allowURL, finishURL] {
                try #require(!FileManager.default.fileExists(atPath: url.path))
            }
            let baselineBytes = try Data(contentsOf: libraryURL)
            let deadline = ContinuousClock.now.advanced(by: .seconds(540))
            var observedRejectedSave = false
            var finished = false
            window.makeKeyAndOrderFront(nil)
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                try #require(directory.resolvingSymlinksInPath().path == expectedDirectory.path)
                let allowWrites = try signalMatches(allowURL, token: token, directory: signalDirectory)
                fixture.writeControl.rejectWrites = !allowWrites
                let currentBytes = try Data(contentsOf: libraryURL)
                let persisted = try #require(try await fixture.store.load())
                let model = fixture.model
                if !allowWrites, model.saveFailureMessage != nil,
                   model.library != baseline, currentBytes == baselineBytes {
                    observedRejectedSave = true
                }
                let finishRequested = try signalMatches(finishURL, token: token, directory: signalDirectory)
                report = RecoveryReport(
                    token: token, updatedAt: Date(), phase: "running", failure: nil,
                    fixtureDirectory: fixture.directory.path,
                    signalDirectory: signalDirectory.path,
                    targetWindowNumber: window.windowNumber,
                    windows: NSApp.windows.map { candidate in
                        RecoveryWindowReport(
                            number: candidate.windowNumber,
                            title: candidate.title,
                            identifier: candidate.identifier?.rawValue,
                            isKey: candidate.isKeyWindow,
                            isVisible: candidate.isVisible,
                            isFixtureWindow: candidate === window,
                            hostsFixtureContent: candidate.contentViewController === fixtureController
                        )
                    },
                    baseline: baseline, baselineBytes: baselineBytes,
                    library: model.library, diskLibrary: persisted, diskBytes: currentBytes,
                    writesAllowed: allowWrites, observedRejectedSave: observedRejectedSave,
                    finishRequested: finishRequested,
                    saveFailureMessage: model.saveFailureMessage,
                    alertTitle: model.presentedError?.title,
                    statusMessage: model.statusMessage,
                    activationDisabled: model.activationDisabled(for: fixture.work.id),
                    pendingChanges: model.hasPendingSelectedChanges,
                    writeAttempts: fixture.writeControl.writeAttempts,
                    dockWrites: await fixture.preferences.writes.count,
                    reloads: await fixture.reloader.attempts,
                    windowRestored: false,
                    cleanupSucceeded: false
                )
                try writeReport(try #require(report), to: reportURL)
                if finishRequested {
                    try #require(window.contentViewController === fixtureController,
                        "the recovery fixture must remain attached to the management window")
                    try #require(observedRejectedSave, "a failed save must retain edited memory and original disk bytes")
                    try #require(allowWrites)
                    try #require(model.saveFailureMessage == nil)
                    try #require(model.presentedError == nil)
                    try #require(model.statusMessage == "changes saved.", "the buffered edit must be recovered through retry saving")
                    try #require(persisted == model.library)
                    try #require(persisted.record(id: fixture.work.id)?.profile.items != fixture.work.items)
                    try #require(model.hasPendingSelectedChanges)
                    try #require(model.library.activeProfile == baseline.activeProfile)
                    try #require(model.library.lastKnownDock == baseline.lastKnownDock)
                    try #require(await fixture.preferences.writes.isEmpty)
                    try #require(await fixture.reloader.attempts == 0)
                    report?.phase = "verified"
                    finished = true
                    break
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            try #require(finished, "interactive recovery timed out after nine minutes without a verified finish")
            restoreWindow()
            report?.windowRestored = window.contentViewController === originalController
                && window.title == originalTitle && window.identifier == originalIdentifier
            try #require(report?.windowRestored == true)
            await fixture.close()
            report?.cleanupSucceeded = !FileManager.default.fileExists(atPath: fixture.directory.path)
            try #require(report?.cleanupSucceeded == true)
            try writeReport(try #require(report), to: reportURL)
        } catch {
            restoreWindow()
            await fixture.close()
            report?.phase = "failed"
            report?.failure = String(describing: error)
            report?.windowRestored = window.contentViewController === originalController
                && window.title == originalTitle && window.identifier == originalIdentifier
            report?.cleanupSucceeded = !FileManager.default.fileExists(atPath: fixture.directory.path)
            if let report { try? writeReport(report, to: reportURL) }
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
            throw error
        }
    }

    private func presentedManagementWindow() async throws -> NSWindow {
        for _ in 0..<200 {
            if let window = NSApp.windows.first(where: {
                $0.identifier?.rawValue == "management" && $0.isVisible
            }) {
                return window
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let windows = NSApp.windows.map {
            "\($0.windowNumber) title=\($0.title) identifier=\($0.identifier?.rawValue ?? "nil") key=\($0.isKeyWindow) visible=\($0.isVisible)"
        }
        Issue.record("the shared presenter did not make a management window key. windows=\(windows)")
        throw InteractiveRecoverySetupFailure.managementWindowNotPresented
    }

    private func signalMatches(_ url: URL, token: String, directory: URL) throws -> Bool {
        try #require(url.deletingLastPathComponent().path == directory.path)
        try #require(url.resolvingSymlinksInPath().path == url.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        try #require(values.isRegularFile == true && values.isSymbolicLink != true)
        return try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == token
    }

    private func writeReport(_ report: RecoveryReport, to url: URL) throws {
        try #require(url.resolvingSymlinksInPath().path == url.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    private struct RecoveryReport: Codable {
        let token: String
        let updatedAt: Date
        var phase: String
        var failure: String?
        let fixtureDirectory: String
        let signalDirectory: String
        let targetWindowNumber: Int
        let windows: [RecoveryWindowReport]
        let baseline: DockLibrary
        let baselineBytes: Data
        let library: DockLibrary
        let diskLibrary: DockLibrary
        let diskBytes: Data
        let writesAllowed: Bool
        let observedRejectedSave: Bool
        let finishRequested: Bool
        let saveFailureMessage: String?
        let alertTitle: String?
        let statusMessage: String
        let activationDisabled: Bool
        let pendingChanges: Bool
        let writeAttempts: Int
        let dockWrites: Int
        let reloads: Int
        var windowRestored: Bool
        var cleanupSucceeded: Bool
    }

    private struct RecoveryWindowReport: Codable {
        let number: Int
        let title: String
        let identifier: String?
        let isKey: Bool
        let isVisible: Bool
        let isFixtureWindow: Bool
        let hostsFixtureContent: Bool
    }

    private enum InteractiveRecoverySetupFailure: Error {
        case managementWindowNotPresented
    }
}

enum ExportIngressStage: CaseIterable, Sendable {
    case selection
    case awaitingDismissal
    case choosingLocation
}

enum DropInterruption: CaseIterable, Sendable {
    case changedLayout
    case changedSelection
    case removedProfile
    case applying
    case reconciling
    case cancelled
}

enum InvalidDropRequest: CaseIterable, Sendable {
    case emptySelection
    case duplicateItem
    case unknownItem
    case partlyUnknownSelection
    case unknownTarget
    case movingTarget
    case missingProfile
}

@MainActor
private final class ActivationResultProbe {
    var value: Bool?
}

@MainActor
private struct AppModelFixture {
    var directory: URL
    var writeControl: WriteControl
    var store: DockLibraryStore
    var model: AppModel
    var preferences: ModelTestPreferences
    var reloader: ModelTestReloader
    var focusBridge: FocusBridgeStore?
    var filePicker: ModelTestFilePicker
    var work: DockProfile
    var reading: DockProfile
    var readingSnapshot: DockSnapshot

    static func make(
        pendingRecovery: Bool,
        failWritesAfterSeed: Bool,
        includesUnavailableApp: Bool,
        divergedRecovery: Bool,
        activeIncludesUnavailableApp: Bool,
        changedWhileClosed: Bool,
        unknownAppliedBaseline: Bool,
        usesFocusBridge: Bool,
        multipleWorkItems: Bool
    ) async throws -> AppModelFixture {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "dockit-app-model-\(UUID().uuidString)", directoryHint: .isDirectory)
        let writeControl = WriteControl()
        let store = DockLibraryStore(fileURL: directory.appending(path: "library.json"),
            fileManager: ToggleWriteFileManager(control: writeControl))
        var work = DockProfile(name: "work", color: .blue, items: [DockItem(kind: .spacer(.small))])
        var reading = DockProfile(name: "reading", color: .green, items: [DockItem(kind: .spacer(.regular))])
        if multipleWorkItems {
            work.items.append(contentsOf: [SpacerSize.regular, .small, .regular].map { DockItem(kind: .spacer($0)) })
        }
        if includesUnavailableApp {
            reading.items.append(DockItem(kind: .application(DockApp(
                bundleIdentifier: "test.dockit.missing-app",
                path: directory.appending(path: "Missing App.app").path,
                displayName: "Missing App"
            ))))
        }
        if activeIncludesUnavailableApp {
            work.items.append(DockItem(kind: .application(DockApp(
                bundleIdentifier: "test.dockit.missing-active-app",
                path: directory.appending(path: "Missing Active App.app").path,
                displayName: "Missing Active App"
            ))))
        }
        let workSnapshot = try DockSnapshot.build(profile: work, localState: DockProfileLocalState()).snapshot
        let readingSnapshot = try DockSnapshot.build(profile: reading, localState: DockProfileLocalState()).snapshot
        var library = DockLibrary(
            profiles: [work, reading].map { DockProfileRecord(profile: $0) },
            selectedProfileID: work.id,
            activeProfile: ActiveProfile(profileID: work.id, source: .manual, appliedLayout: DockLayout(profile: work)),
            lastKnownDock: workSnapshot
        )
        if unknownAppliedBaseline { library.activeProfile?.appliedLayout = nil }
        if pendingRecovery {
            library.pendingApply = PendingDockApply(
                profileID: reading.id, source: .manual,
                previousSnapshot: workSnapshot, intendedSnapshot: readingSnapshot,
                intendedLayout: DockLayout(profile: reading)
            )
        }
        try await store.save(library)
        writeControl.rejectWrites = failWritesAfterSeed
        let initialSnapshot: DockSnapshot
        if divergedRecovery {
            initialSnapshot = try DockSnapshot(rawTiles: [])
        } else if pendingRecovery || changedWhileClosed {
            initialSnapshot = readingSnapshot
        } else {
            initialSnapshot = workSnapshot
        }
        let preferences = ModelTestPreferences(snapshot: initialSnapshot)
        let reloader = ModelTestReloader()
        let focusBridge = try usesFocusBridge
            ? FocusBridgeStore(directoryURL: directory.appending(path: "focus", directoryHint: .isDirectory))
            : nil
        try await focusBridge?.publish(library)
        let filePicker = ModelTestFilePicker()
        let model = AppModel(environment: [:], store: store, preferences: preferences,
            reloader: reloader, integratesWithSystem: false, focusBridge: focusBridge,
            transferFilePicker: { request, _ in
                await filePicker.choose(request)
            })
        await model.load()
        return AppModelFixture(directory: directory, writeControl: writeControl, store: store, model: model,
            preferences: preferences, reloader: reloader, focusBridge: focusBridge,
            filePicker: filePicker, work: work, reading: reading, readingSnapshot: readingSnapshot)
    }

    func close() async {
        writeControl.resumePausedWrite()
        writeControl.rejectWrites = false
        filePicker.resume()
        await reloader.resumePausedReload()
        _ = await model.flushBeforeTermination()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class ModelTestFilePicker {
    var url: URL?
    var requests: [AppModel.TransferFileRequest] = []
    var holdsResponse = false
    private var pendingResponse: CheckedContinuation<Void, Never>?

    func choose(_ request: AppModel.TransferFileRequest) async -> URL? {
        requests.append(request)
        if holdsResponse { await withCheckedContinuation { pendingResponse = $0 } }
        return url
    }

    func resume() {
        holdsResponse = false
        pendingResponse?.resume()
        pendingResponse = nil
    }
}

private final class WriteControl: @unchecked Sendable {
    private let lock = NSLock()
    private var rejectionEnabled = false
    private var attemptCount = 0
    private var nextWritePause: DispatchSemaphore?
    private var pausedWrite: DispatchSemaphore?

    var writeAttempts: Int { lock.withLock { attemptCount } }
    var isWritePaused: Bool { lock.withLock { pausedWrite != nil } }

    var rejectWrites: Bool {
        get { lock.withLock { rejectionEnabled } }
        set { lock.withLock { rejectionEnabled = newValue } }
    }

    func recordAttempt() throws {
        let pause = lock.withLock {
            attemptCount += 1
            let pause = nextWritePause
            nextWritePause = nil
            pausedWrite = pause
            return pause
        }
        pause?.wait()
        if rejectWrites { throw CocoaError(.fileWriteNoPermission) }
    }

    func pauseNextWrite() {
        lock.withLock { nextWritePause = DispatchSemaphore(value: 0) }
    }

    func resumePausedWrite() {
        let pause = lock.withLock {
            let pause = pausedWrite
            pausedWrite = nil
            nextWritePause = nil
            return pause
        }
        pause?.signal()
    }
}

private final class ToggleWriteFileManager: FileManager, @unchecked Sendable {
    private let control: WriteControl

    init(control: WriteControl) {
        self.control = control
        super.init()
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        if createIntermediates { try control.recordAttempt() }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}

private actor ModelTestPreferences: DockPreferencesServing {
    private(set) var snapshot: DockSnapshot
    private(set) var writes: [DockSnapshot] = []

    init(snapshot: DockSnapshot) {
        self.snapshot = snapshot
    }

    func assertMutable() {}

    func readPersistentApps() -> DockSnapshot { snapshot }

    func writePersistentApps(_ snapshot: DockSnapshot) {
        self.snapshot = snapshot
        writes.append(snapshot)
    }

    func setExternalSnapshot(_ snapshot: DockSnapshot) {
        self.snapshot = snapshot
    }
}

private actor ModelTestReloader: DockReloading {
    private(set) var attempts = 0
    private var failureCount = 0
    private var failingAttempts: Set<Int> = []
    private var shouldPause = false
    private var pausedReload: CheckedContinuation<Void, Never>?

    var isPaused: Bool { pausedReload != nil }

    func reload() async throws -> DockReloadResult {
        attempts += 1
        if shouldPause {
            shouldPause = false
            await withCheckedContinuation { pausedReload = $0 }
        }
        if failureCount > 0 || failingAttempts.remove(attempts) != nil {
            failureCount = max(0, failureCount - 1)
            throw ModelTestFailure.reloadFailed
        }
        return DockReloadResult(previousProcessIdentifier: 1, currentProcessIdentifier: 2)
    }

    func failNextReload() { failureCount += 1 }

    func failReload(attempt: Int) { failingAttempts.insert(attempt) }

    func pauseNextReload() { shouldPause = true }

    func resumePausedReload() {
        pausedReload?.resume()
        pausedReload = nil
    }
}

private enum ModelTestFailure: Error {
    case reloadFailed
}
