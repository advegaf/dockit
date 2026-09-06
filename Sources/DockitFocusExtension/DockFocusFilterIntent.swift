import AppIntents
import DockitCore
import Foundation
import OSLog

private let dockFocusLogger = Logger(subsystem: "com.advegaf.dockit", category: "Focus")

struct DockProfileEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "dock"
    static let defaultQuery = DockProfileEntityQuery()

    let id: UUID
    let name: String
    let colorName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(colorName) profile"
        )
    }
}

struct DockProfileEntityQuery: EnumerableEntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [DockProfileEntity] {
        try await loadEntities().filter { identifiers.contains($0.id) }
    }

    func allEntities() async throws -> [DockProfileEntity] {
        try await loadEntities()
    }

    private func loadEntities() async throws -> [DockProfileEntity] {
        do {
            let store = try FocusBridgeStore()
            let profiles = try await store.loadProfiles()
            dockFocusLogger.notice("Returning \(profiles.count, privacy: .public) Focus profile options")
            return profiles.map {
                DockProfileEntity(id: $0.id, name: $0.name, colorName: $0.color.rawValue)
            }
        } catch {
            dockFocusLogger.error("Could not load Focus profile options: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

struct DockFocusFilterIntent: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "switch dockit dock"
    static let description = IntentDescription("choose the dockit dock to use when this focus turns on.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "dock")
    var profile: DockProfileEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("use \(\.$profile)")
    }

    var displayRepresentation: DisplayRepresentation {
        if let profile {
            DisplayRepresentation(
                title: "use \(profile.name) dock"
            )
        } else {
            DisplayRepresentation(title: "leave dock unchanged")
        }
    }

    init() {}

    func perform() async throws -> some IntentResult {
        let store = try FocusBridgeStore()
        _ = try await store.requestActivation(
            profileID: profile?.id,
            createdAt: systemContext.preciseTimestamp ?? Date()
        )
        if profile == nil {
            dockFocusLogger.info("Focus ended. Queued the leave-Dock-unchanged state")
        } else {
            dockFocusLogger.info("Queued a Dock profile from Focus")
        }
        return .result()
    }
}
