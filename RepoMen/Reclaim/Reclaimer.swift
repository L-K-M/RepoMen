import Foundation

/// Carries out a reclaim: re-verifies every item, then moves it to the Trash (default)
/// or deletes it. Between scan and click the world may have changed, so verification
/// happens here, at deletion time, not at scan time:
/// - every path passes `PathGuards.validate`,
/// - a project artifact's anchor must still exist (the `Cargo.toml` that proved
///   `target/` regenerable), or for anchor-less kinds the directory name must still be
///   an unambiguous artifact name (`__pycache__`),
/// - a known-cache item must live under a `KnownCaches.allowedRoots` root.
/// Failures skip the item and are reported, never thrown — one vanished anchor must
/// not abort the rest of the batch.
enum Reclaimer {

    enum Method: Sendable {
        case trash
        case delete
    }

    struct Outcome: Sendable {
        let item: CleanableItem
        /// nil = reclaimed; otherwise why the item was skipped.
        let failure: String?
    }

    static func reclaim(_ items: [CleanableItem],
                        method: Method,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        fileManager: FileManager = .default) -> [Outcome] {
        let keptPaths = PathGuards.dedupeNested(items.map(\.path))
        let kept = items.filter { keptPaths.contains($0.path) }
        let cacheRoots = KnownCaches.allowedRoots(home: home)

        var outcomes: [Outcome] = []
        for item in kept {
            if let failure = verify(item, home: home, cacheRoots: cacheRoots, fileManager: fileManager) {
                Log.reclaim.warning("skipped \(item.path, privacy: .public): \(failure, privacy: .public)")
                outcomes.append(Outcome(item: item, failure: failure))
                continue
            }
            do {
                switch method {
                case .trash:
                    try fileManager.trashItem(at: item.url, resultingItemURL: nil)
                case .delete:
                    try fileManager.removeItem(at: item.url)
                }
                Log.reclaim.info("reclaimed \(item.path, privacy: .public)")
                outcomes.append(Outcome(item: item, failure: nil))
            } catch {
                Log.reclaim.error("failed \(item.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                outcomes.append(Outcome(item: item, failure: error.localizedDescription))
            }
        }
        return outcomes
    }

    private static func verify(_ item: CleanableItem, home: URL,
                               cacheRoots: [String], fileManager: FileManager) -> String? {
        if let violation = PathGuards.validate(path: item.path, home: home.path) {
            return violation.reason
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return "no longer exists"
        }
        if item.isKnownCache {
            guard cacheRoots.contains(where: { PathGuards.isUnder(item.path, root: $0) }) else {
                return "not inside a known cache location"
            }
        } else if !item.anchorPaths.isEmpty {
            guard item.anchorPaths.contains(where: { fileManager.fileExists(atPath: $0) }) else {
                return "its anchor is gone (project moved or deleted?)"
            }
        } else {
            guard RuleCatalog.isUnambiguousArtifactName(item.url.lastPathComponent) else {
                return "can no longer be verified as a build artifact"
            }
        }
        return nil
    }
}
