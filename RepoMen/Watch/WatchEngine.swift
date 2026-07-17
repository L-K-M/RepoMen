import Foundation

/// The pure heart of watch mode: which found artifacts a set of watched folders
/// would auto-reclaim right now. Kept free of IO and clocks so the decision is
/// fully unit-tested — `WatchManager` only feeds it scan results and a `now`.
enum WatchEngine {

    /// The folder whose threshold governs a path: the *most specific* (deepest)
    /// enabled watched folder containing it. Nested watches therefore mean what a
    /// user expects — the inner folder's rule wins for its subtree.
    static func governingFolder(for path: String, folders: [WatchedFolder]) -> WatchedFolder? {
        folders
            .filter { $0.isEnabled && PathGuards.isUnder(path, root: $0.path) }
            .max { $0.path.count < $1.path.count }
    }

    /// Items eligible for auto-reclaim: governed by a watched folder, fully
    /// measured (an unknown age is never "idle"), and last built before that
    /// folder's cutoff.
    static func eligibleItems(items: [CleanableItem],
                              folders: [WatchedFolder],
                              now: Date = Date()) -> [CleanableItem] {
        items.filter { item in
            guard item.isMeasured,
                  let folder = governingFolder(for: item.path, folders: folders) else { return false }
            let cutoff = now.addingTimeInterval(-Double(folder.maxIdleDays) * 86_400)
            return item.lastModified <= cutoff
        }
    }

    /// A stable fingerprint of a candidate set. Dry-run reports compare it against
    /// the last notified set so an unchanged finding doesn't re-notify every cycle.
    static func signature(for items: [CleanableItem]) -> String {
        items.map { "\($0.path)#\($0.sizeBytes)" }.sorted().joined(separator: "|")
    }
}
