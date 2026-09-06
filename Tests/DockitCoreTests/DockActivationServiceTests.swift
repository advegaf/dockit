import Foundation
import Testing
@testable import DockitCore

private actor RollbackWriteFailurePreferences: DockPreferencesServing {
    private(set) var snapshot: DockSnapshot
    private var writeCount = 0

    init(snapshot: DockSnapshot) {
        self.snapshot = snapshot
    }

    func assertMutable() {}

    func readPersistentApps() -> DockSnapshot {
        snapshot
    }

    func writePersistentApps(_ snapshot: DockSnapshot) throws {
        writeCount += 1
        if writeCount == 2 {
            throw DockPreferencesError.synchronizeFailed
        }
        self.snapshot = snapshot
    }
}

private actor InitialReloadFailure: DockReloading {
    func reload() throws -> DockReloadResult {
        throw DockReloadError.didNotRelaunch
    }
}

private actor StablePreferences: DockPreferencesServing {
    private var snapshot: DockSnapshot
    private(set) var writeCount = 0

    init(snapshot: DockSnapshot) {
        self.snapshot = snapshot
    }

    func assertMutable() {}

    func readPersistentApps() -> DockSnapshot {
        snapshot
    }

    func writePersistentApps(_ snapshot: DockSnapshot) {
        writeCount += 1
        self.snapshot = snapshot
    }
}

private actor SuccessfulReload: DockReloading {
    private(set) var reloadCount = 0

    func reload() -> DockReloadResult {
        reloadCount += 1
        return DockReloadResult(previousProcessIdentifier: 1, currentProcessIdentifier: 2)
    }
}

private actor PendingObservingPreferences: DockPreferencesServing {
    private var snapshot: DockSnapshot
    private let store: DockLibraryStore
    private(set) var pendingAtFirstWrite: PendingDockApply?

    init(snapshot: DockSnapshot, store: DockLibraryStore) {
        self.snapshot = snapshot
        self.store = store
    }

    func assertMutable() {}

    func readPersistentApps() -> DockSnapshot {
        snapshot
    }

    func writePersistentApps(_ snapshot: DockSnapshot) async throws {
        if pendingAtFirstWrite == nil {
            pendingAtFirstWrite = try await store.load()?.pendingApply
        }
        self.snapshot = snapshot
    }
}

private actor FailOnceReloader: DockReloading {
    private var reloadCount = 0

    func reload() throws -> DockReloadResult {
        reloadCount += 1
        if reloadCount == 1 {
            throw DockReloadError.didNotRelaunch
        }
        return DockReloadResult(previousProcessIdentifier: 1, currentProcessIdentifier: 2)
    }
}

private actor ChangeBeforeWritePreferences: DockPreferencesServing {
    private let initial: DockSnapshot
    private let changed: DockSnapshot
    private var readCount = 0
    private(set) var writeCount = 0

    init(initial: DockSnapshot, changed: DockSnapshot) {
        self.initial = initial
        self.changed = changed
    }

    func assertMutable() {}

    func readPersistentApps() -> DockSnapshot {
        readCount += 1
        return readCount == 1 ? initial : changed
    }

    func writePersistentApps(_ snapshot: DockSnapshot) {
        writeCount += 1
    }
}

@Test func failedRollbackLeavesRecoveryRecordOnDisk() async throws {
    let original = try DockSnapshot(rawTiles: [[
        "GUID": 7,
        "tile-type": "spacer-tile",
        "tile-data": [String: Any](),
    ]])
    let preferences = RollbackWriteFailurePreferences(snapshot: original)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = DockLibraryStore(fileURL: directory.appending(path: "library.json"))
    let profile = DockProfile(name: "Empty", color: .gray, items: [])
    try await store.save(DockLibrary(
        profiles: [DockProfileRecord(profile: profile)],
        selectedProfileID: profile.id,
        activeProfile: ActiveProfile(profileID: profile.id, source: .manual),
        lastKnownDock: original
    ))
    let service = DockActivationService(
        store: store,
        preferences: preferences,
        reloader: InitialReloadFailure()
    )
    let requestedAt = Date(timeIntervalSince1970: 7_500)
    let requestID = UUID()

    await #expect(throws: DockApplyError.self) {
        _ = try await service.activate(
            profileID: profile.id,
            source: .focus,
            activatedAt: requestedAt,
            focusRequestID: requestID
        )
    }

    let recovered = try #require(await store.load())
    #expect(recovered.pendingApply?.profileID == profile.id)
    #expect(recovered.pendingApply?.activationRequestedAt == requestedAt)
    #expect(recovered.pendingApply?.focusRequestID == requestID)
    #expect(recovered.lastKnownDock?.isEquivalent(to: original) == true)
    #expect(recovered.pendingApply?.intendedLayout == DockLayout(profile: profile))
}

@Test func activationPersistsTheRequestTimeForFocusOrdering() async throws {
    let snapshot = try DockSnapshot(rawTiles: [])
    let preferences = StablePreferences(snapshot: snapshot)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = DockLibraryStore(fileURL: directory.appending(path: "library.json"))
    let profile = DockProfile(name: "Empty", color: .gray, items: [])
    try await store.save(DockLibrary(
        profiles: [DockProfileRecord(profile: profile)],
        selectedProfileID: profile.id
    ))
    let service = DockActivationService(store: store, preferences: preferences)
    let requestedAt = Date(timeIntervalSince1970: 8_000)

    let outcome = try await service.activate(
        profileID: profile.id,
        source: .manual,
        activatedAt: requestedAt
    )

    #expect(outcome.library.activeProfile?.appliedAt == requestedAt)
    #expect(outcome.library.activeProfile?.appliedLayout == DockLayout(profile: profile))
    #expect(try await store.load()?.activeProfile?.appliedAt == requestedAt)
}

@Test func successfulFocusActivationPersistsItsRequestWatermark() async throws {
    let snapshot = try DockSnapshot(rawTiles: [])
    let preferences = StablePreferences(snapshot: snapshot)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = DockLibraryStore(fileURL: directory.appending(path: "library.json"))
    let profile = DockProfile(name: "Empty", color: .gray, items: [])
    try await store.save(DockLibrary(
        profiles: [DockProfileRecord(profile: profile)],
        selectedProfileID: profile.id
    ))
    let service = DockActivationService(store: store, preferences: preferences)
    let requestedAt = Date(timeIntervalSince1970: 9_000)
    let requestID = UUID()
    let expectedWatermark = FocusRequestWatermark(
        requestID: requestID,
        createdAt: requestedAt
    )

    let outcome = try await service.activate(
        profileID: profile.id,
        source: .focus,
        activatedAt: requestedAt,
        focusRequestID: requestID
    )

    #expect(outcome.library.lastHandledFocusRequest == expectedWatermark)
    #expect(try await store.load()?.lastHandledFocusRequest == expectedWatermark)
}

@Test func activationPersistsItsExactIntendedLayoutBeforeWritingTheDock() async throws {
    let original = try DockSnapshot(rawTiles: [])
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = DockLibraryStore(fileURL: directory.appending(path: "library.json"))
    let profile = DockProfile(name: "spaced", color: .teal, items: [
        DockItem(kind: .spacer(.regular)),
    ])
    try await store.save(DockLibrary(
        profiles: [DockProfileRecord(profile: profile)],
        selectedProfileID: profile.id
    ))
    let preferences = PendingObservingPreferences(snapshot: original, store: store)
    let reloader = SuccessfulReload()
    let service = DockActivationService(
        store: store,
        preferences: preferences,
        reloader: reloader
    )

    let outcome = try await service.activate(profileID: profile.id, source: .manual)

    let intendedLayout = DockLayout(profile: profile)
    #expect(await preferences.pendingAtFirstWrite?.intendedLayout == intendedLayout)
    #expect(outcome.library.activeProfile?.appliedLayout == intendedLayout)
    #expect(outcome.library.pendingApply == nil)
    #expect(await reloader.reloadCount == 1)
    #expect(try await store.load()?.activeProfile?.appliedLayout == intendedLayout)
}

@Test func equivalentDockPromotionRecordsTheFullLayoutWithoutReloading() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let profile = DockProfile(name: "same", color: .blue, items: [
        DockItem(kind: .spacer(.small)),
    ])
    let snapshot = try DockSnapshot.build(
        profile: profile,
        localState: DockProfileLocalState()
    ).snapshot
    let store = DockLibraryStore(fileURL: directory.appending(path: "library.json"))
    try await store.save(DockLibrary(
        profiles: [DockProfileRecord(profile: profile)],
        selectedProfileID: profile.id
    ))
    let service = DockActivationService(
        store: store,
        preferences: StablePreferences(snapshot: snapshot),
        reloader: InitialReloadFailure()
    )

    let outcome = try await service.activate(profileID: profile.id, source: .manual)

    #expect(outcome.applyResult.reload == nil)
    #expect(outcome.library.activeProfile?.appliedLayout == DockLayout(profile: profile))
    #expect(outcome.library.pendingApply == nil)
}

@Test func verifiedRollbackClearsTheTransactionWithoutChangingTheKnownDock() async throws {
    let original = try DockSnapshot(rawTiles: [[
        "GUID": 10,
        "tile-type": "spacer-tile",
        "tile-data": [String: Any](),
    ]])
    let profile = DockProfile(name: "empty", color: .gray, items: [])
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = DockLibraryStore(fileURL: directory.appending(path: "library.json"))
    try await store.save(DockLibrary(
        profiles: [DockProfileRecord(profile: profile)],
        selectedProfileID: profile.id,
        activeProfile: ActiveProfile(
            profileID: profile.id,
            source: .manual,
            appliedLayout: DockLayout(items: [.spacer(.regular)])
        ),
        lastKnownDock: original
    ))
    let service = DockActivationService(
        store: store,
        preferences: StablePreferences(snapshot: original),
        reloader: FailOnceReloader()
    )

    await #expect(throws: DockApplyError.self) {
        _ = try await service.activate(profileID: profile.id, source: .manual)
    }

    let stored = try #require(await store.load())
    #expect(stored.pendingApply == nil)
    #expect(stored.lastKnownDock == original)
    #expect(stored.activeProfile?.appliedLayout == DockLayout(items: [.spacer(.regular)]))
}

@Test func dockChangedBeforeApplyClearsTheSafeTransactionWithoutAdvancingTheKnownDock() async throws {
    let original = try DockSnapshot(rawTiles: [[
        "GUID": 11,
        "tile-type": "spacer-tile",
        "tile-data": [String: Any](),
    ]])
    let changed = try DockSnapshot(rawTiles: [[
        "GUID": 12,
        "tile-type": "small-spacer-tile",
        "tile-data": [String: Any](),
    ]])
    let profile = DockProfile(name: "empty", color: .gray, items: [])
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = DockLibraryStore(fileURL: directory.appending(path: "library.json"))
    try await store.save(DockLibrary(
        profiles: [DockProfileRecord(profile: profile)],
        selectedProfileID: profile.id,
        activeProfile: ActiveProfile(
            profileID: profile.id,
            source: .manual,
            appliedLayout: DockLayout(items: [.spacer(.regular)])
        ),
        lastKnownDock: original
    ))
    let preferences = ChangeBeforeWritePreferences(initial: original, changed: changed)
    let service = DockActivationService(
        store: store,
        preferences: preferences,
        reloader: SuccessfulReload()
    )

    await #expect(throws: DockApplyError.self) {
        _ = try await service.activate(profileID: profile.id, source: .manual)
    }

    let stored = try #require(await store.load())
    #expect(stored.pendingApply == nil)
    #expect(stored.lastKnownDock == original)
    #expect(stored.activeProfile?.appliedLayout == DockLayout(items: [.spacer(.regular)]))
    #expect(await preferences.writeCount == 0)
}

@Test func activationRejectsARealDockChangeBeforeCreatingATransaction() async throws {
    let accepted = try DockSnapshot(rawTiles: [[
        "GUID": 20,
        "tile-type": "spacer-tile",
        "tile-data": [String: Any](),
    ]])
    let changed = try DockSnapshot(rawTiles: [[
        "GUID": 21,
        "tile-type": "small-spacer-tile",
        "tile-data": [String: Any](),
    ]])
    let profile = DockProfile(name: "empty", color: .gray, items: [])
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = DockLibraryStore(fileURL: directory.appending(path: "library.json"))
    let appliedLayout = DockLayout(items: [.spacer(.regular)])
    try await store.save(DockLibrary(
        profiles: [DockProfileRecord(profile: profile)],
        selectedProfileID: profile.id,
        activeProfile: ActiveProfile(
            profileID: profile.id,
            source: .manual,
            appliedLayout: appliedLayout
        ),
        lastKnownDock: accepted
    ))
    let preferences = StablePreferences(snapshot: changed)
    let reloader = SuccessfulReload()
    let service = DockActivationService(
        store: store,
        preferences: preferences,
        reloader: reloader
    )

    await #expect(throws: DockApplyError.self) {
        _ = try await service.activate(profileID: profile.id, source: .manual)
    }

    let stored = try #require(await store.load())
    #expect(stored.pendingApply == nil)
    #expect(stored.lastKnownDock == accepted)
    #expect(stored.activeProfile?.appliedLayout == appliedLayout)
    #expect(await preferences.writeCount == 0)
    #expect(await reloader.reloadCount == 0)
}

@Test func reviewedRealDockSnapshotAuthorizesAnExplicitReconciliationApply() async throws {
    let accepted = try DockSnapshot(rawTiles: [[
        "GUID": 30,
        "tile-type": "spacer-tile",
        "tile-data": [String: Any](),
    ]])
    let reviewed = try DockSnapshot(rawTiles: [[
        "GUID": 31,
        "tile-type": "small-spacer-tile",
        "tile-data": [String: Any](),
    ]])
    let profile = DockProfile(name: "empty", color: .gray, items: [])
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = DockLibraryStore(fileURL: directory.appending(path: "library.json"))
    try await store.save(DockLibrary(
        profiles: [DockProfileRecord(profile: profile)],
        selectedProfileID: profile.id,
        activeProfile: ActiveProfile(
            profileID: profile.id,
            source: .manual,
            appliedLayout: DockLayout(items: [.spacer(.regular)])
        ),
        lastKnownDock: accepted
    ))
    let preferences = StablePreferences(snapshot: reviewed)
    let reloader = SuccessfulReload()
    let service = DockActivationService(
        store: store,
        preferences: preferences,
        reloader: reloader
    )

    let outcome = try await service.activate(
        profileID: profile.id,
        source: .manual,
        expectedCurrentSnapshot: reviewed
    )

    #expect(outcome.library.activeProfile?.appliedLayout == DockLayout(profile: profile))
    #expect(outcome.library.lastKnownDock?.hasSameLayout(as: try DockSnapshot(rawTiles: [])) == true)
    #expect(outcome.library.pendingApply == nil)
    #expect(await preferences.writeCount == 1)
    #expect(await reloader.reloadCount == 1)
}

@Test func staleReviewedSnapshotCannotAuthorizeAnApply() async throws {
    let accepted = try DockSnapshot(rawTiles: [[
        "GUID": 40,
        "tile-type": "spacer-tile",
        "tile-data": [String: Any](),
    ]])
    let reviewed = try DockSnapshot(rawTiles: [[
        "GUID": 41,
        "tile-type": "small-spacer-tile",
        "tile-data": [String: Any](),
    ]])
    let changedAgain = try DockSnapshot(rawTiles: [])
    let profile = DockProfile(name: "regular", color: .gray, items: [
        DockItem(kind: .spacer(.regular)),
    ])
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = DockLibraryStore(fileURL: directory.appending(path: "library.json"))
    let appliedLayout = DockLayout(items: [.spacer(.regular)])
    try await store.save(DockLibrary(
        profiles: [DockProfileRecord(profile: profile)],
        selectedProfileID: profile.id,
        activeProfile: ActiveProfile(
            profileID: profile.id,
            source: .manual,
            appliedLayout: appliedLayout
        ),
        lastKnownDock: accepted
    ))
    let preferences = StablePreferences(snapshot: changedAgain)
    let reloader = SuccessfulReload()
    let service = DockActivationService(
        store: store,
        preferences: preferences,
        reloader: reloader
    )

    await #expect(throws: DockApplyError.self) {
        _ = try await service.activate(
            profileID: profile.id,
            source: .manual,
            expectedCurrentSnapshot: reviewed
        )
    }

    let stored = try #require(await store.load())
    #expect(stored.pendingApply == nil)
    #expect(stored.lastKnownDock == accepted)
    #expect(stored.activeProfile?.appliedLayout == appliedLayout)
    #expect(await preferences.writeCount == 0)
    #expect(await reloader.reloadCount == 0)
}

@Test func firstActivationDoesNotTreatAnUnownedSnapshotAsAcceptedState() async throws {
    let unowned = try DockSnapshot(rawTiles: [[
        "GUID": 50,
        "tile-type": "spacer-tile",
        "tile-data": [String: Any](),
    ]])
    let current = try DockSnapshot(rawTiles: [[
        "GUID": 51,
        "tile-type": "small-spacer-tile",
        "tile-data": [String: Any](),
    ]])
    let profile = DockProfile(name: "empty", color: .gray, items: [])
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = DockLibraryStore(fileURL: directory.appending(path: "library.json"))
    try await store.save(DockLibrary(
        profiles: [DockProfileRecord(profile: profile)],
        selectedProfileID: profile.id,
        lastKnownDock: unowned
    ))
    let preferences = StablePreferences(snapshot: current)
    let reloader = SuccessfulReload()
    let service = DockActivationService(
        store: store,
        preferences: preferences,
        reloader: reloader
    )

    let outcome = try await service.activate(profileID: profile.id, source: .manual)

    #expect(outcome.library.activeProfile?.profileID == profile.id)
    #expect(await preferences.writeCount == 1)
    #expect(await reloader.reloadCount == 1)
}

private actor AlwaysFailingProcessAwareReloader: DockReloading {
    func reload() throws -> DockReloadResult {
        throw DockReloadError.didNotRelaunch
    }

    func dockProcessIdentifier() -> Int32? {
        42
    }
}

@Test func activationRecordsTheDockProcessThatWasRunningBeforeTheWrite() async throws {
    let original = try DockSnapshot(rawTiles: [[
        "GUID": 7,
        "tile-type": "spacer-tile",
        "tile-data": [String: Any](),
    ]])
    let preferences = StablePreferences(snapshot: original)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = DockLibraryStore(fileURL: directory.appending(path: "library.json"))
    let profile = DockProfile(name: "Empty", color: .gray, items: [])
    try await store.save(DockLibrary(
        profiles: [DockProfileRecord(profile: profile)],
        selectedProfileID: profile.id,
        activeProfile: ActiveProfile(profileID: profile.id, source: .manual),
        lastKnownDock: original
    ))
    let service = DockActivationService(
        store: store,
        preferences: preferences,
        reloader: AlwaysFailingProcessAwareReloader()
    )

    await #expect(throws: DockApplyError.self) {
        _ = try await service.activate(profileID: profile.id, source: .manual)
    }

    let recovered = try #require(await store.load())
    #expect(recovered.pendingApply?.dockProcessIdentifier == 42)
}
