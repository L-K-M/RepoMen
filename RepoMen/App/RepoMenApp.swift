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
                    .disabled(model.isBusy)
                Button("Stop Scan") { model.cancelScan() }
                    .keyboardShortcut(".")
                    .disabled(!model.isBusy)
            }
        }

        Settings {
            SettingsView(updateChecker: appDelegate.updateChecker)
                .environmentObject(Preferences.shared)
        }
    }
}
