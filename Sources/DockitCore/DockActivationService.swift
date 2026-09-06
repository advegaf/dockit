import Foundation

public struct DockActivationOutcome: Sendable {
    public var library: DockLibrary
    public var applyResult: DockApplyResult

    public init(library: DockLibrary, applyResult: DockApplyResult) {
        self.library = library
        self.applyResult = applyResult
    }
}

public actor DockActivationService {
    private let store: DockLibraryStore
    private let coordinator: DockApplyCoordinator

    public init(
        store: DockLibraryStore = DockLibraryStore(),
        preferences: any DockPreferencesServing = DockPreferencesClient(),
        reloader: any DockReloading = SystemDockReloader()
    ) {
        self.store = store
        coordinator = DockApplyCoordinator(preferences: preferences, reloader: reloader)
    }

    public func activate(
        profileID: UUID,
        source: ActivationSource,
        activatedAt: Date = Date(),
        focusRequestID: UUID? = nil,
        expectedCurrentSnapshot: DockSnapshot? = nil
    ) async throws -> DockActivationOutcome {
        guard var library = try await store.load(), let record = library.record(id: profileID) else {
            throw DockLibraryError.profileNotFound
        }
        let intendedLayout = DockLayout(profile: record.profile)
        let plan = try await coordinator.prepare(profile: record.profile, localState: record.localState)
        let acceptedSnapshot = expectedCurrentSnapshot ?? library.lastKnownDock
        if
            library.activeProfile != nil || expectedCurrentSnapshot != nil,
            let acceptedSnapshot,
            !plan.previousSnapshot.hasSameLayout(as: acceptedSnapshot)
        {
            throw DockApplyError.dockChangedBeforeApply
        }
        library.pendingApply = PendingDockApply(
            profileID: profileID,
            source: source,
            previousSnapshot: plan.previousSnapshot,
            intendedSnapshot: plan.intendedSnapshot,
            activationRequestedAt: activatedAt,
            focusRequestID: focusRequestID,
            intendedLayout: intendedLayout,
            dockProcessIdentifier: await coordinator.currentDockProcessIdentifier()
        )
        try await store.save(library)

        do {
            let result = try await coordinator.apply(plan)
            library.activeProfile = ActiveProfile(
                profileID: profileID,
                source: source,
                appliedAt: activatedAt,
                appliedLayout: intendedLayout
            )
            if source == .focus, let focusRequestID {
                library.advanceFocusWatermark(to: FocusRequestWatermark(
                    requestID: focusRequestID,
                    createdAt: activatedAt
                ))
            }
            library.lastKnownDock = result.appliedSnapshot
            library.pendingApply = nil
            try await store.save(library)
            return DockActivationOutcome(library: library, applyResult: result)
        } catch DockApplyError.dockChangedBeforeApply {
            library.pendingApply = nil
            try? await store.save(library)
            throw DockApplyError.dockChangedBeforeApply
        } catch let error as DockApplyError {
            guard case .rolledBack = error else { throw error }
            library.pendingApply = nil
            try? await store.save(library)
            throw error
        }
    }
}
