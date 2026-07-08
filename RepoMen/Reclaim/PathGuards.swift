import Foundation

/// The last line of defense before anything is moved to the Trash. Every path goes
/// through `validate` at reclaim time regardless of how it was found — a bug in a scan
/// rule must not be able to delete something these guards can name.
enum PathGuards {

    /// Path components that mark trees RepoMen must never touch, whatever a rule says:
    /// container/VM disk images masquerade as "one big stale file" (Docker, OrbStack,
    /// Colima, Lima), and backups/photo libraries are irreplaceable.
    static let denylistComponents: Set<String> = [
        "com.docker.docker", ".docker", "OrbStack", ".orbstack", ".colima", ".lima",
        ".Trash", "Backups.backupdb", "com.apple.TimeMachine.localsnapshots",
    ]

    /// Denylisted name *suffixes* (macOS library bundles carry user data).
    static let denylistSuffixes: [String] = [
        ".photoslibrary", ".musiclibrary", ".tvlibrary",
    ]

    /// Why a path was refused; shown to the user verbatim.
    struct Violation: Error, Equatable, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    /// Returns why `path` must not be reclaimed, or nil if it passes. The rules:
    /// absolute and free of `..`/`.` games, strictly inside the home folder, at least
    /// two levels below it (no trashing `~/Documents` whole), and free of denylisted
    /// components. Deliberately pure — `home` is injected so tests exercise it fully.
    static func validate(path: String, home: String) -> Violation? {
        guard path.hasPrefix("/") else {
            return Violation(reason: "not an absolute path")
        }
        let components = path.split(separator: "/").map(String.init)
        guard !components.contains("..") && !components.contains(".") else {
            return Violation(reason: "path contains relative components")
        }
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard path != home, path.hasPrefix(home + "/") else {
            return Violation(reason: "outside the home folder")
        }
        let depthBelowHome = components.count - home.split(separator: "/").count
        guard depthBelowHome >= 2 else {
            return Violation(reason: "a top-level home folder — too broad to reclaim")
        }
        for component in components {
            if denylistComponents.contains(component) {
                return Violation(reason: "inside a protected area (\(component))")
            }
            for suffix in denylistSuffixes where component.hasSuffix(suffix) {
                return Violation(reason: "inside a protected library (\(component))")
            }
        }
        return nil
    }

    /// True when `path` equals `root` or lives under it.
    static func isUnder(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    /// Keeps only the outermost of any nested paths, so reclaiming a parent and its
    /// child never double-deletes (the child would already be gone — or in the Trash
    /// twice). Order is preserved.
    static func dedupeNested(_ paths: [String]) -> [String] {
        paths.filter { candidate in
            !paths.contains { other in
                other != candidate && isUnder(candidate, root: other)
            }
        }
    }
}
