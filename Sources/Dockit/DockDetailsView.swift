import AppKit
import DockitCore
import SwiftUI

struct DockDetailsView: View {
    @Bindable var model: AppModel
    let profileID: UUID

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedItemID: UUID?

    private var profile: DockProfile? {
        model.library.record(id: profileID)?.profile
    }

    private var isEditable: Bool {
        !model.profileActionsDisabled && model.selectedProfileID == profileID
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("dock details")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let profile {
                            Text(profile.name)
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("edits save automatically. choose use this dock to update your real dock.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let message = model.saveFailureMessage {
                                SaveFailureNotice(model: model, message: message)
                            }
                            if !model.statusMessage.isEmpty {
                                Text(model.statusMessage)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("dock-status")
                            }
                            if profile.items.isEmpty {
                                Text("no pinned apps or spacers")
                                    .foregroundStyle(.secondary)
                            } else {
                                HStack(spacing: 8) {
                                    Button("move earlier") {
                                        Task { await model.moveSelectedItems(by: -1) }
                                    }
                                    .disabled(!canMoveSelectedItems(by: -1))
                                    Button("move later") {
                                        Task { await model.moveSelectedItems(by: 1) }
                                    }
                                    .disabled(!canMoveSelectedItems(by: 1))
                                    Button("remove selected") {
                                        Task { await model.removeSelectedItems() }
                                    }
                                    .disabled(model.selectedItemIDs.isEmpty)
                                }
                                .disabled(!isEditable)

                                DisclosureGroup("keyboard shortcuts") {
                                    Text("arrow keys select an item.\nshift-arrow extends the selection.\ncommand-arrow moves focus without changing the selection.\noption-space toggles the focused item.\ncommand-a selects all items.\ncommand-option-arrow moves selected items earlier or later.\ndelete removes selected items from this saved dock.")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                        .padding(.top, 4)
                                }
                                ForEach(Array(profile.items.enumerated()), id: \.element.id) { index, item in
                                    itemRow(item, at: index, count: profile.items.count)
                                        .id(item.id)
                                    if index < profile.items.count - 1 { Divider() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: focusedItemID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .onChange(of: profile?.items.map(\.id)) { _, ids in
                    if let focusedItemID, ids?.contains(focusedItemID) == true {
                        proxy.scrollTo(focusedItemID)
                    }
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 560)
        .presentationSizing(.fitted)
        .accessibilityIdentifier("dock-details")
        .onKeyPress(keys: [.leftArrow], phases: .down) { handleArrow(-1, modifiers: $0.modifiers) }
        .onKeyPress(keys: [.rightArrow], phases: .down) { handleArrow(1, modifiers: $0.modifiers) }
        .onKeyPress(keys: ["a"], phases: .down) { event in
            guard event.modifiers.contains(.command), isEditable, let profile else { return .ignored }
            model.selectedItemIDs = Set(profile.items.map(\.id))
            return .handled
        }
        .onKeyPress(keys: [.space], phases: .down) { event in
            guard event.modifiers.contains(.option), isEditable, let focusedItemID else { return .ignored }
            model.selectItem(focusedItemID, toggling: true)
            return .handled
        }
        .onDeleteCommand {
            guard isEditable else { return }
            Task { await model.removeSelectedItems() }
        }
    }

    private func itemRow(_ item: DockItem, at index: Int, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                focusedItemID = item.id
                let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                model.selectItem(item.id, extendingRange: modifiers.contains(.shift), toggling: modifiers.contains(.command))
            } label: {
                HStack(spacing: 10) {
                    DockItemIcon(item: item, size: 28)
                    Text(item.editorName)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if model.selectedItemIDs.contains(item.id) {
                        Image(systemName: "checkmark.circle.fill")
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($focusedItemID, equals: item.id)
            .disabled(!isEditable)
            .accessibilityLabel(item.editorAccessibilityLabel(position: index + 1, count: count))
            .accessibilityAddTraits(model.selectedItemIDs.contains(item.id) ? .isSelected : [])
            .accessibilityHint("select this item. hold command to toggle or shift to select a range.")
            if case let .application(app) = item.kind {
                DisclosureGroup("path") {
                    WrappingPathText(path: app.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        }
    }

    private func canMoveSelectedItems(by offset: Int) -> Bool {
        guard let profile else { return false }
        return DockItemEditing.moving(profile.items, selectedIDs: model.selectedItemIDs, by: offset) != profile.items
    }

    private func handleArrow(_ direction: Int, modifiers: EventModifiers) -> KeyPress.Result {
        guard isEditable, let profile, !profile.items.isEmpty else { return .ignored }
        if modifiers.contains(.command), modifiers.contains(.option) {
            Task { await model.moveSelectedItems(by: direction) }
            return .handled
        }
        let items = profile.items
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

struct SaveFailureDetailsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
                if let message = model.saveFailureMessage {
                    SaveFailureNotice(model: model, message: message)
                } else {
                    Label("changes saved", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 440, idealWidth: 520)
        .presentationSizing(.fitted)
    }
}
