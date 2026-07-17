import AppKit

/// Minimal delegate: owns the update checker (the `Updates/` module shared with the
/// sibling apps) and gives the utility its window behavior — quit-on-close normally,
/// menu-bar resident once watch folders exist — with one exception: the app never
/// dies in the middle of a deletion batch, manual or automatic.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let updateChecker = UpdateChecker(
        configuration: .init(owner: "L-K-M", repo: "RepoMen", appName: "RepoMen"))

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        // A WindowGroup + MenuBarExtra app can be mis-classified at launch (treated
        // like an agent): the window then opens unactivated and the app looks
        // unresponsive. RepoMen is a windowed app first — say so explicitly.
        NSApp.setActivationPolicy(.regular)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        updateChecker.start()
        WatchManager.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // With watched folders armed, RepoMen is a menu-bar resident: closing the
        // window parks it rather than quitting, or watching stops with the app.
        !WatchManager.shared.hasWatchedFolders
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A reclaim in flight finishes its batch first (interrupting a permanent
        // delete mid-tree would leave half-deleted directories); the completing
        // reclaim replies and termination proceeds.
        if AppModel.activeReclaimCount > 0 {
            AppModel.terminateAfterReclaim = true
            return .terminateLater
        }
        if WatchManager.activeReclaimCount > 0 {
            WatchManager.terminateAfterReclaim = true
            return .terminateLater
        }
        return .terminateNow
    }

    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil ||
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
