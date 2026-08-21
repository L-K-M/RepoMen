import Foundation

/// The privileged counterpart of `Reclaimer` for `SystemAreas` items. Deletion is
/// permanent — `rm -rf` as root; the Trash is per-user and cannot take root-owned
/// trees — and the UI says so before anything runs. One script per batch means one
/// password prompt however many items are checked. Verification happens twice: in
/// Swift against the catalog before a path is ever built into the script, and again
/// as root immediately before each `rm` (the path must still be a directory and not
/// a symlink — the same "the world may have changed" re-check `Reclaimer.verify`
/// does). Like `Reclaimer`, failures are reported per item, never thrown.
enum SystemReclaimer {

    /// `runner` is injected so tests never spawn osascript.
    static func reclaim(_ items: [CleanableItem],
                        runner: (String) async throws -> String = PrivilegedRunner.run)
        async -> [Reclaimer.Outcome] {
        var outcomes: [Reclaimer.Outcome] = []
        var deletable: [CleanableItem] = []
        for item in items {
            if !item.isSystemArea {
                outcomes.append(Reclaimer.Outcome(item: item, failure: "not a system-area item"))
            } else if let violation = SystemAreas.validate(path: item.path) {
                Log.reclaim.warning("skipped \(item.path, privacy: .public): \(violation.reason, privacy: .public)")
                outcomes.append(Reclaimer.Outcome(item: item, failure: violation.reason))
            } else {
                deletable.append(item)
            }
        }
        guard !deletable.isEmpty else { return outcomes }

        do {
            let output = try await runner(script(for: deletable.map(\.path)))
            guard let records = PrivilegedRunner.decodePayload(output) else {
                throw PrivilegedRunner.Failure.failed("The privileged delete returned unreadable output.")
            }
            let statuses = parseStatuses(records)
            for item in deletable {
                let failure: String?
                switch statuses[item.path] {
                case "OK": failure = nil
                case "ERR": failure = "the privileged delete failed"
                case "GONE": failure = "no longer a plain directory (vanished or replaced?)"
                default: failure = "the privileged helper reported no result"
                }
                if let failure {
                    Log.reclaim.error("failed \(item.path, privacy: .public): \(failure, privacy: .public)")
                } else {
                    Log.reclaim.info("reclaimed \(item.path, privacy: .public) (privileged)")
                }
                outcomes.append(Reclaimer.Outcome(item: item, failure: failure))
            }
        } catch {
            let reason = (error as? PrivilegedRunner.Failure) == .cancelled
                ? "administrator authorization was cancelled"
                : ((error as? PrivilegedRunner.Failure)?.errorDescription
                   ?? error.localizedDescription)
            Log.reclaim.warning("privileged reclaim did not run: \(reason, privacy: .public)")
            outcomes.append(contentsOf: deletable.map {
                Reclaimer.Outcome(item: $0, failure: reason)
            })
        }
        return outcomes
    }

    /// POSIX sh for one batch. Per path: `OK` (deleted), `ERR` (rm failed), `GONE`
    /// (vanished or became a symlink between scan and reclaim — refused). Records
    /// are `STATUS\tPATH`, NUL-separated, base64-wrapped exactly like the probe's.
    /// Callers must have validated every path via `SystemAreas.validate` first.
    static func script(for paths: [String]) -> String {
        var lines = ["("]
        for path in paths {
            let q = PrivilegedRunner.shellQuote(path)
            lines.append("if [ -d \(q) ] && [ ! -L \(q) ]; then"
                + " if rm -rf -- \(q); then printf 'OK\\t%s\\0' \(q);"
                + " else printf 'ERR\\t%s\\0' \(q); fi;"
                + " else printf 'GONE\\t%s\\0' \(q); fi")
        }
        lines.append(") | /usr/bin/base64")
        return lines.joined(separator: "\n")
    }

    /// Path → status from the script's decoded output. Malformed records are
    /// dropped; their items then report "no result", which fails safe.
    static func parseStatuses(_ records: Data) -> [String: String] {
        var statuses: [String: String] = [:]
        for record in records.split(separator: 0) {
            guard let text = String(data: record, encoding: .utf8) else { continue }
            let fields = text.split(separator: "\t", maxSplits: 1,
                                    omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            statuses[String(fields[1])] = String(fields[0])
        }
        return statuses
    }
}
