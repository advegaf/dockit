import Foundation

public enum ActivationSource: String, Codable, Sendable {
    case manual
    case focus
}

public struct ActiveProfile: Codable, Equatable, Sendable {
    public var profileID: UUID
    public var source: ActivationSource
    public var appliedAt: Date
    public var appliedLayout: DockLayout?

    public init(
        profileID: UUID,
        source: ActivationSource,
        appliedAt: Date = Date(),
        appliedLayout: DockLayout? = nil
    ) {
        self.profileID = profileID
        self.source = source
        self.appliedAt = appliedAt
        self.appliedLayout = appliedLayout
    }
}

public struct DockProfileRecord: Codable, Identifiable, Equatable, Sendable {
    public var profile: DockProfile
    public var localState: DockProfileLocalState

    public var id: UUID { profile.id }

    public init(profile: DockProfile, localState: DockProfileLocalState = DockProfileLocalState()) {
        self.profile = profile
        self.localState = localState
    }
}

public struct PendingDockApply: Codable, Equatable, Sendable {
    public var profileID: UUID
    public var source: ActivationSource
    public var previousSnapshot: DockSnapshot
    public var intendedSnapshot: DockSnapshot
    public var startedAt: Date
    public var activationRequestedAt: Date?
    public var focusRequestID: UUID?
    public var intendedLayout: DockLayout?
    /// The Dock process that was running when the intended snapshot was
    /// written. Recovery compares it with the current Dock to tell whether
    /// the written layout has already been loaded. Older libraries decode nil,
    /// which recovery treats as unknown and restarts the Dock.
    public var dockProcessIdentifier: Int32?

    public init(
        profileID: UUID,
        source: ActivationSource,
        previousSnapshot: DockSnapshot,
        intendedSnapshot: DockSnapshot,
        startedAt: Date = Date(),
        activationRequestedAt: Date? = nil,
        focusRequestID: UUID? = nil,
        intendedLayout: DockLayout? = nil,
        dockProcessIdentifier: Int32? = nil
    ) {
        self.profileID = profileID
        self.source = source
        self.previousSnapshot = previousSnapshot
        self.intendedSnapshot = intendedSnapshot
        self.startedAt = startedAt
        self.activationRequestedAt = activationRequestedAt
        self.focusRequestID = focusRequestID
        self.intendedLayout = intendedLayout
        self.dockProcessIdentifier = dockProcessIdentifier
    }
}

public struct DockLibrary: Codable, Equatable, Sendable {
    public static let schemaVersion = 2

    public var schemaVersion: Int
    public var profiles: [DockProfileRecord]
    public var selectedProfileID: UUID?
    public var activeProfile: ActiveProfile?
    public var lastKnownDock: DockSnapshot?
    public var pendingApply: PendingDockApply?
    public var lastHandledFocusRequest: FocusRequestWatermark?

    public init(
        schemaVersion: Int = DockLibrary.schemaVersion,
        profiles: [DockProfileRecord] = [],
        selectedProfileID: UUID? = nil,
        activeProfile: ActiveProfile? = nil,
        lastKnownDock: DockSnapshot? = nil,
        pendingApply: PendingDockApply? = nil,
        lastHandledFocusRequest: FocusRequestWatermark? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.selectedProfileID = selectedProfileID
        self.activeProfile = activeProfile
        self.lastKnownDock = lastKnownDock
        self.pendingApply = pendingApply
        self.lastHandledFocusRequest = lastHandledFocusRequest
    }

    public func validated() throws -> DockLibrary {
        guard schemaVersion == Self.schemaVersion else {
            throw DockLibraryError.unsupportedLibraryVersion(schemaVersion)
        }
        let identifiers = profiles.map(\.id)
        guard Set(identifiers).count == identifiers.count else {
            throw DockLibraryError.duplicateProfileIdentifier
        }
        for record in profiles {
            let profile = record.profile
            try Self.validateProfileName(profile.name)
            guard Set(profile.items.map(\.id)).count == profile.items.count else {
                throw DockLibraryError.duplicateItemIdentifier
            }
            for item in profile.items {
                guard case let .application(app) = item.kind else { continue }
                guard
                    app.path.hasPrefix("/"),
                    !app.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    app.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true
                else {
                    throw DockLibraryError.invalidApp
                }
            }
        }
        if let selectedProfileID, !identifiers.contains(selectedProfileID) {
            throw DockLibraryError.missingSelectedProfile
        }
        if let activeProfile, !identifiers.contains(activeProfile.profileID) {
            throw DockLibraryError.missingActiveProfile
        }
        return self
    }

    public func record(id: UUID) -> DockProfileRecord? {
        profiles.first(where: { $0.id == id })
    }

    public func hasPendingChanges(profileID: UUID) -> Bool {
        guard
            activeProfile?.profileID == profileID,
            let appliedLayout = activeProfile?.appliedLayout,
            let record = record(id: profileID)
        else { return false }
        return DockLayout(profile: record.profile) != appliedLayout
    }

    func migratedToCurrentSchema(fileManager: FileManager) throws -> DockLibrary {
        switch schemaVersion {
        case Self.schemaVersion:
            return try validated()
        case 1:
            var migrated = self
            migrated.schemaVersion = Self.schemaVersion
            if var activeProfile = migrated.activeProfile {
                activeProfile.appliedLayout = nil
                if
                    let record = migrated.record(id: activeProfile.profileID),
                    let lastKnownDock = migrated.lastKnownDock,
                    let dockLayout = try? DockLayout(snapshot: lastKnownDock)
                {
                    let profileLayout = DockLayout(profile: record.profile)
                    let availableLayout = profileLayout.retainingAvailableApplications(
                        fileManager: fileManager
                    )
                    if availableLayout == dockLayout {
                        activeProfile.appliedLayout = profileLayout
                    }
                }
                migrated.activeProfile = activeProfile
            }
            return try migrated.validated()
        default:
            throw DockLibraryError.unsupportedLibraryVersion(schemaVersion)
        }
    }

    public mutating func advanceFocusWatermark(to candidate: FocusRequestWatermark) {
        if candidate.isNewer(than: lastHandledFocusRequest) {
            lastHandledFocusRequest = candidate
        }
    }

    @discardableResult
    public mutating func add(_ record: DockProfileRecord, select: Bool = true) -> UUID {
        profiles.append(record)
        if select { selectedProfileID = record.id }
        return record.id
    }

    @discardableResult
    public mutating func duplicate(id: UUID) throws -> UUID {
        guard let source = record(id: id) else { throw DockLibraryError.profileNotFound }
        try Self.validateProfileName(source.profile.name)
        let names = Set(profiles.map { $0.profile.name.localizedLowercase })
        var copy = source
        copy.profile.id = UUID()
        copy.profile.name = Self.availableName(
            base: source.profile.name,
            preferredDuplicateName: "\(source.profile.name) copy",
            existing: names
        )
        copy.profile.createdAt = Date()
        copy.profile.updatedAt = copy.profile.createdAt
        profiles.append(copy)
        selectedProfileID = copy.id
        return copy.id
    }

    public mutating func delete(id: UUID) throws {
        guard profiles.count > 1 else { throw DockLibraryError.finalProfile }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw DockLibraryError.profileNotFound
        }
        profiles.remove(at: index)
        if selectedProfileID == id {
            selectedProfileID = profiles[min(index, profiles.count - 1)].id
        }
        if activeProfile?.profileID == id {
            activeProfile = nil
        }
    }

    public mutating func replace(_ record: DockProfileRecord) throws {
        guard let index = profiles.firstIndex(where: { $0.id == record.id }) else {
            throw DockLibraryError.profileNotFound
        }
        profiles[index] = record
    }

    public mutating func appendImported(_ archive: DockitArchive) throws -> [UUID] {
        try archive.validate()
        var existingNames = Set(profiles.map { $0.profile.name.localizedLowercase })
        var identifiers: [UUID] = []
        for imported in archive.profiles {
            var profile = imported
            profile.id = UUID()
            profile.name = Self.availableName(base: profile.name, existing: existingNames)
            profile.createdAt = Date()
            profile.updatedAt = profile.createdAt
            existingNames.insert(profile.name.localizedLowercase)
            profiles.append(DockProfileRecord(profile: profile))
            identifiers.append(profile.id)
        }
        selectedProfileID = identifiers.last ?? selectedProfileID
        return identifiers
    }

    private static func availableName(
        base: String,
        preferredDuplicateName: String? = nil,
        existing: Set<String>
    ) -> String {
        guard existing.contains(base.localizedLowercase) else { return base }
        if let preferredDuplicateName,
           preferredDuplicateName.count <= DockProfile.maximumNameLength,
           !existing.contains(preferredDuplicateName.localizedLowercase)
        {
            return preferredDuplicateName
        }
        var suffix = 2
        var candidate = fittedGeneratedName(base: base, suffix: suffix)
        while existing.contains(candidate.localizedLowercase) {
            suffix += 1
            candidate = fittedGeneratedName(base: base, suffix: suffix)
        }
        return candidate
    }

    private static func fittedGeneratedName(base: String, suffix: Int) -> String {
        let ending = " \(suffix)"
        let prefixCount = max(DockProfile.maximumNameLength - ending.count, 1)
        return "\(base.prefix(prefixCount))\(ending)"
    }

    private static func validateProfileName(_ name: String) throws {
        do {
            try DockProfile.validateName(name)
        } catch DockProfileNameError.empty {
            throw DockLibraryError.emptyProfileName
        } catch DockProfileNameError.tooLong {
            throw DockLibraryError.profileNameTooLong
        }
    }
}

public enum DockLibraryError: LocalizedError, Equatable {
    case unsupportedLibraryVersion(Int)
    case duplicateProfileIdentifier
    case duplicateItemIdentifier
    case emptyProfileName
    case profileNameTooLong
    case invalidApp
    case missingSelectedProfile
    case missingActiveProfile
    case profileNotFound
    case finalProfile

    public var errorDescription: String? {
        switch self {
        case let .unsupportedLibraryVersion(version):
            "this dockit library uses unsupported version \(version)."
        case .duplicateProfileIdentifier:
            "two saved docks have the same identifier."
        case .duplicateItemIdentifier:
            "a saved dock contains duplicate item identifiers."
        case .emptyProfileName:
            "every saved dock needs a name."
        case .profileNameTooLong:
            "saved dock names can use up to \(DockProfile.maximumNameLength) characters."
        case .invalidApp:
            "a saved dock contains an invalid app entry."
        case .missingSelectedProfile:
            "the selected dock is missing."
        case .missingActiveProfile:
            "the active dock is missing."
        case .profileNotFound:
            "dockit could not find that dock."
        case .finalProfile:
            "keep at least one dock."
        }
    }
}
