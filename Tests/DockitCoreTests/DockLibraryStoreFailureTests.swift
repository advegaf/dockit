import Foundation
import Testing
@testable import DockitCore

struct DockLibraryStoreFailureTests {
    @Test
    func failedPermissionUpdatePreservesExistingLibraryBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "dockit-store-failure-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "library.json")
        let profile = DockProfile(name: "work", color: .blue, items: [
            DockItem(kind: .spacer(.small))
        ])
        let originalLibrary = DockLibrary(
            profiles: [DockProfileRecord(profile: profile)],
            selectedProfileID: profile.id
        )
        let store = DockLibraryStore(fileURL: fileURL)
        try await store.save(originalLibrary)
        let originalBytes = try Data(contentsOf: fileURL)

        var changedLibrary = originalLibrary
        changedLibrary.profiles[0].profile.items.append(DockItem(kind: .spacer(.regular)))
        let failingStore = DockLibraryStore(
            fileURL: fileURL,
            fileManager: PermissionUpdateFailingFileManager()
        )

        await #expect(throws: DockLibraryStoreError.unwritable) {
            try await failingStore.save(changedLibrary)
        }

        let resultingBytes = try Data(contentsOf: fileURL)
        #expect(resultingBytes == originalBytes)
    }

    @Test
    func migrationPermissionFailurePreservesVersionOneBytes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appending(path: "library.json")
        var legacy = libraryWithSmallSpacer()
        legacy.schemaVersion = 1
        let originalBytes = try JSONEncoder().encode(legacy)
        try originalBytes.write(to: fileURL)
        let store = DockLibraryStore(
            fileURL: fileURL,
            fileManager: PermissionUpdateFailingFileManager()
        )

        await #expect(throws: DockLibraryStoreError.unwritable) {
            _ = try await store.load()
        }

        #expect(try Data(contentsOf: fileURL) == originalBytes)
    }

    @Test
    func firstSavePermissionFailureLeavesNoDestination() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "library.json")
        let store = DockLibraryStore(
            fileURL: fileURL,
            fileManager: PermissionUpdateFailingFileManager()
        )

        await #expect(throws: DockLibraryStoreError.unwritable) {
            try await store.save(libraryWithSmallSpacer())
        }

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test
    func successfulReplacementUsesExactlyOwnerReadWritePermissions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "library.json")
        let store = DockLibraryStore(fileURL: fileURL)
        var library = libraryWithSmallSpacer()
        try await store.save(library)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        library.profiles[0].profile.items.append(DockItem(kind: .spacer(.regular)))

        try await store.save(library)

        let permissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions]
            as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(try await store.load() == library)
    }

    @Test
    func missingStagedFileAtCommitPreservesExistingLibraryBytes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "library.json")
        let originalLibrary = libraryWithSmallSpacer()
        try await DockLibraryStore(fileURL: fileURL).save(originalLibrary)
        let originalBytes = try Data(contentsOf: fileURL)
        var changedLibrary = originalLibrary
        changedLibrary.profiles[0].profile.items.append(DockItem(kind: .spacer(.regular)))
        let store = DockLibraryStore(
            fileURL: fileURL,
            fileManager: DisappearingStagedFileManager(destinationURL: fileURL)
        )

        await #expect(throws: DockLibraryStoreError.unwritable) {
            try await store.save(changedLibrary)
        }

        #expect(try Data(contentsOf: fileURL) == originalBytes)
    }

    @Test
    func cleanupFailureAfterCommitKeepsSuccessfulSave() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "library.json")
        var library = libraryWithSmallSpacer()
        try await DockLibraryStore(fileURL: fileURL).save(library)
        library.profiles[0].profile.items.append(DockItem(kind: .spacer(.regular)))
        let cleanupAttempt = CleanupAttempt()
        let store = DockLibraryStore(
            fileURL: fileURL,
            fileManager: CleanupFailingFileManager(cleanupAttempt: cleanupAttempt)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let expectedBytes = try encoder.encode(library)

        try await store.save(library)

        #expect(cleanupAttempt.didOccur)
        #expect(try Data(contentsOf: fileURL) == expectedBytes)
        #expect(try await store.load() == library)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "dockit-store-failure-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func libraryWithSmallSpacer() -> DockLibrary {
        let profile = DockProfile(name: "work", color: .blue, items: [
            DockItem(kind: .spacer(.small))
        ])
        return DockLibrary(
            profiles: [DockProfileRecord(profile: profile)],
            selectedProfileID: profile.id
        )
    }
}

private final class PermissionUpdateFailingFileManager: FileManager, @unchecked Sendable {
    override func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private final class DisappearingStagedFileManager: FileManager, @unchecked Sendable {
    private let destinationURL: URL

    init(destinationURL: URL) {
        self.destinationURL = destinationURL
        super.init()
    }

    override func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        try super.setAttributes(attributes, ofItemAtPath: path)
        if path != destinationURL.path {
            try super.removeItem(atPath: path)
        }
    }
}

private final class CleanupFailingFileManager: FileManager, @unchecked Sendable {
    private let cleanupAttempt: CleanupAttempt

    init(cleanupAttempt: CleanupAttempt) {
        self.cleanupAttempt = cleanupAttempt
        super.init()
    }

    override func removeItem(at url: URL) throws {
        cleanupAttempt.record()
        throw CocoaError(.fileWriteNoPermission)
    }
}

private final class CleanupAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var attemptedCleanup = false

    var didOccur: Bool {
        lock.withLock { attemptedCleanup }
    }

    func record() {
        lock.withLock { attemptedCleanup = true }
    }
}
