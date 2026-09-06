import Foundation

public enum DockSnapshotError: LocalizedError, Equatable {
    case invalidRoot
    case invalidTile(Int)
    case unsupportedTile(String)
    case missingAppPath(Int)
    case invalidRawTile

    public var errorDescription: String? {
        switch self {
        case .invalidRoot:
            "the dock returned an invalid pinned-items list."
        case let .invalidTile(index):
            "pinned item \(index + 1) is malformed."
        case let .unsupportedTile(type):
            "dockit cannot safely save the pinned item type \"\(type)\"."
        case let .missingAppPath(index):
            "pinned app \(index + 1) has no usable file path."
        case .invalidRawTile:
            "a saved dock item is damaged."
        }
    }
}

public struct DockSnapshot: Codable, Equatable, Sendable {
    public let propertyListData: Data

    public init(propertyListData: Data) throws {
        let value = try PropertyListSerialization.propertyList(from: propertyListData, format: nil)
        guard value is [[String: Any]] else { throw DockSnapshotError.invalidRoot }
        self.propertyListData = propertyListData
    }

    public init(rawTiles: [[String: Any]]) throws {
        guard PropertyListSerialization.propertyList(rawTiles, isValidFor: .binary) else {
            throw DockSnapshotError.invalidRoot
        }
        propertyListData = try PropertyListSerialization.data(
            fromPropertyList: rawTiles,
            format: .binary,
            options: 0
        )
    }

    public func rawTiles() throws -> [[String: Any]] {
        let value = try PropertyListSerialization.propertyList(from: propertyListData, format: nil)
        guard let tiles = value as? [[String: Any]] else { throw DockSnapshotError.invalidRoot }
        return tiles
    }

    public func isEquivalent(to other: DockSnapshot) -> Bool {
        guard
            let left = try? rawTiles() as NSArray,
            let right = try? other.rawTiles()
        else { return false }
        return left.isEqual(to: right)
    }

    public func hasSameLayout(as other: DockSnapshot) -> Bool {
        guard
            let left = try? rawTiles(),
            let right = try? other.rawTiles(),
            left.count == right.count
        else { return false }
        return zip(left, right).allSatisfy { leftTile, rightTile in
            Self.layoutIdentity(for: leftTile) == Self.layoutIdentity(for: rightTile)
        }
    }

    public func capture(name: String, color: ProfileColor) throws -> CapturedDockProfile {
        try DockProfile.validateName(name)
        var items: [DockItem] = []
        var localState = DockProfileLocalState()
        for (index, tile) in try rawTiles().enumerated() {
            let item = try Self.item(from: tile, index: index)
            items.append(item)
            localState.rawTiles[item.id] = try Self.encodeRawTile(tile)
        }
        return CapturedDockProfile(
            profile: DockProfile(name: name, color: color, items: items),
            localState: localState
        )
    }

    public static func build(
        profile: DockProfile,
        localState: DockProfileLocalState,
        fileManager: FileManager = .default
    ) throws -> (snapshot: DockSnapshot, skippedApps: [SkippedDockApp]) {
        var tiles: [[String: Any]] = []
        var skipped: [SkippedDockApp] = []
        for item in profile.items {
            switch item.kind {
            case let .application(app):
                guard fileManager.fileExists(atPath: app.path) else {
                    skipped.append(SkippedDockApp(itemID: item.id, app: app))
                    continue
                }
                if
                    let raw = localState.rawTiles[item.id],
                    let tile = try? decodeRawTile(raw),
                    appPath(in: tile) == app.path
                {
                    tiles.append(tile)
                } else {
                    tiles.append(makeAppTile(app))
                }
            case let .spacer(size):
                if let raw = localState.rawTiles[item.id], let tile = try? decodeRawTile(raw) {
                    tiles.append(tile)
                } else {
                    tiles.append(makeSpacerTile(size))
                }
            }
        }
        return (try DockSnapshot(rawTiles: tiles), skipped)
    }

    private static func item(from tile: [String: Any], index: Int) throws -> DockItem {
        guard let type = tile["tile-type"] as? String else { throw DockSnapshotError.invalidTile(index) }
        switch type {
        case "spacer-tile":
            return DockItem(kind: .spacer(.regular))
        case "small-spacer-tile":
            return DockItem(kind: .spacer(.small))
        case "file-tile":
            guard let path = appPath(in: tile) else { throw DockSnapshotError.missingAppPath(index) }
            let data = tile["tile-data"] as? [String: Any]
            let label = data?["file-label"] as? String
                ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return DockItem(kind: .application(DockApp(
                bundleIdentifier: data?["bundle-identifier"] as? String,
                path: path,
                displayName: label
            )))
        default:
            throw DockSnapshotError.unsupportedTile(type)
        }
    }

    private static func appPath(in tile: [String: Any]) -> String? {
        guard
            let data = tile["tile-data"] as? [String: Any],
            let fileData = data["file-data"] as? [String: Any],
            let value = fileData["_CFURLString"] as? String,
            let url = URL(string: value),
            url.isFileURL
        else { return nil }
        return url.standardizedFileURL.path
    }

    private static func layoutIdentity(for tile: [String: Any]) -> String? {
        guard let type = tile["tile-type"] as? String else { return nil }
        switch type {
        case "file-tile":
            guard let path = appPath(in: tile) else { return nil }
            return "app:\(path)"
        case "spacer-tile":
            return "spacer:regular"
        case "small-spacer-tile":
            return "spacer:small"
        default:
            return nil
        }
    }

    private static func encodeRawTile(_ tile: [String: Any]) throws -> DockRawTile {
        guard PropertyListSerialization.propertyList(tile, isValidFor: .binary) else {
            throw DockSnapshotError.invalidRawTile
        }
        return DockRawTile(propertyListData: try PropertyListSerialization.data(
            fromPropertyList: tile,
            format: .binary,
            options: 0
        ))
    }

    private static func decodeRawTile(_ tile: DockRawTile) throws -> [String: Any] {
        let value = try PropertyListSerialization.propertyList(from: tile.propertyListData, format: nil)
        guard let value = value as? [String: Any] else { throw DockSnapshotError.invalidRawTile }
        return value
    }

    private static func makeAppTile(_ app: DockApp) -> [String: Any] {
        var tileData: [String: Any] = [
            "file-data": [
                "_CFURLString": URL(fileURLWithPath: app.path, isDirectory: true).absoluteString,
                "_CFURLStringType": 15,
            ],
            "file-label": app.displayName,
            "file-type": 41,
        ]
        if let bundleIdentifier = app.bundleIdentifier {
            tileData["bundle-identifier"] = bundleIdentifier
        }
        return [
            "GUID": Int(UInt32.random(in: 1 ... UInt32.max)),
            "tile-data": tileData,
            "tile-type": "file-tile",
        ]
    }

    private static func makeSpacerTile(_ size: SpacerSize) -> [String: Any] {
        [
            "GUID": Int(UInt32.random(in: 1 ... UInt32.max)),
            "tile-data": [String: Any](),
            "tile-type": size == .regular ? "spacer-tile" : "small-spacer-tile",
        ]
    }
}
