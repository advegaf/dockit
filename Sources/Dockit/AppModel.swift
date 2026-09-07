import Accessibility
import AppKit
import DockitCore
import Observation
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    struct PresentedError: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    struct DeleteRequest: Identifiable {
        var id: UUID { profile.id }
        var profile: DockProfile
    }

    struct ImportPreview: Identifiable {
        struct Profile: Identifiable {
            struct UnavailableApp: Identifiable {
                var id: UUID
                var app: DockApp
            }

            var id: UUID { source.id }
            var source: DockProfile
            var importedName: String
            var unavailableApps: [UnavailableApp]

            var isRenamed: Bool { source.name != importedName }
        }

        let id = UUID()
        var archive: DockitArchive
        var fileName: String
        var profiles: [Profile]

        var unavailableAppCount: Int {
            profiles.reduce(0) { $0 + $1.unavailableApps.count }
        }
    }

    struct Reconciliation: Identifiable {
        enum Kind {
            case changedWhileClosed
            case savedEditsConflict
            case interrupted(PendingDockApply)
        }

        let id = UUID()
        var kind: Kind
    }

    struct MissingAppActivation: Identifiable {
        let id = UUID()
        var profileID: UUID
        var source: ActivationSource
        var requestedAt: Date
        var focusRequestID: UUID?
        var focusRequestIDs: [UUID] = []
    }

    enum TransferPresentationHost {
        case management
        case settings
    }

    enum TransferFileRequest: Equatable {
        case importProfiles
        case exportProfiles(defaultName: String)
    }

    typealias TransferFilePicker = @MainActor (TransferFileRequest, NSWindow?) async -> URL?

    private enum ExportFilePhase {
        case awaitingSheetDismissal(DockitArchive)
        case choosingLocation
    }

    private struct QueuedActivation {
        var profileID: UUID
        var source: ActivationSource
        var followsActiveSelection: Bool
        var requestedAt: Date
        var focusRequestID: UUID?
        var expectedCurrentSnapshot: DockSnapshot?
        var continuations: [CheckedContinuation<Bool, Never>]
    }

    private struct ItemEditBaseline {
        let profileID: UUID
        let items: [DockItem]

        func matches(_ profile: DockProfile) -> Bool {
            profile.id == profileID && profile.items == items
        }
    }

    var library = DockLibrary() {
        didSet { syncDockMenu() }
    }
    var isLoading = true { didSet { syncDockMenu() } }
    var storageUnavailable = false { didSet { syncDockMenu() } }
    var storageFailureMessage = ""
    var isApplying = false {
        didSet { syncDockMenu() }
    }
    var applyingProfileID: UUID? {
        didSet { syncDockMenu() }
    }
    var selectedItemIDs: Set<UUID> = []
    private var selectionAnchorID: UUID?
    var selectedItemID: UUID? {
        get { selectedRecord?.profile.items.first(where: { selectedItemIDs.contains($0.id) })?.id }
        set {
            selectedItemIDs = newValue.map { [$0] } ?? []
            selectionAnchorID = newValue
        }
    }
    var saveFailureMessage: String? {
        didSet { syncDockMenu() }
    }
    var statusMessage = "" {
        didSet {
            guard !statusMessage.isEmpty, statusMessage != oldValue else { return }
            announce(statusMessage)
        }
    }
    var presentedError: PresentedError?
    var presentedErrorHost: TransferPresentationHost?
    var deleteRequest: DeleteRequest? { didSet { syncDockMenu() } }
    var reconciliation: Reconciliation? { didSet { syncDockMenu() } }
    var reconciliationPresented = false
    var quickGuidePresented = false
    private(set) var activationUsesKeyboard = false
    var reconciliationErrorMessage = ""
    var exportPresented = false { didSet { syncDockMenu() } }
    var exportSelection: Set<UUID> = []
    var exportErrorMessage: String?
    private var exportFilePhase: ExportFilePhase?
    var transferPresentationHost: TransferPresentationHost?
    var settingsTransferMessage: String?
    @ObservationIgnored private weak var transferInvokingWindow: NSWindow?
    var importPreview: ImportPreview? { didSet { syncDockMenu() } }
    var isImporting = false { didSet { syncDockMenu() } }
    var missingAppActivation: MissingAppActivation? { didSet { syncDockMenu() } }
    var missingAppErrorMessage = ""
    var isResolvingMissingApps = false { didSet { syncDockMenu() } }
    var launchAtLogin = false
    var launchAtLoginNeedsApproval = false
    var launchAtLoginChangeInProgress = false
    var focusAutomationAvailable = false
    var focusAutomationMessage = "dockit needs shared local storage for focus automation."

    private var hasStarted = false
    private var isTerminating = false { didSet { syncDockMenu() } }
    private var mutationOperationCount = 0
    private var profileMutationInProgress = false { didSet { syncDockMenu() } }
    private var launchAtLoginTask: Task<Void, Never>?
    private let store: DockLibraryStore
    private let preferences: any DockPreferencesServing
    private let coordinator: DockApplyCoordinator
    private let activationService: DockActivationService
    private let monitor: DockChangeMonitor
    private let focusBridge: FocusBridgeStore?
    private let focusExtensionIsEmbedded: Bool
    private let isDemo: Bool
    private let integratesWithSystem: Bool
    private let guideDefaults: UserDefaults?
    private let transferFilePicker: TransferFilePicker
    private let demoActivationDelayMilliseconds: Int?
    private let demoFailureProfileName: String?
    private var saveTask: Task<Void, Never>?
    private var saveGeneration = 0
    private var focusRequestTask: Task<Void, Never>?
    private var activationLoopRunning = false
    private var queuedActivation: QueuedActivation?
    private var selectionChangedDuringActivation = false
    private var selectionDuringActivationID: UUID?
    private var lastPersistedLibrary = DockLibrary()

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        store: DockLibraryStore? = nil,
        preferences: any DockPreferencesServing = DockPreferencesClient(),
        reloader: any DockReloading = CoveringDockReloader(SystemDockReloader(), cover: DockRestartCover.shared),
        integratesWithSystem: Bool = true,
        focusBridge: FocusBridgeStore? = nil,
        transferFilePicker: TransferFilePicker? = nil,
        guideDefaults: UserDefaults? = nil
    ) {
        self.integratesWithSystem = integratesWithSystem
        self.guideDefaults = guideDefaults ?? (integratesWithSystem ? .standard : nil)
        self.transferFilePicker = transferFilePicker ?? Self.presentTransferFilePicker
        isDemo = environment["DOCKIT_DEMO"] == "1"
        demoActivationDelayMilliseconds = Int(environment["DOCKIT_DEMO_DELAY_MS"] ?? "")
        demoFailureProfileName = environment["DOCKIT_DEMO_FAIL_PROFILE"]
        let libraryStore: DockLibraryStore
        if let store {
            libraryStore = store
        } else if let path = environment["DOCKIT_LIBRARY_PATH"] {
            libraryStore = DockLibraryStore(fileURL: URL(fileURLWithPath: path))
        } else {
            libraryStore = DockLibraryStore()
        }
        self.store = libraryStore
        self.preferences = preferences
        coordinator = DockApplyCoordinator(preferences: preferences, reloader: reloader)
        activationService = DockActivationService(store: libraryStore, preferences: preferences, reloader: reloader)
        monitor = DockChangeMonitor(preferences: preferences)
        self.focusBridge = focusBridge ?? (isDemo || !integratesWithSystem ? nil : try? FocusBridgeStore())
        focusExtensionIsEmbedded = isDemo || Self.hasEmbeddedFocusExtension
        let loginStatus = integratesWithSystem ? SMAppService.mainApp.status : .notRegistered
        launchAtLogin = loginStatus == .enabled
        launchAtLoginNeedsApproval = loginStatus == .requiresApproval
        focusAutomationAvailable = isDemo
        if isDemo {
            focusAutomationMessage = "choose a dock for each focus in system settings."
        } else if focusBridge != nil, focusExtensionIsEmbedded {
            focusAutomationMessage = "checking focus automation…"
        } else if !focusExtensionIsEmbedded {
            focusAutomationMessage = "this copy of dockit is missing its focus extension. manual switching still works."
        }

        if isDemo {
            library = Self.demoLibrary(useLongContent: environment["DOCKIT_LONG_CONTENT_DEMO"] == "1")
            lastPersistedLibrary = library
            isLoading = false
            syncDockMenu()
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        guard !isDemo else { return }
        Task { await load() }
    }

    var selectedProfileID: UUID? {
        get { library.selectedProfileID }
        set {
            guard
                reconciliation == nil,
                importPreview == nil,
                !isImporting,
                !isLoading,
                !storageUnavailable,
                !isTerminating,
                (!profileMutationInProgress || activationLoopRunning)
            else { return }
            library.selectedProfileID = newValue
            selectedItemID = nil
            if activationLoopRunning {
                selectionChangedDuringActivation = true
                selectionDuringActivationID = newValue
                return
            }
            scheduleSave()
        }
    }

    var selectedRecord: DockProfileRecord? {
        guard let selectedProfileID else { return nil }
        return library.record(id: selectedProfileID)
    }

    var activeRecord: DockProfileRecord? {
        guard let id = library.activeProfile?.profileID else { return nil }
        return library.record(id: id)
    }

    var deleteRequestIsActive: Bool {
        deleteRequest?.id == library.activeProfile?.profileID
    }

    var canEditSelectedDock: Bool {
        selectedProfileID != nil
            && !profileActionsDisabled
    }

    var hasPendingSelectedChanges: Bool {
        guard let selectedProfileID else { return false }
        return library.hasPendingChanges(profileID: selectedProfileID)
    }

    func editorShowsApplied(for profileID: UUID) -> Bool {
        guard !isLoading, !storageUnavailable, saveFailureMessage == nil,
            reconciliation == nil, library.pendingApply == nil,
            library.activeProfile?.profileID == profileID,
            let baseline = library.activeProfile?.appliedLayout,
            let record = library.record(id: profileID)
        else { return false }
        return DockLayout(profile: record.profile) == baseline
    }

    var profileActionsDisabled: Bool {
        profileMutationBlocked || profileMutationInProgress
    }

    private var profileMutationBlocked: Bool {
        isLoading
            || isApplying
            || reconciliation != nil
            || importPreview != nil
            || isImporting
            || missingAppActivation != nil
            || isResolvingMissingApps
            || storageUnavailable
            || isTerminating
    }

    var activationActionsDisabled: Bool {
        isLoading
            || saveFailureMessage != nil
            || reconciliation != nil
            || deleteRequest != nil
            || exportPresented
            || importPreview != nil
            || isImporting
            || missingAppActivation != nil
            || isResolvingMissingApps
            || storageUnavailable
            || isTerminating
            || (profileMutationInProgress && !activationLoopRunning)
    }

    func activationDisabled(for profileID: UUID) -> Bool {
        activationActionsDisabled
            || profileID == applyingProfileID
    }

    func load() async {
        defer { isLoading = false }
        do {
            library = try await store.load() ?? DockLibrary()
            lastPersistedLibrary = library
            storageUnavailable = false
            storageFailureMessage = ""
            let current = try await preferences.readPersistentApps()
            if let pending = library.pendingApply {
                let originalLibrary = library
                if current.hasSameLayout(as: pending.intendedSnapshot) {
                    do {
                        _ = try await coordinator.restore(
                            pending.intendedSnapshot,
                            forceReload: true,
                            writtenWhileDockProcessWas: pending.dockProcessIdentifier
                        )
                        let appliedAt = pending.activationRequestedAt ?? pending.startedAt
                        library.activeProfile = ActiveProfile(
                            profileID: pending.profileID,
                            source: pending.source,
                            appliedAt: appliedAt,
                            appliedLayout: pending.intendedLayout
                        )
                        if pending.source == .focus, let requestID = pending.focusRequestID {
                            library.advanceFocusWatermark(to: FocusRequestWatermark(
                                requestID: requestID,
                                createdAt: appliedAt
                            ))
                        }
                        library.lastKnownDock = current
                        library.pendingApply = nil
                        try await saveLibrary()
                        statusMessage = "recovered the completed dock switch."
                    } catch {
                        library = originalLibrary
                        reconciliation = Reconciliation(kind: .interrupted(pending))
                        reconciliationPresented = true
                        fail(title: "dock recovery needs attention", error: error)
                    }
                } else if current.hasSameLayout(as: pending.previousSnapshot) {
                    do {
                        _ = try await coordinator.restore(
                            pending.previousSnapshot,
                            forceReload: true,
                            writtenWhileDockProcessWas: pending.dockProcessIdentifier
                        )
                        library.pendingApply = nil
                        library.lastKnownDock = current
                        try await saveLibrary()
                        statusMessage = "the interrupted switch was rolled back."
                    } catch {
                        library = originalLibrary
                        reconciliation = Reconciliation(kind: .interrupted(pending))
                        reconciliationPresented = true
                        fail(title: "dock recovery needs attention", error: error)
                    }
                } else {
                    reconciliation = Reconciliation(kind: .interrupted(pending))
                    reconciliationPresented = true
                    reconciliationErrorMessage = ""
                }
            } else if
                library.activeProfile != nil,
                library.activeProfile?.appliedLayout == nil
                    || library.lastKnownDock.map({ !current.hasSameLayout(as: $0) }) != false
            {
                let pendingEdits = library.activeProfile.map {
                    $0.appliedLayout == nil || library.hasPendingChanges(profileID: $0.profileID)
                } ?? false
                reconciliation = Reconciliation(kind: pendingEdits ? .savedEditsConflict : .changedWhileClosed)
                reconciliationPresented = true
                reconciliationErrorMessage = ""
            }
            if library.activeProfile?.appliedLayout == nil,
               library.activeProfile != nil, reconciliation == nil {
                reconciliation = Reconciliation(kind: .savedEditsConflict)
                reconciliationPresented = true
            }
            await publishFocusCatalog()
            await startMonitor()
            startFocusMonitor()
        } catch {
            storageUnavailable = true
            storageFailureMessage = userFacingMessage(for: error)
            fail(title: "dockit could not start", error: error)
        }
    }

    func retryLoad() async {
        guard !isLoading, !isTerminating else { return }
        isLoading = true
        await load()
    }

    func flushBeforeTermination() async -> Bool {
        isTerminating = true
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while (isLoading || isApplying || isImporting || mutationOperationCount > 0), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !isLoading, !isApplying, !isImporting, mutationOperationCount == 0 else {
            isTerminating = false
            statusMessage = "finish the dock update before quitting."
            return false
        }
        guard !isDemo, !storageUnavailable, !library.profiles.isEmpty else { return true }
        await cancelAndDrainScheduledSave()
        do {
            try await saveLibrary()
            return true
        } catch {
            isTerminating = false
            saveFailureMessage = userFacingMessage(for: error)
            fail(title: "changes could not be saved", error: error)
            return false
        }
    }

    func createFirst(launchAtLogin: Bool) async {
        guard library.profiles.isEmpty, !storageUnavailable, !isApplying, !isTerminating, !profileMutationInProgress else { return }
        profileMutationInProgress = true
        mutationOperationCount += 1
        defer {
            mutationOperationCount -= 1
            profileMutationInProgress = false
        }
        await setLaunchAtLogin(launchAtLogin)
        let originalLibrary = library
        do {
            let snapshot = try await preferences.readPersistentApps()
            let captured = try snapshot.capture(name: "current dock", color: .blue)
            let record = DockProfileRecord(profile: captured.profile, localState: captured.localState)
            library.add(record)
            library.activeProfile = ActiveProfile(
                profileID: record.id, source: .manual,
                appliedLayout: DockLayout(profile: record.profile)
            )
            library.lastKnownDock = snapshot
            try await saveLibrary()
            statusMessage = "current dock saved."
            quickGuidePresented = true
            await startMonitor()
        } catch {
            library = originalLibrary
            fail(title: "dock could not be created", error: error)
        }
    }

    func completeQuickGuide() {
        guideDefaults?.set(true, forKey: "quickGuideCompleted")
        quickGuidePresented = false
    }

    func createProfile(captureCurrent: Bool) async {
        guard !profileActionsDisabled else {
            presentReconciliationIfNeeded()
            return
        }
        profileMutationInProgress = true
        mutationOperationCount += 1
        defer {
            mutationOperationCount -= 1
            profileMutationInProgress = false
        }
        await cancelAndDrainScheduledSave()
        let originalLibrary = library
        do {
            let record: DockProfileRecord
            if captureCurrent {
                let captured = try await coordinator.capture(
                    name: availableProfileName(base: "current dock"),
                    color: nextColor
                )
                record = DockProfileRecord(profile: captured.profile, localState: captured.localState)
            } else {
                record = DockProfileRecord(profile: DockProfile(
                    name: availableProfileName(base: "new dock"),
                    color: nextColor,
                    items: []
                ))
            }
            library.add(record)
            try await saveLibrary()
            statusMessage = "\(record.profile.name) created."
        } catch {
            library = originalLibrary
            fail(title: "dock could not be created", error: error)
        }
    }

    func duplicateProfile(_ id: UUID) async {
        guard !profileActionsDisabled, library.record(id: id) != nil else {
            presentReconciliationIfNeeded()
            return
        }
        profileMutationInProgress = true
        mutationOperationCount += 1
        defer {
            mutationOperationCount -= 1
            profileMutationInProgress = false
        }
        await cancelAndDrainScheduledSave()
        let originalLibrary = library
        do {
            let duplicateID = try library.duplicate(id: id)
            try await saveLibrary()
            statusMessage = "\(library.record(id: duplicateID)?.profile.name ?? "dock") created."
        } catch {
            library = originalLibrary
            fail(title: "dock could not be duplicated", error: error)
        }
    }

    func askToDeleteProfile(_ id: UUID) {
        guard !profileActionsDisabled else {
            presentReconciliationIfNeeded()
            return
        }
        guard let profile = library.record(id: id)?.profile else { return }
        deleteRequest = DeleteRequest(profile: profile)
    }

    func deleteConfirmed(_ request: DeleteRequest) async {
        guard !profileActionsDisabled, library.record(id: request.id) != nil else {
            presentReconciliationIfNeeded()
            return
        }
        profileMutationInProgress = true
        mutationOperationCount += 1
        defer {
            mutationOperationCount -= 1
            profileMutationInProgress = false
        }
        await cancelAndDrainScheduledSave()
        let id = request.id
        let originalLibrary = library
        do {
            let name = request.profile.name
            let wasActive = id == library.activeProfile?.profileID
            try library.delete(id: id)
            deleteRequest = nil
            try await saveLibrary()
            if wasActive {
                let nextName = selectedRecord?.profile.name ?? "another saved dock"
                statusMessage = "\(name) deleted. the current dock is unchanged and no longer managed. apply \(nextName) to resume saving dock edits."
            } else {
                statusMessage = "\(name) deleted. the current dock was not changed."
            }
        } catch {
            library = originalLibrary
            deleteRequest = nil
            fail(title: "dock could not be deleted", error: error)
        }
    }

    func renameSelected(_ name: String) {
        guard let id = selectedProfileID else { return }
        renameProfile(id, to: name)
    }

    func renameProfile(_ id: UUID, to name: String) {
        guard !profileActionsDisabled, var record = library.record(id: id) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try DockProfile.validateName(trimmedName)
        } catch {
            fail(title: "dock name could not be changed", error: error)
            return
        }
        record.profile.name = trimmedName
        record.profile.updatedAt = Date()
        try? library.replace(record)
        scheduleSave()
    }

    func colorSelected(_ color: ProfileColor) {
        guard !profileActionsDisabled else { return }
        updateSelected { $0.color = color }
    }

    func promptToRenameProfile(_ id: UUID? = nil) {
        guard !profileActionsDisabled else {
            presentReconciliationIfNeeded()
            return
        }
        let profileID = id ?? selectedProfileID
        guard let profileID, let record = library.record(id: profileID) else { return }

        let field = NSTextField(string: record.profile.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.formatter = DockProfileNameFormatter(maximumLength: DockProfile.maximumNameLength)
        field.setAccessibilityLabel("dock name, up to \(DockProfile.maximumNameLength) characters")
        let alert = NSAlert()
        alert.messageText = "rename dock"
        alert.informativeText = "enter a name for this saved dock. use up to \(DockProfile.maximumNameLength) characters."
        alert.accessoryView = field
        alert.addButton(withTitle: "rename")
        alert.addButton(withTitle: "cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        renameProfile(profileID, to: field.stringValue)
    }

    func colorProfile(_ id: UUID, color: ProfileColor) {
        guard !profileActionsDisabled, var record = library.record(id: id) else {
            presentReconciliationIfNeeded()
            return
        }
        record.profile.color = color
        record.profile.updatedAt = Date()
        library.selectedProfileID = id
        try? library.replace(record)
        scheduleSave()
    }

    func activateSelected() async {
        guard let id = selectedProfileID else { return }
        await activate(id, source: .manual)
    }

    @discardableResult
    func activateFromMenu(_ id: UUID) async -> Bool {
        await activate(id, source: .manual, followsActiveSelection: true)
    }

    @discardableResult
    func activate(
        _ id: UUID,
        source: ActivationSource,
        followsActiveSelection: Bool = false,
        allowingProfileMutation: Bool = false,
        requestedAt: Date = Date(),
        focusRequestID: UUID? = nil,
        expectedCurrentSnapshot: DockSnapshot? = nil
    ) async -> Bool {
        activationUsesKeyboard = NSApp.currentEvent?.type == .keyDown
        guard
            !storageUnavailable,
            saveFailureMessage == nil,
            !isLoading,
            !isTerminating,
            (!profileMutationInProgress || allowingProfileMutation || activationLoopRunning),
            library.record(id: id) != nil
        else { return false }
        mutationOperationCount += 1
        defer { mutationOperationCount -= 1 }
        if reconciliation != nil {
            presentReconciliationIfNeeded()
            return false
        }
        guard importPreview == nil, !isImporting, missingAppActivation == nil else {
            presentManagementWindow()
            return false
        }
        if activationLoopRunning {
            return await withCheckedContinuation { continuation in
                let waiting = (queuedActivation?.continuations ?? []) + [continuation]
                queuedActivation = QueuedActivation(
                    profileID: id,
                    source: source,
                    followsActiveSelection: followsActiveSelection,
                    requestedAt: requestedAt,
                    focusRequestID: focusRequestID,
                    expectedCurrentSnapshot: expectedCurrentSnapshot,
                    continuations: waiting
                )
                let name = library.record(id: id)?.profile.name ?? "dock"
                statusMessage = "\(name) will switch next."
            }
        }
        guard !isApplying else { return false }

        isApplying = true
        activationLoopRunning = true
        defer {
            queuedActivation?.continuations.forEach { $0.resume(returning: false) }
            queuedActivation = nil
            activationLoopRunning = false
            isApplying = false
            applyingProfileID = nil
            if selectionChangedDuringActivation {
                if let id = selectionDuringActivationID, library.record(id: id) != nil {
                    library.selectedProfileID = id
                } else if selectionDuringActivationID == nil {
                    library.selectedProfileID = nil
                }
                selectionChangedDuringActivation = false
                selectionDuringActivationID = nil
                scheduleSave()
            }
        }

        var request = QueuedActivation(
            profileID: id,
            source: source,
            followsActiveSelection: followsActiveSelection,
            requestedAt: requestedAt,
            focusRequestID: focusRequestID,
            expectedCurrentSnapshot: expectedCurrentSnapshot,
            continuations: []
        )
        var firstResult: Bool?

        while reconciliation == nil {
            applyingProfileID = request.profileID
            let name = library.record(id: request.profileID)?.profile.name ?? "dock"
            statusMessage = "switching to \(name)."

            try? await Task.sleep(for: .milliseconds(80))
            if var latest = queuedActivation {
                queuedActivation = nil
                latest.continuations = request.continuations + latest.continuations
                request = latest
                continue
            }

            let result = await performActivation(
                request.profileID,
                source: request.source,
                requestedAt: request.requestedAt,
                focusRequestID: request.focusRequestID,
                expectedCurrentSnapshot: request.expectedCurrentSnapshot
            )
            if result, request.followsActiveSelection {
                selectedProfileID = request.profileID
            }
            if firstResult == nil { firstResult = result }
            request.continuations.forEach { $0.resume(returning: result) }
            request.continuations = []

            guard reconciliation == nil, let next = queuedActivation else { break }
            queuedActivation = nil
            request = next
        }
        return firstResult ?? false
    }

    func unavailableApps(for profileID: UUID) -> [SkippedDockApp] {
        guard let profile = library.record(id: profileID)?.profile else { return [] }
        return profile.items.compactMap { item in
            guard case let .application(app) = item.kind else { return nil }
            guard !FileManager.default.fileExists(atPath: app.path) else { return nil }
            return SkippedDockApp(itemID: item.id, app: app)
        }
    }

    func reviewUnavailableApps() {
        guard !profileActionsDisabled, let profileID = selectedProfileID,
              !unavailableApps(for: profileID).isEmpty else { return }
        missingAppErrorMessage = ""
        missingAppActivation = MissingAppActivation(
            profileID: profileID,
            source: .manual,
            requestedAt: Date()
        )
    }

    func cancelMissingAppActivation(_ requestID: UUID) async {
        guard
            !isTerminating,
            !isResolvingMissingApps,
            let request = missingAppActivation,
            request.id == requestID
        else { return }
        isResolvingMissingApps = true
        mutationOperationCount += 1
        defer {
            mutationOperationCount -= 1
            isResolvingMissingApps = false
        }
        if request.source == .focus, !request.focusRequestIDs.isEmpty, let focusBridge {
            do {
                if let focusRequestID = request.focusRequestID {
                    try await persistHandledFocusRequest(
                        id: focusRequestID,
                        createdAt: request.requestedAt
                    )
                }
                try await focusBridge.acknowledge(requestIDs: request.focusRequestIDs)
            } catch {
                missingAppErrorMessage = userFacingMessage(for: error)
                announce(
                    "the focus request could not be dismissed. \(missingAppErrorMessage)"
                )
                return
            }
        }
        guard missingAppActivation?.id == request.id else { return }
        missingAppActivation = nil
        missingAppErrorMessage = ""
        if let activeName = activeRecord?.profile.name {
            statusMessage = "review closed. \(activeName) is still active and your dock is unchanged."
        } else {
            statusMessage = "review closed. your dock is unchanged."
        }
    }

    func confirmMissingAppActivation(_ requestID: UUID) async {
        guard
            !isTerminating,
            !isResolvingMissingApps,
            saveFailureMessage == nil,
            let request = missingAppActivation,
            request.id == requestID
        else { return }
        isResolvingMissingApps = true
        mutationOperationCount += 1
        defer {
            mutationOperationCount -= 1
            isResolvingMissingApps = false
        }
        missingAppActivation = nil
        missingAppErrorMessage = ""
        let activated = await activate(
            request.profileID,
            source: request.source,
            requestedAt: request.requestedAt,
            focusRequestID: request.focusRequestID
        )
        guard activated else {
            if
                reconciliation == nil,
                library.record(id: request.profileID) != nil,
                missingAppActivation == nil
            {
                missingAppActivation = request
            }
            return
        }
        if request.source == .focus, !request.focusRequestIDs.isEmpty, let focusBridge {
            do {
                try await focusBridge.acknowledge(requestIDs: request.focusRequestIDs)
            } catch {
                focusAutomationAvailable = false
                focusAutomationMessage = userFacingMessage(for: error)
            }
        }
    }

    func relinkUnavailableApp(requestID: UUID, itemID: UUID) async {
        guard
            !isTerminating,
            !isResolvingMissingApps,
            !profileMutationInProgress,
            missingAppActivation?.id == requestID,
            let url = chooseUnavailableAppReplacement()
        else { return }
        await saveUnavailableAppReplacement(requestID: requestID, itemID: itemID, url: url)
    }

    private func chooseUnavailableAppReplacement() -> URL? {
        isResolvingMissingApps = true
        profileMutationInProgress = true
        mutationOperationCount += 1
        defer {
            mutationOperationCount -= 1
            profileMutationInProgress = false
            isResolvingMissingApps = false
        }
        let panel = NSOpenPanel()
        panel.title = "choose replacement app"
        panel.prompt = "choose"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func saveUnavailableAppReplacement(requestID: UUID, itemID: UUID, url: URL) async {
        guard
            !isTerminating,
            !isResolvingMissingApps,
            !profileMutationInProgress,
            let request = missingAppActivation,
            request.id == requestID,
            var record = library.record(id: request.profileID),
            let index = record.profile.items.firstIndex(where: { $0.id == itemID }),
            case .application = record.profile.items[index].kind
        else { return }

        isResolvingMissingApps = true
        profileMutationInProgress = true
        mutationOperationCount += 1
        defer {
            mutationOperationCount -= 1
            profileMutationInProgress = false
            isResolvingMissingApps = false
        }

        await cancelAndDrainScheduledSave()

        let bundle = Bundle(url: url)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        record.profile.items[index].kind = .application(DockApp(
            bundleIdentifier: bundle?.bundleIdentifier,
            path: url.path,
            displayName: name
        ))
        record.localState.rawTiles[itemID] = nil
        record.profile.updatedAt = Date()

        do {
            try library.replace(record)
            try await saveLibrary()
            missingAppErrorMessage = ""
            statusMessage = "replacement app saved."
        } catch {
            let message = userFacingMessage(for: error)
            saveFailureMessage = message
            missingAppErrorMessage = message
            announce("replacement failed. \(missingAppErrorMessage)")
        }
    }

    private func performActivation(
        _ id: UUID,
        source: ActivationSource,
        requestedAt: Date,
        focusRequestID: UUID?,
        expectedCurrentSnapshot: DockSnapshot?
    ) async -> Bool {
        if isDemo {
            if let demoActivationDelayMilliseconds, demoActivationDelayMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(demoActivationDelayMilliseconds))
            }
            if library.record(id: id)?.profile.name == demoFailureProfileName {
                fail(
                    title: "dock could not be switched",
                    error: DemoActivationError.verificationFailed
                )
                return false
            }
            library.activeProfile = ActiveProfile(
                profileID: id,
                source: source,
                appliedAt: requestedAt,
                appliedLayout: library.record(id: id).map { DockLayout(profile: $0.profile) }
            )
            if source == .focus, let focusRequestID {
                library.advanceFocusWatermark(to: FocusRequestWatermark(
                    requestID: focusRequestID,
                    createdAt: requestedAt
                ))
            }
            statusMessage = "\(library.record(id: id)?.profile.name ?? "dock") is active."
            return true
        }
        var savedBeforeApply = false
        do {
            await cancelAndDrainScheduledSave()
            try await saveLibrary()
            savedBeforeApply = true
            let outcome = try await activationService.activate(
                profileID: id,
                source: source,
                activatedAt: requestedAt,
                focusRequestID: focusRequestID,
                expectedCurrentSnapshot: expectedCurrentSnapshot
            )
            var updatedLibrary = outcome.library
            updatedLibrary.selectedProfileID = library.selectedProfileID
            library = updatedLibrary
            lastPersistedLibrary = outcome.library
            await publishFocusCatalog()
            await monitor.suppress(outcome.applyResult.appliedSnapshot)
            let name = library.record(id: id)?.profile.name ?? "dock"
            if outcome.applyResult.skippedApps.isEmpty {
                statusMessage = "\(name) is active."
            } else {
                let skipped = outcome.applyResult.skippedApps.map(\.app.displayName).joined(separator: ", ")
                statusMessage = "\(name) is active. missing apps were skipped: \(skipped)."
            }
            return true
        } catch {
            if savedBeforeApply {
                await reloadAfterActivationFailure()
            } else {
                saveFailureMessage = userFacingMessage(for: error)
            }
            fail(title: "dock could not be switched", error: error)
            return false
        }
    }

    func addApps() async {
        guard canEditSelectedDock, let targetProfileID = selectedProfileID else { return }
        let panel = NSOpenPanel()
        panel.title = "add apps to dock"
        panel.prompt = "add"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let items = panel.urls.map { url -> DockItem in
            let bundle = Bundle(url: url)
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            return DockItem(kind: .application(DockApp(
                bundleIdentifier: bundle?.bundleIdentifier,
                path: url.path,
                displayName: name
            )))
        }
        guard selectedProfileID == targetProfileID else {
            statusMessage = "apps were not added because the selected dock changed."
            return
        }
        await editSelectedItems { $0.append(contentsOf: items) }
    }

    func addSpacer(_ size: SpacerSize = .regular) async {
        guard canEditSelectedDock else { return }
        await editSelectedItems { $0.append(DockItem(kind: .spacer(size))) }
    }

    func removeSelectedItem() async {
        await removeSelectedItems()
    }

    func moveSelectedItem(by offset: Int) async {
        await moveSelectedItems(by: offset)
    }

    func selectItem(_ id: UUID, extendingRange: Bool = false, toggling: Bool = false) {
        guard let items = selectedRecord?.profile.items,
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        if extendingRange, let anchor = selectionAnchorID,
           let anchorIndex = items.firstIndex(where: { $0.id == anchor }) {
            let range = Set(items[min(index, anchorIndex)...max(index, anchorIndex)].map(\.id))
            selectedItemIDs = toggling ? selectedItemIDs.union(range) : range
        } else if toggling {
            if !selectedItemIDs.insert(id).inserted { selectedItemIDs.remove(id) }
            selectionAnchorID = id
        } else {
            selectedItemIDs = [id]
            selectionAnchorID = id
        }
    }

    func removeSelectedItems() async {
        let ids = selectedItemIDs
        await editSelectedItems { $0.removeAll { ids.contains($0.id) } }
        selectedItemIDs.formIntersection(Set(selectedRecord?.profile.items.map(\.id) ?? []))
    }

    func moveSelectedItems(by offset: Int) async {
        let ids = selectedItemIDs
        await editSelectedItems { $0 = DockItemEditing.moving($0, selectedIDs: ids, by: offset) }
    }

    func moveItems(
        _ ids: [UUID],
        before targetID: UUID?,
        sourceProfileID: UUID,
        expectedItems: [DockItem]
    ) async {
        let selectedIDs = Set(ids)
        let availableIDs = Set(expectedItems.map(\.id))
        guard !selectedIDs.isEmpty,
              selectedIDs.count == ids.count,
              selectedIDs.isSubset(of: availableIDs) else { return }
        if let targetID {
            guard availableIDs.contains(targetID), !selectedIDs.contains(targetID) else { return }
        }
        let baseline = ItemEditBaseline(profileID: sourceProfileID, items: expectedItems)
        await editSelectedItems(expected: baseline) {
            $0 = DockItemEditing.moving($0, selectedIDs: selectedIDs, before: targetID)
        }
    }

    func replaceSelectedWithCurrentDock() async {
        guard canEditSelectedDock, let id = selectedProfileID, var record = selectedRecord else { return }
        profileMutationInProgress = true
        mutationOperationCount += 1
        defer {
            mutationOperationCount -= 1
            profileMutationInProgress = false
        }
        await cancelAndDrainScheduledSave()
        do {
            let snapshot = try await preferences.readPersistentApps()
            let capture = try snapshot.capture(name: record.profile.name, color: record.profile.color)
            record.profile.items = capture.profile.items
            record.profile.updatedAt = Date()
            record.localState = capture.localState
            try library.replace(record)
            selectedItemID = nil
            if library.activeProfile?.profileID == id {
                library.activeProfile?.appliedLayout = DockLayout(profile: record.profile)
                library.lastKnownDock = snapshot
            }
            try await saveLibrary()
            statusMessage = "current dock saved."
        } catch {
            saveFailureMessage = userFacingMessage(for: error)
            fail(title: "dock could not be replaced", error: error)
        }
    }

    func exportProfiles(_ identifiers: Set<UUID>) async {
        guard !profileActionsDisabled, exportPresented, transferPresentationHost != nil else {
            presentReconciliationIfNeeded()
            return
        }
        do {
            exportFilePhase = .awaitingSheetDismissal(try DockitArchive(library: library, profileIDs: identifiers))
            exportSelection = identifiers
            exportErrorMessage = nil
            profileMutationInProgress = true
            exportPresented = false
        } catch {
            exportErrorMessage = userFacingMessage(for: error)
        }
    }

    func presentExport(from host: TransferPresentationHost) {
        guard !profileActionsDisabled, transferPresentationHost == nil, !library.profiles.isEmpty else {
            presentReconciliationIfNeeded()
            return
        }
        beginTransfer(from: host)
        exportSelection = selectedProfileID.map { [$0] } ?? Set(library.profiles.map(\.id))
        exportErrorMessage = nil
        exportPresented = true
    }

    func cancelExport() {
        guard exportPresented else { return }
        setTransferMessage("export canceled.")
        exportPresented = false
    }

    func importProfiles(from host: TransferPresentationHost = .management) async {
        guard !profileActionsDisabled, transferPresentationHost == nil else {
            presentReconciliationIfNeeded()
            return
        }
        beginTransfer(from: host)
        guard let url = await chooseTransferFile(.importProfiles) else {
            setTransferMessage("import canceled.")
            finishTransferSheet(from: host)
            return
        }
        await reviewImport(at: url)
    }

    @discardableResult
    func openImportURL(_ url: URL) -> Task<Void, Never> {
        Task {
            while isLoading {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !profileActionsDisabled, transferPresentationHost == nil else { return }
            beginTransfer(from: .management)
            await reviewImport(at: url)
        }
    }

    private func reviewImport(at url: URL) async {
        guard !profileActionsDisabled else {
            presentReconciliationIfNeeded()
            return
        }
        do {
            let archive = try DockitArchive.decode(Data(contentsOf: url))
            var projectedLibrary = library
            let projectedIDs = try projectedLibrary.appendImported(archive)
            let profiles: [ImportPreview.Profile] = zip(archive.profiles, projectedIDs).compactMap { pair in
                let (source, projectedID) = pair
                guard let projected = projectedLibrary.record(id: projectedID)?.profile else { return nil }
                let unavailableApps = source.items.compactMap { item -> ImportPreview.Profile.UnavailableApp? in
                    guard case let .application(app) = item.kind else { return nil }
                    guard !FileManager.default.fileExists(atPath: app.path) else { return nil }
                    return ImportPreview.Profile.UnavailableApp(id: item.id, app: app)
                }
                return ImportPreview.Profile(
                    source: source,
                    importedName: projected.name,
                    unavailableApps: unavailableApps
                )
            }
            guard profiles.count == archive.profiles.count else {
                throw DockitArchiveError.invalidFile
            }
            importPreview = ImportPreview(
                archive: archive,
                fileName: url.lastPathComponent,
                profiles: profiles
            )
        } catch {
            let host = transferPresentationHost
            fail(title: "docks could not be reviewed", error: error, host: host)
            if let host { finishTransferSheet(from: host) }
        }
    }

    func confirmImport(_ previewID: UUID) async {
        guard
            !isApplying,
            reconciliation == nil,
            !storageUnavailable,
            !isImporting,
            !profileMutationInProgress,
            let preview = importPreview,
            preview.id == previewID
        else {
            presentReconciliationIfNeeded()
            return
        }
        isImporting = true
        profileMutationInProgress = true
        mutationOperationCount += 1
        defer {
            mutationOperationCount -= 1
            profileMutationInProgress = false
            isImporting = false
        }
        await cancelAndDrainScheduledSave()
        let originalLibrary = library
        do {
            let identifiers = try library.appendImported(preview.archive)
            try await saveLibrary()
            importPreview = nil
            setTransferMessage("imported \(identifiers.count) dock\(identifiers.count == 1 ? "" : "s").")
        } catch {
            library = originalLibrary
            fail(title: "docks could not be imported", error: error)
        }
    }

    func cancelImport() {
        guard !isImporting, importPreview != nil else { return }
        setTransferMessage("import canceled.")
        importPreview = nil
    }

    @discardableResult
    func finishTransferSheet(from host: TransferPresentationHost) -> Task<Void, Never>? {
        guard transferPresentationHost == host, !exportPresented, importPreview == nil else { return nil }
        if case let .awaitingSheetDismissal(archive) = exportFilePhase {
            exportFilePhase = .choosingLocation
            return Task { await completeExport(archive, from: host) }
        }
        guard exportFilePhase == nil else { return nil }
        let window = transferInvokingWindow
        transferPresentationHost = nil
        transferInvokingWindow = nil
        exportSelection = []
        guard integratesWithSystem, NSApplication.shared.isActive, window?.isVisible == true else { return nil }
        window?.makeKeyAndOrderFront(nil)
        return nil
    }

    private func completeExport(_ archive: DockitArchive, from host: TransferPresentationHost) async {
        let defaultName = archive.profiles.count == 1
            ? "\(archive.profiles[0].name).dockit"
            : "dockit docks.dockit"
        let url = await chooseTransferFile(.exportProfiles(defaultName: defaultName))
        exportFilePhase = nil
        guard let url else {
            exportPresented = true
            return
        }
        do {
            try archive.encoded().write(to: url, options: [.atomic, .completeFileProtection])
            setTransferMessage("exported \(archive.profiles.count) dock\(archive.profiles.count == 1 ? "" : "s").")
            finishTransferSheet(from: host)
        } catch {
            exportErrorMessage = userFacingMessage(for: error)
            exportPresented = true
        }
    }

    private func beginTransfer(from host: TransferPresentationHost) {
        transferPresentationHost = host
        if host == .settings { settingsTransferMessage = nil }
        guard integratesWithSystem else { return }
        let identifier = host == .settings ? "preferences" : "management"
        let title = host == .settings ? "dockit settings" : "dockit"
        transferInvokingWindow = NSApplication.shared.windows.first {
            $0.identifier?.rawValue == identifier || $0.title == title
        }
    }

    private func setTransferMessage(_ message: String) {
        statusMessage = message
        if transferPresentationHost == .settings { settingsTransferMessage = message }
    }

    private func chooseTransferFile(_ request: TransferFileRequest) async -> URL? {
        profileMutationInProgress = true
        mutationOperationCount += 1
        defer {
            mutationOperationCount -= 1
            profileMutationInProgress = false
        }
        return await transferFilePicker(request, transferInvokingWindow)
    }

    private static func presentTransferFilePicker(_ request: TransferFileRequest, window: NSWindow?) async -> URL? {
        let panel: NSSavePanel
        switch request {
        case .importProfiles:
            let openPanel = NSOpenPanel()
            openPanel.title = "import docks"
            openPanel.prompt = "review"
            openPanel.allowedContentTypes = [UTType(importedAs: "com.advegaf.dockit.profiles", conformingTo: .json)]
            openPanel.allowsMultipleSelection = false
            panel = openPanel
        case let .exportProfiles(defaultName):
            panel = NSSavePanel()
            panel.title = "export docks"
            panel.prompt = "export"
            panel.allowedContentTypes = [UTType(exportedAs: "com.advegaf.dockit.profiles", conformingTo: .json)]
            panel.nameFieldStringValue = defaultName
        }
        return await withCheckedContinuation { continuation in
            let completion: (NSApplication.ModalResponse) -> Void = { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
            if let window {
                panel.beginSheetModal(for: window, completionHandler: completion)
            } else {
                panel.begin(completionHandler: completion)
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) async {
        guard integratesWithSystem, !isTerminating, !launchAtLoginChangeInProgress else { return }
        if isDemo {
            launchAtLogin = enabled
            return
        }
        launchAtLoginChangeInProgress = true
        mutationOperationCount += 1
        defer {
            mutationOperationCount -= 1
            launchAtLoginChangeInProgress = false
        }
        await applyLaunchAtLogin(enabled, errorHost: nil)
    }

    func requestLaunchAtLogin(_ enabled: Bool) {
        guard integratesWithSystem, !isTerminating, !launchAtLoginChangeInProgress else { return }
        if isDemo {
            launchAtLogin = enabled
            return
        }
        launchAtLoginChangeInProgress = true
        mutationOperationCount += 1
        launchAtLoginTask = Task { [self] in
            await applyLaunchAtLogin(enabled, errorHost: .settings)
            mutationOperationCount -= 1
            launchAtLoginChangeInProgress = false
            launchAtLoginTask = nil
        }
    }

    func refreshLaunchAtLoginStatus() {
        guard !isDemo, integratesWithSystem, !launchAtLoginChangeInProgress else { return }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        launchAtLoginNeedsApproval = status == .requiresApproval
    }

    private func applyLaunchAtLogin(
        _ enabled: Bool,
        errorHost: TransferPresentationHost?
    ) async {
        let service = SMAppService.mainApp
        do {
            switch (enabled, service.status) {
            case (true, .notRegistered):
                try service.register()
            case (false, .enabled), (false, .requiresApproval):
                try await service.unregister()
            default:
                break
            }
            launchAtLogin = service.status == .enabled
            launchAtLoginNeedsApproval = service.status == .requiresApproval
        } catch {
            launchAtLogin = service.status == .enabled
            launchAtLoginNeedsApproval = service.status == .requiresApproval
            fail(title: "launch at login could not be changed", error: error, host: errorHost)
        }
    }

    func reviewReconciliation() {
        reconciliationPresented = true
    }

    func dismissReconciliation() {
        reconciliationPresented = false
    }

    func applySavedReconciliation() async {
        await restoreSavedDock()
    }

    func keepCurrentAsNewDock() async {
        guard reconciliation != nil, !isApplying, !isTerminating, !profileMutationInProgress else { return }
        profileMutationInProgress = true
        mutationOperationCount += 1
        defer {
            mutationOperationCount -= 1
            profileMutationInProgress = false
        }
        await cancelAndDrainScheduledSave()
        let originalLibrary = library
        do {
            let snapshot = try await preferences.readPersistentApps()
            let capture = try snapshot.capture(name: availableProfileName(base: "current dock"), color: nextColor)
            let record = DockProfileRecord(profile: capture.profile, localState: capture.localState)
            library.add(record)
            library.activeProfile = ActiveProfile(
                profileID: record.id, source: .manual,
                appliedLayout: DockLayout(profile: record.profile)
            )
            library.lastKnownDock = snapshot
            library.pendingApply = nil
            try await saveLibrary()
            reconciliation = nil
            reconciliationPresented = false
            reconciliationErrorMessage = ""
            await monitor.suppress(snapshot)
            statusMessage = "current dock saved as a new profile. your other saved edits are unchanged."
        } catch {
            library = originalLibrary
            fail(title: "current dock could not be saved", error: error)
        }
    }

    func keepCurrentDockChanges() async {
        guard !isApplying, !isTerminating, !profileMutationInProgress, let reconciliation else { return }
        switch reconciliation.kind {
        case .savedEditsConflict, .interrupted:
            await keepCurrentAsNewDock()
            return
        case .changedWhileClosed:
            break
        }
        profileMutationInProgress = true
        mutationOperationCount += 1
        defer {
            mutationOperationCount -= 1
            profileMutationInProgress = false
        }
        await cancelAndDrainScheduledSave()
        let originalLibrary = library
        isApplying = true
        defer { isApplying = false }
        do {
            let current = try await preferences.readPersistentApps()
            guard let activeID = library.activeProfile?.profileID,
                  var record = library.record(id: activeID) else {
                throw DockLibraryError.profileNotFound
            }
            let captured = try current.capture(name: record.profile.name, color: record.profile.color)
            let unavailableIDs = Set(unavailableApps(for: activeID).map(\.itemID))
            record = record.reconciling(captured, retaining: unavailableIDs)
            try library.replace(record)
            library.activeProfile = ActiveProfile(
                profileID: activeID, source: .manual,
                appliedLayout: DockLayout(profile: record.profile)
            )
            library.lastKnownDock = current
            library.pendingApply = nil
            try await saveLibrary()
            self.reconciliation = nil
            reconciliationPresented = false
            reconciliationErrorMessage = ""
            statusMessage = "current dock changes saved."
        } catch {
            library = originalLibrary
            fail(title: "dock changes could not be saved", error: error)
        }
    }

    func restoreSavedDock() async {
        guard !isApplying, !isTerminating, !profileMutationInProgress, let reconciliation else { return }
        profileMutationInProgress = true
        mutationOperationCount += 1
        defer {
            mutationOperationCount -= 1
            profileMutationInProgress = false
        }
        await cancelAndDrainScheduledSave()
        let profileID: UUID
        switch reconciliation.kind {
        case .changedWhileClosed, .savedEditsConflict:
            guard let id = library.activeProfile?.profileID else { return }
            profileID = id
        case let .interrupted(pending):
            if let completed = await finishWrittenPendingApply(pending) {
                if completed {
                    self.reconciliation = nil
                    reconciliationPresented = false
                    reconciliationErrorMessage = ""
                }
                return
            }
            profileID = pending.profileID
        }
        let originalReconciliation = reconciliation
        let approvedSnapshot: DockSnapshot
        do {
            approvedSnapshot = try await preferences.readPersistentApps()
        } catch {
            fail(title: "current dock could not be checked", error: error)
            return
        }
        self.reconciliation = nil
        reconciliationPresented = false
        reconciliationErrorMessage = ""
        let restored = await activate(
            profileID,
            source: .manual,
            allowingProfileMutation: true,
            expectedCurrentSnapshot: approvedSnapshot
        )
        if !restored, self.reconciliation == nil {
            self.reconciliation = originalReconciliation
            reconciliationPresented = true
            if let error = presentedError {
                reconciliationErrorMessage = "\(error.title): \(error.message)"
                presentedError = nil
                presentedErrorHost = nil
            }
        }
    }

    private func finishWrittenPendingApply(_ pending: PendingDockApply) async -> Bool? {
        let current: DockSnapshot
        do {
            current = try await preferences.readPersistentApps()
        } catch {
            fail(title: "saved dock could not be checked", error: error)
            return false
        }
        guard current.hasSameLayout(as: pending.intendedSnapshot) else { return nil }

        let originalLibrary = library
        isApplying = true
        defer { isApplying = false }
        do {
            _ = try await coordinator.restore(
                            pending.intendedSnapshot,
                            forceReload: true,
                            writtenWhileDockProcessWas: pending.dockProcessIdentifier
                        )
            let appliedAt = pending.activationRequestedAt ?? pending.startedAt
            library.activeProfile = ActiveProfile(
                profileID: pending.profileID,
                source: pending.source,
                appliedAt: appliedAt,
                appliedLayout: pending.intendedLayout
            )
            if pending.source == .focus, let requestID = pending.focusRequestID {
                library.advanceFocusWatermark(to: FocusRequestWatermark(
                    requestID: requestID,
                    createdAt: appliedAt
                ))
            }
            library.lastKnownDock = pending.intendedSnapshot
            library.pendingApply = nil
            try await saveLibrary()
            statusMessage = "recovered the completed dock switch."
            reconciliationErrorMessage = ""
            return true
        } catch {
            library = originalLibrary
            fail(title: "saved dock could not be restored", error: error)
            return false
        }
    }

    func restorePreSwitchDock() async {
        guard
            !isApplying,
            !isTerminating,
            !profileMutationInProgress,
            let reconciliation,
            case let .interrupted(pending) = reconciliation.kind
        else { return }
        profileMutationInProgress = true
        mutationOperationCount += 1
        defer {
            mutationOperationCount -= 1
            profileMutationInProgress = false
        }
        await cancelAndDrainScheduledSave()
        let originalLibrary = library
        isApplying = true
        defer { isApplying = false }
        do {
            _ = try await coordinator.restore(
                            pending.previousSnapshot,
                            forceReload: true,
                            writtenWhileDockProcessWas: pending.dockProcessIdentifier
                        )
            library.pendingApply = nil
            library.lastKnownDock = pending.previousSnapshot
            try await saveLibrary()
            self.reconciliation = nil
            reconciliationPresented = false
            reconciliationErrorMessage = ""
            statusMessage = "previous dock restored."
        } catch {
            library = originalLibrary
            fail(title: "previous dock could not be restored", error: error)
        }
    }

    private func updateSelected(_ update: (inout DockProfile) -> Void) {
        guard let id = selectedProfileID, var record = library.record(id: id) else { return }
        update(&record.profile)
        record.profile.updatedAt = Date()
        try? library.replace(record)
        scheduleSave()
    }

    private func editSelectedItems(
        expected baseline: ItemEditBaseline? = nil,
        _ edit: (inout [DockItem]) -> Void
    ) async {
        guard canEditSelectedDock, !Task.isCancelled,
              let id = selectedProfileID,
              let current = library.record(id: id),
              baseline?.matches(current.profile) != false else { return }
        profileMutationInProgress = true
        mutationOperationCount += 1
        defer {
            mutationOperationCount -= 1
            profileMutationInProgress = false
        }
        await cancelAndDrainScheduledSave()
        guard !Task.isCancelled, !profileMutationBlocked,
              selectedProfileID == id,
              var record = library.record(id: id),
              baseline?.matches(record.profile) != false else { return }
        let originalItems = record.profile.items
        edit(&record.profile.items)
        guard record.profile.items != originalItems else { return }
        record.localState.rawTiles = record.localState.rawTiles.filter { entry in
            record.profile.items.contains { $0.id == entry.key }
        }
        record.profile.updatedAt = Date()
        do {
            try library.replace(record)
            try await saveLibrary()
            statusMessage = "saved. choose use this dock to update your dock."
        } catch {
            saveFailureMessage = userFacingMessage(for: error)
            fail(title: "dock could not be edited", error: error)
        }
    }

    private func scheduleSave() {
        guard !isDemo, !storageUnavailable, reconciliation == nil, !isApplying, !isTerminating else { return }
        saveGeneration += 1
        let generation = saveGeneration
        let snapshot = library
        let predecessor = saveTask
        predecessor?.cancel()
        saveTask = Task { [weak self] in
            if let predecessor {
                await predecessor.value
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            do {
                try await self.saveLibrary(snapshot)
            } catch {
                guard generation == self.saveGeneration else { return }
                self.saveFailureMessage = self.userFacingMessage(for: error)
                self.fail(title: "changes could not be saved", error: error)
            }
        }
    }

    private func startMonitor() async {
        guard !isDemo, integratesWithSystem else { return }
        await monitor.start(initialSnapshot: library.lastKnownDock) { [weak self] snapshot in
            await self?.handleDockChange(snapshot) ?? false
        }
    }

    private func saveLibrary(_ snapshot: DockLibrary? = nil) async throws {
        let saved = snapshot ?? library
        if !isDemo { try await store.save(saved) }
        lastPersistedLibrary = saved
        if saved == library { saveFailureMessage = nil }
        await publishFocusCatalog(saved)
    }

    func retrySave() async {
        guard !isApplying, !isTerminating, !profileMutationInProgress else { return }
        profileMutationInProgress = true
        mutationOperationCount += 1
        defer {
            mutationOperationCount -= 1
            profileMutationInProgress = false
        }
        await cancelAndDrainScheduledSave()
        do {
            try await saveLibrary()
            if missingAppActivation != nil {
                missingAppErrorMessage = ""
            }
            statusMessage = "changes saved."
        } catch {
            let message = userFacingMessage(for: error)
            saveFailureMessage = message
            if missingAppActivation != nil {
                missingAppErrorMessage = message
            }
            announce("changes could not be saved. \(message)")
        }
    }

    private func publishFocusCatalog(_ source: DockLibrary? = nil) async {
        guard integratesWithSystem else { return }
        guard focusExtensionIsEmbedded else {
            focusAutomationAvailable = false
            focusAutomationMessage = "this copy of dockit is missing its focus extension. manual switching still works."
            return
        }
        guard let focusBridge else {
            focusAutomationAvailable = isDemo
            return
        }
        do {
            try await focusBridge.publish(source ?? library)
            let expected = (source ?? library).profiles.map { FocusProfileSummary(profile: $0.profile) }
            let published = try await focusBridge.loadProfiles()
            guard published == expected else { throw FocusBridgeStoreError.unreadable }
            focusAutomationAvailable = true
            focusAutomationMessage = "choose a dock for each focus in system settings."
        } catch {
            focusAutomationAvailable = false
            focusAutomationMessage = userFacingMessage(for: error)
        }
    }

    private func startFocusMonitor() {
        guard !isDemo, integratesWithSystem, focusExtensionIsEmbedded, focusBridge != nil, focusRequestTask == nil else { return }
        focusRequestTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.processFocusRequests()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func processFocusRequests() async {
        guard
            !isApplying,
            !activationActionsDisabled,
            let focusBridge
        else { return }
        do {
            let batch = try await focusBridge.pendingRequestBatch()
            if batch.quarantinedCount > 0 {
                let count = batch.quarantinedCount
                focusAutomationMessage = "dockit set aside \(count) damaged focus request\(count == 1 ? "" : "s"). future switching still works."
                statusMessage = focusAutomationMessage
            }
            let requests = batch.requests
            guard let latest = requests.last else { return }
            guard !isApplying, !activationActionsDisabled else { return }
            profileMutationInProgress = true
            mutationOperationCount += 1
            defer {
                mutationOperationCount -= 1
                profileMutationInProgress = false
            }
            focusAutomationAvailable = true
            let requestIDs = requests.map(\.id)

            guard latest.isNewer(
                than: library.lastHandledFocusRequest,
                fallbackActiveProfile: library.activeProfile
            ) else {
                try await completeFocusRequest(latest, requestIDs: requestIDs, using: focusBridge)
                return
            }

            guard let profileID = latest.profileID else {
                try await completeFocusRequest(latest, requestIDs: requestIDs, using: focusBridge)
                return
            }

            guard library.record(id: profileID) != nil else {
                try await completeFocusRequest(latest, requestIDs: requestIDs, using: focusBridge)
                fail(title: "focus dock is unavailable", error: DockLibraryError.profileNotFound)
                return
            }

            let activated = await activate(
                profileID,
                source: .focus,
                allowingProfileMutation: true,
                requestedAt: latest.createdAt,
                focusRequestID: latest.id
            )
            guard activated else {
                if
                    var missingRequest = missingAppActivation,
                    missingRequest.source == .focus,
                    missingRequest.profileID == profileID,
                    missingRequest.requestedAt == latest.createdAt
                {
                    missingRequest.focusRequestID = latest.id
                    missingRequest.focusRequestIDs = requestIDs
                    missingAppActivation = missingRequest
                }
                return
            }
            try await focusBridge.acknowledge(requestIDs: requestIDs)
            focusAutomationMessage = "choose a dock for each focus in system settings."
        } catch {
            focusAutomationAvailable = false
            focusAutomationMessage = userFacingMessage(for: error)
        }
    }

    private func completeFocusRequest(
        _ request: FocusActivationRequest,
        requestIDs: [UUID],
        using focusBridge: FocusBridgeStore
    ) async throws {
        try await persistHandledFocusRequest(id: request.id, createdAt: request.createdAt)
        try await focusBridge.acknowledge(requestIDs: requestIDs)
    }

    private func persistHandledFocusRequest(id: UUID, createdAt: Date) async throws {
        let candidate = FocusRequestWatermark(requestID: id, createdAt: createdAt)
        guard candidate.isNewer(than: library.lastHandledFocusRequest) else { return }
        let ownsProfileMutation = !profileMutationInProgress
        if ownsProfileMutation {
            profileMutationInProgress = true
        }
        defer {
            if ownsProfileMutation {
                profileMutationInProgress = false
            }
        }
        await cancelAndDrainScheduledSave()
        let originalLibrary = library
        library.advanceFocusWatermark(to: candidate)
        do {
            try await saveLibrary()
        } catch {
            library = originalLibrary
            throw error
        }
    }

    func handleDockChange(_ snapshot: DockSnapshot) async -> Bool {
        guard
            !isLoading,
            !isApplying,
            !isTerminating,
            !storageUnavailable,
            saveFailureMessage == nil,
            !profileMutationInProgress
        else { return false }
        guard let id = library.activeProfile?.profileID else { return true }
        if let reconciliation {
            if case .savedEditsConflict = reconciliation.kind,
               library.activeProfile?.appliedLayout != nil,
               let known = library.lastKnownDock, snapshot.hasSameLayout(as: known) {
                self.reconciliation = nil
                reconciliationPresented = false
                reconciliationErrorMessage = ""
                statusMessage = "your dock is back to its last applied layout. saved edits are unchanged."
            }
            return true
        }
        if let known = library.lastKnownDock, snapshot.hasSameLayout(as: known) { return true }
        if library.hasPendingChanges(profileID: id) || library.activeProfile?.appliedLayout == nil {
            reconciliation = Reconciliation(kind: .savedEditsConflict)
            reconciliationPresented = true
            statusMessage = "your dock changed while saved edits were waiting to apply. review both versions."
            presentManagementWindow()
            return true
        }
        profileMutationInProgress = true
        mutationOperationCount += 1
        defer {
            mutationOperationCount -= 1
            profileMutationInProgress = false
        }
        await cancelAndDrainScheduledSave()
        guard var record = library.record(id: id) else { return false }
        do {
            let captured = try snapshot.capture(name: record.profile.name, color: record.profile.color)
            let unavailableIDs = Set(unavailableApps(for: id).map(\.itemID))
            record = record.reconciling(captured, retaining: unavailableIDs)
            try library.replace(record)
            library.activeProfile?.appliedLayout = DockLayout(profile: record.profile)
            library.lastKnownDock = snapshot
            try await saveLibrary()
            statusMessage = "saved changes from the dock."
            return true
        } catch {
            saveFailureMessage = userFacingMessage(for: error)
            fail(title: "dock changes could not be saved", error: error)
            return false
        }
    }

    private func cancelAndDrainScheduledSave() async {
        while let pending = saveTask {
            saveGeneration += 1
            saveTask = nil
            pending.cancel()
            await pending.value
        }
    }

    private func reloadAfterActivationFailure() async {
        do {
            guard let persisted = try await store.load() else { return }
            var updatedLibrary = persisted
            updatedLibrary.selectedProfileID = library.selectedProfileID
            library = updatedLibrary
            lastPersistedLibrary = persisted
            if let pending = persisted.pendingApply {
                reconciliation = Reconciliation(kind: .interrupted(pending))
                reconciliationPresented = true
                reconciliationErrorMessage = ""
            } else if let active = persisted.activeProfile,
                      let current = try? await preferences.readPersistentApps(),
                      persisted.lastKnownDock.map({ !current.hasSameLayout(as: $0) }) != false {
                reconciliation = Reconciliation(kind: persisted.hasPendingChanges(profileID: active.profileID)
                    ? .savedEditsConflict : .changedWhileClosed)
                reconciliationPresented = true
                reconciliationErrorMessage = ""
            }
            await publishFocusCatalog(persisted)
        } catch {
            storageUnavailable = true
            storageFailureMessage = userFacingMessage(for: error)
        }
    }

    private func presentReconciliationIfNeeded() {
        guard reconciliation != nil else { return }
        reconciliationPresented = true
        statusMessage = "review the dock recovery choices before making another change."
    }

    private func availableProfileName(base: String) -> String {
        let names = Set(library.profiles.map { $0.profile.name.localizedLowercase })
        guard names.contains(base.localizedLowercase) else { return base }
        var suffix = 2
        while names.contains("\(base) \(suffix)".localizedLowercase) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    private var nextColor: ProfileColor {
        let colors = ProfileColor.allCases
        return colors[library.profiles.count % colors.count]
    }

    private func syncDockMenu() {
        guard integratesWithSystem else { return }
        DockMenuCoordinator.shared.update(
            profiles: library.profiles.map(\.profile),
            activeID: library.activeProfile?.profileID,
            applyingID: applyingProfileID,
            activationActionsDisabled: activationActionsDisabled
        ) { [weak self] id in
            Task {
                guard let self else { return }
                if await self.activateFromMenu(id) == false {
                    self.presentManagementWindow()
                }
            }
        }
    }

    private func fail(
        title: String,
        error: Error,
        host: TransferPresentationHost? = nil
    ) {
        let message = userFacingMessage(for: error)
        if reconciliation != nil {
            reconciliationErrorMessage = "\(title): \(message)"
            announce("recovery error. \(message)")
            reconciliationPresented = true
            presentManagementWindow()
            return
        }
        presentedErrorHost = host ?? transferPresentationHost
        presentedError = PresentedError(title: title, message: message)
        if presentedErrorHost != .settings {
            presentManagementWindow()
        }
    }

    private func presentManagementWindow() {
        guard integratesWithSystem else { return }
        DockMenuCoordinator.shared.presentMainWindow()
    }

    private func announce(_ message: String) {
        guard integratesWithSystem else { return }
        AccessibilityNotification.Announcement(message).post()
    }

    private func userFacingMessage(for error: Error) -> String {
        if let cocoaError = error as? CocoaError {
            switch cocoaError.code {
            case .fileReadNoSuchFile, .fileReadCorruptFile, .fileReadUnknown:
                return "the selected file could not be read. it may be missing or damaged."
            case .fileWriteNoPermission, .fileWriteOutOfSpace, .fileWriteUnknown:
                return "the file could not be saved. choose a writable location and try again."
            default:
                return "macos could not complete the file operation. try again."
            }
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "macos could not complete the request. try again." : message
    }

    private static func demoLibrary(useLongContent: Bool) -> DockLibrary {
        func app(_ name: String, _ path: String, _ identifier: String) -> DockItem {
            DockItem(kind: .application(DockApp(bundleIdentifier: identifier, path: path, displayName: name)))
        }
        let work = DockProfile(name: "work", color: .blue, items: [
            app("Mail", "/System/Applications/Mail.app", "com.apple.mail"),
            app("Calendar", "/System/Applications/Calendar.app", "com.apple.iCal"),
            DockItem(kind: .spacer(.regular)),
            app("Notes", "/System/Applications/Notes.app", "com.apple.Notes"),
        ])
        let reading = DockProfile(name: useLongContent ? "Research, writing, and deep work" : "Reading", color: .green, items: [
            app(
                useLongContent ? "Research Companion Application" : "Books",
                useLongContent
                    ? "/Applications/Research Tools/Reference Library/Research Companion Application.app"
                    : "/System/Applications/Books.app",
                "com.apple.iBooksX"
            ),
            app("Notes", "/System/Applications/Notes.app", "com.apple.Notes"),
        ])
        let games = DockProfile(name: "games", color: .purple, items: [
            app("Games", "/System/Applications/Games.app", "com.apple.Games"),
            app("Steam", "/Applications/Steam.app", "com.valvesoftware.steam"),
        ])
        let personal = DockProfile(name: "personal", color: .orange, items: [
            app("Safari", "/Applications/Safari.app", "com.apple.Safari"),
            app("Music", "/System/Applications/Music.app", "com.apple.Music"),
        ])
        let travel = DockProfile(name: "travel", color: .pink, items: [
            app("Maps", "/System/Applications/Maps.app", "com.apple.Maps"),
            app("Reminders", "/System/Applications/Reminders.app", "com.apple.reminders"),
        ])
        return DockLibrary(
            profiles: [work, reading, games, personal, travel].map { DockProfileRecord(profile: $0) },
            selectedProfileID: reading.id,
            activeProfile: ActiveProfile(
                profileID: work.id, source: .manual,
                appliedLayout: DockLayout(profile: work)
            )
        )
    }

    private static var hasEmbeddedFocusExtension: Bool {
        let roots = [
            Bundle.main.bundleURL.appending(path: "Contents/Extensions", directoryHint: .isDirectory),
            Bundle.main.builtInPlugInsURL,
        ].compactMap { $0 }
        return roots.contains { root in
            let url = root.appending(path: "DockitFocusExtension.appex", directoryHint: .isDirectory)
            return Bundle(url: url)?.bundleIdentifier == "com.advegaf.dockit.focus"
        }
    }
}

private enum DemoActivationError: LocalizedError {
    case verificationFailed

    var errorDescription: String? {
        "the simulated dock did not match the requested profile. the previous dock remains active."
    }
}

final class DockProfileNameFormatter: Formatter {
    private let maximumLength: Int

    init(maximumLength: Int) {
        self.maximumLength = maximumLength
        super.init()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func string(for obj: Any?) -> String? {
        obj as? String
    }

    override func getObjectValue(
        _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
        for string: String,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        obj?.pointee = string as NSString
        return true
    }

    override func isPartialStringValid(
        _ partialString: String,
        newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        partialString.count <= maximumLength
    }
}
