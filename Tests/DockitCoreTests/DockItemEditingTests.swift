import XCTest
@testable import DockitCore

final class DockItemEditingTests: XCTestCase {
    private func fixtures(_ count: Int = 5) -> [DockItem] {
        (0..<count).map { _ in DockItem(kind: .spacer(.regular)) }
    }

    func testKeyboardMovesAdjacentSelectionAsBlock() {
        let items = fixtures()
        let result = DockItemEditing.moving(items, selectedIDs: [items[1].id, items[2].id], by: 1)
        XCTAssertEqual(result, [items[0], items[3], items[1], items[2], items[4]])
        XCTAssertEqual(DockItemEditing.moving(result, selectedIDs: [items[1].id, items[2].id], by: -1), items)
    }

    func testKeyboardMovesDisjointSelectionWithoutChangingOrder() {
        let items = fixtures()
        XCTAssertEqual(
            DockItemEditing.moving(items, selectedIDs: [items[1].id, items[3].id], by: -1),
            [items[1], items[0], items[3], items[2], items[4]]
        )
    }

    func testKeyboardMovesDisjointSelectionEarlierWhenFirstItemIsSelected() {
        let items = fixtures()
        XCTAssertEqual(
            DockItemEditing.moving(items, selectedIDs: [items[0].id, items[2].id], by: -1),
            [items[0], items[2], items[1], items[3], items[4]]
        )
    }

    func testKeyboardMovesDisjointSelectionLaterWhenLastItemIsSelected() {
        let items = fixtures()
        XCTAssertEqual(
            DockItemEditing.moving(items, selectedIDs: [items[2].id, items[4].id], by: 1),
            [items[0], items[1], items[3], items[2], items[4]]
        )
    }

    func testKeyboardMovePreservesSelectedItemsInSavedOrder() {
        let items = fixtures()
        let selectedIDs = Set([items[3].id, items[1].id])
        let result = DockItemEditing.moving(items, selectedIDs: selectedIDs, by: 1)
        XCTAssertEqual(result, [items[0], items[2], items[1], items[4], items[3]])
        XCTAssertEqual(result.filter { selectedIDs.contains($0.id) }, [items[1], items[3]])
    }

    func testKeyboardHandlesBoundariesAndExtremeOffset() {
        let items = fixtures()
        XCTAssertEqual(DockItemEditing.moving(items, selectedIDs: Set(items.map(\.id)), by: -1), items)
        XCTAssertEqual(DockItemEditing.moving(items, selectedIDs: Set(items.map(\.id)), by: 1), items)
        XCTAssertEqual(DockItemEditing.moving(items, selectedIDs: [items[0].id], by: Int.min), items)
        XCTAssertEqual(DockItemEditing.moving(items, selectedIDs: [items[0].id], by: -1), items)
        XCTAssertEqual(DockItemEditing.moving(items, selectedIDs: [items[4].id], by: 1), items)
        XCTAssertEqual(DockItemEditing.moving([], selectedIDs: [], by: 1), [])
    }

    func testDragGathersSelectionInSavedOrder() {
        let items = fixtures()
        XCTAssertEqual(
            DockItemEditing.moving(items, selectedIDs: [items[3].id, items[1].id], before: items[0].id),
            [items[1], items[3], items[0], items[2], items[4]]
        )
        XCTAssertEqual(
            DockItemEditing.moving(items, selectedIDs: [items[1].id, items[2].id], before: nil),
            [items[0], items[3], items[4], items[1], items[2]]
        )
    }

    func testInvalidAndSelfDropsDoNotMutate() {
        let items = fixtures()
        XCTAssertEqual(DockItemEditing.moving(items, selectedIDs: [items[1].id], before: items[1].id), items)
        XCTAssertEqual(DockItemEditing.moving(items, selectedIDs: [items[1].id], before: UUID()), items)
        XCTAssertEqual(DockItemEditing.moving(items, selectedIDs: [UUID()], before: nil), items)
    }
}
