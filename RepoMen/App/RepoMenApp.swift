import SwiftUI

/// Entry point. Unlike sibling Gans (a menu-bar agent), RepoMen is a regular windowed
/// utility, so the SwiftUI `App` lifecycle fits: one main window plus Settings (⌘,).
@main
struct RepoMenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(Preferences.shared)
                .frame(minWidth: 780, minHeight: 460)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { appDelegate.updateChecker.checkNow() }
            }
            // A single-window utility: no File > New.
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Scan Now") { model.startScan() }
                    .keyboardShortcut("r")
                    .disabled(model.isBusy || model.isReclaiming)
                Button("Stop Scan") { model.cancelScan() }
                    .keyboardShortcut(".")
                    .disabled(!model.isBusy)
                Divider()
                // ⌘⌫ — Finder's "Move to Trash" chord. It only opens the confirmation
                // dialog; the destructive step still takes an explicit click there.
                Button("Reclaim Checked…") { model.confirmingReclaim = true }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.checkedItems.isEmpty || model.isReclaiming)
            }
            // The context menu's row actions, discoverable and Help-searchable.
            CommandMenu("Items") {
                Button("Reveal in Finder") { model.revealInFinder(ids: model.tableSelection) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.tableSelection.isEmpty)
                Button("Copy Path") { model.copyPaths(ids: model.tableSelection) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.tableSelection.isEmpty)
                Divider()
                Button("Check") { model.setChecked(true, ids: model.tableSelection) }
                    .disabled(model.tableSelection.isEmpty || model.isReclaiming)
                Button("Uncheck") { model.setChecked(false, ids: model.tableSelection) }
                    .disabled(model.tableSelection.isEmpty || model.isReclaiming)
                Divider()
                Button("Exclude from Future Scans") { model.exclude(ids: model.tableSelection) }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.tableSelection.isEmpty || model.isReclaiming)
            }
        }

        Settings {
            SettingsView(updateChecker: appDelegate.updateChecker)
                .environmentObject(Preferences.shared)
        }
    }
}
