import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    private var loginStatus: String {
        if model.launchAtLoginChangeInProgress { return "updating" }
        if model.launchAtLoginNeedsApproval { return "approval required" }
        return model.launchAtLogin ? "on" : "off"
    }

    var body: some View {
        Form {
            Section("general") {
                Toggle("launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.requestLaunchAtLogin($0) }
                ))
                .disabled(model.launchAtLoginChangeInProgress)

                LabeledContent("login items", value: loginStatus)

                if model.launchAtLoginNeedsApproval {
                    Label("allow dockit in login items to finish turning this on.", systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                }

                NativeSettingsButton(
                    title: "open login items settings...",
                    accessibilityLabel: "open login items settings",
                    systemImage: "gearshape"
                ) {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }

            Section("focus") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("automatic switching", systemImage: "moon")
                    Text(model.focusAutomationMessage)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(focusGuidance)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                NativeSettingsButton(
                    title: "open focus settings...",
                    accessibilityLabel: "open focus settings",
                    systemImage: "moon"
                ) {
                    let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")!
                    NSWorkspace.shared.open(url)
                }
            }

            Section("data & privacy") {
                Text("your profiles stay on this mac. dockit has no account, cloud sync, analytics, or telemetry.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("move profiles between macs with import and export.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Spacer()
                        importButton
                        exportButton
                    }
                    VStack(alignment: .trailing, spacing: 8) {
                        importButton
                        exportButton
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if let message = model.settingsTransferMessage {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(message)
                }
            }

            Section("about") {
                HStack(alignment: .center, spacing: 16) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("dockit")
                            .font(.title2.weight(.semibold))
                        Text("version \(version), build \(build)")
                            .foregroundStyle(.secondary)
                        Text("requires macos 26 or later")
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)

                Text("your dock profiles remain on this mac unless you export them yourself.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .frame(minWidth: DockitWindowSize.settingsMinimum.width, minHeight: DockitWindowSize.settingsMinimum.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsWindowConfigurator())
        .onAppear { model.refreshLaunchAtLoginStatus() }
        .sheet(isPresented: exportPresented, onDismiss: { model.finishTransferSheet(from: .settings) }) {
            ExportProfilesView(model: model)
        }
        .sheet(item: importPreview, onDismiss: { model.finishTransferSheet(from: .settings) }) { preview in
            ImportProfilesView(model: model, preview: preview)
        }
        .alert(item: settingsError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("ok"))
            )
        }
    }

    private var importButton: some View {
        NativeSettingsButton(
            title: "import docks...",
            accessibilityLabel: "import docks",
            systemImage: "square.and.arrow.down",
            isEnabled: !model.profileActionsDisabled
        ) {
            Task { await model.importProfiles(from: .settings) }
        }
    }

    private var exportButton: some View {
        NativeSettingsButton(
            title: "export docks...",
            accessibilityLabel: "export docks",
            systemImage: "square.and.arrow.up",
            isEnabled: !model.library.profiles.isEmpty && !model.profileActionsDisabled
        ) {
            model.presentExport(from: .settings)
        }
    }

    private var focusGuidance: String {
        if !model.focusAutomationAvailable {
            return "you can still apply profiles from the dockit window, docks menu, or menu bar."
        }
        if !model.launchAtLogin {
            return "launch dockit at login to keep focus switching ready after you sign in."
        }
        return "dockit is ready for focus switching after sign-in."
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    private var settingsError: Binding<AppModel.PresentedError?> {
        Binding(
            get: { model.presentedErrorHost == .settings ? model.presentedError : nil },
            set: { error in
                model.presentedError = error
                if error == nil { model.presentedErrorHost = nil }
            }
        )
    }

    private var exportPresented: Binding<Bool> {
        Binding(
            get: { model.transferPresentationHost == .settings && model.exportPresented },
            set: { if !$0 { model.cancelExport() } }
        )
    }

    private var importPreview: Binding<AppModel.ImportPreview?> {
        Binding(
            get: { model.transferPresentationHost == .settings ? model.importPreview : nil },
            set: { if $0 == nil { model.cancelImport() } }
        )
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSView) {
        Task { @MainActor [weak view] in
            guard let window = view?.window else { return }
            window.styleMask.formUnion([.resizable, .miniaturizable])
            window.contentMinSize = DockitWindowSize.settingsMinimum
            window.title = "dockit settings"
        }
    }
}

private struct NativeSettingsButton: NSViewRepresentable {
    let title: String
    let accessibilityLabel: String
    let systemImage: String
    var isEnabled = true
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.performAction))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel(accessibilityLabel)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = title
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(accessibilityLabel)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    final class Coordinator: NSObject {
        var action: @MainActor () -> Void

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        @MainActor @objc func performAction() {
            action()
        }
    }
}
