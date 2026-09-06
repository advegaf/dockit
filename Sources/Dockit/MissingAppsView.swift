import DockitCore
import SwiftUI

struct MissingAppsView: View {
  @Bindable var model: AppModel
  let request: AppModel.MissingAppActivation

  private var profileName: String {
    model.library.record(id: request.profileID)?.profile.name ?? "dock"
  }

  private var missingApps: [SkippedDockApp] {
    model.unavailableApps(for: request.profileID)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 5) {
        Text("unavailable apps")
          .font(.title2.weight(.semibold))
        Text(introduction)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if missingApps.isEmpty {
        ContentUnavailableView(
          "all apps are available",
          systemImage: "checkmark.circle",
          description: Text("you can apply this dock now.")
        )
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            ForEach(missingApps, id: \.itemID) { unavailable in
              MissingAppRow(
                unavailable: unavailable,
                chooseReplacement: {
                  Task {
                    await model.relinkUnavailableApp(
                      requestID: request.id,
                      itemID: unavailable.itemID
                    )
                  }
                }
              )
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 320)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("unavailable apps in \(profileName)")
      }

      if !model.missingAppErrorMessage.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
              .accessibilityHidden(true)
            Text(model.missingAppErrorMessage)
              .foregroundStyle(.primary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel("replacement error: \(model.missingAppErrorMessage)")
          if model.saveFailureMessage != nil {
            Button("retry save") {
              Task { await model.retrySave() }
            }
            .accessibilityIdentifier("retry-missing-app-save")
          }
        }
      }

      actionButtons
    }
    .padding(24)
    .frame(minWidth: 460, idealWidth: 520)
    .presentationSizing(.fitted)
    .disabled(model.isResolvingMissingApps)
  }

  private var introduction: String {
    if missingApps.isEmpty {
      return "the unavailable apps in \(profileName) have replacements."
    }
    return
      "\(profileName) includes apps that are not available at their saved locations. choose replacements, cancel without changing your dock, or skip them for this switch."
  }

  private var actionButtons: some View {
    ViewThatFits(in: .horizontal) {
      HStack {
        cancelButton
        Spacer()
        applyButton
      }

      VStack(alignment: .trailing, spacing: 8) {
        applyButton
        cancelButton
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  private var cancelButton: some View {
    Button("cancel") {
      Task { await model.cancelMissingAppActivation(request.id) }
    }
    .keyboardShortcut(.cancelAction)
    .accessibilityValue("cancel")
  }

  private var applyButton: some View {
    Button(missingApps.isEmpty ? "apply dock" : "skip and apply") {
      Task { await model.confirmMissingAppActivation(request.id) }
    }
    .keyboardShortcut(.defaultAction)
    .disabled(model.saveFailureMessage != nil)
    .accessibilityValue(missingApps.isEmpty ? "apply dock" : "skip and apply")
  }
}

private struct MissingAppRow: View {
  let unavailable: SkippedDockApp
  let chooseReplacement: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "app.dashed")
          .font(.system(size: 24))
          .frame(width: 32, height: 32)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 2) {
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

      Button("choose replacement...", action: chooseReplacement)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityValue("choose replacement")
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      "\(unavailable.app.displayName), unavailable app, \(unavailable.app.path)"
    )
  }
}
