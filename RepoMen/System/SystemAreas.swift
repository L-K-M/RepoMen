import Foundation

/// The fixed catalog of *root-owned* locations RepoMen can inspect and clean — with
/// administrator privileges, since `/private/var/root` is unreadable to a normal
/// user process. The headline tenant is `rtcreportingd`: kept busy by another app
/// (Dropbox is the documented culprit), it fills `/private/var/root/Library/Logs/
/// RTCReporting` with tens of gigabytes of message logs, plus event caches under
/// root's `Library/Caches` — invisible to every unprivileged disk tool.
///
/// Everything here is disposable by the owning daemon's contract: logs are
/// diagnostic output nothing reads back (the daemon starts a fresh file on its next
/// report), and `Library/Caches` contents are rebuilt on demand. The catalog is the
/// only thing the privileged probe reports on and the only thing the privileged
/// reclaimer will delete — direct children of these roots, never the roots
/// themselves, never anything deeper, never an arbitrary path.
enum SystemAreas {

    struct Root: Sendable {
        /// Absolute physical path (no trailing slash). `/var` is a symlink to
        /// `/private/var`; storing the physical spelling keeps the prefix checks
        /// below judging physical locations, like `PathGuards` does.
        let path: String
        let kind: ArtifactKind
        /// Item labels read "<prefix> · <child name>".
        let labelPrefix: String
    }

    static let roots: [Root] = [
        Root(path: "/private/var/root/Library/Logs", kind: .systemLogs,
             labelPrefix: "Root logs"),
        Root(path: "/private/var/root/Library/Caches", kind: .systemCaches,
             labelPrefix: "Root caches"),
    ]

    /// The catalog root a path lives strictly under, if any.
    static func root(containing path: String) -> Root? {
        roots.first { path.hasPrefix($0.path + "/") }
    }

    /// Why `path` must not be touched as a system area, or nil if it passes. The
    /// counterpart of `PathGuards.validate` for the root-owned catalog: absolute,
    /// NUL-free, no relative components, and a DIRECT child of a catalog root —
    /// never a root itself, never deeper, never outside. The probe only ever
    /// reports direct children, so anything else is a bug (or a tampered record)
    /// and is refused. Both the scanner and the reclaimer run every path through
    /// this; the reclaim script additionally re-checks each path as root (still a
    /// directory, not a symlink) immediately before deleting.
    static func validate(path: String) -> PathGuards.Violation? {
        guard path.hasPrefix("/") else {
            return PathGuards.Violation(reason: "not an absolute path")
        }
        guard !path.contains("\0") else {
            return PathGuards.Violation(reason: "path contains a NUL byte")
        }
        guard !path.hasSuffix("/") else {
            return PathGuards.Violation(reason: "path has a trailing slash")
        }
        let components = path.split(separator: "/").map(String.init)
        guard !components.contains("..") && !components.contains(".") else {
            return PathGuards.Violation(reason: "path contains relative components")
        }
        guard let root = root(containing: path) else {
            return PathGuards.Violation(reason: "outside the system-areas catalog")
        }
        guard components.count == root.path.split(separator: "/").count + 1 else {
            return PathGuards.Violation(reason: "not a direct child of \(root.path)")
        }
        return nil
    }

    // MARK: Culprits

    /// An app known to keep a system area growing while it runs. RTCReporting is
    /// the canonical case: Dropbox keeps `rtcreportingd` (and `fileproviderd`)
    /// busy, so the log folder regrows immediately after cleaning — and files the
    /// daemon still holds open free no space until it lets go.
    struct Culprit: Sendable {
        let appName: String
        let bundleIDs: [String]
    }

    /// Keyed by the child directory's lowercased name.
    static let culprits: [String: Culprit] = [
        "rtcreporting": Culprit(appName: "Dropbox",
                                bundleIDs: ["com.getdropbox.dropbox"]),
        "com.apple.rtcreporting": Culprit(appName: "Dropbox",
                                          bundleIDs: ["com.getdropbox.dropbox"]),
    ]

    /// A warning badge for the item while its known culprit app is running — the
    /// same mechanism as the browser-cache warnings. `isRunning` answers whether an
    /// app with the given bundle id is open (injected so tests need no AppKit).
    static func culpritWarning(childName: String,
                               isRunning: (String) -> Bool) -> String? {
        guard let culprit = culprits[childName.lowercased()],
              culprit.bundleIDs.contains(where: isRunning) else { return nil }
        return "\(culprit.appName) is running — it keeps this folder growing, so it will refill (and files it holds open free no space) until you quit it"
    }
}
