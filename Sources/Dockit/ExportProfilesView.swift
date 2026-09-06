import SwiftUI

struct ExportProfilesView: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("export docks")
        .font(.title2.weight(.semibold))
      Text(
        "choose the saved docks to include. running apps, folders, and other dock settings are never exported."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(model.library.profiles) { record in
            Toggle(
              isOn: Binding(
                get: { model.exportSelection.contains(record.id) },
                set: { selected in
                  if selected {
                    model.exportSelection.insert(record.id)
                  } else {
                    model.exportSelection.remove(record.id)
                  }
                }
              )
            ) {
              Text(record.profile.name)
                .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 320)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityLabel("docks to export")

      if let message = model.exportErrorMessage {
        Text("docks could not be exported. \(message)")
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }

      HStack {
        Spacer()
        Button("cancel") {
          model.cancelExport()
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityValue("cancel")
        Button("export") {
          Task { await model.exportProfiles(model.exportSelection) }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(model.exportSelection.isEmpty)
        .accessibilityValue("export")
      }
    }
    .padding(24)
    .frame(minWidth: 460, idealWidth: 520)
    .presentationSizing(.fitted)
  }
}
