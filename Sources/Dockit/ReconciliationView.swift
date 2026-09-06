import SwiftUI

struct ReconciliationView: View {
    @Bindable var model: AppModel
    let reconciliation: AppModel.Reconciliation

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    Text(title)
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !model.reconciliationErrorMessage.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .accessibilityHidden(true)
                            Text(model.reconciliationErrorMessage)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityLabel("recovery error: \(model.reconciliationErrorMessage)")
                    }

                    if model.isApplying {
                        ProgressView("updating dock")
                            .controlSize(.small)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    notNowButton
                    Spacer()
                    restoreBeforeSwitchButton
                    applySavedButton
                    keepCurrentButton
                }

                VStack(alignment: .trailing, spacing: 10) {
                    restoreBeforeSwitchButton
                    applySavedButton
                    keepCurrentButton
                    notNowButton
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .disabled(model.isApplying)
            .padding(20)
        }
        .frame(minWidth: 460, idealWidth: 560)
        .presentationSizing(.fitted)
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var restoreBeforeSwitchButton: some View {
        if case .interrupted = reconciliation.kind {
            Button("restore before switch") {
                Task { await model.restorePreSwitchDock() }
            }
            .accessibilityValue("restore before switch")
        }
    }

    private var notNowButton: some View {
        Button("not now") {
            model.dismissReconciliation()
        }
        .keyboardShortcut(.cancelAction)
    }

    private var applySavedButton: some View {
        Button("apply saved changes") {
            Task { await model.applySavedReconciliation() }
        }
    }

    @ViewBuilder
    private var keepCurrentButton: some View {
        switch reconciliation.kind {
        case .savedEditsConflict, .interrupted:
            Button("keep current as a new dock") {
                Task { await model.keepCurrentAsNewDock() }
            }
        case .changedWhileClosed:
            Button("save current dock", role: .destructive) {
                Task { await model.keepCurrentDockChanges() }
            }
        }
    }

    private var title: String {
        switch reconciliation.kind {
        case .changedWhileClosed:
            "your dock changed while dockit was closed"
        case .interrupted:
            "a dock switch was interrupted"
        case .savedEditsConflict:
            "your dock and saved profile both changed"
        }
    }

    private var message: String {
        switch reconciliation.kind {
        case .changedWhileClosed:
            "the real dock no longer matches saved \(profileName). save its current pinned apps and spacers to this profile, or apply the saved version. folders, recent and running apps, windows, and other dock settings stay unchanged."
        case .interrupted:
            "the switch to \(profileName) did not finish. the current dock may be incomplete. restore the dock from before the switch, apply saved \(profileName), or keep the current dock as a new profile. your saved edits stay intact."
        case .savedEditsConflict:
            "\(profileName) has saved edits that you have not applied, and the real dock changed too. apply your saved changes, or keep the current dock as a new profile. neither version is replaced until you choose. automatic switching stays paused if you choose not now."
        }
    }

    private var profileName: String {
        let profileID: UUID?
        switch reconciliation.kind {
        case .changedWhileClosed, .savedEditsConflict:
            profileID = model.library.activeProfile?.profileID
        case let .interrupted(pending):
            profileID = pending.profileID
        }
        return profileID.flatMap { model.library.record(id: $0)?.profile.name } ?? "dock"
    }
}
