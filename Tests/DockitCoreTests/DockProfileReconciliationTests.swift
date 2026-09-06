import XCTest
@testable import DockitCore

final class DockProfileReconciliationTests: XCTestCase {
    func testExternalEditKeepsUnavailableEntriesAtSavedPositions() {
        let first = missing("first")
        let second = missing("second")
        let previous = DockItem(kind: .spacer(.regular))
        let saved = DockProfileRecord(profile: DockProfile(name: "My Dock", color: .purple, items: [first, previous, second]))
        let newItem = DockItem(kind: .spacer(.small))
        let capture = CapturedDockProfile(
            profile: DockProfile(name: "ignored", color: .blue, items: [newItem, previous]),
            localState: DockProfileLocalState()
        )
        let result = saved.reconciling(capture, retaining: [first.id, second.id])
        XCTAssertEqual(result.profile.items, [first, newItem, second, previous])
        XCTAssertEqual(result.profile.id, saved.id)
        XCTAssertEqual(result.profile.name, "My Dock")
        XCTAssertEqual(result.profile.color, .purple)
        XCTAssertEqual(result.profile.createdAt, saved.profile.createdAt)
        XCTAssertEqual(result.profile.items.filter { $0.id != first.id && $0.id != second.id }, capture.profile.items)
    }

    func testEmptyLiveDockRetainsOnlyUnavailableApps() {
        let unavailable = missing("app")
        let saved = DockProfileRecord(profile: DockProfile(name: "work", color: .blue, items: [DockItem(kind: .spacer(.regular)), unavailable]))
        let capture = CapturedDockProfile(profile: DockProfile(name: "work", color: .blue, items: []), localState: DockProfileLocalState())
        XCTAssertEqual(saved.reconciling(capture, retaining: [unavailable.id]).profile.items, [unavailable])
    }

    func testObservedUnavailableAppIsNotDuplicated() {
        let unavailable = missing("app")
        let saved = DockProfileRecord(profile: DockProfile(name: "work", color: .blue, items: [unavailable]))
        let observed = DockItem(kind: unavailable.kind)
        let capture = CapturedDockProfile(profile: DockProfile(name: "work", color: .blue, items: [observed]), localState: DockProfileLocalState())
        XCTAssertEqual(saved.reconciling(capture, retaining: [unavailable.id]).profile.items, [observed])
    }

    private func missing(_ name: String) -> DockItem {
        DockItem(kind: .application(DockApp(bundleIdentifier: "test.\(name)", path: "/missing/\(name).app", displayName: name)))
    }
}
