import Foundation

public struct DockitArchive: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var exportedAt: Date
    public var profiles: [DockProfile]

    public init(
        version: Int = DockitArchive.currentVersion,
        exportedAt: Date = Date(),
        profiles: [DockProfile]
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.profiles = profiles
    }

    public init(library: DockLibrary, profileIDs: Set<UUID>) throws {
        let profiles = library.profiles
            .filter { profileIDs.contains($0.id) }
            .map(\.profile)
        guard !profiles.isEmpty else { throw DockitArchiveError.noProfiles }
        self.init(profiles: profiles)
    }

    public func validate() throws {
        guard version == Self.currentVersion else {
            throw DockitArchiveError.unsupportedVersion(version)
        }
        guard !profiles.isEmpty else { throw DockitArchiveError.noProfiles }
        guard Set(profiles.map(\.id)).count == profiles.count else {
            throw DockitArchiveError.duplicateProfileIdentifier
        }
        for profile in profiles {
            try Self.validateProfileName(profile.name)
            guard Set(profile.items.map(\.id)).count == profile.items.count else {
                throw DockitArchiveError.duplicateItemIdentifier
            }
            for item in profile.items {
                guard case let .application(app) = item.kind else { continue }
                guard
                    app.path.hasPrefix("/"),
                    !app.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    app.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true
                else {
                    throw DockitArchiveError.invalidApp
                }
            }
        }
    }

    private static func validateProfileName(_ name: String) throws {
        do {
            try DockProfile.validateName(name)
        } catch DockProfileNameError.empty {
            throw DockitArchiveError.emptyProfileName
        } catch DockProfileNameError.tooLong {
            throw DockitArchiveError.profileNameTooLong
        }
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> DockitArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let archive = try decoder.decode(DockitArchive.self, from: data)
            try archive.validate()
            return archive
        } catch let error as DockitArchiveError {
            throw error
        } catch {
            throw DockitArchiveError.invalidFile
        }
    }
}

public enum DockitArchiveError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case noProfiles
    case duplicateProfileIdentifier
    case duplicateItemIdentifier
    case emptyProfileName
    case profileNameTooLong
    case invalidApp
    case invalidFile

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            "this file uses unsupported dockit format version \(version)."
        case .noProfiles:
            "choose at least one dock."
        case .duplicateProfileIdentifier:
            "the file contains duplicate dock identifiers."
        case .duplicateItemIdentifier:
            "the file contains duplicate pinned-item identifiers."
        case .emptyProfileName:
            "every imported dock needs a name."
        case .profileNameTooLong:
            "an imported dock name exceeds \(DockProfile.maximumNameLength) characters. shorten it in the original app or archive, then import again."
        case .invalidApp:
            "the file contains an invalid app entry."
        case .invalidFile:
            "dockit could not read this file. it may be damaged or from an unsupported version."
        }
    }
}
