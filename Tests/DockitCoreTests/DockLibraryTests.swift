import Foundation
import Testing
@testable import DockitCore

@Test func finalProfileCannotBeDeleted() throws {
    let profile = DockProfile(name: "Only", color: .blue, items: [])
    var library = DockLibrary(profiles: [DockProfileRecord(profile: profile)], selectedProfileID: profile.id)

    #expect(throws: DockLibraryError.finalProfile) {
        try library.delete(id: profile.id)
    }
}

@Test func duplicateIsIndependentAndGetsAnAvailableName() throws {
    let item = DockItem(kind: .spacer(.regular))
    let profile = DockProfile(name: "Work", color: .blue, items: [item])
    var library = DockLibrary(profiles: [DockProfileRecord(profile: profile)], selectedProfileID: profile.id)
    let duplicateID = try library.duplicate(id: profile.id)

    var duplicate = try #require(library.record(id: duplicateID))
    duplicate.profile.items = []
    try library.replace(duplicate)

    #expect(library.record(id: profile.id)?.profile.items == [item])
    #expect(library.record(id: duplicateID)?.profile.name == "Work copy")
}

@Test func archiveExcludesLocalRawTilesAndRenamesCollisions() throws {
    let raw = DockRawTile(propertyListData: Data([1, 2, 3]))
    let item = DockItem(kind: .spacer(.regular))
    let profile = DockProfile(name: "Reading", color: .green, items: [item])
    let source = DockLibrary(
        profiles: [DockProfileRecord(
            profile: profile,
            localState: DockProfileLocalState(rawTiles: [item.id: raw])
        )],
        lastHandledFocusRequest: FocusRequestWatermark(
            requestID: UUID(),
            createdAt: Date(timeIntervalSince1970: 100)
        )
    )
    let archive = try DockitArchive(library: source, profileIDs: [profile.id])
    let data = try archive.encoded()

    #expect(!String(decoding: data, as: UTF8.self).contains("propertyListData"))
    #expect(!String(decoding: data, as: UTF8.self).contains("lastHandledFocusRequest"))

    var destination = DockLibrary(profiles: [DockProfileRecord(profile: profile)])
    let imported = try destination.appendImported(DockitArchive.decode(data))
    #expect(destination.record(id: try #require(imported.first))?.profile.name == "Reading 2")
}

@Test func invalidArchiveLeavesLibraryUntouched() throws {
    let profile = DockProfile(name: "Work", color: .blue, items: [])
    let library = DockLibrary(profiles: [DockProfileRecord(profile: profile)])
    let original = library

    #expect(throws: DockitArchiveError.invalidFile) {
        _ = try DockitArchive.decode(Data("not json".utf8))
    }
    #expect(library == original)
}

@Test func archiveRejectsDuplicateItemIdentifiers() throws {
    let identifier = UUID()
    let profile = DockProfile(name: "Broken", color: .red, items: [
        DockItem(id: identifier, kind: .spacer(.regular)),
        DockItem(id: identifier, kind: .spacer(.small)),
    ])

    #expect(throws: DockitArchiveError.duplicateItemIdentifier) {
        try DockitArchive(profiles: [profile]).validate()
    }
}

@Test func archiveRejectsInvalidAppEntries() throws {
    let profile = DockProfile(name: "Broken", color: .red, items: [
        DockItem(kind: .application(DockApp(
            bundleIdentifier: "",
            path: "/Applications/Test.app",
            displayName: "Test"
        ))),
    ])

    #expect(throws: DockitArchiveError.invalidApp) {
        try DockitArchive(profiles: [profile]).validate()
    }
}

@Test func libraryRejectsWhitespaceOnlyNames() throws {
    let profile = DockProfile(name: "   ", color: .gray, items: [])
    let library = DockLibrary(profiles: [DockProfileRecord(profile: profile)])

    #expect(throws: DockLibraryError.emptyProfileName) {
        _ = try library.validated()
    }
}

@Test func libraryAndArchiveRejectNamesBeyondTheMenuLimit() throws {
    let name = String(repeating: "A", count: DockProfile.maximumNameLength + 1)
    let profile = DockProfile(name: name, color: .blue, items: [])
    let library = DockLibrary(profiles: [DockProfileRecord(profile: profile)])

    #expect(throws: DockLibraryError.profileNameTooLong) {
        _ = try library.validated()
    }
    #expect(throws: DockitArchiveError.profileNameTooLong) {
        try DockitArchive(profiles: [profile]).validate()
    }
}

@Test func profileNamesCountExtendedGraphemeClusters() throws {
    let cluster = "👩🏽‍💻"
    let accepted = String(repeating: cluster, count: DockProfile.maximumNameLength)
    let rejected = accepted + cluster

    try DockProfile.validateName(accepted)
    #expect(throws: DockProfileNameError.tooLong(maximum: DockProfile.maximumNameLength)) {
        try DockProfile.validateName(rejected)
    }
}

@Test func invalidNamesAreRejectedWithoutChangingStoredText() throws {
    let name = String(repeating: "A", count: DockProfile.maximumNameLength + 1)
    let profile = DockProfile(name: name, color: .blue, items: [])
    let library = DockLibrary(profiles: [DockProfileRecord(profile: profile)])

    #expect(throws: DockLibraryError.profileNameTooLong) {
        _ = try library.validated()
    }
    #expect(profile.name == name)
}

@Test func duplicateCollisionNamesStayWithinTheMenuLimit() throws {
    let name = String(repeating: "A", count: DockProfile.maximumNameLength)
    let profile = DockProfile(name: name, color: .blue, items: [])
    var library = DockLibrary(profiles: [DockProfileRecord(profile: profile)])

    let duplicateID = try library.duplicate(id: profile.id)
    let duplicateName = try #require(library.record(id: duplicateID)?.profile.name)

    #expect(duplicateName.count == DockProfile.maximumNameLength)
    #expect(duplicateName != name)
    #expect(duplicateName.hasSuffix(" 2"))
}

@Test func duplicateFitsItsGeneratedNameWithoutChangingTheOriginal() throws {
    let name = String(repeating: "A", count: DockProfile.maximumNameLength)
    let profile = DockProfile(name: name, color: .blue, items: [])
    var library = DockLibrary(profiles: [DockProfileRecord(profile: profile)])

    let duplicateID = try library.duplicate(id: profile.id)
    let duplicate = try #require(library.record(id: duplicateID)?.profile.name)

    #expect(library.record(id: profile.id)?.profile.name == name)
    #expect(duplicate.count == DockProfile.maximumNameLength)
    #expect(duplicate.hasSuffix(" 2"))
}

@Test func libraryStoreHidesFilesystemDetailsOnWriteFailure() async throws {
    let store = DockLibraryStore(fileURL: URL(fileURLWithPath: "/dev/null/library.json"))
    let profile = DockProfile(name: "Local", color: .blue, items: [])
    let library = DockLibrary(profiles: [DockProfileRecord(profile: profile)])

    await #expect(throws: DockLibraryStoreError.unwritable) {
        try await store.save(library)
    }
}

@Test func unreadableLibraryIsLeftByteForByteUnchanged() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let file = directory.appending(path: "library.json")
    let bytes = Data("damaged Dockit library".utf8)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try bytes.write(to: file)
    let store = DockLibraryStore(fileURL: file)

    await #expect(throws: DockLibraryStoreError.unreadable) {
        _ = try await store.load()
    }
    #expect(try Data(contentsOf: file) == bytes)
}

@Test func importRetainsUnavailableAppsWithoutChangingActiveDockState() throws {
    let current = DockProfile(name: "Current", color: .blue, items: [])
    let snapshot = try DockSnapshot(rawTiles: [])
    let missingApp = DockApp(
        bundleIdentifier: "com.example.unavailable",
        path: "/Applications/Unavailable Dockit Test.app",
        displayName: "Unavailable Dockit Test"
    )
    let imported = DockProfile(
        name: "Travel",
        color: .orange,
        items: [DockItem(kind: .application(missingApp))]
    )
    let archive = DockitArchive(profiles: [imported])
    var library = DockLibrary(
        profiles: [DockProfileRecord(profile: current)],
        selectedProfileID: current.id,
        activeProfile: ActiveProfile(profileID: current.id, source: .manual),
        lastKnownDock: snapshot
    )

    let identifiers = try library.appendImported(archive)
    let importedID = try #require(identifiers.first)
    let importedRecord = try #require(library.record(id: importedID))

    #expect(importedRecord.profile.items.first?.kind == .application(missingApp))
    #expect(library.activeProfile?.profileID == current.id)
    #expect(library.lastKnownDock == snapshot)
    #expect(library.pendingApply == nil)
}

@Test func importAssignsEachCollidingNameInArchiveOrder() throws {
    let existing = DockProfile(name: "Reading", color: .blue, items: [])
    let first = DockProfile(name: "Reading", color: .green, items: [])
    let second = DockProfile(name: "Reading", color: .purple, items: [])
    var library = DockLibrary(profiles: [DockProfileRecord(profile: existing)])

    let identifiers = try library.appendImported(DockitArchive(profiles: [first, second]))
    let names = identifiers.compactMap { library.record(id: $0)?.profile.name }

    #expect(names == ["Reading 2", "Reading 3"])
}

@Test func importedMaximumLengthCollisionFitsSuffixAndPreservesLibraryState() throws {
    let name = "Research, writing, and deep work"
    let existing = DockProfile(
        name: name,
        color: .blue,
        items: [DockItem(kind: .spacer(.small))]
    )
    let snapshot = try DockSnapshot(rawTiles: [])
    let active = ActiveProfile(
        profileID: existing.id,
        source: .manual,
        appliedAt: Date(timeIntervalSince1970: 100),
        appliedLayout: DockLayout(profile: existing)
    )
    let importedItems = [
        DockItem(kind: .spacer(.regular)),
        DockItem(kind: .application(DockApp(
            bundleIdentifier: "com.example.unavailable",
            path: "/Applications/Unavailable Dockit Test.app",
            displayName: "Unavailable Dockit Test"
        ))),
        DockItem(kind: .spacer(.small)),
    ]
    let imported = DockProfile(name: name, color: .green, items: importedItems)
    var library = DockLibrary(
        profiles: [DockProfileRecord(profile: existing)],
        selectedProfileID: existing.id,
        activeProfile: active,
        lastKnownDock: snapshot
    )
    let existingBeforeImport = library.record(id: existing.id)

    let identifiers = try library.appendImported(DockitArchive(profiles: [imported]))
    let importedID = try #require(identifiers.first)
    let importedProfile = try #require(library.record(id: importedID)?.profile)

    #expect(name.count == DockProfile.maximumNameLength)
    #expect(importedProfile.name == "Research, writing, and deep wo 2")
    #expect(importedProfile.name.count == DockProfile.maximumNameLength)
    #expect(importedProfile.items == importedItems)
    #expect(library.record(id: existing.id) == existingBeforeImport)
    #expect(library.activeProfile == active)
    #expect(library.lastKnownDock == snapshot)
    #expect(library.pendingApply == nil)
}

@Test func libraryStorePersistsLocallyWithRestrictedPermissions() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let file = directory.appending(path: "library.json")
    let store = DockLibraryStore(fileURL: file)
    let profile = DockProfile(name: "Local", color: .teal, items: [])
    let library = DockLibrary(profiles: [DockProfileRecord(profile: profile)], selectedProfileID: profile.id)

    try await store.save(library)
    let loaded = try await store.load()
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber

    #expect(loaded == library)
    #expect(permissions?.intValue == 0o600)
}

@Test func libraryStorePersistsFocusWatermark() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let file = directory.appending(path: "library.json")
    let store = DockLibraryStore(fileURL: file)
    let watermark = FocusRequestWatermark(
        requestID: UUID(),
        createdAt: Date(timeIntervalSince1970: 5_000)
    )
    let library = DockLibrary(lastHandledFocusRequest: watermark)

    try await store.save(library)

    #expect(try await store.load()?.lastHandledFocusRequest == watermark)
}

@Test func legacyLibraryWithoutFocusWatermarkDecodesAsNil() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let file = directory.appending(path: "library.json")
    let store = DockLibraryStore(fileURL: file)
    let encoded = try JSONEncoder().encode(DockLibrary())
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "lastHandledFocusRequest")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: object).write(to: file)

    #expect(try await store.load()?.lastHandledFocusRequest == nil)
}

@Test func dockLayoutEqualityUsesOnlyOrderedDockIdentity() throws {
    let createdAt = Date(timeIntervalSince1970: 100)
    let first = DockProfile(
        name: "work",
        color: .blue,
        items: [
            DockItem(kind: .application(DockApp(
                bundleIdentifier: "com.example.editor",
                path: "/Applications/Editor.app",
                displayName: "editor"
            ))),
            DockItem(kind: .spacer(.small)),
        ],
        createdAt: createdAt,
        updatedAt: createdAt
    )
    let sameLayout = DockProfile(
        name: "personal",
        color: .red,
        items: [
            DockItem(kind: .application(DockApp(
                bundleIdentifier: "com.example.editor",
                path: "/Applications/Editor.app",
                displayName: "renamed editor"
            ))),
            DockItem(kind: .spacer(.small)),
        ],
        createdAt: Date(timeIntervalSince1970: 200),
        updatedAt: Date(timeIntervalSince1970: 300)
    )

    #expect(DockLayout(profile: first) == DockLayout(profile: sameLayout))

    var changedBundle = sameLayout
    changedBundle.items[0].kind = .application(DockApp(
        bundleIdentifier: "com.example.other",
        path: "/Applications/Editor.app",
        displayName: "editor"
    ))
    #expect(DockLayout(profile: first) != DockLayout(profile: changedBundle))

    var changedOrder = sameLayout
    changedOrder.items.reverse()
    #expect(DockLayout(profile: first) != DockLayout(profile: changedOrder))

    var changedSpacer = sameLayout
    changedSpacer.items[1].kind = .spacer(.regular)
    #expect(DockLayout(profile: first) != DockLayout(profile: changedSpacer))
}

@Test func v1MigrationPreservesProfilesAndInfersAFullBaselineFromAvailableItems() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let availableAppURL = directory.appending(path: "Available.app", directoryHint: .isDirectory)
    let missingAppURL = directory.appending(path: "Missing.app", directoryHint: .isDirectory)
    let file = directory.appending(path: "library.json")
    try FileManager.default.createDirectory(at: availableAppURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let profile = DockProfile(
        id: UUID(),
        name: "legacy",
        color: .teal,
        items: [
            DockItem(kind: .application(DockApp(
                bundleIdentifier: "com.example.available",
                path: availableAppURL.path,
                displayName: "available"
            ))),
            DockItem(kind: .spacer(.regular)),
            DockItem(kind: .application(DockApp(
                bundleIdentifier: "com.example.missing",
                path: missingAppURL.path,
                displayName: "missing"
            ))),
        ],
        createdAt: Date(timeIntervalSince1970: 1_000),
        updatedAt: Date(timeIntervalSince1970: 2_000)
    )
    let record = DockProfileRecord(profile: profile)
    let snapshot = try DockSnapshot.build(profile: profile, localState: record.localState).snapshot
    let legacy = DockLibrary(
        schemaVersion: 1,
        profiles: [record],
        selectedProfileID: profile.id,
        activeProfile: ActiveProfile(
            profileID: profile.id,
            source: .manual,
            appliedAt: Date(timeIntervalSince1970: 3_000)
        ),
        lastKnownDock: snapshot
    )
    try JSONEncoder().encode(legacy).write(to: file)

    let loaded = try #require(await DockLibraryStore(fileURL: file).load())

    #expect(loaded.schemaVersion == 2)
    #expect(loaded.profiles == [record])
    #expect(loaded.activeProfile?.appliedLayout == DockLayout(profile: profile))
    let persisted = try JSONDecoder().decode(DockLibrary.self, from: Data(contentsOf: file))
    #expect(persisted.schemaVersion == 2)
    #expect(persisted.activeProfile?.appliedLayout == DockLayout(profile: profile))
}

@Test func v1MigrationLeavesTheAppliedLayoutUnknownWhenTheDockDoesNotMatch() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let availableAppURL = directory.appending(path: "Available.app", directoryHint: .isDirectory)
    let file = directory.appending(path: "library.json")
    try FileManager.default.createDirectory(at: availableAppURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let profile = DockProfile(name: "legacy", color: .blue, items: [
        DockItem(kind: .application(DockApp(
            bundleIdentifier: "com.example.available",
            path: availableAppURL.path,
            displayName: "available"
        ))),
    ])
    let legacy = DockLibrary(
        schemaVersion: 1,
        profiles: [DockProfileRecord(profile: profile)],
        activeProfile: ActiveProfile(profileID: profile.id, source: .manual),
        lastKnownDock: try DockSnapshot(rawTiles: [])
    )
    try JSONEncoder().encode(legacy).write(to: file)

    let loaded = try #require(await DockLibraryStore(fileURL: file).load())

    #expect(loaded.schemaVersion == 2)
    #expect(loaded.activeProfile?.appliedLayout == nil)
}

@Test func oldPendingTransactionMigratesWithoutInventingAnIntendedLayout() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let file = directory.appending(path: "library.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let profile = DockProfile(name: "legacy", color: .gray, items: [])
    let snapshot = try DockSnapshot(rawTiles: [])
    let pending = PendingDockApply(
        profileID: profile.id,
        source: .manual,
        previousSnapshot: snapshot,
        intendedSnapshot: snapshot,
        startedAt: Date(timeIntervalSince1970: 4_000)
    )
    let legacy = DockLibrary(
        schemaVersion: 1,
        profiles: [DockProfileRecord(profile: profile)],
        activeProfile: ActiveProfile(profileID: profile.id, source: .manual),
        lastKnownDock: snapshot,
        pendingApply: pending
    )
    try JSONEncoder().encode(legacy).write(to: file)

    let loaded = try #require(await DockLibraryStore(fileURL: file).load())

    #expect(loaded.pendingApply?.profileID == profile.id)
    #expect(loaded.pendingApply?.previousSnapshot == snapshot)
    #expect(loaded.pendingApply?.intendedSnapshot == snapshot)
    #expect(loaded.pendingApply?.intendedLayout == nil)
}

@Test func pendingChangesCompareTheActiveProfileWithItsVerifiedLayout() throws {
    let profile = DockProfile(name: "work", color: .blue, items: [
        DockItem(kind: .spacer(.regular)),
    ])
    var library = DockLibrary(
        profiles: [DockProfileRecord(profile: profile)],
        activeProfile: ActiveProfile(
            profileID: profile.id,
            source: .manual,
            appliedLayout: DockLayout(profile: profile)
        )
    )

    #expect(!library.hasPendingChanges(profileID: profile.id))

    var renamed = try #require(library.record(id: profile.id))
    renamed.profile.name = "renamed"
    renamed.profile.color = .orange
    renamed.profile.updatedAt = Date(timeIntervalSince1970: 9_000)
    try library.replace(renamed)
    #expect(!library.hasPendingChanges(profileID: profile.id))

    var edited = try #require(library.record(id: profile.id))
    edited.profile.items.append(DockItem(kind: .application(DockApp(
        bundleIdentifier: "com.example.missing",
        path: "/Applications/Missing.app",
        displayName: "missing"
    ))))
    try library.replace(edited)
    #expect(library.hasPendingChanges(profileID: profile.id))

    edited.profile.items.removeLast()
    try library.replace(edited)
    #expect(!library.hasPendingChanges(profileID: profile.id))
}

@Test func unknownOrInactiveAppliedLayoutsDoNotClaimPendingEdits() {
    let active = DockProfile(name: "active", color: .blue, items: [])
    let inactive = DockProfile(name: "inactive", color: .red, items: [
        DockItem(kind: .spacer(.small)),
    ])
    let library = DockLibrary(
        profiles: [DockProfileRecord(profile: active), DockProfileRecord(profile: inactive)],
        activeProfile: ActiveProfile(profileID: active.id, source: .manual)
    )

    #expect(!library.hasPendingChanges(profileID: active.id))
    #expect(!library.hasPendingChanges(profileID: inactive.id))
}

@Test func pendingApplyDecodesWithoutTheDockProcessIdentifier() throws {
    let snapshot = try DockSnapshot(rawTiles: [])
    let pending = PendingDockApply(
        profileID: UUID(),
        source: .manual,
        previousSnapshot: snapshot,
        intendedSnapshot: snapshot,
        dockProcessIdentifier: 7
    )
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(pending)) as? [String: Any])
    object["dockProcessIdentifier"] = nil

    let decoded = try JSONDecoder().decode(
        PendingDockApply.self,
        from: JSONSerialization.data(withJSONObject: object)
    )

    #expect(decoded.dockProcessIdentifier == nil)
    #expect(decoded.profileID == pending.profileID)
}
