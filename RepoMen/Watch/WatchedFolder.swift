import Foundation

/// One directory RepoMen keeps clean on its own: while watch mode runs, build
/// artifacts found under `path` whose newest content is older than `maxIdleDays`
/// are moved to the Trash automatically (re-verified at trash time like any manual
/// reclaim — see `WatchManager` and `Reclaimer`).
struct WatchedFolder: Identifiable, Hashable, Codable, Sendable {
    let path: String
    /// Days since the artifact was last built before watch mode considers it stale.
    var maxIdleDays: Int
    var isEnabled: Bool

    var id: String { path }

    init(path: String, maxIdleDays: Int = 30, isEnabled: Bool = true) {
        self.path = path
        self.maxIdleDays = maxIdleDays
        self.isEnabled = isEnabled
    }
}

/// The persisted outcome of one watch check, shown in the menu bar and in
/// Settings → Watch ("last run: repossessed 2.3 GB, 3 h ago").
struct WatchRunRecord: Hashable, Codable, Sendable {
    let date: Date
    /// True when auto-trash was off and nothing was actually reclaimed.
    let dryRun: Bool
    let candidateCount: Int
    let candidateBytes: Int64
    let reclaimedCount: Int
    let reclaimedBytes: Int64
    let failureCount: Int
}
