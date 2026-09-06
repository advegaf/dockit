import Foundation

public enum ProfileColor: String, CaseIterable, Codable, Sendable {
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case teal
    case gray
}

public enum SpacerSize: String, Codable, Sendable {
    case regular
    case small
}

public enum DockProfileNameError: LocalizedError, Equatable, Sendable {
    case empty
    case tooLong(maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .empty:
            "every saved dock needs a name."
        case let .tooLong(maximum):
            "saved dock names can use up to \(maximum) characters."
        }
    }
}

public enum DockProfileNamePolicy {
    public static let maximumGraphemeClusters = 32

    public static func validate(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DockProfileNameError.empty
        }
        guard name.count <= maximumGraphemeClusters else {
            throw DockProfileNameError.tooLong(maximum: maximumGraphemeClusters)
        }
    }
}

public struct DockApp: Codable, Equatable, Hashable, Sendable {
    public var bundleIdentifier: String?
    public var path: String
    public var displayName: String

    public init(bundleIdentifier: String?, path: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.displayName = displayName
    }
}

public struct DockItem: Codable, Identifiable, Equatable, Hashable, Sendable {
    public enum Kind: Codable, Equatable, Hashable, Sendable {
        case application(DockApp)
        case spacer(SpacerSize)
    }

    public var id: UUID
    public var kind: Kind

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

public struct DockProfile: Codable, Identifiable, Equatable, Sendable {
    public static let maximumNameLength = DockProfileNamePolicy.maximumGraphemeClusters

    public var id: UUID
    public var name: String
    public var color: ProfileColor
    public var items: [DockItem]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        color: ProfileColor,
        items: [DockItem],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func validateName(_ name: String) throws {
        try DockProfileNamePolicy.validate(name)
    }
}

public struct DockLayout: Codable, Equatable, Sendable {
    public struct Application: Codable, Equatable, Sendable {
        public var path: String
        public var bundleIdentifier: String?

        public init(path: String, bundleIdentifier: String?) {
            self.path = URL(fileURLWithPath: path).standardizedFileURL.path
            self.bundleIdentifier = bundleIdentifier
        }
    }

    public enum Item: Codable, Equatable, Sendable {
        case application(Application)
        case spacer(SpacerSize)
    }

    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    public init(profile: DockProfile) {
        items = profile.items.map { item in
            switch item.kind {
            case let .application(app):
                .application(Application(
                    path: app.path,
                    bundleIdentifier: app.bundleIdentifier
                ))
            case let .spacer(size):
                .spacer(size)
            }
        }
    }

    func retainingAvailableApplications(fileManager: FileManager) -> DockLayout {
        DockLayout(items: items.filter { item in
            guard case let .application(app) = item else { return true }
            return fileManager.fileExists(atPath: app.path)
        })
    }

    init(snapshot: DockSnapshot) throws {
        self.init(profile: try snapshot.capture(name: "dock", color: .blue).profile)
    }
}

public struct DockRawTile: Codable, Equatable, Sendable {
    public var propertyListData: Data

    public init(propertyListData: Data) {
        self.propertyListData = propertyListData
    }
}

public struct DockProfileLocalState: Codable, Equatable, Sendable {
    public var rawTiles: [UUID: DockRawTile]

    public init(rawTiles: [UUID: DockRawTile] = [:]) {
        self.rawTiles = rawTiles
    }
}

public struct CapturedDockProfile: Equatable, Sendable {
    public var profile: DockProfile
    public var localState: DockProfileLocalState

    public init(profile: DockProfile, localState: DockProfileLocalState) {
        self.profile = profile
        self.localState = localState
    }
}

public struct SkippedDockApp: Codable, Equatable, Sendable {
    public var itemID: UUID
    public var app: DockApp

    public init(itemID: UUID, app: DockApp) {
        self.itemID = itemID
        self.app = app
    }
}
