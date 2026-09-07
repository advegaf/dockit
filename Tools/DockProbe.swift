import AppKit
import CoreFoundation
import CoreGraphics
import DockitCore
import Foundation

actor AuditedDockPreferencesClient: DockPreferencesServing {
    private struct Entry: Encodable {
        let timestamp: Date
        let sequence: Int
        let phase: String
        let operation: String
        let snapshot: DockSnapshot?
        let error: String?
        let freshDomainPersistentApps: DockSnapshot?
        let freshDomainCapturedAt: Date?
        let freshDomainError: String?
    }

    private let client = DockPreferencesClient()
    private let auditURL: URL
    private var phase = "initial"
    private var sequence = 0

    init(reportURL: URL) throws {
        auditURL = reportURL.appendingPathExtension("preferences.jsonl")
        try FileManager.default.createDirectory(
            at: auditURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: auditURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auditURL.path)
    }

    func setPhase(_ value: String) {
        phase = value
        record("phase")
    }

    func assertMutable() async throws {
        try await client.assertMutable()
    }

    func readPersistentApps() async throws -> DockSnapshot {
        do {
            let snapshot = try await client.readPersistentApps()
            record("read", snapshot: snapshot)
            return snapshot
        } catch {
            record("read-failed", error: error.localizedDescription)
            throw error
        }
    }

    func writePersistentApps(_ snapshot: DockSnapshot) async throws {
        record("write-requested", snapshot: snapshot)
        do {
            try await client.writePersistentApps(snapshot)
            record("write-completed", snapshot: snapshot)
        } catch {
            record("write-failed", snapshot: snapshot, error: error.localizedDescription)
            throw error
        }
    }

    private func record(_ operation: String, snapshot: DockSnapshot? = nil, error: String? = nil) {
        sequence += 1
        let timestamp = Date()
        var freshSnapshot: DockSnapshot?
        var freshCapturedAt: Date?
        var freshError: String?
        if phase == "restore", operation == "read" {
            do {
                freshSnapshot = try freshDomainSnapshot()
                freshCapturedAt = Date()
            } catch {
                freshError = error.localizedDescription
            }
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(Entry(
                timestamp: timestamp, sequence: sequence, phase: phase,
                operation: operation, snapshot: snapshot, error: error,
                freshDomainPersistentApps: freshSnapshot,
                freshDomainCapturedAt: freshCapturedAt, freshDomainError: freshError
            ))
            data.append(0x0A)
            let handle = try FileHandle(forWritingTo: auditURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            FileHandle.standardError.write(Data("DOCKIT_PROBE_AUDIT_WRITE_FAILED \(error.localizedDescription)\n".utf8))
        }
    }

    private func freshDomainSnapshot() throws -> DockSnapshot {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["export", "com.apple.dock", "-"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProbeFailure.invariant("Independent Dock read exited with \(process.terminationStatus)")
        }
        guard let domain = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let tiles = domain["persistent-apps"] as? [[String: Any]] else {
            throw ProbeFailure.invariant("Independent Dock read returned invalid pinned apps")
        }
        return try DockSnapshot(rawTiles: tiles)
    }
}

struct ProbeArguments {
    var backup: URL
    var report: URL
    var holdSeconds: Double
    var nonProfileFolder: URL?
    var strategy: DockReloadStrategy
    var reloadMode: ProbeReloadMode = .strategy

    static func parse(_ values: [String] = Array(CommandLine.arguments.dropFirst())) throws -> ProbeArguments {
        func value(after flag: String) throws -> String {
            guard let index = values.firstIndex(of: flag), values.indices.contains(index + 1) else {
                throw ProbeFailure.invalidArguments("Missing \(flag)")
            }
            return values[index + 1]
        }
        let backup = URL(fileURLWithPath: try value(after: "--backup")).standardizedFileURL
        let report = URL(fileURLWithPath: try value(after: "--report")).standardizedFileURL
        guard backup != report else {
            throw ProbeFailure.invalidArguments("The backup and report paths must be different")
        }
        let hold = Double(try value(after: "--hold-seconds")) ?? 5
        guard hold >= 0, hold <= 30 else {
            throw ProbeFailure.invalidArguments("Hold time must be between 0 and 30 seconds")
        }
        let strategy: DockReloadStrategy
        if values.contains("--strategy") {
            guard values.filter({ $0 == "--strategy" }).count == 1 else {
                throw ProbeFailure.invalidArguments("Pass --strategy only once")
            }
            let rawStrategy = try value(after: "--strategy")
            guard let selected = DockReloadStrategy(rawValue: rawStrategy) else {
                throw ProbeFailure.invalidArguments("Unknown probe reload strategy \(rawStrategy)")
            }
            strategy = selected
        } else {
            strategy = .forcedTermination
        }
        let nonProfileFolder: URL?
        if values.contains("--non-profile-folder") {
            guard values.filter({ $0 == "--non-profile-folder" }).count == 1 else {
                throw ProbeFailure.invalidArguments("Pass --non-profile-folder only once")
            }
            let path = try value(after: "--non-profile-folder")
            guard path.hasPrefix("/") else {
                throw ProbeFailure.invalidArguments("The non-profile fixture folder must use an absolute path")
            }
            let folder = URL(fileURLWithPath: path, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                isDirectory.boolValue,
                FileManager.default.isReadableFile(atPath: folder.path)
            else {
                throw ProbeFailure.invalidArguments("The non-profile fixture folder must be a readable directory")
            }
            nonProfileFolder = folder
        } else {
            nonProfileFolder = nil
        }
        let reloadMode: ProbeReloadMode
        if values.contains("--reload") {
            guard values.filter({ $0 == "--reload" }).count == 1 else {
                throw ProbeFailure.invalidArguments("Pass --reload only once")
            }
            let rawMode = try value(after: "--reload")
            guard let selected = ProbeReloadMode(rawValue: rawMode) else {
                throw ProbeFailure.invalidArguments("Unknown probe reload mode \(rawMode)")
            }
            reloadMode = selected
        } else {
            reloadMode = .strategy
        }
        return ProbeArguments(
            backup: backup,
            report: report,
            holdSeconds: hold,
            nonProfileFolder: nonProfileFolder,
            strategy: strategy,
            reloadMode: reloadMode
        )
    }
}

/// Probe-only reload experiments. `strategy` is the product path through
/// `SystemDockReloader`. The others exist to answer one question each on a real
/// Dock and never ship in DockitCore.
enum ProbeReloadMode: String, CaseIterable {
    /// The product reloader with the selected `--strategy`.
    case strategy
    /// Post `com.apple.dock.prefchanged` and never touch the process. Answers
    /// whether the Dock reloads pinned items without a restart.
    case notification
    /// `kill(pid, SIGTERM)`, the signal Firefox sends when it pins itself.
    case sigterm
    /// `launchctl kickstart -k`, so launchd restarts the agent in one step
    /// instead of noticing the exit and respawning it.
    case kickstart

    func makeReloader() -> any DockReloading {
        switch self {
        case .strategy:
            return SystemDockReloader()
        case .notification:
            return NotificationDockReloader()
        case .sigterm:
            return SystemDockReloader(processController: SignalDockProcessController(signal: SIGTERM))
        case .kickstart:
            return SystemDockReloader(processController: KickstartDockProcessController())
        }
    }
}

actor NotificationDockReloader: DockReloading {
    private let controller = SystemDockProcessController()

    func reload() async throws -> DockReloadResult {
        guard let processIdentifier = await controller.dockProcessIdentifier() else {
            throw DockReloadError.notRunning
        }
        await MainActor.run {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.apple.dock.prefchanged"),
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        }
        try await Task.sleep(for: .seconds(2))
        return DockReloadResult(
            previousProcessIdentifier: processIdentifier,
            currentProcessIdentifier: await controller.dockProcessIdentifier() ?? processIdentifier
        )
    }
}

/// Wraps the system controller and replaces only the forced termination.
actor SignalDockProcessController: DockProcessControlling {
    private let inner = SystemDockProcessController()
    private let signal: Int32

    init(signal: Int32) {
        self.signal = signal
    }

    func dockProcessIdentifier() async -> Int32? { await inner.dockProcessIdentifier() }
    func terminateDockGracefully(processIdentifier: Int32) async -> Bool {
        await inner.terminateDockGracefully(processIdentifier: processIdentifier)
    }
    func terminateDockForcibly(processIdentifier: Int32) async -> Bool {
        kill(processIdentifier, signal) == 0
    }
    func waitForDockProcess(excluding processIdentifier: Int32?, timeout: Duration) async -> Int32? {
        await inner.waitForDockProcess(excluding: processIdentifier, timeout: timeout)
    }
    func waitForDockExit(processIdentifier: Int32, timeout: Duration) async -> Bool {
        await inner.waitForDockExit(processIdentifier: processIdentifier, timeout: timeout)
    }
    func launchDock() async -> Bool { await inner.launchDock() }
}

actor KickstartDockProcessController: DockProcessControlling {
    private let inner = SystemDockProcessController()

    func dockProcessIdentifier() async -> Int32? { await inner.dockProcessIdentifier() }
    func terminateDockGracefully(processIdentifier: Int32) async -> Bool {
        await inner.terminateDockGracefully(processIdentifier: processIdentifier)
    }
    func terminateDockForcibly(processIdentifier: Int32) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/com.apple.Dock.agent"]
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
    func waitForDockProcess(excluding processIdentifier: Int32?, timeout: Duration) async -> Int32? {
        await inner.waitForDockProcess(excluding: processIdentifier, timeout: timeout)
    }
    func waitForDockExit(processIdentifier: Int32, timeout: Duration) async -> Bool {
        await inner.waitForDockExit(processIdentifier: processIdentifier, timeout: timeout)
    }
    func launchDock() async -> Bool { await inner.launchDock() }
}

enum ProbeFailure: LocalizedError {
    case invalidArguments(String)
    case backupExists(String)
    case invariant(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message), let .invariant(message): message
        case let .backupExists(path): "The backup already exists at \(path)."
        }
    }
}

struct ProcessIdentity: Codable, Hashable {
    var bundleIdentifier: String
    var processIdentifier: Int32
}

struct WindowIdentity: Codable, Hashable {
    var ownerProcessIdentifier: Int32
    var windowNumber: Int
    var layer: Int
    var bounds: String
}

struct ProbeReport: Codable {
    var startedAt: Date
    var finishedAt: Date
    var appliedProfileItems: Int
    var restoredOriginal: Bool
    var foldersPreserved: Bool
    var recentAppsSettingPreserved: Bool
    var recentAppsRemainedValid: Bool
    var recentAppsRecomputedByDock: Bool
    var settingsPreservedDuringApply: Bool
    var settingsPreservedAfterRestore: Bool
    var regularAppsPreservedDuringApply: Bool
    var regularAppsPreservedAfterRestore: Bool
    var windowsPreservedDuringApply: Bool
    var windowsPreservedAfterRestore: Bool
    var originalDockProcessIdentifier: Int32?
    var fixtureDockProcessIdentifier: Int32?
    var restoredDockProcessIdentifier: Int32?
    var skippedApps: [SkippedDockApp]
    var nonProfileFixtureFolder: String?
    var nonProfileFixtureReloadDockProcessIdentifier: Int32?
    var nonProfileRecentAppsNonemptyAfterReload: Bool?
    var nonProfileRecentAppsNonemptyAfterProfileApply: Bool?
    var nonProfileFolderAndSettingsPreservedDuringApply: Bool?
    var nonProfilePlistValuesRestored: Bool?
}

struct DockReloadBenchmarkArguments {
    static let requiredSwitchCount = 20

    var backup: URL
    var report: URL
    var recoveryMarker: URL
    var strategy: DockReloadStrategy
    var switchCount: Int

    static func parse() throws -> DockReloadBenchmarkArguments {
        try parse(Array(CommandLine.arguments.dropFirst()))
    }

    static func parse(_ values: [String]) throws -> DockReloadBenchmarkArguments {
        let requiredFlags = [
            "--benchmark-reload",
            "--confirm-real-dock-mutation",
            "--backup",
            "--report",
            "--recovery-marker",
            "--strategy",
            "--switch-count",
        ]
        guard
            values.count == 12,
            requiredFlags.allSatisfy({ flag in values.filter { $0 == flag }.count == 1 })
        else {
            throw ProbeFailure.invalidArguments(
                "Benchmark usage: --benchmark-reload --confirm-real-dock-mutation --strategy <strategy> --switch-count 20 --backup <absolute path> --report <absolute path> --recovery-marker <absolute path>"
            )
        }

        func value(after flag: String) throws -> String {
            guard let index = values.firstIndex(of: flag), values.indices.contains(index + 1) else {
                throw ProbeFailure.invalidArguments("Missing \(flag)")
            }
            return values[index + 1]
        }

        let backupPath = try value(after: "--backup")
        let reportPath = try value(after: "--report")
        let recoveryMarkerPath = try value(after: "--recovery-marker")
        guard backupPath.hasPrefix("/"), reportPath.hasPrefix("/"), recoveryMarkerPath.hasPrefix("/") else {
            throw ProbeFailure.invalidArguments("Benchmark backup, report, and recovery-marker paths must be absolute")
        }
        let backup = URL(fileURLWithPath: backupPath).standardizedFileURL
        let report = URL(fileURLWithPath: reportPath).standardizedFileURL
        let recoveryMarker = URL(fileURLWithPath: recoveryMarkerPath).standardizedFileURL
        guard backup != report, backup != recoveryMarker, report != recoveryMarker else {
            throw ProbeFailure.invalidArguments("The benchmark backup, report, and recovery-marker paths must be different")
        }
        let rawStrategy = try value(after: "--strategy")
        guard let strategy = DockReloadStrategy(rawValue: rawStrategy) else {
            throw ProbeFailure.invalidArguments("Unknown benchmark reload strategy \(rawStrategy)")
        }
        guard let switchCount = Int(try value(after: "--switch-count")) else {
            throw ProbeFailure.invalidArguments("Benchmark switch count must be an integer")
        }
        guard switchCount == requiredSwitchCount else {
            throw ProbeFailure.invalidArguments(
                "The reload benchmark requires exactly \(requiredSwitchCount) switches per strategy"
            )
        }
        return DockReloadBenchmarkArguments(
            backup: backup,
            report: report,
            recoveryMarker: recoveryMarker,
            strategy: strategy,
            switchCount: switchCount
        )
    }
}

enum BenchmarkWindowStatus: String, Codable, Equatable {
    case preserved
    case changed
    case inconclusive
}

enum BenchmarkRecoveryMarkerState: String, Codable, Equatable {
    case active = "DOCKIT_BENCHMARK_RECOVERY_ACTIVE"
    case restored = "DOCKIT_BENCHMARK_RECOVERY_RESTORED"
    case noMutation = "DOCKIT_BENCHMARK_RECOVERY_NO_MUTATION"
}

struct BenchmarkIgnoredRuntimeKey: Codable, Equatable {
    var key: String
    var rationale: String
}

struct BenchmarkReloadEvent: Codable, Equatable {
    var previousProcessIdentifier: Int32
    var currentProcessIdentifier: Int32
    var strategy: DockReloadStrategy
    var usedForcedFallback: Bool

    init(_ result: DockReloadResult) {
        previousProcessIdentifier = result.previousProcessIdentifier
        currentProcessIdentifier = result.currentProcessIdentifier
        strategy = result.strategy
        usedForcedFallback = result.usedForcedFallback
    }
}

struct DockReloadBenchmarkSwitchReport: Codable, Equatable {
    var iteration: Int
    var profileName: String
    var elapsedMilliseconds: Double
    var reload: BenchmarkReloadEvent?
    var skippedApps: [SkippedDockApp]
    var nonPinnedPreferenceChangedKeys: [String]
    var regularApps: [ProcessIdentity]
    var regularAppsPreserved: Bool
    var windowRecords: [WindowIdentity]?
    var windows: BenchmarkWindowStatus
    var failure: String?
}

struct DockReloadBenchmarkReport: Codable, Equatable {
    static let schemaVersion = 2
    static let ignoredRuntimeKeyRationales = [
        BenchmarkIgnoredRuntimeKey(
            key: "mod-count",
            rationale: "The Dock updates this mutation counter while saving preferences. It is not a user setting."
        ),
    ]
    static let ignoredRuntimeKeys = ignoredRuntimeKeyRationales.map(\.key)

    var schemaVersion: Int
    var startedAt: Date
    var finishedAt: Date
    var strategy: DockReloadStrategy
    var requiredSwitchCount: Int
    var requestedSwitchCount: Int
    var backupPath: String
    var recoveryMarkerPath: String
    var ignoredRuntimeKeys: [String]
    var ignoredRuntimeKeyRationales: [BenchmarkIgnoredRuntimeKey]
    var baselineDockProcessIdentifier: Int32?
    var baselineRegularApps: [ProcessIdentity]
    var baselineWindowRecords: [WindowIdentity]?
    var switches: [DockReloadBenchmarkSwitchReport]
    var finalNonPinnedPreferenceChangedKeys: [String]
    var finalRegularApps: [ProcessIdentity]
    var finalRegularAppsPreserved: Bool
    var finalWindowRecords: [WindowIdentity]?
    var finalWindows: BenchmarkWindowStatus
    var restorationReload: BenchmarkReloadEvent?
    var recoveryMarkerState: BenchmarkRecoveryMarkerState?
    var restoredOriginal: Bool
    var failure: String?
    var gatePassed: Bool

    init(
        startedAt: Date,
        strategy: DockReloadStrategy,
        requestedSwitchCount: Int,
        backupPath: String,
        recoveryMarkerPath: String
    ) {
        schemaVersion = Self.schemaVersion
        self.startedAt = startedAt
        finishedAt = startedAt
        self.strategy = strategy
        requiredSwitchCount = DockReloadBenchmarkArguments.requiredSwitchCount
        self.requestedSwitchCount = requestedSwitchCount
        self.backupPath = backupPath
        self.recoveryMarkerPath = recoveryMarkerPath
        ignoredRuntimeKeys = Self.ignoredRuntimeKeys
        ignoredRuntimeKeyRationales = Self.ignoredRuntimeKeyRationales
        baselineDockProcessIdentifier = nil
        baselineRegularApps = []
        baselineWindowRecords = nil
        switches = []
        finalNonPinnedPreferenceChangedKeys = []
        finalRegularApps = []
        finalRegularAppsPreserved = false
        finalWindowRecords = nil
        finalWindows = .inconclusive
        restorationReload = nil
        recoveryMarkerState = nil
        restoredOriginal = false
        failure = nil
        gatePassed = false
    }

    func gateFailures() -> [String] {
        var failures: [String] = []
        if schemaVersion != Self.schemaVersion {
            failures.append("Unsupported benchmark report schema")
        }
        if requiredSwitchCount != DockReloadBenchmarkArguments.requiredSwitchCount {
            failures.append("The report does not require 20 switches")
        }
        if requestedSwitchCount != requiredSwitchCount {
            failures.append("The requested switch count is not the required switch count")
        }
        if ignoredRuntimeKeys != Self.ignoredRuntimeKeys {
            failures.append("The report does not declare the allowed runtime keys")
        }
        if ignoredRuntimeKeyRationales != Self.ignoredRuntimeKeyRationales {
            failures.append("The report does not explain the allowed runtime keys")
        }
        let initialDockProcessIdentifier = baselineDockProcessIdentifier ?? 0
        if initialDockProcessIdentifier <= 0 {
            failures.append("The report has no baseline Dock process identifier")
        }
        if baselineRegularApps != DockProbe.canonicalRegularApps(baselineRegularApps) {
            failures.append("The baseline regular-app evidence is not canonical")
        }
        if baselineWindowRecords != DockProbe.canonicalWindows(baselineWindowRecords) {
            failures.append("The baseline window evidence is not canonical")
        }
        if !DockProbe.hasUsableWindowEvidence(
            regularApps: baselineRegularApps,
            windows: baselineWindowRecords
        ) {
            failures.append("The baseline window evidence is inconclusive")
        }
        if switches.count != requiredSwitchCount {
            failures.append("Completed \(switches.count) of \(requiredSwitchCount) switches")
        }
        if switches.map(\.iteration) != Array(1 ... requiredSwitchCount) {
            failures.append("The switch records are not a complete ordered sequence")
        }
        var expectedPreviousDockProcessIdentifier = initialDockProcessIdentifier
        for result in switches {
            if result.reload == nil {
                failures.append("Switch \(result.iteration) did not reload the Dock")
            }
            if result.reload?.strategy != strategy {
                failures.append("Switch \(result.iteration) used the wrong reload strategy")
            }
            if let reload = result.reload {
                if reload.previousProcessIdentifier <= 0
                    || reload.currentProcessIdentifier <= 0
                    || reload.previousProcessIdentifier == reload.currentProcessIdentifier
                {
                    failures.append("Switch \(result.iteration) has invalid Dock process evidence")
                }
                if reload.previousProcessIdentifier != expectedPreviousDockProcessIdentifier {
                    failures.append("Switch \(result.iteration) has a discontinuous Dock process sequence")
                }
                expectedPreviousDockProcessIdentifier = reload.currentProcessIdentifier
                if strategy != .gracefulTerminationWithForcedFallback, reload.usedForcedFallback {
                    failures.append("Switch \(result.iteration) reported an unexpected forced fallback")
                }
            }
            if !result.skippedApps.isEmpty {
                failures.append("Switch \(result.iteration) skipped one or more apps")
            }
            if !result.nonPinnedPreferenceChangedKeys.isEmpty {
                failures.append("Switch \(result.iteration) changed non-pinned preferences")
            }
            if !result.regularAppsPreserved {
                failures.append("Switch \(result.iteration) changed the regular-app set")
            }
            if result.regularApps != baselineRegularApps {
                failures.append("Switch \(result.iteration) has different regular-app evidence")
            }
            if result.regularApps != DockProbe.canonicalRegularApps(result.regularApps) {
                failures.append("Switch \(result.iteration) has non-canonical regular-app evidence")
            }
            if result.windows != .preserved {
                failures.append("Switch \(result.iteration) has \(result.windows.rawValue) window evidence")
            }
            if result.windowRecords != baselineWindowRecords {
                failures.append("Switch \(result.iteration) has different window evidence")
            }
            if result.windowRecords != DockProbe.canonicalWindows(result.windowRecords) {
                failures.append("Switch \(result.iteration) has non-canonical window evidence")
            }
            if !DockProbe.hasUsableWindowEvidence(
                regularApps: result.regularApps,
                windows: result.windowRecords
            ) {
                failures.append("Switch \(result.iteration) has inconclusive raw window evidence")
            }
            if result.failure != nil {
                failures.append("Switch \(result.iteration) failed")
            }
        }
        if !finalNonPinnedPreferenceChangedKeys.isEmpty {
            failures.append("The final Dock domain changed non-pinned preferences")
        }
        if !finalRegularAppsPreserved {
            failures.append("The final regular-app set changed")
        }
        if finalRegularApps != baselineRegularApps {
            failures.append("The final regular-app evidence changed")
        }
        if finalRegularApps != DockProbe.canonicalRegularApps(finalRegularApps) {
            failures.append("The final regular-app evidence is not canonical")
        }
        if finalWindows != .preserved {
            failures.append("The final window evidence is \(finalWindows.rawValue)")
        }
        if finalWindowRecords != baselineWindowRecords {
            failures.append("The final window evidence changed")
        }
        if finalWindowRecords != DockProbe.canonicalWindows(finalWindowRecords) {
            failures.append("The final window evidence is not canonical")
        }
        if !DockProbe.hasUsableWindowEvidence(
            regularApps: finalRegularApps,
            windows: finalWindowRecords
        ) {
            failures.append("The final raw window evidence is inconclusive")
        }
        if let restorationReload {
            if restorationReload.previousProcessIdentifier <= 0
                || restorationReload.currentProcessIdentifier <= 0
                || restorationReload.previousProcessIdentifier == restorationReload.currentProcessIdentifier
            {
                failures.append("The restoration has invalid Dock process evidence")
            }
            if restorationReload.strategy != .forcedTermination || restorationReload.usedForcedFallback {
                failures.append("The restoration did not use the forced baseline strategy")
            }
            if restorationReload.previousProcessIdentifier != expectedPreviousDockProcessIdentifier {
                failures.append("The restoration has a discontinuous Dock process sequence")
            }
        } else {
            failures.append("The restoration did not reload the Dock")
        }
        if recoveryMarkerState != .restored {
            failures.append("The benchmark recovery marker does not confirm restoration")
        }
        if !restoredOriginal {
            failures.append("The original Dock did not restore")
        }
        if failure != nil {
            failures.append("The benchmark reported a failure")
        }
        return failures
    }
}

struct DockPreferenceValueSnapshot {
    var exists: Bool
    var propertyListData: Data?

    init(value: Any?) throws {
        guard let value else {
            exists = false
            propertyListData = nil
            return
        }
        guard PropertyListSerialization.propertyList(value, isValidFor: .binary) else {
            throw ProbeFailure.invariant("A non-profile Dock preference is not a valid property list")
        }
        exists = true
        propertyListData = try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .binary,
            options: 0
        )
    }

    func decodedValue() throws -> Any? {
        guard exists else { return nil }
        guard let propertyListData else {
            throw ProbeFailure.invariant("A non-profile Dock preference snapshot is incomplete")
        }
        return try PropertyListSerialization.propertyList(from: propertyListData, format: nil)
    }

    func matches(_ value: Any?) throws -> Bool {
        guard exists == (value != nil) else { return false }
        guard exists else { return true }
        return DockProbe.equalValue(try decodedValue(), value)
    }
}

struct NonProfileFixture {
    static let keys = ["persistent-others", "show-recents", "recent-apps"]

    var folder: URL
    var originalValues: [String: DockPreferenceValueSnapshot]
    var fixtureFolders: [[String: Any]]
    var fixtureRecentApps: [[String: Any]]
    var folderIdentifier: UInt32
    var recentAppIdentifier: UInt32

    init(folder: URL, domain: [String: Any]) throws {
        guard !Self.keys.contains(where: DockProbe.isDockPreferenceForced) else {
            throw ProbeFailure.invariant("A configuration profile manages the non-profile Dock fixture values")
        }
        let existingFolders: [[String: Any]]
        if let value = domain["persistent-others"] {
            guard let folders = value as? [[String: Any]] else {
                throw ProbeFailure.invariant("The existing persistent-others value is invalid")
            }
            existingFolders = folders
        } else {
            existingFolders = []
        }
        guard !existingFolders.contains(where: { Self.folderURL(in: $0) == folder }) else {
            throw ProbeFailure.invariant("The non-profile fixture folder is already pinned in the Dock")
        }
        if let showRecents = domain["show-recents"] {
            guard showRecents is NSNumber else {
                throw ProbeFailure.invariant("The existing show-recents value is invalid")
            }
        }
        if let recentApps = domain["recent-apps"] {
            guard recentApps is [Any] else {
                throw ProbeFailure.invariant("The existing recent-apps value is invalid")
            }
        }

        var originalValues: [String: DockPreferenceValueSnapshot] = [:]
        for key in Self.keys {
            originalValues[key] = try DockPreferenceValueSnapshot(value: domain[key])
        }

        var usedIdentifiers = Self.tileIdentifiers(in: domain)
        let folderIdentifier = Self.nextAvailableIdentifier(avoiding: &usedIdentifiers)
        let tile: [String: Any] = [
            "GUID": Int(folderIdentifier),
            "tile-data": [
                "arrangement": 1,
                "displayas": 0,
                "file-data": [
                    "_CFURLString": folder.absoluteString,
                    "_CFURLStringType": 15,
                ],
                "file-label": folder.lastPathComponent,
                "file-type": 2,
                "preferreditemsize": -1,
                "showas": 1,
            ],
            "tile-type": "directory-tile",
        ]
        let fixtureFolders = existingFolders + [tile]
        guard PropertyListSerialization.propertyList(fixtureFolders, isValidFor: .binary) else {
            throw ProbeFailure.invariant("The non-profile folder fixture is not a valid property list")
        }
        let recentFixture = try Self.makeRecentAppsFixture(
            from: domain,
            avoiding: &usedIdentifiers
        )

        self.folder = folder
        self.originalValues = originalValues
        self.fixtureFolders = fixtureFolders
        self.fixtureRecentApps = recentFixture.tiles
        self.folderIdentifier = folderIdentifier
        self.recentAppIdentifier = recentFixture.identifier
    }

    func apply() throws {
        DockProbe.setDockPreference(fixtureFolders, forKey: "persistent-others")
        DockProbe.setDockPreference(true, forKey: "show-recents")
        DockProbe.setDockPreference(fixtureRecentApps, forKey: "recent-apps")
        try DockProbe.synchronizeDockPreferences()
        let domain = DockProbe.dockDomain()
        try DockProbe.require(
            DockProbe.equalValue(fixtureFolders, domain["persistent-others"]),
            "macOS did not save the folder fixture"
        )
        try DockProbe.require(
            DockProbe.equalValue(fixtureRecentApps, domain["recent-apps"]),
            "macOS did not save the recent app fixture"
        )
        try DockProbe.require(
            (domain["show-recents"] as? NSNumber)?.boolValue == true,
            "macOS did not enable recent apps"
        )
    }

    func verifyLoaded(in domain: [String: Any]) throws {
        try DockProbe.require(
            containsFolderFixture(in: domain),
            "The folder fixture is missing after the Dock reload"
        )
        try DockProbe.require(
            (domain["show-recents"] as? NSNumber)?.boolValue == true,
            "The recent apps setting is disabled after the Dock reload"
        )
        guard let recentApps = domain["recent-apps"] as? [[String: Any]], !recentApps.isEmpty else {
            throw ProbeFailure.invariant("The recent app fixture is empty after the Dock reload")
        }
        try DockProbe.require(
            recentApps.contains(where: {
                Self.identifier(in: $0) == recentAppIdentifier && Self.isValidFileTile($0)
            }),
            "The recent app fixture is missing or invalid after the Dock reload"
        )
    }

    func verifyAfterProfileApply(in domain: [String: Any]) throws {
        try DockProbe.require(
            containsFolderFixture(in: domain),
            "The folder fixture is missing after the profile switch"
        )
        try DockProbe.require(
            (domain["show-recents"] as? NSNumber)?.boolValue == true,
            "The recent apps setting changed during the profile switch"
        )
        guard let recentApps = domain["recent-apps"] as? [[String: Any]], !recentApps.isEmpty else {
            throw ProbeFailure.invariant("The recent apps section became empty after the profile switch")
        }
        try DockProbe.require(
            recentApps.allSatisfy(Self.isValidRecentAppTile),
            "The recent apps section became invalid after the profile switch"
        )
    }

    func restore() throws {
        for key in Self.keys {
            guard let snapshot = originalValues[key] else {
                throw ProbeFailure.invariant("The non-profile Dock preference snapshot is incomplete")
            }
            DockProbe.setDockPreference(try snapshot.decodedValue(), forKey: key)
        }
        try DockProbe.synchronizeDockPreferences()
        try verifyRestored(in: DockProbe.dockDomain())
    }

    func verifyRestored(in domain: [String: Any]) throws {
        for key in Self.keys {
            guard let snapshot = originalValues[key] else {
                throw ProbeFailure.invariant("The non-profile Dock preference snapshot is incomplete")
            }
            try DockProbe.require(
                try snapshot.matches(domain[key]),
                "The original \(key) value did not restore"
            )
        }
    }

    private func containsFolderFixture(in domain: [String: Any]) -> Bool {
        guard let folders = domain["persistent-others"] as? [[String: Any]] else { return false }
        return folders.contains { tile in
            Self.identifier(in: tile) == folderIdentifier && Self.folderURL(in: tile) == folder
        }
    }

    private static func makeRecentAppsFixture(
        from domain: [String: Any],
        avoiding usedIdentifiers: inout Set<UInt32>
    ) throws -> (tiles: [[String: Any]], identifier: UInt32) {
        guard let persistentApps = domain["persistent-apps"] as? [[String: Any]], !persistentApps.isEmpty else {
            throw ProbeFailure.invariant("No pinned app is available to build a safe recent app fixture")
        }
        guard let source = persistentApps.first(where: isValidFileTile) else {
            throw ProbeFailure.invariant("No valid pinned app tile is available to build a safe recent app fixture")
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: source,
            format: .binary,
            options: 0
        )
        guard var clone = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ProbeFailure.invariant("The pinned app tile could not be cloned safely")
        }
        let identifier = nextAvailableIdentifier(avoiding: &usedIdentifiers)
        clone["GUID"] = Int(identifier)
        guard isValidFileTile(clone) else {
            throw ProbeFailure.invariant("The cloned recent app tile is invalid")
        }
        return ([clone], identifier)
    }

    private static func identifier(in tile: [String: Any]) -> UInt32? {
        (tile["GUID"] as? NSNumber)?.uint32Value
    }

    private static func folderURL(in tile: [String: Any]) -> URL? {
        guard
            tile["tile-type"] as? String == "directory-tile",
            let tileData = tile["tile-data"] as? [String: Any],
            let fileData = tileData["file-data"] as? [String: Any],
            let urlString = fileData["_CFURLString"] as? String,
            let url = URL(string: urlString),
            url.isFileURL
        else { return nil }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func tileIdentifiers(in domain: [String: Any]) -> Set<UInt32> {
        let tiles = ["persistent-apps", "persistent-others", "recent-apps"]
            .compactMap { domain[$0] as? [[String: Any]] }
            .flatMap { $0 }
        return Set(tiles.compactMap { ($0["GUID"] as? NSNumber)?.uint32Value })
    }

    private static func nextAvailableIdentifier(avoiding identifiers: inout Set<UInt32>) -> UInt32 {
        var identifier = UInt32.random(in: 1 ... UInt32.max)
        while identifiers.contains(identifier) {
            identifier = UInt32.random(in: 1 ... UInt32.max)
        }
        identifiers.insert(identifier)
        return identifier
    }

    private static func isValidFileTile(_ tile: [String: Any]) -> Bool {
        guard
            tile["tile-type"] as? String == "file-tile",
            let tileData = tile["tile-data"] as? [String: Any],
            let fileData = tileData["file-data"] as? [String: Any],
            let urlString = fileData["_CFURLString"] as? String,
            let url = URL(string: urlString),
            url.isFileURL,
            (fileData["_CFURLStringType"] as? NSNumber)?.intValue == 15,
            (tileData["file-type"] as? NSNumber)?.intValue == 41,
            FileManager.default.fileExists(atPath: url.path),
            Bundle(url: url) != nil,
            PropertyListSerialization.propertyList(tile, isValidFor: .binary)
        else { return false }
        return true
    }

    private static func isValidRecentAppTile(_ tile: [String: Any]) -> Bool {
        guard
            tile["tile-type"] as? String == "file-tile",
            let tileData = tile["tile-data"] as? [String: Any],
            let fileData = tileData["file-data"] as? [String: Any],
            let urlString = fileData["_CFURLString"] as? String,
            let url = URL(string: urlString),
            url.isFileURL,
            FileManager.default.fileExists(atPath: url.path),
            Bundle(url: url) != nil,
            PropertyListSerialization.propertyList(tile, isValidFor: .binary)
        else { return false }
        return true
    }
}

@main
enum DockProbe {
    static func main() async {
        do {
            let values = Array(CommandLine.arguments.dropFirst())
            if let restoreIndex = values.firstIndex(of: "--restore-backup") {
                guard
                    values.filter({ $0 == "--restore-backup" }).count == 1,
                    values.indices.contains(restoreIndex + 1),
                    values.count == 2
                else {
                    throw ProbeFailure.invalidArguments("Pass only --restore-backup and one absolute backup path")
                }
                let path = values[restoreIndex + 1]
                guard path.hasPrefix("/") else {
                    throw ProbeFailure.invalidArguments("The recovery backup must use an absolute path")
                }
                try await restoreDomainBackup(
                    at: URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
                )
            } else if values == ["--probe-arguments-self-test"] {
                try runProbeArgumentsSelfTest()
            } else if values == ["--benchmark-report-self-test"] {
                try runBenchmarkReportSelfTest()
            } else if let reportIndex = values.firstIndex(of: "--validate-benchmark-report") {
                guard
                    values.filter({ $0 == "--validate-benchmark-report" }).count == 1,
                    values.indices.contains(reportIndex + 1),
                    values.count == 2
                else {
                    throw ProbeFailure.invalidArguments(
                        "Pass only --validate-benchmark-report and one absolute report path"
                    )
                }
                let path = values[reportIndex + 1]
                guard path.hasPrefix("/") else {
                    throw ProbeFailure.invalidArguments("The benchmark report path must be absolute")
                }
                try validateBenchmarkReport(
                    at: URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
                )
            } else if values.contains("--benchmark-reload") {
                try await runBenchmark(try DockReloadBenchmarkArguments.parse())
            } else if values.contains("--experiment") {
                try await runExperiment(try ExperimentArguments.parse(values))
            } else {
                let args = try ProbeArguments.parse()
                try await run(args)
            }
        } catch {
            FileHandle.standardError.write(Data("DOCKIT_PROBE_FAILED \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    static func run(_ args: ProbeArguments) async throws {
        guard !FileManager.default.fileExists(atPath: args.backup.path) else {
            throw ProbeFailure.backupExists(args.backup.path)
        }

        let preferences = try AuditedDockPreferencesClient(reportURL: args.report)
        let coordinator: DockApplyCoordinator
        if args.reloadMode == .strategy {
            coordinator = DockApplyCoordinator(
                preferences: preferences,
                reloadConfiguration: DockReloadConfiguration(strategy: args.strategy)
            )
        } else {
            coordinator = DockApplyCoordinator(preferences: preferences, reloader: args.reloadMode.makeReloader())
        }
        // The notification experiment may leave the Dock showing stale tiles, so
        // its restore always goes through the product reloader with a forced
        // restart. The signal experiments restore through themselves so each
        // recording holds two restarts of the same kind.
        let restoreCoordinator = args.reloadMode == .notification
            ? DockApplyCoordinator(preferences: preferences)
            : coordinator
        writeLine("DOCKIT_PROBE_STRATEGY \(args.strategy.rawValue)")
        writeLine("DOCKIT_PROBE_RELOAD_MODE \(args.reloadMode.rawValue)")
        try await preferences.assertMutable()
        let originalDomain = dockDomain()
        guard let originalTiles = originalDomain["persistent-apps"] as? [[String: Any]] else {
            throw ProbeFailure.invariant("The current Dock has no readable pinned apps")
        }
        let original = try DockSnapshot(rawTiles: originalTiles)
        let nonProfileFixture = try args.nonProfileFolder.map {
            try NonProfileFixture(folder: $0, domain: originalDomain)
        }

        try writeDomainBackup(originalDomain, to: args.backup)

        let startedAt = Date()
        let originalApps = regularApps()
        let originalWindows = windows(ownedBy: originalApps)
        let originalDockPID = dockProcessIdentifier()
        let fixture = DockProfile(name: "dockit probe", color: .blue, items: [
            appItem(path: "/System/Applications/Notes.app"),
            DockItem(kind: .spacer(.regular)),
            appItem(path: "/System/Applications/TextEdit.app"),
        ])

        var restored = false
        var mutationStarted = false
        var nonProfileReload: DockReloadResult?
        do {
            try require(
                recoverableStateEqual(originalDomain, dockDomain()),
                "The Dock changed after backup and before the probe could start"
            )
            if let nonProfileFixture {
                mutationStarted = true
                try nonProfileFixture.apply()
                writeLine("DOCKIT_PROBE_NON_PROFILE_FIXTURE_APPLIED \(nonProfileFixture.folder.path)")
                nonProfileReload = try await SystemDockReloader().reload()
                try nonProfileFixture.verifyLoaded(in: dockDomain())
                writeLine("DOCKIT_PROBE_NON_PROFILE_FIXTURE_RELOADED_WITH_RECENT_APP")
            }
            let applyBaselineDomain = dockDomain()
            mutationStarted = true
            await preferences.setPhase("apply")
            let applied = try await coordinator.apply(profile: fixture, localState: DockProfileLocalState())
            let appliedDomain = dockDomain()
            let appliedApps = regularApps()
            let appliedWindows = windows(ownedBy: originalApps)
            if !recentAppsEqual(applyBaselineDomain, appliedDomain) {
                writeLine("DOCKIT_PROBE_RECENT_APPS_BEFORE \(recentAppSummary(applyBaselineDomain))")
                writeLine("DOCKIT_PROBE_RECENT_APPS_AFTER \(recentAppSummary(appliedDomain))")
            }
            if let nonProfileFixture {
                try nonProfileFixture.verifyAfterProfileApply(in: appliedDomain)
            }
            try require(
                foldersEqual(applyBaselineDomain, appliedDomain),
                "Folders changed during apply"
            )
            try require(settingsEqual(applyBaselineDomain, appliedDomain), "A non-profile Dock setting changed during apply")
            try require(originalApps == appliedApps, "A regular app opened or quit during apply")
            try require(originalWindows == appliedWindows, "An app window changed during apply")
            if nonProfileFixture != nil {
                writeLine("DOCKIT_PROBE_NON_PROFILE_FOLDER_AND_SETTINGS_PRESERVED")
            }

            writeLine("DOCKIT_PROBE_APPLIED")
            writeLine("DOCKIT_PROBE_APPLY_RELOAD previous=\(applied.reload?.previousProcessIdentifier ?? -1) current=\(applied.reload?.currentProcessIdentifier ?? -1)")
            let holdStart = ContinuousClock.now
            if args.reloadMode != .notification {
                // The relaunched Dock rewrites persistent-apps on its own a few
                // seconds after launch. Measure that delay: a write that lands
                // before it is overwritten by the Dock's startup flush.
                let flushDelay = await waitForDockFlush(preferences: preferences, written: applied.appliedSnapshot, timeout: .seconds(10))
                writeLine("DOCKIT_PROBE_DOCK_FLUSH_AFTER_MS \(flushDelay.map { String($0) } ?? "none")")
            }
            let remaining = Duration.seconds(args.holdSeconds) - (ContinuousClock.now - holdStart)
            if remaining > .zero { try await Task.sleep(for: remaining) }
            if args.reloadMode == .notification {
                // Did the Dock keep or overwrite the written prefs while it ran on?
                let afterHold = try await preferences.readPersistentApps()
                writeLine("DOCKIT_PROBE_NOTIFICATION_PREFS_STABLE \(afterHold.hasSameLayout(as: applied.appliedSnapshot)) pid=\(dockProcessIdentifier() ?? -1)")
            }

            if let nonProfileFixture {
                try nonProfileFixture.restore()
            }
            await preferences.setPhase("restore")
            let restoredReload = try await restoreCoordinator.restore(
                original,
                forceReload: nonProfileFixture != nil || args.reloadMode == .notification
            )
            writeLine("DOCKIT_PROBE_RESTORE_RELOAD previous=\(restoredReload?.previousProcessIdentifier ?? -1) current=\(restoredReload?.currentProcessIdentifier ?? -1)")
            let finalSnapshot = try await preferences.readPersistentApps()
            let finalDomain = dockDomain()
            let finalApps = regularApps()
            let finalWindows = windows(ownedBy: originalApps)
            try require(finalSnapshot.hasSameLayout(as: original), "Pinned apps did not restore")
            try require(foldersEqual(originalDomain, finalDomain), "Folders did not restore")
            try require(settingsEqual(originalDomain, finalDomain), "A non-profile Dock setting did not restore")
            try require(originalApps == finalApps, "A regular app changed while restoring")
            try require(originalWindows == finalWindows, "An app window changed while restoring")
            if let nonProfileFixture {
                try nonProfileFixture.verifyRestored(in: finalDomain)
                writeLine("DOCKIT_PROBE_NON_PROFILE_FIXTURE_RESTORED")
            }
            restored = true

            let report = ProbeReport(
                startedAt: startedAt,
                finishedAt: Date(),
                appliedProfileItems: fixture.items.count,
                restoredOriginal: true,
                foldersPreserved: true,
                recentAppsSettingPreserved: true,
                recentAppsRemainedValid: true,
                recentAppsRecomputedByDock: !recentAppsEqual(applyBaselineDomain, appliedDomain),
                settingsPreservedDuringApply: true,
                settingsPreservedAfterRestore: true,
                regularAppsPreservedDuringApply: true,
                regularAppsPreservedAfterRestore: true,
                windowsPreservedDuringApply: true,
                windowsPreservedAfterRestore: true,
                originalDockProcessIdentifier: originalDockPID,
                fixtureDockProcessIdentifier: applied.reload?.currentProcessIdentifier,
                restoredDockProcessIdentifier: restoredReload?.currentProcessIdentifier,
                skippedApps: applied.skippedApps,
                nonProfileFixtureFolder: nonProfileFixture?.folder.path,
                nonProfileFixtureReloadDockProcessIdentifier: nonProfileReload?.currentProcessIdentifier,
                nonProfileRecentAppsNonemptyAfterReload: nonProfileFixture.map { _ in true },
                nonProfileRecentAppsNonemptyAfterProfileApply: nonProfileFixture.map { _ in true },
                nonProfileFolderAndSettingsPreservedDuringApply: nonProfileFixture.map { _ in true },
                nonProfilePlistValuesRestored: nonProfileFixture.map { _ in true }
            )
            try write(report, to: args.report)
            writeLine("DOCKIT_PROBE_RESTORED")
            writeLine("DOCKIT_PROBE_PASSED \(args.report.path)")
        } catch {
            if mutationStarted, !restored {
                do {
                    await preferences.setPhase("emergency-restore-before")
                    _ = try? await preferences.readPersistentApps()
                    try await restoreDomain(originalDomain)
                    await preferences.setPhase("emergency-restore-after")
                    _ = try? await preferences.readPersistentApps()
                    restored = true
                    writeLine("DOCKIT_PROBE_FULL_DOMAIN_EMERGENCY_RESTORE_PASSED")
                } catch let restoreError {
                    throw ProbeFailure.invariant(
                        "The probe failed and full Dock recovery also failed. Probe error: \(error.localizedDescription) Recovery error: \(restoreError.localizedDescription) Backup: \(args.backup.path)"
                    )
                }
            }
            throw error
        }
    }

    static func runBenchmark(_ args: DockReloadBenchmarkArguments) async throws {
        guard !FileManager.default.fileExists(atPath: args.backup.path) else {
            throw ProbeFailure.backupExists(args.backup.path)
        }
        guard !FileManager.default.fileExists(atPath: args.report.path) else {
            throw ProbeFailure.invalidArguments("The benchmark report already exists at \(args.report.path)")
        }
        guard !FileManager.default.fileExists(atPath: args.recoveryMarker.path) else {
            throw ProbeFailure.invalidArguments(
                "The benchmark recovery marker already exists at \(args.recoveryMarker.path)"
            )
        }

        let startedAt = Date()
        var report = DockReloadBenchmarkReport(
            startedAt: startedAt,
            strategy: args.strategy,
            requestedSwitchCount: args.switchCount,
            backupPath: args.backup.path,
            recoveryMarkerPath: args.recoveryMarker.path
        )
        let preferences = DockPreferencesClient()
        let recoveryCoordinator = DockApplyCoordinator(preferences: preferences)
        var originalDomain: [String: Any] = [:]
        var originalSnapshot: DockSnapshot?
        var originalApps: Set<ProcessIdentity> = []
        var originalWindows: Set<WindowIdentity>?
        var recoveryRequired = false
        var recoveryMarkerCreated = false
        var completedMutations = 0
        var restored = false

        do {
            try await preferences.assertMutable()
            originalDomain = dockDomain()
            guard let tiles = originalDomain["persistent-apps"] as? [[String: Any]] else {
                throw ProbeFailure.invariant("The current Dock has no readable pinned apps")
            }
            let original = try DockSnapshot(rawTiles: tiles)
            originalSnapshot = original
            try writeDomainBackup(originalDomain, to: args.backup)
            writeLine(
                "DOCKIT_BENCHMARK_BACKUP_WRITTEN strategy=\(args.strategy.rawValue) path=\(args.backup.path)"
            )

            originalApps = regularApps()
            originalWindows = observableWindows(ownedBy: originalApps)
            report.baselineDockProcessIdentifier = dockProcessIdentifier()
            report.baselineRegularApps = canonicalRegularApps(originalApps)
            report.baselineWindowRecords = canonicalWindows(originalWindows)
            guard (report.baselineDockProcessIdentifier ?? 0) > 0 else {
                report.failure = "The Dock process is not running. The Dock was not changed."
                report.finishedAt = Date()
                try write(report, to: args.report)
                throw ProbeFailure.invariant(report.failure ?? "The Dock process is not running")
            }
            guard hasUsableWindowEvidence(
                regularApps: report.baselineRegularApps,
                windows: report.baselineWindowRecords
            ) else {
                report.failure = "Window inspection is inconclusive. The Dock was not changed."
                report.finishedAt = Date()
                try write(report, to: args.report)
                throw ProbeFailure.invariant(report.failure ?? "Window inspection is inconclusive")
            }

            let profiles = benchmarkProfiles()
            let fixtures = try profiles.map {
                try DockSnapshot.build(profile: $0, localState: DockProfileLocalState())
            }
            try require(
                fixtures.allSatisfy(\.skippedApps.isEmpty),
                "A benchmark fixture app is missing. The Dock was not changed."
            )
            try require(
                !fixtures[0].snapshot.hasSameLayout(as: fixtures[1].snapshot),
                "The benchmark fixtures do not produce distinct Dock layouts"
            )
            try require(
                recoverableStateEqual(originalDomain, dockDomain()),
                "The Dock changed after backup and before the benchmark could start"
            )

            let coordinator = DockApplyCoordinator(
                preferences: preferences,
                reloadConfiguration: DockReloadConfiguration(strategy: args.strategy)
            )
            var profileIndex = original.hasSameLayout(as: fixtures[0].snapshot) ? 1 : 0
            writeLine(
                "DOCKIT_BENCHMARK_STARTED strategy=\(args.strategy.rawValue) switches=\(args.switchCount)"
            )

            for iteration in 1 ... args.switchCount {
                let profile = profiles[profileIndex]
                let switchStartedAt = Date()
                writeLine(
                    "DOCKIT_BENCHMARK_SWITCH_BEGIN strategy=\(args.strategy.rawValue) iteration=\(iteration) profile=\(profile.name)"
                )
                if !recoveryMarkerCreated {
                    try createBenchmarkRecoveryMarker(at: args.recoveryMarker)
                    recoveryMarkerCreated = true
                    recoveryRequired = true
                    report.recoveryMarkerState = .active
                }

                let result: DockReloadBenchmarkSwitchReport
                do {
                    let applied = try await coordinator.apply(
                        profile: profile,
                        localState: DockProfileLocalState()
                    )
                    let currentDomain = dockDomain()
                    let currentApps = regularApps()
                    let currentWindows = observableWindows(ownedBy: originalApps)
                    let windowStatus = benchmarkWindowStatus(
                        baseline: originalWindows,
                        current: currentWindows
                    )
                    if applied.reload != nil {
                        completedMutations += 1
                    } else if completedMutations == 0 {
                        try writeBenchmarkRecoveryMarker(.noMutation, to: args.recoveryMarker)
                        report.recoveryMarkerState = .noMutation
                        recoveryRequired = false
                    }
                    result = DockReloadBenchmarkSwitchReport(
                        iteration: iteration,
                        profileName: profile.name,
                        elapsedMilliseconds: Date().timeIntervalSince(switchStartedAt) * 1_000,
                        reload: applied.reload.map(BenchmarkReloadEvent.init),
                        skippedApps: applied.skippedApps,
                        nonPinnedPreferenceChangedKeys: nonPinnedPreferenceChangedKeys(
                            from: originalDomain,
                            to: currentDomain
                        ),
                        regularApps: canonicalRegularApps(currentApps),
                        regularAppsPreserved: currentApps == originalApps,
                        windowRecords: canonicalWindows(currentWindows),
                        windows: windowStatus,
                        failure: nil
                    )
                } catch {
                    if case DockApplyError.dockChangedBeforeApply = error,
                       completedMutations == 0,
                       recoveryMarkerCreated
                    {
                        try writeBenchmarkRecoveryMarker(.noMutation, to: args.recoveryMarker)
                        report.recoveryMarkerState = .noMutation
                        recoveryRequired = false
                    }
                    let currentApps = regularApps()
                    let currentWindows = observableWindows(ownedBy: originalApps)
                    report.switches.append(DockReloadBenchmarkSwitchReport(
                        iteration: iteration,
                        profileName: profile.name,
                        elapsedMilliseconds: Date().timeIntervalSince(switchStartedAt) * 1_000,
                        reload: nil,
                        skippedApps: [],
                        nonPinnedPreferenceChangedKeys: nonPinnedPreferenceChangedKeys(
                            from: originalDomain,
                            to: dockDomain()
                        ),
                        regularApps: canonicalRegularApps(currentApps),
                        regularAppsPreserved: currentApps == originalApps,
                        windowRecords: canonicalWindows(currentWindows),
                        windows: benchmarkWindowStatus(
                            baseline: originalWindows,
                            current: currentWindows
                        ),
                        failure: error.localizedDescription
                    ))
                    throw error
                }
                report.switches.append(result)
                try require(result.reload != nil, "Switch \(iteration) did not reload the Dock")
                try require(
                    result.reload?.strategy == args.strategy,
                    "Switch \(iteration) used the wrong Dock reload strategy"
                )
                try require(
                    result.skippedApps.isEmpty,
                    "Switch \(iteration) skipped one or more fixture apps"
                )
                try require(
                    result.nonPinnedPreferenceChangedKeys.isEmpty,
                    "Switch \(iteration) changed non-pinned Dock preferences: \(result.nonPinnedPreferenceChangedKeys.joined(separator: ", "))"
                )
                try require(
                    result.regularAppsPreserved,
                    "Switch \(iteration) opened or quit a regular app"
                )
                try require(
                    result.windows == .preserved,
                    "Switch \(iteration) has \(result.windows.rawValue) window evidence"
                )
                writeLine(
                    "DOCKIT_BENCHMARK_SWITCH_PASSED strategy=\(args.strategy.rawValue) iteration=\(iteration) elapsed-ms=\(Int(result.elapsedMilliseconds.rounded()))"
                )
                profileIndex = profileIndex == 0 ? 1 : 0
            }

            writeLine("DOCKIT_BENCHMARK_RESTORE_BEGIN strategy=\(args.strategy.rawValue)")
            let restorationReload = try await recoveryCoordinator.restore(original, forceReload: true)
            let restoredDomain = dockDomain()
            let restoredSnapshot = try await preferences.readPersistentApps()
            let finalApps = regularApps()
            let finalWindows = observableWindows(ownedBy: originalApps)
            report.finalNonPinnedPreferenceChangedKeys = nonPinnedPreferenceChangedKeys(
                from: originalDomain,
                to: restoredDomain
            )
            report.finalRegularApps = canonicalRegularApps(finalApps)
            report.finalRegularAppsPreserved = finalApps == originalApps
            report.finalWindowRecords = canonicalWindows(finalWindows)
            report.finalWindows = benchmarkWindowStatus(
                baseline: originalWindows,
                current: finalWindows
            )
            report.restorationReload = restorationReload.map(BenchmarkReloadEvent.init)
            report.restoredOriginal = restoredSnapshot.hasSameLayout(as: original)
                && report.finalNonPinnedPreferenceChangedKeys.isEmpty
                && report.finalRegularAppsPreserved
                && report.finalWindows == .preserved
            try require(report.restoredOriginal, "The original Dock did not restore after the benchmark")
            try writeBenchmarkRecoveryMarker(.restored, to: args.recoveryMarker)
            report.recoveryMarkerState = .restored
            recoveryRequired = false
            restored = true
            report.finishedAt = Date()
            report.gatePassed = report.gateFailures().isEmpty
            try write(report, to: args.report)
            try require(report.gatePassed, "The benchmark did not satisfy its release gate")
            writeLine("DOCKIT_BENCHMARK_RESTORED strategy=\(args.strategy.rawValue)")
            writeLine("DOCKIT_BENCHMARK_PASSED report=\(args.report.path)")
        } catch {
            let benchmarkError = error.localizedDescription
            if recoveryRequired, !restored, let original = originalSnapshot {
                writeLine("DOCKIT_BENCHMARK_EMERGENCY_RESTORE_BEGIN strategy=\(args.strategy.rawValue)")
                do {
                    try await restoreDomain(originalDomain)
                    let recoveredDomain = dockDomain()
                    let recoveredSnapshot = try await preferences.readPersistentApps()
                    let recoveredApps = regularApps()
                    let recoveredWindows = observableWindows(ownedBy: originalApps)
                    report.finalNonPinnedPreferenceChangedKeys = nonPinnedPreferenceChangedKeys(
                        from: originalDomain,
                        to: recoveredDomain
                    )
                    report.finalRegularApps = canonicalRegularApps(recoveredApps)
                    report.finalRegularAppsPreserved = recoveredApps == originalApps
                    report.finalWindowRecords = canonicalWindows(recoveredWindows)
                    report.finalWindows = benchmarkWindowStatus(
                        baseline: originalWindows,
                        current: recoveredWindows
                    )
                    report.restoredOriginal = recoveredSnapshot.hasSameLayout(as: original)
                        && report.finalNonPinnedPreferenceChangedKeys.isEmpty
                        && report.finalRegularAppsPreserved
                        && report.finalWindows == .preserved
                    try writeBenchmarkRecoveryMarker(.restored, to: args.recoveryMarker)
                    report.recoveryMarkerState = .restored
                    recoveryRequired = false
                    restored = true
                    writeLine("DOCKIT_BENCHMARK_EMERGENCY_RESTORE_FINISHED strategy=\(args.strategy.rawValue)")
                } catch {
                    report.failure = "\(benchmarkError) Recovery failed: \(error.localizedDescription) Backup: \(args.backup.path)"
                    report.finishedAt = Date()
                    report.gatePassed = false
                    try? write(report, to: args.report)
                    throw ProbeFailure.invariant(report.failure ?? "Benchmark recovery failed")
                }
            }
            report.failure = benchmarkError
            report.finishedAt = Date()
            report.gatePassed = false
            try? write(report, to: args.report)
            throw error
        }
    }

    static func validateBenchmarkReport(at url: URL) throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ProbeFailure.invalidArguments("The benchmark report is not readable")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(
            DockReloadBenchmarkReport.self,
            from: Data(contentsOf: url)
        )
        let failures = report.gateFailures()
        guard report.gatePassed, failures.isEmpty else {
            throw ProbeFailure.invariant(
                "The benchmark gate failed: \(failures.joined(separator: "; "))"
            )
        }
        writeLine("DOCKIT_BENCHMARK_GATE_PASSED report=\(url.path)")
    }

    static func runProbeArgumentsSelfTest() throws {
        let base = [
            "--backup", "/tmp/dockit-parser-backup.plist",
            "--report", "/tmp/dockit-parser-report.json",
            "--hold-seconds", "1",
        ]
        let defaults = try ProbeArguments.parse(base)
        try require(defaults.strategy == .forcedTermination, "Default probe strategy changed")
        for strategy in DockReloadStrategy.allCases {
            let arguments = try ProbeArguments.parse(base + ["--strategy", strategy.rawValue])
            try require(arguments.strategy == strategy, "Probe strategy parsing failed")
        }
        try require(defaults.reloadMode == .strategy, "Default probe reload mode changed")
        for mode in ProbeReloadMode.allCases {
            let arguments = try ProbeArguments.parse(base + ["--reload", mode.rawValue])
            try require(arguments.reloadMode == mode, "Probe reload mode parsing failed")
        }
        for suffix in [
            ["--strategy"],
            ["--strategy", "invalid"],
            ["--strategy", "forcedTermination", "--strategy", "forcedTermination"],
            ["--reload"],
            ["--reload", "invalid"],
            ["--reload", "sigterm", "--reload", "sigterm"],
        ] {
            var rejected = false
            do {
                _ = try ProbeArguments.parse(base + suffix)
            } catch ProbeFailure.invalidArguments {
                rejected = true
            }
            try require(rejected, "Invalid probe strategy arguments were accepted")
        }
        writeLine("DOCKIT_PROBE_ARGUMENTS_SELF_TEST_PASSED")
    }

    static func runBenchmarkReportSelfTest() throws {
        let arguments = try DockReloadBenchmarkArguments.parse([
            "--benchmark-reload",
            "--confirm-real-dock-mutation",
            "--strategy", "forcedTermination",
            "--switch-count", "20",
            "--backup", "/tmp/dockit-benchmark-backup.plist",
            "--report", "/tmp/dockit-benchmark-report.json",
            "--recovery-marker", "/tmp/dockit-benchmark-recovery.marker",
        ])
        try require(arguments.strategy == .forcedTermination, "Benchmark argument parsing failed")
        try require(arguments.switchCount == 20, "Benchmark switch-count parsing failed")
        do {
            _ = try DockReloadBenchmarkArguments.parse([
                "--benchmark-reload",
                "--confirm-real-dock-mutation",
                "--strategy", "forcedTermination",
                "--switch-count", "19",
                "--backup", "/tmp/dockit-benchmark-backup.plist",
                "--report", "/tmp/dockit-benchmark-report.json",
                "--recovery-marker", "/tmp/dockit-benchmark-recovery.marker",
            ])
            throw ProbeFailure.invariant("Benchmark argument parsing accepted fewer than 20 switches")
        } catch ProbeFailure.invalidArguments {
        }
        do {
            _ = try DockReloadBenchmarkArguments.parse([
                "--benchmark-reload",
                "--confirm-real-dock-mutation",
                "--strategy", "forcedTermination",
                "--switch-count", "20",
                "--backup", "/tmp/dockit-benchmark-backup.plist",
                "--report", "/tmp/dockit-benchmark-report.json",
            ])
            throw ProbeFailure.invariant("Benchmark argument parsing accepted no recovery marker")
        } catch ProbeFailure.invalidArguments {
        }

        let date = Date(timeIntervalSince1970: 0)
        var report = DockReloadBenchmarkReport(
            startedAt: date,
            strategy: .forcedTermination,
            requestedSwitchCount: 20,
            backupPath: "/tmp/dockit-benchmark-backup.plist",
            recoveryMarkerPath: "/tmp/dockit-benchmark-recovery.marker"
        )
        let app = ProcessIdentity(bundleIdentifier: "com.example.fixture", processIdentifier: 42)
        let window = WindowIdentity(
            ownerProcessIdentifier: 42,
            windowNumber: 7,
            layer: 0,
            bounds: "{{0, 0}, {100, 100}}"
        )
        let restorationEvent = BenchmarkReloadEvent(DockReloadResult(
            previousProcessIdentifier: 21,
            currentProcessIdentifier: 22,
            strategy: .forcedTermination
        ))
        report.baselineDockProcessIdentifier = 1
        report.baselineRegularApps = [app]
        report.baselineWindowRecords = [window]
        report.switches = (1 ... 20).map { iteration in
            DockReloadBenchmarkSwitchReport(
                iteration: iteration,
                profileName: "Fixture \(iteration)",
                elapsedMilliseconds: 1,
                reload: BenchmarkReloadEvent(DockReloadResult(
                    previousProcessIdentifier: Int32(iteration),
                    currentProcessIdentifier: Int32(iteration + 1),
                    strategy: .forcedTermination
                )),
                skippedApps: [],
                nonPinnedPreferenceChangedKeys: [],
                regularApps: [app],
                regularAppsPreserved: true,
                windowRecords: [window],
                windows: .preserved,
                failure: nil
            )
        }
        report.finalRegularApps = [app]
        report.finalRegularAppsPreserved = true
        report.finalWindowRecords = [window]
        report.finalWindows = .preserved
        report.restorationReload = restorationEvent
        report.recoveryMarkerState = .restored
        report.restoredOriginal = true
        report.finishedAt = date
        report.gatePassed = report.gateFailures().isEmpty
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            DockReloadBenchmarkReport.self,
            from: encoder.encode(report)
        )
        try require(decoded.gatePassed, "Benchmark report serialization failed")
        try require(decoded.gateFailures().isEmpty, "Benchmark report validation failed")

        let directory = FileManager.default.temporaryDirectory.appending(
            path: "dockit-benchmark-report-self-test-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let reportURL = directory.appending(path: "report.json", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(decoded, to: reportURL)
        try validateBenchmarkReport(at: reportURL)

        var incomplete = decoded
        incomplete.switches.removeLast()
        try require(!incomplete.gateFailures().isEmpty, "Benchmark gate accepted fewer than 20 switches")
        var invalidProcessEvidence = decoded
        invalidProcessEvidence.switches[0].reload?.currentProcessIdentifier = 1
        try require(
            !invalidProcessEvidence.gateFailures().isEmpty,
            "Benchmark gate accepted invalid Dock process evidence"
        )
        var missingWindowEvidence = decoded
        missingWindowEvidence.baselineWindowRecords = []
        try require(
            !missingWindowEvidence.gateFailures().isEmpty,
            "Benchmark gate accepted empty window evidence for a regular app"
        )
        var unconfirmedRecovery = decoded
        unconfirmedRecovery.recoveryMarkerState = .noMutation
        try require(
            !unconfirmedRecovery.gateFailures().isEmpty,
            "Benchmark gate accepted an unconfirmed recovery marker"
        )
        writeLine("DOCKIT_BENCHMARK_REPORT_SELF_TEST_PASSED")
    }

    static func writeDomainBackup(_ domain: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard PropertyListSerialization.propertyList(domain, isValidFor: .binary) else {
            throw ProbeFailure.invariant("The current Dock domain cannot be backed up safely")
        }
        let backupData = try PropertyListSerialization.data(
            fromPropertyList: domain,
            format: .binary,
            options: 0
        )
        try backupData.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let savedBackup = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url),
            format: nil
        )
        try require(
            (savedBackup as? NSDictionary)?.isEqual(to: domain) == true,
            "The on-disk Dock backup did not verify"
        )
    }

    static func createBenchmarkRecoveryMarker(at url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ProbeFailure.invalidArguments(
                "The benchmark recovery marker already exists at \(url.path)"
            )
        }
        try writeBenchmarkRecoveryMarker(.active, to: url)
    }

    static func writeBenchmarkRecoveryMarker(
        _ state: BenchmarkRecoveryMarkerState,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("\(state.rawValue)\n".utf8).write(
            to: url,
            options: [.atomic, .completeFileProtection]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func benchmarkProfiles() -> [DockProfile] {
        [
            DockProfile(name: "dockit benchmark A", color: .blue, items: [
                appItem(path: "/System/Applications/Notes.app"),
                DockItem(kind: .spacer(.regular)),
                appItem(path: "/System/Applications/TextEdit.app"),
            ]),
            DockProfile(name: "dockit benchmark B", color: .purple, items: [
                appItem(path: "/System/Applications/TextEdit.app"),
                DockItem(kind: .spacer(.small)),
                appItem(path: "/System/Applications/Notes.app"),
            ]),
        ]
    }

    static func nonPinnedPreferenceChangedKeys(
        from original: [String: Any],
        to current: [String: Any]
    ) -> [String] {
        let ignored = Set(DockReloadBenchmarkReport.ignoredRuntimeKeys + ["persistent-apps"])
        let keys = Set(original.keys).union(current.keys)
        return keys
            .filter { !ignored.contains($0) && !equalValue(original[$0], current[$0]) }
            .sorted()
    }

    static func restoreDomainBackup(at url: URL) async throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ProbeFailure.invalidArguments("The Dock backup is not readable")
        }
        let value = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url),
            format: nil
        )
        guard let domain = value as? [String: Any] else {
            throw ProbeFailure.invalidArguments("The Dock backup does not contain a preference domain")
        }
        try await restoreDomain(domain)
        writeLine("DOCKIT_PROBE_BACKUP_RESTORED \(url.path)")
    }

    static func restoreDomain(_ domain: [String: Any]) async throws {
        guard let tiles = domain["persistent-apps"] as? [[String: Any]] else {
            throw ProbeFailure.invariant("The Dock backup has no readable pinned apps")
        }
        _ = try DockSnapshot(rawTiles: tiles)
        UserDefaults.standard.setPersistentDomain(domain, forName: "com.apple.dock")
        try synchronizeDockPreferences()
        try require(
            recoverableStateEqual(domain, dockDomain()),
            "The Dock backup did not restore before reload"
        )
        _ = try await SystemDockReloader().reload()
        try require(
            restoredUserStateEqual(domain, dockDomain()),
            "The Dock backup did not remain restored after reload"
        )
    }

    static func appItem(path: String) -> DockItem {
        let bundle = Bundle(path: path)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return DockItem(kind: .application(DockApp(
            bundleIdentifier: bundle?.bundleIdentifier,
            path: path,
            displayName: name
        )))
    }

    static func dockDomain() -> [String: Any] {
        UserDefaults.standard.persistentDomain(forName: "com.apple.dock") ?? [:]
    }

    static func setDockPreference(_ value: Any?, forKey key: String) {
        CFPreferencesSetAppValue(
            key as CFString,
            value as CFPropertyList?,
            "com.apple.dock" as CFString
        )
    }

    static func isDockPreferenceForced(_ key: String) -> Bool {
        CFPreferencesAppValueIsForced(key as CFString, "com.apple.dock" as CFString)
    }

    static func synchronizeDockPreferences() throws {
        guard CFPreferencesAppSynchronize("com.apple.dock" as CFString) else {
            throw ProbeFailure.invariant("macOS did not save the non-profile Dock fixture")
        }
    }

    static func settings(from domain: [String: Any]) -> [String: Any] {
        let runtimeKeys = Set([
            "persistent-apps",
            "persistent-others",
            "recent-apps",
            "mod-count",
            "last-analytics-stamp",
            "lastShowIndicatorTime",
        ])
        return domain.filter { !runtimeKeys.contains($0.key) }
    }

    static func settingsEqual(_ left: [String: Any], _ right: [String: Any]) -> Bool {
        NSDictionary(dictionary: settings(from: left)).isEqual(to: settings(from: right))
    }

    static func recoverableStateEqual(_ left: [String: Any], _ right: [String: Any]) -> Bool {
        guard
            let leftTiles = left["persistent-apps"] as? [[String: Any]],
            let rightTiles = right["persistent-apps"] as? [[String: Any]],
            let leftSnapshot = try? DockSnapshot(rawTiles: leftTiles),
            let rightSnapshot = try? DockSnapshot(rawTiles: rightTiles),
            leftSnapshot.hasSameLayout(as: rightSnapshot)
        else { return false }
        return foldersEqual(left, right)
            && recentAppsEqual(left, right)
            && settingsEqual(left, right)
    }

    static func restoredUserStateEqual(_ left: [String: Any], _ right: [String: Any]) -> Bool {
        guard
            let leftTiles = left["persistent-apps"] as? [[String: Any]],
            let rightTiles = right["persistent-apps"] as? [[String: Any]],
            let leftSnapshot = try? DockSnapshot(rawTiles: leftTiles),
            let rightSnapshot = try? DockSnapshot(rawTiles: rightTiles),
            leftSnapshot.hasSameLayout(as: rightSnapshot)
        else { return false }
        return foldersEqual(left, right) && settingsEqual(left, right)
    }

    static func foldersEqual(_ left: [String: Any], _ right: [String: Any]) -> Bool {
        let leftTiles = left["persistent-others"] as? [[String: Any]] ?? []
        let rightTiles = right["persistent-others"] as? [[String: Any]] ?? []
        guard leftTiles.count == rightTiles.count else { return false }
        return zip(leftTiles, rightTiles).allSatisfy { leftTile, rightTile in
            folderIdentity(leftTile) == folderIdentity(rightTile)
        }
    }

    static func recentAppsEqual(_ left: [String: Any], _ right: [String: Any]) -> Bool {
        let leftTiles = left["recent-apps"] as? [[String: Any]] ?? []
        let rightTiles = right["recent-apps"] as? [[String: Any]] ?? []
        guard
            leftTiles.count == rightTiles.count,
            let leftSnapshot = try? DockSnapshot(rawTiles: leftTiles),
            let rightSnapshot = try? DockSnapshot(rawTiles: rightTiles)
        else { return false }
        return leftSnapshot.hasSameLayout(as: rightSnapshot)
    }

    static func recentAppSummary(_ domain: [String: Any]) -> String {
        let tiles = domain["recent-apps"] as? [[String: Any]] ?? []
        let values = tiles.map { tile -> String in
            let identifier = (tile["GUID"] as? NSNumber)?.stringValue ?? "no-guid"
            let tileData = tile["tile-data"] as? [String: Any]
            let fileData = tileData?["file-data"] as? [String: Any]
            let path = (fileData?["_CFURLString"] as? String)
                .flatMap(URL.init(string:))?
                .path ?? "no-path"
            return "\(identifier):\(path)"
        }
        return values.isEmpty ? "empty" : values.joined(separator: " | ")
    }

    static func folderIdentity(_ tile: [String: Any]) -> [String]? {
        guard
            tile["tile-type"] as? String == "directory-tile",
            let tileData = tile["tile-data"] as? [String: Any],
            let fileData = tileData["file-data"] as? [String: Any],
            let urlString = fileData["_CFURLString"] as? String,
            let url = URL(string: urlString),
            url.isFileURL
        else { return nil }
        let keys = ["arrangement", "displayas", "file-type", "preferreditemsize", "showas"]
        let settings = keys.map { key in
            (tileData[key] as? NSNumber)?.stringValue ?? "missing"
        }
        return [
            "directory-tile",
            url.resolvingSymlinksInPath().standardizedFileURL.path,
        ] + settings
    }

    static func equalValue(_ left: Any?, _ right: Any?) -> Bool {
        switch (left, right) {
        case (nil, nil): true
        case let (left?, right?): (left as? NSObject)?.isEqual(right) ?? false
        default: false
        }
    }

    static func regularApps() -> Set<ProcessIdentity> {
        Set(NSWorkspace.shared.runningApplications.compactMap { app in
            guard
                app.activationPolicy == .regular,
                let bundleIdentifier = app.bundleIdentifier,
                bundleIdentifier != "com.apple.dock",
                app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else { return nil }
            return ProcessIdentity(bundleIdentifier: bundleIdentifier, processIdentifier: app.processIdentifier)
        })
    }

    static func canonicalRegularApps<S: Sequence>(_ apps: S) -> [ProcessIdentity]
        where S.Element == ProcessIdentity
    {
        Array(Set(apps)).sorted { left, right in
            if left.bundleIdentifier != right.bundleIdentifier {
                return left.bundleIdentifier < right.bundleIdentifier
            }
            return left.processIdentifier < right.processIdentifier
        }
    }

    static func canonicalWindows<S: Sequence>(_ windows: S?) -> [WindowIdentity]?
        where S.Element == WindowIdentity
    {
        windows.map { windows in
            Array(Set(windows)).sorted { left, right in
                if left.ownerProcessIdentifier != right.ownerProcessIdentifier {
                    return left.ownerProcessIdentifier < right.ownerProcessIdentifier
                }
                if left.windowNumber != right.windowNumber {
                    return left.windowNumber < right.windowNumber
                }
                if left.layer != right.layer {
                    return left.layer < right.layer
                }
                return left.bounds < right.bounds
            }
        }
    }

    static func hasUsableWindowEvidence(
        regularApps: [ProcessIdentity],
        windows: [WindowIdentity]?
    ) -> Bool {
        guard let windows else { return false }
        return regularApps.isEmpty || !windows.isEmpty
    }

    static func windows(ownedBy apps: Set<ProcessIdentity>) -> Set<WindowIdentity> {
        observableWindows(ownedBy: apps) ?? []
    }

    static func observableWindows(ownedBy apps: Set<ProcessIdentity>) -> Set<WindowIdentity>? {
        let processIdentifiers = Set(apps.map(\.processIdentifier))
        guard let values = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return Set(values.compactMap { value in
            guard
                let processIdentifier = value[kCGWindowOwnerPID as String] as? Int32,
                processIdentifiers.contains(processIdentifier),
                let number = value[kCGWindowNumber as String] as? Int,
                let layer = value[kCGWindowLayer as String] as? Int,
                let boundsValue = value[kCGWindowBounds as String]
            else { return nil }
            return WindowIdentity(
                ownerProcessIdentifier: processIdentifier,
                windowNumber: number,
                layer: layer,
                bounds: String(describing: boundsValue)
            )
        })
    }

    static func benchmarkWindowStatus(
        baseline: Set<WindowIdentity>?,
        current: Set<WindowIdentity>?
    ) -> BenchmarkWindowStatus {
        guard let baseline, let current else { return .inconclusive }
        return baseline == current ? .preserved : .changed
    }

    /// Polls until the Dock rewrites the pinned apps in its own normalized form
    /// (same layout, different bytes). Returns the delay in milliseconds, or nil
    /// when the Dock never wrote within the timeout.
    static func waitForDockFlush(
        preferences: AuditedDockPreferencesClient,
        written: DockSnapshot,
        timeout: Duration
    ) async -> Int? {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: timeout)
        while clock.now < deadline {
            if let current = try? await preferences.readPersistentApps(), !current.isEquivalent(to: written) {
                let elapsed = clock.now - start
                let milliseconds = Int(elapsed / .milliseconds(1))
                writeLine("DOCKIT_PROBE_DOCK_FLUSH_LAYOUT_MATCHES \(current.hasSameLayout(as: written))")
                return milliseconds
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    static func dockProcessIdentifier() -> Int32? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ProbeFailure.invariant(message) }
    }

    static func write<Value: Encodable>(_ report: Value, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    static func writeLine(_ value: String) {
        FileHandle.standardOutput.write(Data("\(value)\n".utf8))
    }
}

// MARK: - Settle-wait experiments

/// One question each, on a real Dock, never in DockitCore. All of them start
/// from a Dock that is two seconds old (restarted through the product path onto
/// a fixture layout) and try to put the original layout back around a kill.
enum ProbeExperiment: String, CaseIterable {
    /// Write, then `kill(pid, SIGKILL)`. A SIGKILLed Dock cannot write, so a
    /// clobber here comes from cfprefsd or the new Dock.
    case sigkillWriteKill = "sigkill-write-kill"
    /// Write, then `kill(pid, SIGTERM)`, what `killall Dock` sends.
    case sigtermWriteKill = "sigterm-write-kill"
    /// Write, then `NSRunningApplication.forceTerminate()`, the product path.
    case forceTerminateWriteKill = "forceterminate-write-kill"
    /// Write and never kill. Says whether the young Dock's own rewrite (about
    /// four seconds after launch) clobbers a write that landed before it.
    case writeThenWait = "write-then-wait"
    /// SIGKILL, wait for the exit through kqueue, write at once, then verify
    /// when the new Dock appears and again after its own rewrite.
    case killThenWrite = "kill-then-write"
}

struct ExperimentArguments {
    var experiment: ProbeExperiment
    var backup: URL
    var iterations: Int

    static func parse(_ values: [String]) throws -> ExperimentArguments {
        func value(after flag: String) throws -> String {
            guard let index = values.firstIndex(of: flag), values.indices.contains(index + 1) else {
                throw ProbeFailure.invalidArguments("Missing \(flag)")
            }
            return values[index + 1]
        }
        guard let experiment = ProbeExperiment(rawValue: try value(after: "--experiment")) else {
            throw ProbeFailure.invalidArguments("Unknown experiment; pick one of \(ProbeExperiment.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let backupPath = try value(after: "--backup")
        guard backupPath.hasPrefix("/") else {
            throw ProbeFailure.invalidArguments("The backup path must be absolute")
        }
        let iterations = values.contains("--iterations") ? Int(try value(after: "--iterations")) ?? 0 : 1
        guard iterations >= 1 else { throw ProbeFailure.invalidArguments("--iterations must be at least 1") }
        return ExperimentArguments(
            experiment: experiment,
            backup: URL(fileURLWithPath: backupPath).standardizedFileURL,
            iterations: iterations
        )
    }
}

extension DockProbe {
    static func runExperiment(_ args: ExperimentArguments) async throws {
        guard !FileManager.default.fileExists(atPath: args.backup.path) else {
            throw ProbeFailure.backupExists(args.backup.path)
        }
        let client = DockPreferencesClient()
        try await client.assertMutable()
        let originalDomain = dockDomain()
        guard let originalTiles = originalDomain["persistent-apps"] as? [[String: Any]], originalTiles.count >= 2 else {
            throw ProbeFailure.invariant("The current Dock needs at least two pinned apps for the experiment")
        }
        let original = try DockSnapshot(rawTiles: originalTiles)
        // Built the way the product builds a profile, so the tiles are not in
        // the Dock's normalized form. The Dock only rewrites (and a dying Dock
        // only flushes) when it has something to normalize.
        let fixture = try DockSnapshot.build(
            profile: DockProfile(name: "dockit probe", color: .blue, items: [
                appItem(path: "/System/Applications/Notes.app"),
                DockItem(kind: .spacer(.regular)),
                appItem(path: "/System/Applications/TextEdit.app"),
            ]),
            localState: DockProfileLocalState()
        ).snapshot
        try require(!fixture.hasSameLayout(as: original), "The current Dock already matches the fixture")
        try writeDomainBackup(originalDomain, to: args.backup)
        writeLine("DOCKIT_EXPERIMENT \(args.experiment.rawValue) iterations=\(args.iterations)")

        func name(_ snapshot: DockSnapshot) -> String {
            if snapshot.hasSameLayout(as: original) { return "original" }
            if snapshot.hasSameLayout(as: fixture) { return "fixture" }
            return "other"
        }

        var failures = 0
        for iteration in 1...args.iterations {
            // Fresh Dock on the fixture, through the product path.
            try await client.writePersistentApps(fixture)
            let fresh = try await SystemDockReloader().reload()
            let freshStart = ContinuousClock.now
            writeLine("DOCKIT_EXPERIMENT_ITERATION \(iteration) dock=\(fresh.currentProcessIdentifier)")
            try await Task.sleep(until: freshStart.advanced(by: .seconds(2)), clock: .continuous)

            let outcome: Bool
            switch args.experiment {
            case .sigkillWriteKill, .sigtermWriteKill, .forceTerminateWriteKill:
                outcome = try await writeKillTrace(
                    client: client, dock: fresh.currentProcessIdentifier, target: original,
                    signal: args.experiment == .sigtermWriteKill ? SIGTERM : SIGKILL,
                    useForceTerminate: args.experiment == .forceTerminateWriteKill, name: name
                )
            case .writeThenWait:
                outcome = try await writeThenWait(client: client, dockStart: freshStart, target: original, name: name)
            case .killThenWrite:
                outcome = try await killThenWrite(client: client, dock: fresh.currentProcessIdentifier, target: original, name: name)
            }
            writeLine("DOCKIT_EXPERIMENT_RESULT iteration=\(iteration) verified=\(outcome)")
            if !outcome { failures += 1 }
        }

        // Leave the Dock on the original layout whatever happened above.
        let final = try await client.readPersistentApps()
        if !final.hasSameLayout(as: original) || args.experiment == .writeThenWait {
            try await client.writePersistentApps(original)
            _ = try await SystemDockReloader().reload()
            try await Task.sleep(for: .seconds(5))
        }
        try require(try await client.readPersistentApps().hasSameLayout(as: original), "Pinned apps did not restore")
        writeLine("DOCKIT_EXPERIMENT_DONE failures=\(failures) of=\(args.iterations)")
    }

    /// Reads the layout every 10 ms across the kill and reports when it flips,
    /// against the old Dock's exit and the new Dock's start.
    private static func writeKillTrace(
        client: DockPreferencesClient,
        dock: Int32,
        target: DockSnapshot,
        signal: Int32,
        useForceTerminate: Bool,
        name: @escaping (DockSnapshot) -> String
    ) async throws -> Bool {
        let clock = ContinuousClock()
        try await client.writePersistentApps(target)
        let written = clock.now
        let afterWrite = try await client.readPersistentApps()
        writeLine("DOCKIT_EXPERIMENT_WRITTEN readsBack=\(name(afterWrite))")

        let exit = ProcessExitWatch(processIdentifier: dock)
        let killed: Bool
        if useForceTerminate {
            killed = await MainActor.run {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
                    .first(where: { $0.processIdentifier == dock })?.forceTerminate() ?? false
            }
        } else {
            killed = kill(dock, signal) == 0
        }
        try require(killed, "The kill was refused")
        let killAt = clock.now
        let exitTask = Task.detached { exit.wait(timeout: .seconds(3)) }

        var lastName = name(afterWrite)
        var flipAt: ContinuousClock.Instant?
        var newPID: Int32?
        var newPIDAt: ContinuousClock.Instant?
        var newPIDStart: Date?
        let deadline = killAt.advanced(by: .seconds(3))
        while clock.now < deadline {
            if newPID == nil, let current = dockProcessIdentifier(), current != dock {
                newPID = current
                newPIDAt = clock.now
                newPIDStart = processStartDate(current)
            }
            if let snapshot = try? await client.readPersistentApps() {
                let now = name(snapshot)
                if now != lastName {
                    flipAt = clock.now
                    writeLine("DOCKIT_EXPERIMENT_FLIP from=\(lastName) to=\(now) afterKillMs=\(ms(clock.now - killAt)) newPIDSeen=\(newPID != nil)")
                    lastName = now
                }
            }
            if let newPIDAt, clock.now > newPIDAt.advanced(by: .milliseconds(1500)) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let exited = await exitTask.value
        writeLine("DOCKIT_EXPERIMENT_TIMELINE writeToKillMs=\(ms(killAt - written)) oldExitMs=\(exited.map { String(ms($0)) } ?? "none") newPIDMs=\(newPIDAt.map { String(ms($0 - killAt)) } ?? "none") newPIDStartMs=\(newPIDStart.map { String(Int($0.timeIntervalSinceNow * -1000)) } ?? "none") flipMs=\(flipAt.map { String(ms($0 - killAt)) } ?? "none") pid=\(newPID ?? -1)")
        // Past the new Dock's own rewrite.
        if let newPIDAt { try await Task.sleep(until: newPIDAt.advanced(by: .seconds(5)), clock: clock) }
        let late = try await client.readPersistentApps()
        writeLine("DOCKIT_EXPERIMENT_LATE layout=\(name(late))")
        return late.hasSameLayout(as: target)
    }

    private static func writeThenWait(
        client: DockPreferencesClient,
        dockStart: ContinuousClock.Instant,
        target: DockSnapshot,
        name: @escaping (DockSnapshot) -> String
    ) async throws -> Bool {
        let clock = ContinuousClock()
        try await client.writePersistentApps(target)
        let written = try await client.readPersistentApps()
        var lastBytes = written
        var lastName = name(written)
        writeLine("DOCKIT_EXPERIMENT_WRITTEN dockAgeMs=\(ms(clock.now - dockStart)) readsBack=\(lastName)")
        while clock.now < dockStart.advanced(by: .seconds(8)) {
            if let snapshot = try? await client.readPersistentApps() {
                if !snapshot.isEquivalent(to: lastBytes) {
                    writeLine("DOCKIT_EXPERIMENT_REWRITE dockAgeMs=\(ms(clock.now - dockStart)) layout=\(name(snapshot))")
                    lastBytes = snapshot
                }
                let now = name(snapshot)
                if now != lastName {
                    writeLine("DOCKIT_EXPERIMENT_FLIP from=\(lastName) to=\(now) dockAgeMs=\(ms(clock.now - dockStart))")
                    lastName = now
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return lastName == "original"
    }

    private static func killThenWrite(
        client: DockPreferencesClient,
        dock: Int32,
        target: DockSnapshot,
        name: @escaping (DockSnapshot) -> String
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let exit = ProcessExitWatch(processIdentifier: dock)
        try require(kill(dock, SIGKILL) == 0, "SIGKILL was refused")
        let killAt = clock.now
        guard let exitAfter = await Task.detached(operation: { exit.wait(timeout: .seconds(3)) }).value else {
            throw ProbeFailure.invariant("The Dock did not exit within 3 s of SIGKILL")
        }
        let writeStart = clock.now
        try await client.writePersistentApps(target)
        let writeEnd = clock.now
        var newPID: Int32?
        var newPIDAt: ContinuousClock.Instant?
        while clock.now < killAt.advanced(by: .seconds(5)) {
            if let current = dockProcessIdentifier(), current != dock {
                newPID = current
                newPIDAt = clock.now
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let newPID, let newPIDAt else { throw ProbeFailure.invariant("The Dock did not come back") }
        let startDate = processStartDate(newPID)
        let startMs = startDate.map { Int((Date().timeIntervalSince($0)) * 1000) }.map { Int(ms(clock.now - killAt)) - $0 }
        let early = try await client.readPersistentApps()
        writeLine("DOCKIT_EXPERIMENT_TIMELINE oldExitMs=\(ms(exitAfter)) writeStartMs=\(ms(writeStart - killAt)) writeMs=\(ms(writeEnd - writeStart)) newPIDSeenMs=\(ms(newPIDAt - killAt)) newPIDStartMs=\(startMs.map(String.init) ?? "none") pid=\(newPID) earlyLayout=\(name(early))")
        try await Task.sleep(until: newPIDAt.advanced(by: .seconds(5)), clock: clock)
        let late = try await client.readPersistentApps()
        writeLine("DOCKIT_EXPERIMENT_LATE layout=\(name(late))")
        return early.hasSameLayout(as: target) && late.hasSameLayout(as: target)
    }

    private static func ms(_ duration: Duration) -> Int {
        Int(duration / .milliseconds(1))
    }

    private static func processStartDate(_ pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }
}

/// kqueue NOTE_EXIT armed before the kill, so the exit is seen without a poll.
final class ProcessExitWatch: @unchecked Sendable {
    private let queue = kqueue()
    private let armedAt = ContinuousClock.now

    init(processIdentifier: Int32) {
        var event = kevent(
            ident: UInt(processIdentifier), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil
        )
        kevent(queue, &event, 1, nil, 0, nil)
    }

    /// Blocks until the process exits. Returns the time since arming, or nil on timeout.
    func wait(timeout: Duration) -> Duration? {
        var out = kevent()
        var limit = timespec(tv_sec: Int(timeout / .seconds(1)), tv_nsec: 0)
        let count = kevent(queue, nil, 0, &out, 1, &limit)
        close(queue)
        return count > 0 ? ContinuousClock.now - armedAt : nil
    }
}
