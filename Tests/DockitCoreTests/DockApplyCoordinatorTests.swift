import Foundation
import Testing
@testable import DockitCore

private actor MemoryPreferences: DockPreferencesServing {
    var snapshot: DockSnapshot
    var writes: [DockSnapshot] = []

    init(snapshot: DockSnapshot) {
        self.snapshot = snapshot
    }

    func assertMutable() {}

    func readPersistentApps() -> DockSnapshot {
        snapshot
    }

    func writePersistentApps(_ snapshot: DockSnapshot) {
        self.snapshot = snapshot
        writes.append(snapshot)
    }
}

private actor FailingOnceReloader: DockReloading {
    var attempts = 0

    func reload() throws -> DockReloadResult {
        attempts += 1
        if attempts == 1 { throw DockReloadError.didNotRelaunch }
        return DockReloadResult(previousProcessIdentifier: 1, currentProcessIdentifier: 2)
    }
}

private actor SuccessfulReloader: DockReloading {
    private(set) var attempts = 0

    func reload() -> DockReloadResult {
        attempts += 1
        return DockReloadResult(previousProcessIdentifier: 1, currentProcessIdentifier: 2)
    }
}

private actor NormalizingReloader: DockReloading {
    let preferences: MemoryPreferences
    let normalized: DockSnapshot

    init(preferences: MemoryPreferences, normalized: DockSnapshot) {
        self.preferences = preferences
        self.normalized = normalized
    }

    func reload() async -> DockReloadResult {
        await preferences.writePersistentApps(normalized)
        return DockReloadResult(previousProcessIdentifier: 1, currentProcessIdentifier: 2)
    }
}

private actor CorruptingFirstWritePreferences: DockPreferencesServing {
    private(set) var snapshot: DockSnapshot
    private(set) var writes: [DockSnapshot] = []
    private let corruptedSnapshot: DockSnapshot

    init(snapshot: DockSnapshot, corruptedSnapshot: DockSnapshot) {
        self.snapshot = snapshot
        self.corruptedSnapshot = corruptedSnapshot
    }

    func assertMutable() {}

    func readPersistentApps() -> DockSnapshot {
        snapshot
    }

    func writePersistentApps(_ snapshot: DockSnapshot) {
        writes.append(snapshot)
        self.snapshot = writes.count == 1 ? corruptedSnapshot : snapshot
    }
}

private actor BlockingFirstReloader: DockReloading {
    private var reloadCount = 0
    private var firstReloadWaiter: CheckedContinuation<Void, Never>?
    private var firstReloadRelease: CheckedContinuation<Void, Never>?

    func reload() async -> DockReloadResult {
        reloadCount += 1
        if reloadCount == 1 {
            firstReloadWaiter?.resume()
            firstReloadWaiter = nil
            await withCheckedContinuation { continuation in
                firstReloadRelease = continuation
            }
        }
        return DockReloadResult(previousProcessIdentifier: 1, currentProcessIdentifier: 2)
    }

    func waitForFirstReload() async {
        guard reloadCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstReloadWaiter = continuation
        }
    }

    func releaseFirstReload() {
        firstReloadRelease?.resume()
        firstReloadRelease = nil
    }
}

@Test func applyFailureRestoresExactPreimage() async throws {
    let original = try DockSnapshot(rawTiles: [["GUID": 7, "tile-type": "spacer-tile", "tile-data": [String: Any]()]])
    let preferences = MemoryPreferences(snapshot: original)
    let reloader = FailingOnceReloader()
    let coordinator = DockApplyCoordinator(preferences: preferences, reloader: reloader)
    let profile = DockProfile(name: "Empty", color: .gray, items: [])

    do {
        _ = try await coordinator.apply(profile: profile, localState: DockProfileLocalState())
        Issue.record("The injected reload failure did not fail the apply")
    } catch let error as DockApplyError {
        guard case .rolledBack = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
    }

    let restored = await preferences.snapshot
    let writes = await preferences.writes
    #expect(restored.isEquivalent(to: original))
    #expect(writes.count == 2)
}

@Test func preparedSnapshotIsTheSnapshotThatGetsWritten() async throws {
    let original = try DockSnapshot(rawTiles: [])
    let preferences = MemoryPreferences(snapshot: original)
    let coordinator = DockApplyCoordinator(preferences: preferences, reloader: SuccessfulReloader())
    let profile = DockProfile(name: "Prepared", color: .blue, items: [
        DockItem(kind: .application(DockApp(
            bundleIdentifier: "com.apple.Notes",
            path: "/System/Applications/Notes.app",
            displayName: "Notes"
        ))),
        DockItem(kind: .spacer(.regular)),
    ])

    let plan = try await coordinator.prepare(profile: profile, localState: DockProfileLocalState())
    let result = try await coordinator.apply(plan)
    let written = try #require(await preferences.writes.last)

    #expect(written.isEquivalent(to: plan.intendedSnapshot))
    #expect(result.appliedSnapshot.isEquivalent(to: plan.intendedSnapshot))
}

@Test func applyAcceptsDockMetadataNormalization() async throws {
    let original = try DockSnapshot(rawTiles: [])
    let preferences = MemoryPreferences(snapshot: original)
    let notesURL = URL(fileURLWithPath: "/System/Applications/Notes.app", isDirectory: true).absoluteString
    let normalized = try DockSnapshot(rawTiles: [[
        "GUID": 400,
        "tile-type": "file-tile",
        "tile-data": [
            "file-data": ["_CFURLString": notesURL, "_CFURLStringType": 15],
            "file-label": "Notes",
            "file-type": 41,
            "parent-mod-date": 123,
        ],
    ]])
    let coordinator = DockApplyCoordinator(
        preferences: preferences,
        reloader: NormalizingReloader(preferences: preferences, normalized: normalized)
    )
    let profile = DockProfile(name: "Normalized", color: .blue, items: [
        DockItem(kind: .application(DockApp(
            bundleIdentifier: "com.apple.Notes",
            path: "/System/Applications/Notes.app",
            displayName: "Notes"
        ))),
    ])

    let result = try await coordinator.apply(profile: profile, localState: DockProfileLocalState())

    #expect(result.appliedSnapshot.isEquivalent(to: normalized))
}

@Test func equivalentLayoutsDoNotRewriteOrReloadTheDock() async throws {
    let applicationURL = FileManager.default.temporaryDirectory.appending(
        path: "DockitLayoutFixture-\(UUID().uuidString).app",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: applicationURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: applicationURL) }

    let original = try DockSnapshot(rawTiles: [[
        "GUID": 91,
        "tile-type": "file-tile",
        "tile-data": [
            "file-data": [
                "_CFURLString": applicationURL.absoluteString,
                "_CFURLStringType": 15,
            ],
            "file-label": "Fixture",
            "file-type": 41,
            "parent-mod-date": 123,
        ],
    ]])
    let preferences = MemoryPreferences(snapshot: original)
    let reloader = SuccessfulReloader()
    let coordinator = DockApplyCoordinator(preferences: preferences, reloader: reloader)
    let profile = DockProfile(name: "Equivalent", color: .blue, items: [
        DockItem(kind: .application(DockApp(
            bundleIdentifier: "com.example.fixture",
            path: applicationURL.path,
            displayName: "Fixture"
        ))),
    ])

    let result = try await coordinator.apply(profile: profile, localState: DockProfileLocalState())

    #expect(result.reload == nil)
    #expect(result.appliedSnapshot.isEquivalent(to: original))
    #expect((await preferences.writes).isEmpty)
    #expect(await reloader.attempts == 0)
}

@Test func failedExactVerificationRollsBackBeforeReloading() async throws {
    let original = try DockSnapshot(rawTiles: [])
    let corrupted = try DockSnapshot(rawTiles: [[
        "GUID": 9,
        "tile-type": "small-spacer-tile",
        "tile-data": [String: Any](),
    ]])
    let preferences = CorruptingFirstWritePreferences(
        snapshot: original,
        corruptedSnapshot: corrupted
    )
    let reloader = SuccessfulReloader()
    let coordinator = DockApplyCoordinator(preferences: preferences, reloader: reloader)
    let profile = DockProfile(name: "Exact", color: .blue, items: [
        DockItem(kind: .spacer(.regular)),
    ])

    await #expect(throws: DockApplyError.self) {
        _ = try await coordinator.apply(profile: profile, localState: DockProfileLocalState())
    }

    #expect((await preferences.snapshot).isEquivalent(to: original))
    #expect((await preferences.writes).count == 2)
    #expect(await reloader.attempts == 1)
}

@Test func concurrentAppliesSerializeTheirWrites() async throws {
    let original = try DockSnapshot(rawTiles: [])
    let preferences = MemoryPreferences(snapshot: original)
    let reloader = BlockingFirstReloader()
    let coordinator = DockApplyCoordinator(preferences: preferences, reloader: reloader)
    let regular = DockProfile(name: "Regular", color: .blue, items: [
        DockItem(kind: .spacer(.regular)),
    ])
    let small = DockProfile(name: "Small", color: .green, items: [
        DockItem(kind: .spacer(.small)),
    ])

    let first = Task {
        try await coordinator.apply(profile: regular, localState: DockProfileLocalState())
    }
    await reloader.waitForFirstReload()
    let second = Task {
        try await coordinator.apply(profile: small, localState: DockProfileLocalState())
    }
    for _ in 0 ..< 20 {
        await Task.yield()
    }

    #expect((await preferences.writes).count == 1)

    await reloader.releaseFirstReload()
    _ = try await first.value
    _ = try await second.value

    let writes = await preferences.writes
    #expect(writes.count == 2)
    #expect(writes.last?.hasSameLayout(as: try DockSnapshot(rawTiles: [[
        "GUID": 1,
        "tile-type": "small-spacer-tile",
        "tile-data": [String: Any](),
    ]])) == true)
}

@Test func preparedApplyStopsIfDockChangedBeforeWrite() async throws {
    let original = try DockSnapshot(rawTiles: [])
    let changed = try DockSnapshot(rawTiles: [[
        "GUID": 9,
        "tile-type": "spacer-tile",
        "tile-data": [String: Any](),
    ]])
    let preferences = MemoryPreferences(snapshot: original)
    let coordinator = DockApplyCoordinator(preferences: preferences, reloader: SuccessfulReloader())
    let profile = DockProfile(name: "Empty", color: .gray, items: [])
    let plan = try await coordinator.prepare(profile: profile, localState: DockProfileLocalState())

    await preferences.writePersistentApps(changed)

    await #expect(throws: DockApplyError.self) {
        _ = try await coordinator.apply(plan)
    }
    #expect((await preferences.writes).count == 1)
}

@Test func forcedRestoreReloadsAnAlreadyWrittenSnapshot() async throws {
    let snapshot = try DockSnapshot(rawTiles: [])
    let preferences = MemoryPreferences(snapshot: snapshot)
    let reloader = SuccessfulReloader()
    let coordinator = DockApplyCoordinator(preferences: preferences, reloader: reloader)

    _ = try await coordinator.restore(snapshot, forceReload: true)

    #expect(await reloader.attempts == 1)
    #expect((await preferences.writes).isEmpty)
}

private actor ProcessAwareReloader: DockReloading {
    private let processIdentifier: Int32
    private(set) var attempts = 0

    init(processIdentifier: Int32) {
        self.processIdentifier = processIdentifier
    }

    func reload() -> DockReloadResult {
        attempts += 1
        return DockReloadResult(
            previousProcessIdentifier: processIdentifier,
            currentProcessIdentifier: processIdentifier + 1
        )
    }

    func dockProcessIdentifier() -> Int32? {
        processIdentifier
    }
}

@Test func recoveryRestoreSkipsTheReloadWhenTheDockRelaunchedAfterTheWrite() async throws {
    let snapshot = try DockSnapshot(rawTiles: [])
    let preferences = MemoryPreferences(snapshot: snapshot)
    let reloader = ProcessAwareReloader(processIdentifier: 11)
    let coordinator = DockApplyCoordinator(preferences: preferences, reloader: reloader)

    let result = try await coordinator.restore(snapshot, forceReload: true, writtenWhileDockProcessWas: 10)

    #expect(result == nil)
    #expect(await reloader.attempts == 0)
    #expect((await preferences.writes).isEmpty)
}

@Test func recoveryRestoreReloadsWhenTheSameDockProcessStillRuns() async throws {
    let snapshot = try DockSnapshot(rawTiles: [])
    let preferences = MemoryPreferences(snapshot: snapshot)
    let reloader = ProcessAwareReloader(processIdentifier: 11)
    let coordinator = DockApplyCoordinator(preferences: preferences, reloader: reloader)

    let result = try await coordinator.restore(snapshot, forceReload: true, writtenWhileDockProcessWas: 11)

    #expect(result != nil)
    #expect(await reloader.attempts == 1)
}

@Test func recoveryRestoreReloadsWhenTheWritingDockProcessIsUnknown() async throws {
    let snapshot = try DockSnapshot(rawTiles: [])
    let preferences = MemoryPreferences(snapshot: snapshot)
    let reloader = ProcessAwareReloader(processIdentifier: 11)
    let coordinator = DockApplyCoordinator(preferences: preferences, reloader: reloader)

    _ = try await coordinator.restore(snapshot, forceReload: true, writtenWhileDockProcessWas: nil)

    #expect(await reloader.attempts == 1)
}

@Test func recoveryRestoreWritesAndReloadsWhenThePreferencesDiffer() async throws {
    let current = try DockSnapshot(rawTiles: [["GUID": 7, "tile-type": "spacer-tile", "tile-data": [String: Any]()]])
    let wanted = try DockSnapshot(rawTiles: [])
    let preferences = MemoryPreferences(snapshot: current)
    let reloader = ProcessAwareReloader(processIdentifier: 11)
    let coordinator = DockApplyCoordinator(preferences: preferences, reloader: reloader)

    _ = try await coordinator.restore(wanted, forceReload: true, writtenWhileDockProcessWas: 10)

    #expect((await preferences.writes).count == 1)
    #expect(await reloader.attempts == 1)
}

/// Preferences and reloader in one: after a reload the simulated Dock holds
/// what it loaded and, three reads later, writes it back in its own encoding,
/// the way the real Dock does about four seconds after launch.
private actor SimulatedDock: DockPreferencesServing, DockReloading {
    private var preferences: DockSnapshot
    private var dockHolds: DockSnapshot
    private var flushed = true
    private var readsSinceReload = 0
    private(set) var reloads = 0

    init(snapshot: DockSnapshot) {
        preferences = snapshot
        dockHolds = snapshot
    }

    func assertMutable() {}

    func readPersistentApps() throws -> DockSnapshot {
        readsSinceReload += 1
        if !flushed, readsSinceReload >= 3 {
            flushed = true
            preferences = try Self.reencoded(dockHolds)
        }
        return preferences
    }

    func writePersistentApps(_ snapshot: DockSnapshot) {
        preferences = snapshot
    }

    func reload() -> DockReloadResult {
        reloads += 1
        dockHolds = preferences
        flushed = false
        readsSinceReload = 0
        return DockReloadResult(previousProcessIdentifier: 1, currentProcessIdentifier: 2)
    }

    private static func reencoded(_ snapshot: DockSnapshot) throws -> DockSnapshot {
        let tiles = try snapshot.rawTiles().map { tile -> [String: Any] in
            var copy = tile
            copy["GUID"] = (copy["GUID"] as? Int ?? 0) + 100_000
            return copy
        }
        return try DockSnapshot(rawTiles: tiles)
    }
}

@Test func aSecondApplyWaitsForTheRelaunchedDockToWriteItsPreferences() async throws {
    let dock = SimulatedDock(snapshot: try DockSnapshot(rawTiles: []))
    let coordinator = DockApplyCoordinator(preferences: dock, reloader: dock)
    let notes = DockProfile(name: "Notes", color: .blue, items: [
        DockItem(kind: .application(DockApp(
            bundleIdentifier: "com.apple.Notes",
            path: "/System/Applications/Notes.app",
            displayName: "Notes"
        ))),
    ])
    let textEdit = DockProfile(name: "TextEdit", color: .green, items: [
        DockItem(kind: .application(DockApp(
            bundleIdentifier: "com.apple.TextEdit",
            path: "/System/Applications/TextEdit.app",
            displayName: "TextEdit"
        ))),
    ])

    _ = try await coordinator.apply(profile: notes, localState: DockProfileLocalState())
    let second = try await coordinator.apply(profile: textEdit, localState: DockProfileLocalState())

    #expect(await dock.reloads == 2)
    #expect(second.appliedSnapshot.hasSameLayout(as: second.previousSnapshot) == false)
}
