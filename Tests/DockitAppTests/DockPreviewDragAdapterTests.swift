import AppKit
import CoreGraphics
import DockitCore
import Foundation
import Testing
@testable import dockit

struct DockPreviewDragAdapterTests {
    @Test @MainActor
    func nativeDragEndClearsSessionAndCallsOriginalCompletionOnce() throws {
        let view = NativeDockDragView(frame: .zero)
        let drag = NativeDockDrag(id: UUID(), profileID: UUID(), items: fixtures())
        var originalEnds: [UUID] = []
        var replacementEnds: [UUID] = []
        view.begin = { drag }
        view.ended = { originalEnds.append($0) }

        #expect(view.prepareDrag()?.id == drag.id)
        #expect(view.prepareDrag() == nil)
        view.ended = { replacementEnds.append($0) }
        view.finishDrag()
        view.finishDrag()

        #expect(originalEnds == [drag.id])
        #expect(replacementEnds.isEmpty)
        #expect(view.prepareDrag()?.id == drag.id)
        view.finishDrag()
        #expect(replacementEnds == [drag.id])
    }

    @Test @MainActor
    func disabledOrRejectedNativeDragNeverStartsASession() {
        let view = NativeDockDragView(frame: .zero)
        var begins = 0
        var ends = 0
        view.begin = { begins += 1; return nil }
        view.ended = { _ in ends += 1 }
        view.isEnabled = false

        #expect(view.prepareDrag() == nil)
        #expect(begins == 0)
        view.isEnabled = true
        #expect(view.prepareDrag() == nil)
        #expect(begins == 1)
        view.finishDrag()
        #expect(ends == 0)
    }

    @Test
    func nativeGroupedDragRetainsEveryItemInSavedOrder() throws {
        let profileID = UUID()
        let items = fixtures()
        let selected = [items[0], items[2]]
        let drag = NativeDockDrag(id: UUID(), profileID: profileID, items: selected)
        let payload = try #require(DockPreviewDragPayload(tokens: drag.tokens))
        #expect(payload.profileID == profileID)
        #expect(payload.itemIDs == selected.map(\.id))
    }

    enum PayloadFault: CaseIterable, Sendable {
        case emptyArray, emptyToken, wrongPrefix, legacyPrefix
        case missingProfile, missingItem, extraField, leadingSeparator, trailingSeparator
        case invalidProfile, invalidItem, emptyProfile, emptyItem, whitespacePrefix, invalidCompanion

        func tokens(profileID: UUID, itemID: UUID) -> [String] {
            let profile = profileID.uuidString
            let item = itemID.uuidString
            let valid = "dockit-item:\(profile):\(item)"
            return switch self {
            case .emptyArray: []
            case .emptyToken: [""]
            case .wrongPrefix: ["other-item:\(profile):\(item)"]
            case .legacyPrefix: ["dockit-items:\(profile):\(item)"]
            case .missingProfile: ["dockit-item:\(item)"]
            case .missingItem: ["dockit-item:\(profile)"]
            case .extraField: ["\(valid):extra"]
            case .leadingSeparator: [":\(valid)"]
            case .trailingSeparator: ["\(valid):"]
            case .invalidProfile: ["dockit-item:not-a-uuid:\(item)"]
            case .invalidItem: ["dockit-item:\(profile):not-a-uuid"]
            case .emptyProfile: ["dockit-item::\(item)"]
            case .emptyItem: ["dockit-item:\(profile):"]
            case .whitespacePrefix: [" \(valid)"]
            case .invalidCompanion: [valid, "not-a-token"]
            }
        }
    }

    enum GeometryFault: CaseIterable, Sendable {
        case nanX, positiveInfiniteX, negativeInfiniteX
        case nanY, positiveInfiniteY, negativeInfiniteY
        case zeroWidth, negativeWidth, nanWidth, positiveInfiniteWidth, negativeInfiniteWidth

        var geometry: (location: CGPoint, size: CGSize) {
            var location = CGPoint(x: 13, y: 25)
            var size = CGSize(width: 26, height: 50)
            switch self {
            case .nanX: location.x = .nan
            case .positiveInfiniteX: location.x = .infinity
            case .negativeInfiniteX: location.x = -.infinity
            case .nanY: location.y = .nan
            case .positiveInfiniteY: location.y = .infinity
            case .negativeInfiniteY: location.y = -.infinity
            case .zeroWidth: size.width = 0
            case .negativeWidth: size.width = -26
            case .nanWidth: size.width = .nan
            case .positiveInfiniteWidth: size.width = .infinity
            case .negativeInfiniteWidth: size.width = -.infinity
            }
            return (location, size)
        }
    }

    @Test
    func itemTokensRoundTripWithoutChangingTheirOrder() throws {
        let profileID = UUID()
        let ids = [UUID(), UUID()]
        let tokens = ids.map { DockPreviewDragPayload.token(profileID: profileID, itemID: $0) }

        #expect(tokens == ids.map { "dockit-item:\(profileID.uuidString):\($0.uuidString)" })
        let payload = try #require(DockPreviewDragPayload(tokens: tokens))
        #expect(payload.profileID == profileID)
        #expect(payload.itemIDs == ids)
    }

    @Test(arguments: PayloadFault.allCases)
    func malformedTokensCannotBecomeAPayload(_ fault: PayloadFault) {
        let tokens = fault.tokens(profileID: UUID(), itemID: UUID())

        #expect(DockPreviewDragPayload(tokens: tokens) == nil)
    }

    @Test
    func tokensFromDifferentProfilesCannotBeCombined() {
        let tokens = [UUID(), UUID()].map {
            DockPreviewDragPayload.token(profileID: $0, itemID: UUID())
        }

        #expect(DockPreviewDragPayload(tokens: tokens) == nil)
    }

    @Test
    func duplicateItemIDsAreRejectedRegardlessOfUUIDLetterCase() {
        let profileID = UUID()
        let itemID = UUID()
        let token = DockPreviewDragPayload.token(profileID: profileID, itemID: itemID)

        #expect(DockPreviewDragPayload(tokens: [token, token]) == nil)
        #expect(DockPreviewDragPayload(tokens: [token, token.lowercased()]) == nil)
    }

    @Test
    func nativeItemOrderDoesNotChangeSelectionMatching() throws {
        let profileID = UUID()
        let items = fixtures()
        let selectedIDs = [items[0].id, items[2].id]
        let session = try #require(DockPreviewDragSession(
            profileID: profileID, items: items, selectedIDs: selectedIDs
        ))
        let tokens = selectedIDs.reversed().map {
            DockPreviewDragPayload.token(profileID: profileID, itemID: $0)
        }
        let payload = try #require(DockPreviewDragPayload(tokens: tokens))

        #expect(payload.itemIDs == Array(selectedIDs.reversed()))
        #expect(payload.matches(session))
    }

    @Test
    func matchingItemIDsFromAnotherProfileDoNotMatchTheSession() throws {
        let items = fixtures()
        let session = try #require(DockPreviewDragSession(
            profileID: UUID(), items: items, selectedIDs: [items[0].id]
        ))
        let payload = try #require(DockPreviewDragPayload(tokens: [
            DockPreviewDragPayload.token(profileID: UUID(), itemID: items[0].id)
        ]))

        #expect(!payload.matches(session))
    }

    @Test(arguments: [[0], [0, 1, 2], [0, 2]])
    func subsetsSupersetsAndDifferentSelectionsDoNotMatch(_ indices: [Int]) throws {
        let profileID = UUID()
        let items = fixtures()
        let session = try #require(DockPreviewDragSession(
            profileID: profileID, items: items, selectedIDs: [items[0].id, items[1].id]
        ))
        let tokens = indices.map {
            DockPreviewDragPayload.token(profileID: profileID, itemID: items[$0].id)
        }
        let payload = try #require(DockPreviewDragPayload(tokens: tokens))

        #expect(!payload.matches(session))
    }

    @Test(arguments: [CGFloat(52), CGFloat(26)])
    func eachSlotUsesItsOwnMidpointAndEqualityMeansBefore(_ width: CGFloat) throws {
        let items = fixtures()
        let session = try #require(DockPreviewDragSession(
            profileID: UUID(), items: items, selectedIDs: [items[1].id]
        ))
        let target = DockPreviewDropTarget.item(items[0].id)
        let size = CGSize(width: width, height: 50)
        let midpoint = width / 2

        #expect(target.position(at: CGPoint(x: 0, y: 25), in: size, session: session) == .before(items[0].id))
        #expect(target.position(at: CGPoint(x: midpoint, y: 25), in: size, session: session) == .before(items[0].id))
        #expect(target.position(at: CGPoint(x: midpoint.nextUp, y: 25), in: size, session: session) == .after(items[0].id))
        #expect(target.position(at: CGPoint(x: width, y: 25), in: size, session: session) == .after(items[0].id))
    }

    @Test(arguments: GeometryFault.allCases)
    func invalidGeometryDoesNotProduceAnItemProposal(_ fault: GeometryFault) throws {
        let items = fixtures()
        let session = try #require(DockPreviewDragSession(
            profileID: UUID(), items: items, selectedIDs: [items[1].id]
        ))
        let geometry = fault.geometry
        let position = DockPreviewDropTarget.item(items[0].id).position(
            at: geometry.location, in: geometry.size, session: session
        )

        #expect(position == nil)
    }

    @Test(arguments: [1, 2], [CGFloat(52), CGFloat(26)])
    func selectedCellsDoNotResetAnExistingProposal(_ index: Int, _ width: CGFloat) throws {
        let profileID = UUID()
        let items = fixtures()
        var session = try #require(DockPreviewDragSession(
            profileID: profileID, items: items, selectedIDs: [items[1].id, items[2].id]
        ))
        let didUpdate = session.updateProposal(.end, currentProfileID: profileID, currentItems: items)
        #expect(didUpdate)
        let proposedSession = session
        let position = DockPreviewDropTarget.item(items[index].id).position(
            at: CGPoint(x: width, y: 25), in: CGSize(width: width, height: 50), session: session
        )

        #expect(position == nil)
        if let position {
            session.updateProposal(position, currentProfileID: profileID, currentItems: items)
        }
        #expect(session == proposedSession)
        #expect(session.displayedItems == [items[0], items[3], items[1], items[2]])
    }

    @Test
    func unknownItemsDoNotProduceAProposal() throws {
        let items = fixtures()
        let session = try #require(DockPreviewDragSession(
            profileID: UUID(), items: items, selectedIDs: [items[1].id]
        ))
        let position = DockPreviewDropTarget.item(UUID()).position(
            at: CGPoint(x: 40, y: 25), in: CGSize(width: 52, height: 50), session: session
        )

        #expect(position == nil)
    }

    @Test
    func theTrailingTargetDoesNotNeedAnItemMidpoint() throws {
        let items = fixtures()
        let session = try #require(DockPreviewDragSession(
            profileID: UUID(), items: items, selectedIDs: [items[1].id]
        ))
        let position = DockPreviewDropTarget.end.position(at: .zero, in: .zero, session: session)

        #expect(position == .end)
    }

    private func fixtures() -> [DockItem] {
        [SpacerSize.regular, .regular, .small, .small].map { DockItem(kind: .spacer($0)) }
    }
}
