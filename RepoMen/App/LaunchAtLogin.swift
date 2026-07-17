import Foundation
import ServiceManagement

/// "Open RepoMen automatically when you log in" (Settings → General).
///
/// `SMAppService` is the single source of truth — nothing is mirrored into
/// UserDefaults, so the toggle can never disagree with System Settings › General ›
/// Login Items, however the user flips it there.
enum LaunchAtLogin {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers/unregisters the app as a login item. Failures are logged, not
    /// thrown: the toggle re-reads `isEnabled` on the next pass and simply snaps
    /// back to the true state.
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
