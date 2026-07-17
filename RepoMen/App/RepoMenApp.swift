import SwiftUI

/// Entry point. Unlike sibling Gans (a menu-bar agent), RepoMen is a regular windowed
/// utility, so the SwiftUI `App` lifecycle fits: one main window plus Settings (⌘,).
@main
struct RepoMenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var preferences = Preferences.shared
    @StateObject private var watchManager = WatchManager.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(preferences)
                .frame(minWidth: 780, minHeight: 460)
                .onAppear {
                    // Opt-in automation: one scan when the window first appears.
                    if preferences.scanAtLaunch, model.phase == .idle {
                        model.startScan()
                    }
                }
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
        }

        // Watch mode's presence: status + quick actions. Insertion is user-controlled
        // (Settings → General); the scene exists regardless so toggling is instant.
        MenuBarExtra("RepoMen", systemImage: "internaldrive",
                     isInserted: $preferences.showInMenuBar) {
            WatchMenuContent()
                .environmentObject(model)
                .environmentObject(preferences)
                .environmentObject(watchManager)
        }

        Settings {
            SettingsView(updateChecker: appDelegate.updateChecker)
                .environmentObject(preferences)
                .environmentObject(watchManager)
        }
    }
}
