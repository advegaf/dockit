import DockitCore
import Foundation

struct DockPreviewDragSession: Equatable, Sendable {
    enum Position: Equatable, Sendable {
        case before(UUID)
        case after(UUID)
        case end
    }

    enum Phase: Equatable, Sendable {
        case active(Position?)
        case cancelled
        case accepted(Position?)
    }

    struct ReorderIntent: Equatable, Sendable {
        let sourceProfileID: UUID
        let expectedItems: [DockItem]
        let selectedIDs: [UUID]
        let beforeItemID: UUID?
    }

    let sourceProfileID: UUID
    let originalItems: [DockItem]
    let selectedIDs: [UUID]
    private(set) var phase: Phase = .active(nil)

    init?(profileID: UUID, items: [DockItem], selectedIDs: [UUID]) {
        let itemIDs = Set(items.map(\.id))
        let selection = Set(selectedIDs)
        guard itemIDs.count == items.count,
              !selection.isEmpty,
              selection.count == selectedIDs.count,
              selection.isSubset(of: itemIDs) else { return nil }
        sourceProfileID = profileID
        originalItems = items
        self.selectedIDs = items.filter { selection.contains($0.id) }.map(\.id)
    }

    var proposedPosition: Position? {
        switch phase {
        case let .active(position), let .accepted(position):
            position
        case .cancelled:
            nil
        }
    }

    var displayedItems: [DockItem] {
        guard let intent = proposedReorder else { return originalItems }
        return DockItemEditing.moving(
            originalItems,
            selectedIDs: Set(selectedIDs),
            before: intent.beforeItemID
        )
    }

    @discardableResult
    mutating func updateProposal(
        _ position: Position,
        currentProfileID: UUID,
        currentItems: [DockItem]
    ) -> Bool {
        guard case .active = phase else { return false }
        guard currentProfileID == sourceProfileID, currentItems == originalItems else {
            phase = .cancelled
            return false
        }
        switch position {
        case let .before(id), let .after(id):
            guard originalItems.contains(where: { $0.id == id }) else {
                phase = .active(nil)
                return false
            }
        case .end:
            break
        }
        phase = .active(position)
        return true
    }

    mutating func cancel() {
        guard case .active = phase else { return }
        phase = .cancelled
    }

    mutating func accept(
        currentProfileID: UUID,
        currentItems: [DockItem]
    ) -> ReorderIntent? {
        guard case .active = phase else { return nil }
        guard currentProfileID == sourceProfileID, currentItems == originalItems else {
            phase = .cancelled
            return nil
        }
        let intent = displayedItems == originalItems ? nil : proposedReorder
        phase = .accepted(proposedPosition)
        return intent
    }

    private var proposedReorder: ReorderIntent? {
        guard let position = proposedPosition else { return nil }
        let beforeItemID: UUID?
        switch position {
        case let .before(id):
            guard !selectedIDs.contains(id) else { return nil }
            beforeItemID = id
        case let .after(id):
            guard !selectedIDs.contains(id) else { return nil }
            beforeItemID = originalItems.drop { $0.id != id }.dropFirst()
                .first { !selectedIDs.contains($0.id) }?.id
        case .end:
            beforeItemID = nil
        }
        return ReorderIntent(
            sourceProfileID: sourceProfileID,
            expectedItems: originalItems,
            selectedIDs: selectedIDs,
            beforeItemID: beforeItemID
        )
    }
}
