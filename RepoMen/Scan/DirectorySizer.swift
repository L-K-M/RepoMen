import Foundation

/// Measures a directory: allocated bytes plus the newest modification time seen —
/// which for a build directory is "when this was last built". Runs synchronously;
/// callers parallelize with a bounded task group and may cancel (a cancelled
/// measurement comes back with `isComplete == false` and must be discarded).
enum DirectorySizer {

    struct Measurement: Sendable {
        var bytes: Int64 = 0
        var newestModification: Date = .distantPast
        /// False when the walk was aborted by cancellation — the counts are partial
        /// and must never be presented as a measured size.
        var isComplete: Bool = true
        /// Read failures make byte counts a lower bound rather than a full size.
        var unreadableEntries = 0
    }

    static func measure(_ url: URL, fileManager: FileManager = .default) -> Measurement {
        var measurement = Measurement()
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
            .contentModificationDateKey, .linkCountKey, .fileResourceIdentifierKey,
        ]
        if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            measurement.newestModification = date
        }
        guard let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: Array(keys),
            options: [], errorHandler: { _, _ in
                measurement.unreadableEntries += 1
                return true
            }) else {
            measurement.unreadableEntries += 1
            return measurement
        }

        // Hardlinked files (pnpm-style stores, cargo caches) are enumerated once per
        // link; count each underlying file once so the size reflects what deleting the
        // directory could actually free. Only multi-link files pay the set lookup.
        var seenHardlinks = Set<NSObject>()
        var visited = 0
        for case let entry as URL in enumerator {
            visited += 1
            if visited % 512 == 0 && Task.isCancelled {
                measurement.isComplete = false
                break
            }
            guard let values = try? entry.resourceValues(forKeys: keys) else {
                measurement.unreadableEntries += 1
                continue
            }
            if let date = values.contentModificationDate,
               date > measurement.newestModification, date <= Date() {
                measurement.newestModification = date
            }
            guard values.isRegularFile == true else { continue }
            if let linkCount = values.linkCount, linkCount > 1,
               let identifier = values.fileResourceIdentifier as? NSObject,
               !seenHardlinks.insert(identifier).inserted {
                continue
            }
            measurement.bytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return measurement
    }
}
