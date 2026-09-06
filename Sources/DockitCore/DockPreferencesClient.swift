import CoreFoundation
import Foundation

public enum DockPreferencesError: LocalizedError, Equatable {
    case missingPinnedApps
    case invalidPinnedApps
    case managed
    case synchronizeFailed

    public var errorDescription: String? {
        switch self {
        case .missingPinnedApps:
            "macos did not return the pinned dock items."
        case .invalidPinnedApps:
            "macos returned pinned dock data that dockit cannot read."
        case .managed:
            "a configuration profile manages this dock, so dockit left it unchanged."
        case .synchronizeFailed:
            "macos did not save the dock update."
        }
    }
}

public protocol DockPreferencesServing: Sendable {
    func assertMutable() async throws
    func readPersistentApps() async throws -> DockSnapshot
    func writePersistentApps(_ snapshot: DockSnapshot) async throws
}

public actor DockPreferencesClient: DockPreferencesServing {
    private let domain = "com.apple.dock" as CFString
    private let pinnedAppsKey = "persistent-apps" as CFString

    public init() {}

    public func assertMutable() throws {
        let managedKeys = [pinnedAppsKey, "contents-immutable" as CFString, "static-only" as CFString]
        if managedKeys.contains(where: { CFPreferencesAppValueIsForced($0, domain) }) {
            throw DockPreferencesError.managed
        }
        for key in managedKeys.dropFirst() {
            if let value = CFPreferencesCopyAppValue(key, domain) as? NSNumber, value.boolValue {
                throw DockPreferencesError.managed
            }
        }
    }

    public func readPersistentApps() throws -> DockSnapshot {
        guard let value = CFPreferencesCopyAppValue(pinnedAppsKey, domain) else {
            throw DockPreferencesError.missingPinnedApps
        }
        guard let tiles = value as? [[String: Any]] else {
            throw DockPreferencesError.invalidPinnedApps
        }
        return try DockSnapshot(rawTiles: tiles)
    }

    public func writePersistentApps(_ snapshot: DockSnapshot) throws {
        let tiles = try snapshot.rawTiles()
        CFPreferencesSetAppValue(pinnedAppsKey, tiles as CFArray, domain)
        guard CFPreferencesAppSynchronize(domain) else {
            throw DockPreferencesError.synchronizeFailed
        }
    }
}
