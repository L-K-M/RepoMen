import Foundation

/// Small, pure display formatters (unit-tested; no locale-dependent machinery for the
/// age strings so tests are deterministic).
enum Format {

    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    /// Coarse "how stale is this" buckets — build artifacts don't need minutes-level
    /// precision, they need "worth keeping warm?" at a glance.
    static func age(_ date: Date, now: Date = Date()) -> String {
        guard date > .distantPast else { return "—" }
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 0 else { return "just now" }
        let minute = 60.0, hour = 3_600.0, day = 86_400.0
        switch seconds {
        case ..<(2 * minute): return "just now"
        case ..<(2 * hour): return "\(Int(seconds / minute)) min ago"
        case ..<(2 * day): return "\(Int(seconds / hour)) h ago"
        case ..<(14 * day): return "\(Int(seconds / day)) days ago"
        case ..<(61 * day): return "\(Int(seconds / (7 * day))) weeks ago"
        case ..<(730 * day): return "\(Int(seconds / (30.44 * day))) months ago"
        default: return "\(Int(seconds / (365.25 * day))) years ago"
        }
    }

    /// Abbreviates the home directory to `~` for display.
    static func abbreviatePath(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
