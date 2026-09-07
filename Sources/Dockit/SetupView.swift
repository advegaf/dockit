import AppKit
import SwiftUI

struct SetupView: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = false
    @State private var isCreating = false
    @State private var creatingLabel = "creating dock"

    var body: some View {
        VStack(spacing: 24) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("a different dock for whatever you are doing.")
                    .font(.title.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("dockit saves pinned apps and spacers. folders, recent and open apps, windows, and other dock settings stay unchanged.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("launch dockit at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .help("keeps focus automation ready after you sign in")

            saveCurrentDockButton

            if isCreating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(creatingLabel)
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var saveCurrentDockButton: some View {
        Button("save current dock") {
            creatingLabel = "saving current dock"
            isCreating = true
            Task {
                await model.createFirst(launchAtLogin: launchAtLogin)
                isCreating = false
            }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(isCreating)
        .accessibilityValue("save current dock")
    }
}

struct QuickGuideView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("a little guide to dockit")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("your docks, ready when you are.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                tip("choose a dock", symbol: "chevron.up.chevron.down",
                    detail: "the profile picker lets you inspect a dock without switching to it.")
                tip("make it yours", symbol: "hand.draw",
                    detail: "drag apps and spacers to rearrange them. edits save automatically.")
                tip("use this dock", symbol: "checkmark.circle",
                    detail: "apply your saved layout when you are ready. only pinned items change; running apps and windows stay open.")
                tip("switch from the menu bar", symbol: "dock.rectangle",
                    detail: "choose a profile from the little dock in your menu bar to apply it directly.")
            }

            HStack {
                Text("find this again in help → quick guide.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Button("got it", action: model.completeQuickGuide)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("complete-quick-guide")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 460)
        .presentationSizing(.fitted)
        .onExitCommand(perform: model.completeQuickGuide)
    }

    private func tip(_ title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
