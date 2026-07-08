import Foundation

/// Measures a directory: allocated bytes plus the newest modification time seen —
/// which for a build directory is "when this was last built". Runs synchronously;
/// callers parallelize with a bounded task group and may cancel (a cancelled
/// measurement returns what it had, which is discarded with the scan).
enum DirectorySizer {

    struct Measurement: Sendable {
        var bytes: Int64 = 0
        var newestModification: Date = .distantPast
    }

    static func measure(_ url: URL, fileManager: FileManager = .default) -> Measurement {
        var measurement = Measurement()
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
            .contentModificationDateKey,
        ]
        if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            measurement.newestModification = date
        }
        guard let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: Array(keys),
            options: [], errorHandler: { _, _ in true }) else { return measurement }

        var visited = 0
        for case let entry as URL in enumerator {
            visited += 1
            if visited % 512 == 0 && Task.isCancelled { break }
            guard let values = try? entry.resourceValues(forKeys: keys) else { continue }
            if let date = values.contentModificationDate,
               date > measurement.newestModification, date <= Date() {
                measurement.newestModification = date
            }
            guard values.isRegularFile == true else { continue }
            measurement.bytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return measurement
    }
}
