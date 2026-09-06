import AppKit
import DockitCore
import SwiftUI

struct DockPreviewView: View {
    let model: AppModel
    let profile: DockProfile

    private struct DragState: Equatable {
        let id: UUID
        var preview: DockPreviewDragSession
    }

    @State private var dragState: DragState?
    @FocusState private var focusedItemID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if profile.items.isEmpty {
                VStack(spacing: 6) {
                    Text("no pinned apps or spacers")
                        .foregroundStyle(.secondary)
                    Button("add apps...") {
                        Task { await model.addApps() }
                    }
                    .disabled(model.profileActionsDisabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(contentTransition)
            } else {
                ScrollViewReader { reader in
                    GeometryReader { geometry in
                        ScrollView(.horizontal) {
                            HStack(spacing: 4) {
                                ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
                                    previewItem(item, at: index)
                                        .id(item.id)
                                        .transition(itemTransition)
                                }
                            }
                            .padding(8)
                            .background {
                                ZStack {
                                    if reduceTransparency {
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(Color(nsColor: .controlBackgroundColor))
                                    } else {
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(.regularMaterial)
                                    }
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(.black.opacity(colorScheme == .dark ? 0.18 : 0.08))
                                }
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(.primary.opacity(contrast == .increased ? 0.6 : 0.1), lineWidth: 1)
                                    .allowsHitTesting(false)
                            }
                            .overlay(alignment: .trailing) {
                                nativeDragSurface(item: nil, target: .end)
                                    .frame(width: 8, height: 68)
                                    .accessibilityHidden(true)
                            }
                            .padding(.horizontal, 12)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                        }
                        .scrollIndicators(.visible)
                        .onChange(of: focusedItemID) { _, id in
                            if let id { reader.scrollTo(id, anchor: .center) }
                        }
                    }
                }
                .transition(contentTransition)
            }
        }
        .animation(
            reduceMotion ? nil : .spring(duration: 0.24, bounce: 0),
            value: Set(profile.items.map(\.id))
        )
        .frame(minHeight: 88)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            } else {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.primary.opacity(contrast == .increased ? 0.5 : 0.05), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("dock preview")
        .accessibilityIdentifier("dock-preview")
        .onChange(of: profile.id) { _, _ in discardDrag() }
        .onChange(of: profile.items) { _, _ in invalidateStaleDrag() }
        .onChange(of: model.selectedProfileID) { _, _ in invalidateStaleDrag() }
        .onChange(of: model.profileActionsDisabled) { _, disabled in
            if disabled, let dragState, case .active = dragState.preview.phase { discardDrag() }
        }
        .onDisappear { discardDrag() }
        .onKeyPress(keys: [.leftArrow], phases: .down) { event in handleArrow(-1, modifiers: event.modifiers) }
        .onKeyPress(keys: [.rightArrow], phases: .down) { event in handleArrow(1, modifiers: event.modifiers) }
        .onKeyPress(keys: ["a"], phases: .down) { event in
            guard event.modifiers.contains(.command), !model.profileActionsDisabled else { return .ignored }
            discardDrag()
            model.selectedItemIDs = Set(profile.items.map(\.id))
            return .handled
        }
        .onKeyPress(keys: [.space], phases: .down) { event in
            guard event.modifiers.contains(.option), !model.profileActionsDisabled,
                  let focusedItemID else { return .ignored }
            discardDrag()
            model.selectItem(focusedItemID, toggling: true)
            return .handled
        }
        .onDeleteCommand {
            guard !model.profileActionsDisabled else { return }
            discardDrag()
            Task { await model.removeSelectedItems() }
        }
    }

    private var contentTransition: AnyTransition {
        if reduceMotion {
            .opacity.animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.12))
        } else {
            .opacity
        }
    }

    private var itemTransition: AnyTransition {
        reduceMotion ? contentTransition : .opacity.combined(with: .scale(scale: 0.95))
    }

    private var displayedItems: [DockItem] {
        guard let dragState, dragState.preview.sourceProfileID == profile.id else { return profile.items }
        switch dragState.preview.phase {
        case .active where sourceIsCurrent(dragState.preview):
            return dragState.preview.displayedItems
        case .accepted:
            return dragState.preview.displayedItems
        default:
            return profile.items
        }
    }

    private var canBeginDrag: Bool {
        guard !model.profileActionsDisabled else { return false }
        if let dragState, case .accepted = dragState.preview.phase { return false }
        return true
    }

    private func select(_ id: UUID) {
        discardDrag()
        focusedItemID = id
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        model.selectItem(id, extendingRange: modifiers.contains(.shift), toggling: modifiers.contains(.command))
    }

    private func previewItem(_ item: DockItem, at index: Int) -> some View {
        DockPreviewItemView(
            item: item,
            position: index + 1,
            count: profile.items.count,
            isSelected: model.selectedItemIDs.contains(item.id),
            isEditable: canBeginDrag,
            focus: $focusedItemID,
            select: { select(item.id) },
            toggleSelection: {
                discardDrag()
                model.selectItem(item.id, toggling: true)
            }
        )
        .overlay {
            nativeDragSurface(item: item, target: .item(item.id))
        }
    }

    private func nativeDragSurface(item: DockItem?, target: DockPreviewDropTarget) -> NativeDockDragSurface {
        NativeDockDragSurface(
            isEnabled: canBeginDrag,
            select: { if let item { select(item.id) } },
            begin: { if let item { beginDrag(item.id) } else { nil } },
            ended: { id in
                if dragState?.id == id { cancelActiveDrag(animated: true) }
            },
            update: { tokens, location, size in
                updateDrop(tokens, location: location, size: size, target: target)
            },
            accept: { tokens, location, size in
                acceptDrop(tokens, location: location, size: size, target: target)
            }
        )
    }

    private func sourceIsCurrent(_ preview: DockPreviewDragSession) -> Bool {
        preview.sourceProfileID == profile.id
            && model.selectedProfileID == preview.sourceProfileID
            && profile.items == preview.originalItems
            && model.selectedRecord?.profile.items == preview.originalItems
    }

    private func beginDrag(_ itemID: UUID) -> NativeDockDrag? {
        guard canBeginDrag else { return nil }
        let selected = model.selectedItemIDs.contains(itemID) ? model.selectedItemIDs : [itemID]
        let items = profile.items.filter { selected.contains($0.id) }
        guard let preview = DockPreviewDragSession(
            profileID: profile.id, items: profile.items, selectedIDs: items.map(\.id)
        ), sourceIsCurrent(preview) else { return nil }
        focusedItemID = itemID
        model.selectedItemIDs = selected
        let id = UUID()
        dragState = DragState(id: id, preview: preview)
        return NativeDockDrag(id: id, profileID: profile.id, items: items)
    }

    private func validLocalDrag(_ tokens: [String]) -> DragState? {
        guard canBeginDrag, let state = dragState,
              case .active = state.preview.phase,
              sourceIsCurrent(state.preview),
              let payload = DockPreviewDragPayload(tokens: tokens),
              payload.matches(state.preview) else { return nil }
        return state
    }

    private func updateDrop(_ tokens: [String], location: CGPoint, size: CGSize, target: DockPreviewDropTarget) -> Bool {
        guard var state = validLocalDrag(tokens) else { return false }
        if let position = target.position(at: location, in: size, session: state.preview),
           position != state.preview.proposedPosition,
           state.preview.updateProposal(position, currentProfileID: profile.id, currentItems: profile.items) {
            updatePresentation(state, animated: true)
        }
        return true
    }

    private func acceptDrop(_ values: [String], location: CGPoint, size: CGSize, target: DockPreviewDropTarget) -> Bool {
        guard var state = validLocalDrag(values) else {
            invalidateStaleDrag()
            return false
        }
        if let position = target.position(at: location, in: size, session: state.preview) {
            state.preview.updateProposal(position, currentProfileID: profile.id, currentItems: profile.items)
        }
        guard let intent = state.preview.accept(currentProfileID: profile.id, currentItems: profile.items) else {
            discardDrag()
            return false
        }
        let acceptedID = state.id
        updatePresentation(state, animated: true)
        Task {
            await model.moveItems(
                intent.selectedIDs,
                before: intent.beforeItemID,
                sourceProfileID: intent.sourceProfileID,
                expectedItems: intent.expectedItems
            )
            if dragState?.id == acceptedID { discardDrag() }
        }
        return true
    }

    private func invalidateStaleDrag() {
        guard let dragState else { return }
        if dragState.preview.sourceProfileID != profile.id
            || model.selectedProfileID != dragState.preview.sourceProfileID {
            discardDrag()
        } else if case .active = dragState.preview.phase, !sourceIsCurrent(dragState.preview) {
            discardDrag()
        }
    }

    private func cancelActiveDrag(animated: Bool) {
        guard let dragState, case .active = dragState.preview.phase else { return }
        updatePresentation(nil, animated: animated)
    }

    private func discardDrag() {
        updatePresentation(nil, animated: false)
    }

    private func updatePresentation(_ state: DragState?, animated: Bool) {
        guard dragState != state else { return }
        if animated, !reduceMotion {
            withAnimation(.spring(duration: 0.24, bounce: 0)) { dragState = state }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { dragState = state }
        }
    }

    private func handleArrow(_ direction: Int, modifiers: EventModifiers) -> KeyPress.Result {
        guard !model.profileActionsDisabled else { return .ignored }
        discardDrag()
        if modifiers.contains(.command), modifiers.contains(.option) {
            Task { await model.moveSelectedItems(by: direction) }
            return .handled
        }
        let items = profile.items
        guard !items.isEmpty else { return .ignored }
        let selected = items.indices.filter { model.selectedItemIDs.contains(items[$0].id) }
        let edge = items.firstIndex { $0.id == focusedItemID }
            ?? (direction < 0 ? selected.first : selected.last)
        let index = edge.map { min(max($0 + direction, 0), items.count - 1) }
            ?? (direction < 0 ? items.count - 1 : 0)
        if !modifiers.contains(.command) {
            model.selectItem(items[index].id, extendingRange: modifiers.contains(.shift), toggling: false)
        }
        focusedItemID = items[index].id
        return .handled
    }
}

private struct DockPreviewItemView: View {
    let item: DockItem
    let position: Int
    let count: Int
    let isSelected: Bool
    let isEditable: Bool
    let focus: FocusState<UUID?>.Binding
    let select: () -> Void
    let toggleSelection: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: select) {
            DockItemIcon(item: item, size: 52)
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(contrast == .increased ? 0.32 : 0.2) : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 11, style: .continuous))
        .focusable()
        .focused(focus, equals: item.id)
        .disabled(!isEditable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.editorAccessibilityLabel(position: position, count: count))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction { select() }
        .accessibilityAction(named: Text("toggle selection"), toggleSelection)
        .accessibilityHint("arrow keys select. shift-arrow extends the selection. command-arrow moves focus. option-space toggles selection. command-a selects all. command-option-arrow or dragging reorders selected items. delete removes selected items from the saved dock.")
        .accessibilityIdentifier("dock-item-\(position)")
        .help(item.editorName)
    }
}

struct NativeDockDrag {
    let id: UUID
    let profileID: UUID
    let items: [DockItem]

    var tokens: [String] {
        items.map { DockPreviewDragPayload.token(profileID: profileID, itemID: $0.id) }
    }
}

private struct NativeDockDragSurface: NSViewRepresentable {
    let isEnabled: Bool
    let select: () -> Void
    let begin: () -> NativeDockDrag?
    let ended: (UUID) -> Void
    let update: ([String], CGPoint, CGSize) -> Bool
    let accept: ([String], CGPoint, CGSize) -> Bool

    func makeNSView(context: Context) -> NativeDockDragView { NativeDockDragView() }

    func updateNSView(_ view: NativeDockDragView, context: Context) {
        view.isEnabled = isEnabled
        view.select = select
        view.begin = begin
        view.ended = ended
        view.update = update
        view.accept = accept
    }
}

final class NativeDockDragView: NSView, NSDraggingSource {
    static let pasteboardType = NSPasteboard.PasteboardType("com.advegaf.dockit.preview-item")
    var isEnabled = true
    var select: () -> Void = {}
    var begin: () -> NativeDockDrag? = { nil }
    var ended: (UUID) -> Void = { _ in }
    var update: ([String], CGPoint, CGSize) -> Bool = { _, _, _ in false }
    var accept: ([String], CGPoint, CGSize) -> Bool = { _, _, _ in false }
    private var downEvent: NSEvent?
    private var activeDrag: (id: UUID, ended: (UUID) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([Self.pasteboardType])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        downEvent = event
    }

    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil }
        guard isEnabled, downEvent != nil, activeDrag == nil else { return }
        select()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, activeDrag == nil, let downEvent,
              hypot(event.locationInWindow.x - downEvent.locationInWindow.x,
                    event.locationInWindow.y - downEvent.locationInWindow.y) >= 3,
              let drag = prepareDrag() else { return }
        self.downEvent = nil
        let draggingItems = zip(drag.items, drag.tokens).map { item, token in
            let pasteboard = NSPasteboardItem()
            pasteboard.setString(token, forType: Self.pasteboardType)
            let draggingItem = NSDraggingItem(pasteboardWriter: pasteboard)
            let size = NSSize(width: item.previewWidth, height: 52)
            draggingItem.setDraggingFrame(NSRect(origin: .zero, size: size), contents: Self.image(for: item))
            return draggingItem
        }
        let session = beginDraggingSession(with: draggingItems, event: downEvent, source: self)
        session.draggingFormation = .stack
        session.animatesToStartingPositionsOnCancelOrFail = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finishDrag()
    }

    func prepareDrag() -> NativeDockDrag? {
        guard isEnabled, activeDrag == nil, let drag = begin(), !drag.items.isEmpty else { return nil }
        activeDrag = (drag.id, ended)
        return drag
    }

    func finishDrag() {
        let drag = activeDrag
        activeDrag = nil
        downEvent = nil
        if let drag { drag.ended(drag.id) }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let tokens = localTokens(sender),
              update(tokens, convert(sender.draggingLocation, from: nil), bounds.size) else { return [] }
        return .move
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        localTokens(sender) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let tokens = localTokens(sender) else { return false }
        return accept(tokens, convert(sender.draggingLocation, from: nil), bounds.size)
    }

    private func localTokens(_ sender: any NSDraggingInfo) -> [String]? {
        guard isEnabled, sender.draggingSource is NativeDockDragView,
              sender.draggingSourceOperationMask.contains(.move),
              let items = sender.draggingPasteboard.pasteboardItems else { return nil }
        let tokens = items.compactMap { $0.string(forType: Self.pasteboardType) }
        guard tokens.count == items.count, DockPreviewDragPayload(tokens: tokens) != nil else { return nil }
        return tokens
    }

    private static func image(for item: DockItem) -> NSImage {
        if case let .application(app) = item.kind {
            return NSWorkspace.shared.icon(forFile: app.path)
        }
        let size = NSSize(width: item.previewWidth, height: 52)
        return NSImage(size: size, flipped: false) { rect in
            let marker = NSRect(x: rect.midX - 7, y: 1, width: 14, height: 50)
            NSColor.controlBackgroundColor.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: marker, xRadius: 7, yRadius: 7).fill()
            NSColor.secondaryLabelColor.setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: rect.midX, y: 9))
            line.line(to: NSPoint(x: rect.midX, y: 43))
            line.stroke()
            return true
        }
    }
}

struct DockPreviewDragPayload: Equatable, Sendable {
    let profileID: UUID
    let itemIDs: [UUID]

    init?(tokens: [String]) {
        var sourceProfileID: UUID?
        var ids: [UUID] = []
        for token in tokens {
            let fields = token.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 3, fields[0] == "dockit-item",
                  let profileID = UUID(uuidString: String(fields[1])),
                  let itemID = UUID(uuidString: String(fields[2])),
                  sourceProfileID == nil || sourceProfileID == profileID else { return nil }
            sourceProfileID = profileID
            ids.append(itemID)
        }
        guard let sourceProfileID, !ids.isEmpty, Set(ids).count == ids.count else { return nil }
        profileID = sourceProfileID
        itemIDs = ids
    }

    static func token(profileID: UUID, itemID: UUID) -> String {
        "dockit-item:\(profileID.uuidString):\(itemID.uuidString)"
    }

    func matches(_ session: DockPreviewDragSession) -> Bool {
        profileID == session.sourceProfileID
            && itemIDs.count == session.selectedIDs.count
            && Set(itemIDs) == Set(session.selectedIDs)
    }
}

enum DockPreviewDropTarget {
    case item(UUID)
    case end

    func position(
        at location: CGPoint,
        in size: CGSize,
        session: DockPreviewDragSession
    ) -> DockPreviewDragSession.Position? {
        switch self {
        case let .item(id):
            guard location.x.isFinite, location.y.isFinite, size.width.isFinite, size.width > 0,
                  session.originalItems.contains(where: { $0.id == id }),
                  !session.selectedIDs.contains(id) else { return nil }
            return location.x <= size.width / 2 ? .before(id) : .after(id)
        case .end:
            return .end
        }
    }
}
