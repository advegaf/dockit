import AppKit
import DockitCore
import SwiftUI

struct ProfileDetailView: View {
    @Bindable var model: AppModel
    let record: DockProfileRecord

    @State private var detailsPresented = false
    @State private var saveFailurePresented = false
    @State private var replaceConfirmationPresented = false
    @State private var progress = ApplyProgressPresentation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Feedback: CaseIterable, Hashable {
        case normal, pending, applying, saveFailure, reconciliation
    }

    var feedback: Feedback {
        if model.saveFailureMessage != nil { return .saveFailure }
        if model.reconciliation != nil { return .reconciliation }
        if hasApplyingRequest && progress.isVisible { return .applying }
        if model.hasPendingSelectedChanges { return .pending }
        return .normal
    }

    private var isActive: Bool {
        record.id == model.library.activeProfile?.profileID
    }

    private func canMoveSelectedItems(by offset: Int) -> Bool {
        DockItemEditing.moving(
            record.profile.items,
            selectedIDs: model.selectedItemIDs,
            by: offset
        ) != record.profile.items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                profileIdentity
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                profileControls
            }
            DockPreviewView(model: model, profile: record.profile)
                .frame(maxHeight: 134)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            ToolbarSpacer(.flexible, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                NativeProfileToolbarPicker(model: model)
                    .padding(.horizontal, NativeProfilePopUpButton.backingHorizontalInset)
                    .background(DockEditorControlSurface(cornerRadius: 12))
                    .padding(.top, NativeProfilePopUpButton.toolbarTopOffset)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        .sheet(isPresented: $detailsPresented) {
            DockDetailsView(model: model, profileID: record.id)
        }
        .sheet(isPresented: $saveFailurePresented) {
            SaveFailureDetailsView(model: model)
        }
        .confirmationDialog(
            "replace the saved items in \(record.profile.name)?",
            isPresented: $replaceConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("replace saved items", role: .destructive) {
                Task { await model.replaceSelectedWithCurrentDock() }
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("this copies the apps and spacers from your current dock into this profile. its saved items will be replaced. your real dock will not change.")
        }
        .task(id: hasApplyingRequest) {
            await progress.follow(isApplying: hasApplyingRequest)
        }
    }

    var hasApplyingRequest: Bool {
        record.id == model.applyingProfileID
            && !model.editorShowsApplied(for: record.id)
            && model.saveFailureMessage == nil
            && model.reconciliation == nil
    }

    private var profileIdentity: some View {
        HStack(alignment: .center, spacing: 10) {
            ProfileIdentityBadge(color: record.profile.color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.profile.name)
                    .font(.system(size: 20, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .frame(width: 13, height: 13)
                        .accessibilityHidden(true)
                    ZStack(alignment: .leading) {
                        ForEach(Feedback.allCases, id: \.self) { state in
                            feedbackContent(for: state)
                                .opacity(feedback == state ? 1 : 0)
                                .disabled(feedback != state)
                                .allowsHitTesting(feedback == state)
                                .accessibilityHidden(feedback != state)
                        }
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .frame(minHeight: 16, alignment: .leading)
                .animation(
                    feedback == .saveFailure || feedback == .reconciliation || model.activationUsesKeyboard
                        ? nil
                        : .timingCurve(0.23, 1, 0.32, 1, duration: reduceMotion ? 0.12 : 0.25),
                    value: feedback
                )
                .accessibilityIdentifier("profile-activation-status")
            }
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private func feedbackContent(for state: Feedback) -> some View {
        switch state {
        case .saveFailure:
            Button {
                saveFailurePresented = true
            } label: {
                Label("not saved. review", systemImage: "exclamationmark.triangle")
            }
            .buttonStyle(.link)
            .accessibilityLabel("changes could not be saved. review saving error")
            .accessibilityIdentifier("review-save-failure")
        case .reconciliation:
            Button {
                model.reviewReconciliation()
            } label: {
                Label("review dock changes", systemImage: "exclamationmark.triangle")
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("review-dock-changes")
        case .applying:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 13, height: 13)
                Text("applying · \(itemCountDescription)")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("applying \(record.profile.name)")
        case .pending:
            Text("\(profileStatus) · saved, not applied")
                .fixedSize(horizontal: false, vertical: true)
                .monospacedDigit()
                .accessibilityIdentifier("pending-changes-status")
        case .normal:
            Text(profileStatus)
                .fixedSize(horizontal: false, vertical: true)
                .monospacedDigit()
        }
    }

    private var profileControls: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.activate(record.id, source: .manual) }
            } label: {
                DockApplyActionLabel(isApplied: model.editorShowsApplied(for: record.id))
            }
            .buttonStyle(DockEditorActionStyle())
            .disabled(model.editorShowsApplied(for: record.id) || model.activationDisabled(for: record.id))
            .help(model.editorShowsApplied(for: record.id)
                ? "this saved layout is already applied"
                : "apply the latest saved items to your real dock")
            .accessibilityLabel(model.editorShowsApplied(for: record.id)
                ? "\(record.profile.name), applied" : "use \(record.profile.name)")
            .accessibilityIdentifier("apply-dock")

            editMenu
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)
                .controlSize(.regular)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(DockEditorControlSurface())
        }
        .font(.system(size: 12, weight: .semibold))
        .fixedSize(horizontal: true, vertical: false)
    }

    private var editMenu: some View {
        Menu("edit dock") {
            Button("add apps...") {
                Task { await model.addApps() }
            }
            .disabled(model.profileActionsDisabled)
            Menu("add spacer") {
                Button("regular spacer") {
                    Task { await model.addSpacer(.regular) }
                }
                Button("small spacer") {
                    Task { await model.addSpacer(.small) }
                }
            }
            .disabled(model.profileActionsDisabled)
            Button("replace with current dock...") {
                replaceConfirmationPresented = true
            }
            .disabled(model.profileActionsDisabled)
            if !model.unavailableApps(for: record.id).isEmpty {
                Button("review unavailable apps...") {
                    model.reviewUnavailableApps()
                }
                .disabled(model.profileActionsDisabled)
            }
            Divider()
            Button("move selected earlier") {
                Task { await model.moveSelectedItems(by: -1) }
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(model.profileActionsDisabled || !canMoveSelectedItems(by: -1))
            Button("move selected later") {
                Task { await model.moveSelectedItems(by: 1) }
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(model.profileActionsDisabled || !canMoveSelectedItems(by: 1))
            Button("remove selected") {
                Task { await model.removeSelectedItems() }
            }
            .disabled(model.profileActionsDisabled || model.selectedItemIDs.isEmpty)
            Divider()
            Button("dock details...") {
                detailsPresented = true
            }
            .accessibilityIdentifier("open-dock-details")
        }
        .accessibilityIdentifier("edit-dock")
    }

    private var profileStatus: String {
        let state = isActive
            ? (model.library.activeProfile?.source == .focus ? "current from focus" : "current")
            : "not active"
        return "\(state) · \(itemCountDescription)"
    }

    private var itemCountDescription: String {
        let count = record.profile.items.count
        return "\(count) \(count == 1 ? "item" : "items")"
    }
}

struct DockApplyActionLabel: View {
    let isApplied: Bool

    var body: some View {
        ZStack {
            Text("use this dock").hidden().accessibilityHidden(true)
            Text(isApplied ? "applied" : "use this dock")
                .contentTransition(.identity)
        }
    }
}

@MainActor
@Observable
final class ApplyProgressPresentation {
    private(set) var isVisible = false

    func follow(isApplying: Bool) async {
        isVisible = false
        guard isApplying else { return }
        do {
            try await Task.sleep(for: .milliseconds(150))
            try Task.checkCancellation()
            isVisible = true
        } catch {
            // A completed or superseded apply never reveals its delayed feedback.
        }
    }
}

private struct DockEditorControlSurface: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var cornerRadius: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                Color(nsColor: colorScheme == .dark ? .controlBackgroundColor : .controlColor)
                    .opacity(reduceTransparency ? 1 : 0.75)
            )
    }
}

private struct DockEditorActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .frame(height: 32)
            .foregroundStyle(isEnabled ? .primary : .secondary)
            .background(DockEditorControlSurface())
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(configuration.isPressed ? 0.08 : 0))
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}


struct DockItemIcon: View {
    let item: DockItem
    let size: CGFloat

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        switch item.kind {
        case let .application(app):
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .overlay(alignment: .bottomTrailing) {
                    if !FileManager.default.fileExists(atPath: app.path) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.primary, .background)
                    }
                }
                .accessibilityHidden(true)
        case let .spacer(spacerSize):
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.white.opacity(contrast == .increased ? 0.3 : 0.18))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.white.opacity(contrast == .increased ? 0.65 : 0.35), lineWidth: 1)
                }
                .overlay {
                    Rectangle()
                        .fill(.secondary.opacity(contrast == .increased ? 0.72 : 0.42))
                        .frame(width: contrast == .increased ? 2 : 1, height: size * 0.64)
                }
                .frame(width: size * 14 / 52, height: size * 50 / 52)
                .frame(width: spacerSize == .regular ? size : size / 2, height: size)
                .accessibilityHidden(true)
        }
    }
}

extension DockItem {
    var editorName: String {
        switch kind {
        case let .application(app): app.displayName
        case .spacer(.regular): "spacer"
        case .spacer(.small): "small spacer"
        }
    }

    var previewWidth: CGFloat {
        switch kind {
        case .application, .spacer(.regular): 52
        case .spacer(.small): 26
        }
    }

    func editorAccessibilityLabel(position: Int, count: Int) -> String {
        switch kind {
        case let .application(app):
            let availability = FileManager.default.fileExists(atPath: app.path) ? "available" : "unavailable"
            return "\(app.displayName), app, \(availability), item \(position) of \(count)"
        case .spacer:
            return "\(editorName), item \(position) of \(count)"
        }
    }
}

struct WrappingPathText: View {
    let path: String

    var body: some View {
        Text(verbatim: path)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityLabel(path)
            .contextMenu {
                Button("copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
    }
}
