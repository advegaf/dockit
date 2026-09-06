import Foundation
import Testing
@testable import DockitCore

private actor MonitorPreferences: DockPreferencesServing {
    var snapshot: DockSnapshot

    init(snapshot: DockSnapshot) {
        self.snapshot = snapshot
    }

    func assertMutable() {}

    func readPersistentApps() -> DockSnapshot {
        snapshot
    }

    func writePersistentApps(_ snapshot: DockSnapshot) {
        self.snapshot = snapshot
    }
}

private actor MonitorAttempts {
    private(set) var count = 0

    func record() -> Bool {
        count += 1
        return count >= 2
    }
}

@Test func monitorIgnoresDockMetadataNormalization() async throws {
    let path = URL(fileURLWithPath: "/System/Applications/Notes.app", isDirectory: true).absoluteString
    let original = try DockSnapshot(rawTiles: [[
        "GUID": 1,
        "tile-type": "file-tile",
        "tile-data": [
            "file-data": ["_CFURLString": path, "_CFURLStringType": 15],
            "file-type": 41,
        ],
    ]])
    let normalized = try DockSnapshot(rawTiles: [[
        "GUID": 9,
        "tile-type": "file-tile",
        "tile-data": [
            "file-data": ["_CFURLString": path, "_CFURLStringType": 15],
            "file-type": 41,
            "parent-mod-date": 123,
        ],
    ]])
    let preferences = MonitorPreferences(snapshot: original)
    let attempts = MonitorAttempts()
    let monitor = DockChangeMonitor(preferences: preferences)

    await monitor.start(interval: .milliseconds(10)) { _ in
        await attempts.record()
    }
    try await Task.sleep(for: .milliseconds(30))
    await preferences.writePersistentApps(normalized)
    try await Task.sleep(for: .milliseconds(80))
    await monitor.stop()

    #expect(await attempts.count == 0)
}

@Test func monitorRetriesAnUnpersistedDockChange() async throws {
    let original = try DockSnapshot(rawTiles: [])
    let changed = try DockSnapshot(rawTiles: [[
        "GUID": 4,
        "tile-type": "small-spacer-tile",
        "tile-data": [String: Any](),
    ]])
    let preferences = MonitorPreferences(snapshot: original)
    let attempts = MonitorAttempts()
    let monitor = DockChangeMonitor(preferences: preferences)

    await monitor.start(interval: .milliseconds(10)) { _ in
        await attempts.record()
    }
    try await Task.sleep(for: .milliseconds(30))
    await preferences.writePersistentApps(changed)

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while await attempts.count < 2, clock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    await monitor.stop()

    #expect(await attempts.count >= 2)
}

@Test func monitorComparesItsFirstPollWithTheAcceptedLibrarySnapshot() async throws {
    let accepted = try DockSnapshot(rawTiles: [[
        "GUID": 60,
        "tile-type": "spacer-tile",
        "tile-data": [String: Any](),
    ]])
    let changedBeforeStart = try DockSnapshot(rawTiles: [[
        "GUID": 61,
        "tile-type": "small-spacer-tile",
        "tile-data": [String: Any](),
    ]])
    let preferences = MonitorPreferences(snapshot: changedBeforeStart)
    let attempts = MonitorAttempts()
    let monitor = DockChangeMonitor(preferences: preferences)

    await monitor.start(interval: .milliseconds(10), initialSnapshot: accepted) { _ in
        await attempts.record()
    }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while await attempts.count == 0, clock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    await monitor.stop()

    #expect(await attempts.count >= 1)
}
