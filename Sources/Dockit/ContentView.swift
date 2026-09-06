import DockitCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView("reading your dock")
                    .controlSize(.large)
            } else if model.storageUnavailable {
                ContentUnavailableView {
                    Label("saved docks are unavailable", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(model.storageFailureMessage)
                } actions: {
                    Button("try again") {
                        Task { await model.retryLoad() }
                    }
                    .accessibilityValue("try again")
                }
            } else if model.library.profiles.isEmpty {
                SetupView(model: model)
            } else {
                managementView
            }
        }
        .alert(item: managementError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("ok"))
            )
        }
        .confirmationDialog(
            "delete \(model.deleteRequest?.profile.name ?? "dock")?",
            isPresented: Binding(
                get: { model.deleteRequest != nil },
                set: { if !$0 { model.deleteRequest = nil } }
            ),
            presenting: model.deleteRequest
        ) { request in
            Button("delete dock", role: .destructive) {
                Task { await model.deleteConfirmed(request) }
            }
            Button("cancel", role: .cancel) {
                model.deleteRequest = nil
            }
        } message: { request in
            if request.id == model.library.activeProfile?.profileID {
                Text("this removes the active profile. your current dock stays as it is. apply another saved dock to resume saving edits made directly in the dock.")
            } else {
                Text("this removes the saved profile. your current dock stays as it is.")
            }
        }
        .sheet(isPresented: exportPresented, onDismiss: { model.finishTransferSheet(from: .management) }) {
            ExportProfilesView(model: model)
        }
        .sheet(item: importPreview, onDismiss: { model.finishTransferSheet(from: .management) }) { preview in
            ImportProfilesView(model: model, preview: preview)
        }
        .sheet(item: $model.missingAppActivation) { request in
            MissingAppsView(model: model, request: request)
        }
        .sheet(isPresented: $model.reconciliationPresented) {
            if let reconciliation = model.reconciliation {
                ReconciliationView(model: model, reconciliation: reconciliation)
            }
        }
        .sheet(isPresented: $model.quickGuidePresented, onDismiss: model.completeQuickGuide) {
            QuickGuideView(model: model)
        }
        .onOpenURL { url in
            model.openImportURL(url)
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .containerBackground(colorScheme == .dark ? Material.ultraThick : Material.regular, for: .window)
    }

    private var managementError: Binding<AppModel.PresentedError?> {
        Binding(
            get: {
                model.presentedErrorHost == .settings ? nil : model.presentedError
            },
            set: { error in
                model.presentedError = error
                if error == nil { model.presentedErrorHost = nil }
            }
        )
    }

    private var exportPresented: Binding<Bool> {
        Binding(
            get: {
                model.transferPresentationHost == .management && model.exportPresented
            },
            set: { presented in
                if !presented { model.cancelExport() }
            }
        )
    }

    private var importPreview: Binding<AppModel.ImportPreview?> {
        Binding(
            get: {
                model.transferPresentationHost == .management ? model.importPreview : nil
            },
            set: { preview in
                if preview == nil { model.cancelImport() }
            }
        )
    }

    private var managementView: some View {
        Group {
            if let record = model.selectedRecord {
                ProfileDetailView(model: model, record: record)
                    .id(record.id)
            } else {
                emptySelection
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("dockit")
    }

    private var emptySelection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let message = model.saveFailureMessage {
                SaveFailureNotice(model: model, message: message)
            }
            ContentUnavailableView(
                "choose a dock",
                systemImage: "dock.rectangle",
                description: Text("choose a saved dock to edit it.")
            )
            Picker("dock", selection: $model.selectedProfileID) {
                ForEach(model.library.profiles) { record in
                    Text(record.profile.name).tag(Optional(record.id))
                }
            }
        }
    }
}

struct SaveFailureNotice: View {
    @Bindable var model: AppModel
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("changes could not be saved", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message)
                .textSelection(.enabled)
            Button("retry saving") {
                Task { await model.retrySave() }
            }
            .accessibilityIdentifier("retry-save")
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}
