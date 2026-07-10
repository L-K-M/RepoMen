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

    /// `progress` is invoked on the calling thread before each item is processed,
    /// with the 1-based position, the batch total, and the item itself.
    static func reclaim(_ items: [CleanableItem],
                        method: Method,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        fileManager: FileManager = .default,
                        progress: ((_ current: Int, _ total: Int, _ item: CleanableItem) -> Void)? = nil) -> [Outcome] {
        let keptPaths = PathGuards.dedupeNested(items.map(\.path))
        let kept = items.filter { keptPaths.contains($0.path) }
        // Resolve once up front: every guard below compares physical locations, not
        // spellings — a symlinked component must not smuggle a path past them.
        let resolvedHome = home.resolvingSymlinksInPath()
        let cacheRoots = KnownCaches.allowedRoots(home: resolvedHome)

        var outcomes: [Outcome] = []
        for (index, item) in kept.enumerated() {
            progress?(index + 1, kept.count, item)
            if let failure = verify(item, home: resolvedHome, cacheRoots: cacheRoots, fileManager: fileManager) {
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

    /// `home` and `cacheRoots` arrive symlink-resolved; the item's path is resolved
    /// here, so every check judges where the directory physically lives.
    private static func verify(_ item: CleanableItem, home: URL,
                               cacheRoots: [String], fileManager: FileManager) -> String? {
        // The scanned artifact was a directory. If the path is now a symlink, the
        // world changed underneath us — refuse (attributesOfItem does not traverse
        // the final component, so this is an lstat).
        if let type = (try? fileManager.attributesOfItem(atPath: item.path))?[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            return "is now a symlink, not the scanned directory"
        }
        // Between scan and reclaim a parent can become a symlink (say, ~/Projects
        // moved to an external disk and linked back): the lexical path still reads
        // "inside home" while the directory physically lives elsewhere. Guard the
        // resolved location.
        let resolvedPath = item.url.resolvingSymlinksInPath().path
        if let violation = PathGuards.validate(path: resolvedPath, home: home.path) {
            return violation.reason
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return "no longer exists"
        }
        if item.isKnownCache {
            guard cacheRoots.contains(where: { PathGuards.isUnder(resolvedPath, root: $0) }) else {
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
