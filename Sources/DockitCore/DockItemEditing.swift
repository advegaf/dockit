import Foundation

public enum DockItemEditing {
    public static func moving(_ items: [DockItem], selectedIDs: Set<UUID>, by offset: Int) -> [DockItem] {
        guard !items.isEmpty, offset != 0 else { return items }
        var result = items
        for _ in 0..<min(offset.magnitude, UInt(items.count)) {
            if offset < 0 {
                for index in result.indices.dropFirst() where selectedIDs.contains(result[index].id) {
                    if !selectedIDs.contains(result[index - 1].id) {
                        result.swapAt(index, index - 1)
                    }
                }
            } else {
                for index in result.indices.dropLast().reversed() where selectedIDs.contains(result[index].id) {
                    if !selectedIDs.contains(result[index + 1].id) {
                        result.swapAt(index, index + 1)
                    }
                }
            }
        }
        return result
    }

    public static func moving(_ items: [DockItem], selectedIDs: Set<UUID>, before targetID: UUID?) -> [DockItem] {
        if let targetID, selectedIDs.contains(targetID) { return items }
        let moving = items.filter { selectedIDs.contains($0.id) }
        guard !moving.isEmpty else { return items }
        var remaining = items.filter { !selectedIDs.contains($0.id) }
        let insertion: Int
        if let targetID {
            guard let index = remaining.firstIndex(where: { $0.id == targetID }) else { return items }
            insertion = index
        } else {
            insertion = remaining.endIndex
        }
        remaining.insert(contentsOf: moving, at: insertion)
        return remaining
    }
}
