import SwiftUI

struct DockitCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appTermination) {
            Button("close dockit windows") {
                DockMenuCoordinator.shared.closeAllWindows()
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        CommandGroup(replacing: .help) {
            Button("quick guide") {
                DockMenuCoordinator.shared.presentMainWindow()
                model.quickGuidePresented = true
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button("settings...") {
                DockMenuCoordinator.shared.presentSettingsWindow()
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(replacing: .newItem) {
            Button("new dock...") {
                Task { await model.createProfile(captureCurrent: false) }
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model.profileActionsDisabled)

            Button("capture current dock") {
                Task { await model.createProfile(captureCurrent: true) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(model.profileActionsDisabled)
        }
    }
}
