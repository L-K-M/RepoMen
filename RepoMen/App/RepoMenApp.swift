import SwiftUI

/// Entry point. Unlike sibling Gans (a menu-bar agent), RepoMen is a regular windowed
/// utility, so the SwiftUI `App` lifecycle fits: one main window plus Settings (⌘,).
@main
struct RepoMenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var preferences = Preferences.shared
    @StateObject private var watchManager = WatchManager.shared
    @StateObject private var snapshotModel = SnapshotModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(preferences)
                .environmentObject(snapshotModel)
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
                    .disabled(model.isBusy || model.isReclaiming || model.isSystemScanning)
                // Ellipsis: it always costs an admin-password prompt.
                Button("Scan System Areas…") { model.scanSystemAreas() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.isBusy || model.isReclaiming || model.isSystemScanning)
                // Selects the sidebar row; listing is read-only and needs no password.
                ShowSnapshotsButton(model: model)
                Button("Stop Scan") {
                    if model.isSystemScanning {
                        model.cancelSystemScan()
                    } else {
                        model.cancelScan()
                    }
                }
                    .keyboardShortcut(".")
                    .disabled(!model.isBusy && !model.isSystemScanning)
                Divider()
                // ⌘⌫ — Finder's "Move to Trash" chord. It only opens the confirmation
                // dialog; the destructive step still takes an explicit click there.
                Button("Reclaim Checked…") { model.confirmingReclaim = true }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.checkedItems.isEmpty || model.isReclaiming
                              || model.isSystemScanning)
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
                Button("Add to Watched Folders") { model.addToWatchedFolders(ids: model.tableSelection) }
                    .disabled(!model.canWatchSelection(ids: model.tableSelection))
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

/// The Scan menu's entry to the snapshots pane: selects the sidebar row and brings
/// the main window forward (it may be closed). A separate view so it can read the
/// `openWindow` action from the environment, which a bare menu `Button` cannot.
private struct ShowSnapshotsButton: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Time Machine Snapshots") {
            model.sidebarSelection = .snapshots
            openWindow(id: "main")
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])
    }
}
