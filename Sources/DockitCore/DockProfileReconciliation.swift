import Foundation

extension DockProfileRecord {
    public func reconciling(
        _ captured: CapturedDockProfile,
        retaining unavailableIDs: Set<UUID>
    ) -> DockProfileRecord {
        var result = self
        result.profile.items = captured.profile.items
        result.profile.updatedAt = captured.profile.updatedAt
        result.localState = captured.localState
        let visiblePaths = Set(captured.profile.items.compactMap { item -> String? in
            guard case let .application(app) = item.kind else { return nil }
            return app.path
        })
        for (index, item) in profile.items.enumerated() where unavailableIDs.contains(item.id) {
            guard case let .application(app) = item.kind, !visiblePaths.contains(app.path) else { continue }
            result.profile.items.insert(item, at: min(index, result.profile.items.count))
            result.localState.rawTiles[item.id] = localState.rawTiles[item.id]
        }
        return result
    }
}
