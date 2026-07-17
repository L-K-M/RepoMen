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

        // Watch mode's presence: status + quick actions. Insertion is user-controlled
        // (Settings → General); the scene exists regardless so toggling is instant.
        //
        // `isInserted` is two-way: MenuBarExtraController writes the status item's
        // visibility back through it via KVO. `@Published` re-emits on *every* set,
        // even an equal one — publish → scene invalidation → configuration update →
        // KVO writeback → publish → … an endless update loop that beachballs the app
        // at launch (and persists `true`, so a default of `false` never gets read).
        // The deduping setter below swallows no-op writes and breaks the cycle.
        MenuBarExtra("RepoMen", systemImage: "internaldrive",
                     isInserted: Binding(
                        get: { preferences.showInMenuBar },
                        set: { newValue in
                            if preferences.showInMenuBar != newValue {
                                preferences.showInMenuBar = newValue
                            }
                        })) {
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
