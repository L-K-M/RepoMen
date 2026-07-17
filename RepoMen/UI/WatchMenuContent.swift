import AppKit
import SwiftUI

/// The menu-bar extra: watch status at a glance plus the quick actions. It never
/// scans or reclaims on its own schedule beyond `WatchManager`'s — the buttons are
/// shortcuts into the same machinery the window uses.
struct WatchMenuContent: View {
    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var watchManager: WatchManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        if preferences.lifetimeReclaimedBytes > 0 {
            Text("Lifetime: \(Format.bytes(preferences.lifetimeReclaimedBytes)) repossessed")
        }
        Divider()
        Button("Open RepoMen") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Run Watch Check Now") { watchManager.runCheck() }
            .disabled(watchManager.isChecking || !watchManager.hasWatchedFolders)
        Divider()
        if #available(macOS 14.0, *) {
            // SettingsLink is the public, selector-free way to open the Settings
            // scene — and the only one that works from a menu-bar extra.
            SettingsLink {
                Text("Settings…")
            }
        } else {
            Button("Settings…") { SettingsOpener.open() }
        }
        Button("Quit RepoMen") { NSApp.terminate(nil) }
    }

    private var statusLine: String {
        if watchManager.isChecking { return "Checking watched folders…" }
        if !watchManager.hasWatchedFolders { return "No watched folders — add some in Settings › Watch" }
        guard let run = preferences.lastWatchRun else { return "Watch check hasn't run yet" }
        let age = Format.age(run.date)
        if run.dryRun {
            return run.candidateCount == 0
                ? "Watched folders clean · \(age)"
                : "Could repossess \(Format.bytes(run.candidateBytes)) · \(age)"
        }
        return "Repossessed \(Format.bytes(run.reclaimedBytes)) · \(age)"
    }
}
