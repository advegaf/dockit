import Darwin
import Foundation

public actor DockLibraryStore {
    public let fileURL: URL
    private let fileManager: FileManager

    public init(
        fileURL: URL = DockLibraryStore.defaultFileURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport
            .appending(path: "Dockit", directoryHint: .isDirectory)
            .appending(path: "library.json", directoryHint: .notDirectory)
    }

    public func load() async throws -> DockLibrary? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw DockLibraryStoreError.unreadable
        }

        let decoded: DockLibrary
        do {
            decoded = try JSONDecoder().decode(DockLibrary.self, from: data)
        } catch let error as DockLibraryError {
            throw error
        } catch {
            throw DockLibraryStoreError.unreadable
        }

        let library = try decoded.migratedToCurrentSchema(fileManager: fileManager)
        if decoded.schemaVersion != library.schemaVersion {
            try write(library)
        }
        return library
    }

    public func save(_ library: DockLibrary) throws {
        try write(library.validated())
    }

    private func write(_ library: DockLibrary) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(library)
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let stagingDirectory = directory.appending(path: ".dockit-save-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? fileManager.removeItem(at: stagingDirectory) }
            let stagedFile = stagingDirectory.appending(path: "library.json")
            try data.write(to: stagedFile, options: [.completeFileProtection])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedFile.path)
            try stagedFile.withUnsafeFileSystemRepresentation { source in
                try fileURL.withUnsafeFileSystemRepresentation { destination in
                    guard let source, let destination else { throw DockLibraryStoreError.unwritable }
                    guard Darwin.rename(source, destination) == 0 else {
                        let code = errno
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                    }
                }
            }
        } catch let error as DockLibraryError {
            throw error
        } catch {
            throw DockLibraryStoreError.unwritable
        }
    }
}

public enum DockLibraryStoreError: LocalizedError, Equatable {
    case unreadable
    case unwritable

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            "dockit could not read its local profile library. the file was left unchanged."
        case .unwritable:
            "dockit could not save its local profile library. your last saved profiles were left unchanged."
        }
    }
}
