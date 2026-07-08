import AppKit

/// Minimal delegate: owns the update checker (the `Updates/` module shared with the
/// sibling apps) and gives the one-window utility its quit-on-close behavior.
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

    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil ||
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
