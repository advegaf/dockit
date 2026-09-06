import Foundation
import OSLog

private let focusBridgeLogger = Logger(subsystem: "com.advegaf.dockit", category: "FocusBridge")

public struct FocusProfileSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var color: ProfileColor

    public init(id: UUID, name: String, color: ProfileColor) {
        self.id = id
        self.name = name
        self.color = color
    }

    public init(profile: DockProfile) {
        self.init(id: profile.id, name: profile.name, color: profile.color)
    }
}

public struct FocusProfileCatalog: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var profiles: [FocusProfileSummary]

    public init(schemaVersion: Int = FocusProfileCatalog.schemaVersion, profiles: [FocusProfileSummary]) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
    }
}

public struct FocusRequestWatermark: Codable, Comparable, Sendable {
    public var requestID: UUID
    public var createdAt: Date

    public init(requestID: UUID, createdAt: Date) {
        self.requestID = requestID
        self.createdAt = createdAt
    }

    public func isNewer(than other: FocusRequestWatermark?) -> Bool {
        guard let other else { return true }
        return self > other
    }

    public static func < (lhs: FocusRequestWatermark, rhs: FocusRequestWatermark) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.requestID.uuidString < rhs.requestID.uuidString
    }
}

public struct FocusActivationRequest: Codable, Equatable, Identifiable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var profileID: UUID?
    public var createdAt: Date

    public init(
        schemaVersion: Int = FocusActivationRequest.schemaVersion,
        id: UUID = UUID(),
        profileID: UUID?,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.profileID = profileID
        self.createdAt = createdAt
    }

    public var watermark: FocusRequestWatermark {
        FocusRequestWatermark(requestID: id, createdAt: createdAt)
    }

    public func isNewer(
        than watermark: FocusRequestWatermark?,
        fallbackActiveProfile activeProfile: ActiveProfile?
    ) -> Bool {
        guard self.watermark.isNewer(than: watermark) else { return false }
        guard let activeProfile else { return true }
        if activeProfile.source == .manual {
            return createdAt > activeProfile.appliedAt
        }
        if let watermark, watermark.createdAt >= activeProfile.appliedAt {
            return true
        }
        return createdAt > activeProfile.appliedAt
    }
}

public struct FocusPendingRequestBatch: Equatable, Sendable {
    public var requests: [FocusActivationRequest]
    public var quarantinedCount: Int

    public init(requests: [FocusActivationRequest], quarantinedCount: Int) {
        self.requests = requests
        self.quarantinedCount = quarantinedCount
    }
}

public actor FocusBridgeStore {
    public static let appGroupIdentifier = "group.com.advegaf.dockit"

    public let directoryURL: URL

    private var catalogURL: URL {
        directoryURL.appending(path: "focus-catalog.json", directoryHint: .notDirectory)
    }

    private var requestsURL: URL {
        directoryURL.appending(path: "Focus Requests", directoryHint: .isDirectory)
    }

    public init(directoryURL: URL? = nil) throws {
        if let directoryURL {
            self.directoryURL = directoryURL
            return
        }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            throw FocusBridgeStoreError.unavailable
        }
        self.directoryURL = container.appending(path: "Dockit", directoryHint: .isDirectory)
    }

    public func publish(_ library: DockLibrary) throws {
        try prepareDirectory(directoryURL)
        let catalog = FocusProfileCatalog(
            profiles: library.profiles.map { FocusProfileSummary(profile: $0.profile) }
        )
        try write(catalog, to: catalogURL)
        focusBridgeLogger.notice("Published \(catalog.profiles.count, privacy: .public) Focus profiles")
    }

    public func loadProfiles() throws -> [FocusProfileSummary] {
        guard FileManager.default.fileExists(atPath: catalogURL.path) else {
            focusBridgeLogger.error("The Focus profile catalog is missing")
            return []
        }
        let catalog = try read(FocusProfileCatalog.self, from: catalogURL)
        guard catalog.schemaVersion == FocusProfileCatalog.schemaVersion else {
            throw FocusBridgeStoreError.unsupportedVersion
        }
        focusBridgeLogger.notice("Loaded \(catalog.profiles.count, privacy: .public) Focus profiles")
        return catalog.profiles
    }

    @discardableResult
    public func requestActivation(
        profileID: UUID?,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> FocusActivationRequest {
        let request = FocusActivationRequest(id: id, profileID: profileID, createdAt: createdAt)
        try prepareDirectory(requestsURL)
        try write(request, to: requestURL(id: id))
        return request
    }

    public func pendingRequests() throws -> [FocusActivationRequest] {
        try pendingRequestBatch().requests
    }

    public func pendingRequestBatch() throws -> FocusPendingRequestBatch {
        guard FileManager.default.fileExists(atPath: requestsURL.path) else {
            return FocusPendingRequestBatch(requests: [], quarantinedCount: 0)
        }
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: requestsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            var requests: [FocusActivationRequest] = []
            var quarantinedCount = 0
            for file in files where file.pathExtension == "json" {
                do {
                    let request = try read(FocusActivationRequest.self, from: file)
                    guard request.schemaVersion == FocusActivationRequest.schemaVersion else {
                        throw FocusBridgeStoreError.unsupportedVersion
                    }
                    requests.append(request)
                } catch {
                    try quarantine(file)
                    quarantinedCount += 1
                }
            }
            requests.sort { $0.watermark < $1.watermark }
            return FocusPendingRequestBatch(
                requests: requests,
                quarantinedCount: quarantinedCount
            )
        } catch let error as FocusBridgeStoreError {
            throw error
        } catch {
            throw FocusBridgeStoreError.unreadable
        }
    }

    public func acknowledge(requestIDs: [UUID]) throws {
        do {
            for id in Set(requestIDs) {
                let url = requestURL(id: id)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            throw FocusBridgeStoreError.unwritable
        }
    }

    private func requestURL(id: UUID) -> URL {
        requestsURL.appending(path: "\(id.uuidString).json", directoryHint: .notDirectory)
    }

    private func quarantine(_ file: URL) throws {
        let directory = directoryURL.appending(path: "Rejected Focus Requests", directoryHint: .isDirectory)
        do {
            try prepareDirectory(directory)
            let destination = directory.appending(
                path: "\(file.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).json",
                directoryHint: .notDirectory
            )
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            throw FocusBridgeStoreError.unwritable
        }
    }

    private func prepareDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw FocusBridgeStoreError.unwritable
        }
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw FocusBridgeStoreError.unwritable
        }
    }

    private func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url))
        } catch {
            throw FocusBridgeStoreError.unreadable
        }
    }
}

public enum FocusBridgeStoreError: LocalizedError, Equatable {
    case unavailable
    case unreadable
    case unwritable
    case unsupportedVersion

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "focus automation is unavailable because dockit cannot open its shared local storage."
        case .unreadable:
            "dockit could not read a pending focus request."
        case .unwritable:
            "dockit could not update the shared local data used by focus automation."
        case .unsupportedVersion:
            "dockit found focus data from an unsupported version."
        }
    }
}
