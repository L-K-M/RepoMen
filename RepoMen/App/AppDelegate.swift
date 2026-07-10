import AppKit

/// Minimal delegate: owns the update checker (the `Updates/` module shared with the
/// sibling apps) and gives the one-window utility its quit-on-close behavior — with
/// one exception: the app never dies in the middle of a deletion batch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let updateChecker = UpdateChecker(
        configuration: .init(owner: "L-K-M", repo: "RepoMen", appName: "RepoMen"))

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        updateChecker.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A reclaim in flight finishes its batch first (interrupting a permanent
        // delete mid-tree would leave half-deleted directories); the completing
        // reclaim replies and termination proceeds.
        if AppModel.activeReclaimCount > 0 {
            AppModel.terminateAfterReclaim = true
            return .terminateLater
        }
        return .terminateNow
    }

    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil ||
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
