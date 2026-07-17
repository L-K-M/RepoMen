import Foundation
import ServiceManagement

/// Applies the "Open RepoMen automatically when you log in" preference
/// (`Preferences.launchAtLogin`) via `SMAppService`.
///
/// Failures are logged, not thrown: the toggle is driven by the persisted
/// preference (the user's intent), and a failed registration surfaces in the log
/// rather than freezing the UI.
enum LaunchAtLogin {

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.warning("launch-at-login \(enabled ? "registration" : "unregistration") failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
