import Foundation

public actor DockChangeMonitor {
    private let preferences: any DockPreferencesServing
    private var task: Task<Void, Never>?
    private var suppressedSnapshot: DockSnapshot?

    public init(preferences: any DockPreferencesServing = DockPreferencesClient()) {
        self.preferences = preferences
    }

    deinit {
        task?.cancel()
    }

    public func suppress(_ snapshot: DockSnapshot?) {
        suppressedSnapshot = snapshot
    }

    public func start(
        interval: Duration = .seconds(1),
        initialSnapshot: DockSnapshot? = nil,
        onChange: @escaping @Sendable (DockSnapshot) async -> Bool
    ) {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            var previous = initialSnapshot
            if previous == nil {
                previous = try? await preferences.readPersistentApps()
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let current = try? await preferences.readPersistentApps() else { continue }
                if let previous, current.hasSameLayout(as: previous) { continue }
                if await self.isSuppressed(current) {
                    previous = current
                    continue
                }
                if await onChange(current) {
                    previous = current
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func isSuppressed(_ snapshot: DockSnapshot) -> Bool {
        guard let suppressedSnapshot else { return false }
        self.suppressedSnapshot = nil
        if snapshot.hasSameLayout(as: suppressedSnapshot) {
            return true
        }
        return false
    }
}
