import AppKit

/// Opens the SwiftUI `Settings` scene programmatically. There's no public API for
/// this before macOS 14's `SettingsLink`; the selector was renamed in Ventura, so try
/// the current name first and fall back to the pre-13 one.
enum SettingsOpener {
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        let settings = Selector(("showSettingsWindow:"))
        let preferences = Selector(("showPreferencesWindow:"))
        if NSApp.responds(to: settings) {
            NSApp.sendAction(settings, to: nil, from: nil)
        } else {
            NSApp.sendAction(preferences, to: nil, from: nil)
        }
    }
}
