import Foundation
import os
import UserNotifications

/// Watch-mode summaries, delivered as user notifications. Best-effort by design:
/// a denied notification permission must never break cleaning, it only logs.
enum WatchNotifier {

    /// Ask once, lazily, the first time a watch run has something to report.
    private static var didRequestAuthorization = false

    private static func authorizeIfNeeded(then deliver: @escaping () -> Void) {
        if didRequestAuthorization {
            deliver()
            return
        }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.watch.warning("notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                Log.watch.info("notifications denied — watch runs will stay silent")
            }
            DispatchQueue.main.async(execute: deliver)
        }
    }

    /// "Eviction notice served — N squatters evicted, X repossessed." The theme is
    /// fun; the facts (count, bytes, Trash, failures) stay exact.
    static func postReclaim(record: WatchRunRecord) {
        let content = UNMutableNotificationContent()
        content.title = "Eviction notice served"
        var body = "\(record.reclaimedCount) squatter\(record.reclaimedCount == 1 ? "" : "s") evicted from watched folders — \(Format.bytes(record.reclaimedBytes)) repossessed to the Trash."
        if record.failureCount > 0 {
            body += " \(record.failureCount) item\(record.failureCount == 1 ? "" : "s") refused to verify and were left alone."
        }
        content.body = body
        content.sound = .default
        post(content)
    }

    /// Dry-run mode: what *would* be repossessed if the master switch were on.
    static func postDryRun(record: WatchRunRecord) {
        let content = UNMutableNotificationContent()
        content.title = "Watched folders report"
        content.body = "\(record.candidateCount) stale artifact\(record.candidateCount == 1 ? "" : "s") (\(Format.bytes(record.candidateBytes))) could be repossessed. Auto-clean is off — enable it in Settings › Watch."
        post(content)
    }

    private static func post(_ content: UNMutableNotificationContent) {
        authorizeIfNeeded {
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    Log.watch.warning("notification delivery failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
