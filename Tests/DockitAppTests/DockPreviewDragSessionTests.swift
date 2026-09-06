import DockitCore
import Foundation
import Testing
@testable import dockit

struct DockPreviewDragSessionTests {
    enum Placement: Sendable {
        case before(Int)
        case after(Int)
        case end

        func position(in items: [DockItem]) -> DockPreviewDragSession.Position {
            switch self {
            case let .before(index): .before(items[index].id)
            case let .after(index): .after(items[index].id)
            case .end: .end
            }
        }
    }

    struct MoveCase: Sendable {
        let selection: [Int]
        let placement: Placement
        let expected: [Int]
        let beforeIndex: Int?
    }

    @Test(arguments: [
        MoveCase(selection: [3], placement: .before(1), expected: [0, 3, 1, 2, 4], beforeIndex: 1),
        MoveCase(selection: [1], placement: .after(3), expected: [0, 2, 3, 1, 4], beforeIndex: 4),
        MoveCase(selection: [1], placement: .end, expected: [0, 2, 3, 4, 1], beforeIndex: nil),
        MoveCase(selection: [3, 1], placement: .before(0), expected: [1, 3, 0, 2, 4], beforeIndex: 0),
        MoveCase(selection: [1, 3], placement: .after(2), expected: [0, 2, 1, 3, 4], beforeIndex: 4),
        MoveCase(selection: [1, 3], placement: .end, expected: [0, 2, 4, 1, 3], beforeIndex: nil),
        MoveCase(selection: [1, 3], placement: .after(4), expected: [0, 2, 4, 1, 3], beforeIndex: nil)
    ])
    func hoverPreviewsAndAcceptsTheSameOrderedMove(_ move: MoveCase) throws {
        let profileID = UUID()
        let items = fixtures()
        var session = try #require(DockPreviewDragSession(
            profileID: profileID,
            items: items,
            selectedIDs: move.selection.map { items[$0].id }
        ))

        #expect(session.displayedItems == items)
        let proposalAccepted1 = session.updateProposal(move.placement.position(in: items), currentProfileID: profileID, currentItems: items)
        #expect(proposalAccepted1)
        let expected = move.expected.map { items[$0] }
        #expect(session.displayedItems == expected)
        #expect(session.originalItems == items)
        #expect(session.selectedIDs == move.selection.sorted().map { items[$0].id })

        let acceptedIntent = session.accept(currentProfileID: profileID, currentItems: items)
        let intent = try #require(acceptedIntent)
        #expect(intent.sourceProfileID == profileID)
        #expect(intent.expectedItems == items)
        #expect(intent.selectedIDs == session.selectedIDs)
        #expect(intent.beforeItemID == move.beforeIndex.map { items[$0].id })
        #expect(session.displayedItems == expected)
        #expect(DockItemEditing.moving(items, selectedIDs: Set(intent.selectedIDs), before: intent.beforeItemID) == expected)
    }

    @Test
    func reverseHoverAlwaysStartsFromTheImmutableLayout() throws {
        let profileID = UUID()
        let items = fixtures()
        var session = try #require(DockPreviewDragSession(profileID: profileID, items: items, selectedIDs: [items[1].id]))

        let proposalAccepted1 = session.updateProposal(.end, currentProfileID: profileID, currentItems: items)
        #expect(proposalAccepted1)
        #expect(session.displayedItems == [items[0], items[2], items[3], items[4], items[1]])
        let proposalAccepted2 = session.updateProposal(.before(items[0].id), currentProfileID: profileID, currentItems: items)
        #expect(proposalAccepted2)
        #expect(session.displayedItems == [items[1], items[0], items[2], items[3], items[4]])
        let proposalAccepted3 = session.updateProposal(.after(items[2].id), currentProfileID: profileID, currentItems: items)
        #expect(proposalAccepted3)
        #expect(session.displayedItems == [items[0], items[2], items[1], items[3], items[4]])
        #expect(session.originalItems == items)
    }

    @Test(arguments: [Placement.before(1), .after(1), .before(3), .after(3)])
    func hoveringSelectedTargetsRestoresTheOriginalOrder(_ placement: Placement) throws {
        let profileID = UUID()
        let items = fixtures()
        var session = try #require(DockPreviewDragSession(profileID: profileID, items: items, selectedIDs: [items[1].id, items[3].id]))
        let proposalAccepted1 = session.updateProposal(.end, currentProfileID: profileID, currentItems: items)
        #expect(proposalAccepted1)

        let proposalAccepted2 = session.updateProposal(placement.position(in: items), currentProfileID: profileID, currentItems: items)
        #expect(proposalAccepted2)
        #expect(session.displayedItems == items)
        let rejectedIntent1 = session.accept(currentProfileID: profileID, currentItems: items)
        #expect(rejectedIntent1 == nil)
        let proposalAccepted3 = session.updateProposal(.end, currentProfileID: profileID, currentItems: items)
        #expect(!proposalAccepted3)
        let rejectedIntent2 = session.accept(currentProfileID: profileID, currentItems: items)
        #expect(rejectedIntent2 == nil)
    }

    @Test
    func acceptingAnUnchangedGapDoesNotEmitAReorder() throws {
        let profileID = UUID()
        let items = fixtures()
        var session = try #require(DockPreviewDragSession(profileID: profileID, items: items, selectedIDs: [items[1].id, items[2].id]))

        let proposalAccepted1 = session.updateProposal(.after(items[0].id), currentProfileID: profileID, currentItems: items)
        #expect(proposalAccepted1)
        #expect(session.displayedItems == items)
        let rejectedIntent1 = session.accept(currentProfileID: profileID, currentItems: items)
        #expect(rejectedIntent1 == nil)
        #expect(session.displayedItems == items)
    }

    @Test
    func acceptingWithoutAHoverDoesNotEmitAReorder() throws {
        let profileID = UUID()
        let items = fixtures()
        var session = try #require(DockPreviewDragSession(profileID: profileID, items: items, selectedIDs: [items[1].id]))

        let rejectedIntent1 = session.accept(currentProfileID: profileID, currentItems: items)
        #expect(rejectedIntent1 == nil)
        #expect(session.displayedItems == items)
        let proposalAccepted1 = session.updateProposal(.end, currentProfileID: profileID, currentItems: items)
        #expect(!proposalAccepted1)
    }

    @Test
    func cancellationRestoresTheSnapshotAndCannotBeAccepted() throws {
        let profileID = UUID()
        let items = fixtures()
        var session = try #require(DockPreviewDragSession(profileID: profileID, items: items, selectedIDs: [items[1].id]))
        let proposalAccepted1 = session.updateProposal(.end, currentProfileID: profileID, currentItems: items)
        #expect(proposalAccepted1)

        session.cancel()

        #expect(session.phase == .cancelled)
        #expect(session.proposedPosition == nil)
        #expect(session.displayedItems == items)
        let rejectedIntent1 = session.accept(currentProfileID: profileID, currentItems: items)
        #expect(rejectedIntent1 == nil)
        let proposalAccepted2 = session.updateProposal(.before(items[0].id), currentProfileID: profileID, currentItems: items)
        #expect(!proposalAccepted2)
        session.cancel()
        #expect(session.phase == .cancelled)
    }

    @Test
    func acceptanceIsOneShotAndLaterEventsDoNotChangeTheAcceptedPreview() throws {
        let profileID = UUID()
        let items = fixtures()
        var session = try #require(DockPreviewDragSession(profileID: profileID, items: items, selectedIDs: [items[1].id]))
        let proposalAccepted1 = session.updateProposal(.end, currentProfileID: profileID, currentItems: items)
        #expect(proposalAccepted1)

        let acceptedIntent = session.accept(currentProfileID: profileID, currentItems: items)
        let intent = try #require(acceptedIntent)
        let acceptedItems = session.displayedItems
        let rejectedIntent1 = session.accept(currentProfileID: profileID, currentItems: items)
        #expect(rejectedIntent1 == nil)
        let proposalAccepted2 = session.updateProposal(.before(items[0].id), currentProfileID: profileID, currentItems: items)
        #expect(!proposalAccepted2)
        session.cancel()
        #expect(session.displayedItems == acceptedItems)
        #expect(intent.expectedItems == items)
        #expect(intent.beforeItemID == nil)
    }

    @Test
    func unknownHoverTargetClearsTheProposalButAllowsAnotherValidHover() throws {
        let profileID = UUID()
        let items = fixtures()
        var session = try #require(DockPreviewDragSession(profileID: profileID, items: items, selectedIDs: [items[1].id]))
        let proposalAccepted1 = session.updateProposal(.end, currentProfileID: profileID, currentItems: items)
        #expect(proposalAccepted1)

        let proposalAccepted2 = session.updateProposal(.before(UUID()), currentProfileID: profileID, currentItems: items)
        #expect(!proposalAccepted2)
        #expect(session.proposedPosition == nil)
        #expect(session.displayedItems == items)
        let proposalAccepted3 = session.updateProposal(.before(items[0].id), currentProfileID: profileID, currentItems: items)
        #expect(proposalAccepted3)
    }

    @Test
    func aDifferentProfileCancelsHoverEvenWhenItsItemsAreIdentical() throws {
        let profileID = UUID()
        let items = fixtures()
        var session = try #require(DockPreviewDragSession(profileID: profileID, items: items, selectedIDs: [items[1].id]))
        let proposalAccepted1 = session.updateProposal(.end, currentProfileID: profileID, currentItems: items)
        #expect(proposalAccepted1)

        let proposalAccepted2 = session.updateProposal(.before(items[0].id), currentProfileID: UUID(), currentItems: items)
        #expect(!proposalAccepted2)
        #expect(session.phase == .cancelled)
        #expect(session.displayedItems == items)
        let rejectedIntent1 = session.accept(currentProfileID: profileID, currentItems: items)
        #expect(rejectedIntent1 == nil)
    }

    @Test
    func aDifferentProfileRejectsAnOtherwiseValidAcceptance() throws {
        let profileID = UUID()
        let items = fixtures()
        var session = try #require(DockPreviewDragSession(profileID: profileID, items: items, selectedIDs: [items[1].id]))
        let proposalAccepted1 = session.updateProposal(.end, currentProfileID: profileID, currentItems: items)
        #expect(proposalAccepted1)

        let rejectedIntent1 = session.accept(currentProfileID: UUID(), currentItems: items)
        #expect(rejectedIntent1 == nil)
        #expect(session.phase == .cancelled)
        #expect(session.displayedItems == items)
    }

    @Test(arguments: [false, true])
    func itemEditsWithTheSameIDsRejectHoverAndAcceptance(_ rejectOnHover: Bool) throws {
        let profileID = UUID()
        let items = fixtures()
        var changedItems = items
        changedItems[0].kind = .spacer(.small)
        var session = try #require(DockPreviewDragSession(profileID: profileID, items: items, selectedIDs: [items[1].id]))
        let proposalAccepted1 = session.updateProposal(.end, currentProfileID: profileID, currentItems: items)
        #expect(proposalAccepted1)

        if rejectOnHover {
            let proposalAccepted2 = session.updateProposal(.before(items[0].id), currentProfileID: profileID, currentItems: changedItems)
            #expect(!proposalAccepted2)
        } else {
            let rejectedIntent1 = session.accept(currentProfileID: profileID, currentItems: changedItems)
            #expect(rejectedIntent1 == nil)
        }
        #expect(session.phase == .cancelled)
        #expect(session.displayedItems == items)
    }

    @Test
    func reorderedAndRemovedSourceItemsRejectAcceptance() throws {
        let profileID = UUID()
        let items = fixtures()
        for changedItems in [Array(items.reversed()), Array(items.dropLast())] {
            var session = try #require(DockPreviewDragSession(profileID: profileID, items: items, selectedIDs: [items[1].id]))
            let proposalAccepted1 = session.updateProposal(.end, currentProfileID: profileID, currentItems: items)
            #expect(proposalAccepted1)
            let rejectedIntent1 = session.accept(currentProfileID: profileID, currentItems: changedItems)
            #expect(rejectedIntent1 == nil)
            #expect(session.phase == .cancelled)
        }
    }

    @Test
    func malformedSelectionsAndDuplicateSourceIDsCannotStartASession() {
        let profileID = UUID()
        let items = fixtures()

        #expect(DockPreviewDragSession(profileID: profileID, items: items, selectedIDs: []) == nil)
        #expect(DockPreviewDragSession(profileID: profileID, items: [], selectedIDs: [UUID()]) == nil)
        #expect(DockPreviewDragSession(profileID: profileID, items: items, selectedIDs: [UUID()]) == nil)
        #expect(DockPreviewDragSession(profileID: profileID, items: items, selectedIDs: [items[0].id, items[0].id]) == nil)
        #expect(DockPreviewDragSession(profileID: profileID, items: items + [items[0]], selectedIDs: [items[1].id]) == nil)
    }

    private func fixtures() -> [DockItem] {
        (0..<5).map { _ in DockItem(kind: .spacer(.regular)) }
    }
}
