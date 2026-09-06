import DockitCore
import SwiftUI

struct ImportProfilesView: View {
    @Bindable var model: AppModel
    let preview: AppModel.ImportPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("import docks")
                    .font(.title2.weight(.semibold))
                Text("review the saved docks in \(preview.fileName) before adding them.")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(preview.profiles) { profile in
                        ImportProfileRow(profile: profile)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("docks to import")

            VStack(alignment: .leading, spacing: 6) {
                if preview.unavailableAppCount > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(unavailableSummary)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("unavailable apps stay in the saved dock. applying uses available apps and reports what was skipped. you can relink missing apps in the editor.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("importing adds saved docks only. your current dock will not change.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)

            actionButtons
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 560)
        .presentationSizing(.fitted)
        .interactiveDismissDisabled(model.isImporting)
    }

    private var actionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Spacer()
                cancelButton
                importButton
            }

            VStack(alignment: .trailing, spacing: 8) {
                importButton
                cancelButton
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var cancelButton: some View {
        Button("cancel") {
            model.cancelImport()
        }
        .keyboardShortcut(.cancelAction)
        .disabled(model.isImporting)
        .accessibilityValue("cancel")
    }

    private var importButton: some View {
        Button(importButtonTitle) {
            Task { await model.confirmImport(preview.id) }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(model.isImporting)
        .accessibilityValue(importButtonTitle)
    }

    private var importButtonTitle: String {
        model.isImporting
            ? "importing"
            : "import \(preview.profiles.count) dock\(preview.profiles.count == 1 ? "" : "s")"
    }

    private var unavailableSummary: String {
        "\(preview.unavailableAppCount) unavailable app\(preview.unavailableAppCount == 1 ? "" : "s") found"
    }
}

private struct ImportProfileRow: View {
    let profile: AppModel.ImportPreview.Profile

    private var applicationCount: Int {
        profile.source.items.reduce(0) { count, item in
            if case .application = item.kind { count + 1 } else { count }
        }
    }

    private var spacerCount: Int {
        profile.source.items.count - applicationCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                ProfileColorSwatch(color: profile.source.color)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.importedName)
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                    if profile.isRenamed {
                        Label("renamed from \(profile.source.name)", systemImage: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text(itemSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !profile.unavailableApps.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(profile.unavailableApps) { unavailable in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "app.dashed")
                                .foregroundStyle(.orange)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(unavailable.app.displayName)
                                    .fixedSize(horizontal: false, vertical: true)
                                WrappingPathText(path: unavailable.app.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("unavailable")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "\(unavailable.app.displayName), unavailable app, \(unavailable.app.path)"
                        )
                    }
                }
                .padding(.leading, 19)
            }
        }
        .padding(.vertical, 6)
    }

    private var itemSummary: String {
        let appText = "\(applicationCount) app\(applicationCount == 1 ? "" : "s")"
        guard spacerCount > 0 else { return appText }
        return "\(appText), \(spacerCount) spacer\(spacerCount == 1 ? "" : "s")"
    }
}
