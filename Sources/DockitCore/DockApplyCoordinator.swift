import Foundation

private actor DockOperationGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard let next = waiters.first else {
            isHeld = false
            return
        }
        waiters.removeFirst()
        next.resume()
    }
}

public struct DockApplyResult: Sendable {
    public var previousSnapshot: DockSnapshot
    public var appliedSnapshot: DockSnapshot
    public var skippedApps: [SkippedDockApp]
    public var reload: DockReloadResult?

    public init(
        previousSnapshot: DockSnapshot,
        appliedSnapshot: DockSnapshot,
        skippedApps: [SkippedDockApp],
        reload: DockReloadResult?
    ) {
        self.previousSnapshot = previousSnapshot
        self.appliedSnapshot = appliedSnapshot
        self.skippedApps = skippedApps
        self.reload = reload
    }
}

struct DockApplyPlan: Sendable {
    var previousSnapshot: DockSnapshot
    var intendedSnapshot: DockSnapshot
    var skippedApps: [SkippedDockApp]
}

public enum DockApplyError: LocalizedError {
    case verificationFailed
    case dockChangedBeforeApply
    case rolledBack(cause: String)
    case rollbackFailed(cause: String, rollbackCause: String)

    public var errorDescription: String? {
        switch self {
        case .verificationFailed:
            "the dock did not match the requested profile."
        case .dockChangedBeforeApply:
            "the dock changed before the saved profile could be applied. try again after the dock settles."
        case let .rolledBack(cause):
            "dockit could not apply the profile and restored the previous dock. \(cause)"
        case let .rollbackFailed(cause, rollbackCause):
            "dockit could not apply or restore the dock. apply error: \(cause) restore error: \(rollbackCause)"
        }
    }
}

public actor DockApplyCoordinator {
    private let preferences: any DockPreferencesServing
    private let reloader: any DockReloading
    private let operationGate = DockOperationGate()

    public init(
        preferences: any DockPreferencesServing = DockPreferencesClient(),
        reloader: any DockReloading = SystemDockReloader()
    ) {
        self.preferences = preferences
        self.reloader = reloader
    }

    public init(
        preferences: any DockPreferencesServing = DockPreferencesClient(),
        reloadConfiguration: DockReloadConfiguration,
        processController: any DockProcessControlling = SystemDockProcessController()
    ) {
        self.preferences = preferences
        reloader = SystemDockReloader(
            configuration: reloadConfiguration,
            processController: processController
        )
    }

    public func capture(name: String, color: ProfileColor) async throws -> CapturedDockProfile {
        return try await preferences.readPersistentApps().capture(name: name, color: color)
    }

    public func apply(
        profile: DockProfile,
        localState: DockProfileLocalState
    ) async throws -> DockApplyResult {
        try await performSerialized {
            let plan = try await self.prepare(profile: profile, localState: localState)
            return try await self.applyPrepared(plan)
        }
    }

    /// The Dock process running now, when the reloader can tell.
    public func currentDockProcessIdentifier() async -> Int32? {
        await reloader.dockProcessIdentifier()
    }

    func prepare(
        profile: DockProfile,
        localState: DockProfileLocalState
    ) async throws -> DockApplyPlan {
        try await preferences.assertMutable()
        let previous = try await preferences.readPersistentApps()
        let built = try DockSnapshot.build(profile: profile, localState: localState)
        return DockApplyPlan(
            previousSnapshot: previous,
            intendedSnapshot: built.snapshot,
            skippedApps: built.skippedApps
        )
    }

    func apply(_ plan: DockApplyPlan) async throws -> DockApplyResult {
        try await performSerialized {
            try await self.applyPrepared(plan)
        }
    }

    private func applyPrepared(_ prepared: DockApplyPlan) async throws -> DockApplyResult {
        try await preferences.assertMutable()
        let current = try await preferences.readPersistentApps()
        var plan = prepared
        if !current.isEquivalent(to: plan.previousSnapshot) {
            // A relaunched Dock rewrites its pinned apps in its own encoding a
            // few seconds after it starts. Same layout, different bytes: that is
            // the Dock, not the user, so it is still the layout to roll back to.
            guard current.hasSameLayout(as: plan.previousSnapshot) else {
                throw DockApplyError.dockChangedBeforeApply
            }
            plan.previousSnapshot = current
        }
        if plan.previousSnapshot.hasSameLayout(as: plan.intendedSnapshot) {
            return DockApplyResult(
                previousSnapshot: plan.previousSnapshot,
                appliedSnapshot: plan.previousSnapshot,
                skippedApps: plan.skippedApps,
                reload: nil
            )
        }

        var reloaded = false
        do {
            try await preferences.writePersistentApps(plan.intendedSnapshot)
            try await verifyExact(plan.intendedSnapshot)
            let reload = try await reloader.reload()
            reloaded = true
            let appliedSnapshot = try await verifyLayout(plan.intendedSnapshot)
            return DockApplyResult(
                previousSnapshot: plan.previousSnapshot,
                appliedSnapshot: appliedSnapshot,
                skippedApps: plan.skippedApps,
                reload: reload
            )
        } catch {
            let applyCause = error.localizedDescription
            do {
                // A Dock that finished relaunching shows what is on disk. When
                // that is already the previous layout, a second restart would
                // only repeat the flash.
                if reloaded, let current = try? await preferences.readPersistentApps(),
                   current.hasSameLayout(as: plan.previousSnapshot)
                {
                    throw DockApplyError.rolledBack(cause: applyCause)
                }
                try await preferences.writePersistentApps(plan.previousSnapshot)
                try await verifyExact(plan.previousSnapshot)
                _ = try await reloader.reload()
                _ = try await verifyLayout(plan.previousSnapshot)
                throw DockApplyError.rolledBack(cause: applyCause)
            } catch let rollbackError as DockApplyError {
                if case .rolledBack = rollbackError { throw rollbackError }
                throw DockApplyError.rollbackFailed(
                    cause: applyCause,
                    rollbackCause: rollbackError.localizedDescription
                )
            } catch {
                throw DockApplyError.rollbackFailed(
                    cause: applyCause,
                    rollbackCause: error.localizedDescription
                )
            }
        }
    }

    /// Puts `snapshot` back and reloads the Dock.
    ///
    /// When the preferences already hold `snapshot`, `forceReload` decides
    /// whether the Dock restarts anyway. Recovery after an interrupted apply
    /// passes `writtenWhileDockProcessWas`, the Dock PID recorded before that
    /// write: a Dock that has relaunched since then loaded the written
    /// preferences at launch and does not need another restart. The same PID
    /// means the old process still shows the old layout, so it restarts.
    public func restore(
        _ snapshot: DockSnapshot,
        forceReload: Bool = false,
        writtenWhileDockProcessWas recordedProcessIdentifier: Int32? = nil
    ) async throws -> DockReloadResult? {
        try await performSerialized {
            try await self.restorePrepared(
                snapshot,
                forceReload: forceReload,
                recordedProcessIdentifier: recordedProcessIdentifier
            )
        }
    }

    private func restorePrepared(
        _ snapshot: DockSnapshot,
        forceReload: Bool,
        recordedProcessIdentifier: Int32?
    ) async throws -> DockReloadResult? {
        try await preferences.assertMutable()
        let current = try await preferences.readPersistentApps()
        if current.isEquivalent(to: snapshot) {
            guard forceReload else { return nil }
            if let recordedProcessIdentifier,
               let currentProcessIdentifier = await reloader.dockProcessIdentifier(),
               currentProcessIdentifier != recordedProcessIdentifier
            {
                return nil
            }
            let result = try await reloader.reload()
            _ = try await verifyLayout(snapshot)
            return result
        }
        try await preferences.writePersistentApps(snapshot)
        try await verifyExact(snapshot)
        let result = try await reloader.reload()
        _ = try await verifyLayout(snapshot)
        return result
    }

    private func performSerialized<Result: Sendable>(
        _ operation: () async throws -> Result
    ) async throws -> Result {
        await operationGate.acquire()
        do {
            let result = try await operation()
            await operationGate.release()
            return result
        } catch {
            await operationGate.release()
            throw error
        }
    }

    private func verifyExact(_ expected: DockSnapshot) async throws {
        let actual = try await preferences.readPersistentApps()
        guard actual.isEquivalent(to: expected) else { throw DockApplyError.verificationFailed }
    }

    private func verifyLayout(_ expected: DockSnapshot) async throws -> DockSnapshot {
        let actual = try await preferences.readPersistentApps()
        guard actual.hasSameLayout(as: expected) else { throw DockApplyError.verificationFailed }
        return actual
    }
}
