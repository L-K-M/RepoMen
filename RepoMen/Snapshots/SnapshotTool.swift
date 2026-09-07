import Foundation

/// Everything RepoMen does with Time Machine local snapshots, on top of `tmutil`:
/// pure argument builders, a pure parser for `listlocalsnapshots` output, the
/// privileged fallback scripts, and the three operations — list, delete, thin — with
/// injectable runners so tests never spawn a process or a password dialog.
///
/// The safety story, in one place:
/// - Exactly three tmutil verbs exist here (`validate(arguments:)` refuses any
///   other), always against the boot volume, with operands that are validated date
///   tokens or plain integers. `SnapshotRunner` re-checks before spawning.
/// - A snapshot can only be named through `LocalSnapshot`, which accepts nothing but
///   `com.apple.TimeMachine.<date>.local` — never third-party, macOS-update or
///   `.backup` snapshots. That filter does real work: despite its name,
///   `tmutil listlocalsnapshots` lists EVERY snapshot on the volume (an Arq agent
///   snapshot `com_haystacksoftware_arqagent_…` was seen in the field). Foreign
///   names are reported as "left alone" (`Listing.otherNames`) so the user knows
///   they exist and may hold freed blocks, and are never offered for deletion.
/// - Deletion is permanent and the UI says so; nothing is pre-selected; every
///   destructive action passes a confirmation dialog; watch mode never comes here;
///   snapshots are never routed through `Reclaimer` or `SystemReclaimer`.
/// - Sizes are not invented: macOS exposes no per-snapshot size to apps (Disk
///   Utility's Private Size column comes from private API), so none is shown.
enum SnapshotTool {

    /// The volume whose snapshots RepoMen manages. On Catalina and later tmutil
    /// resolves `/` to the Data volume, where the local snapshots live.
    static let mountPoint = "/"

    static let listVerb = "listlocalsnapshots"
    static let deleteVerb = "deletelocalsnapshots"
    static let thinVerb = "thinlocalsnapshots"

    /// Listing is instant; removing one snapshot takes APFS a few seconds; thinning
    /// many can take minutes. Generous ceilings — the UI's Stop button cancels.
    static let listTimeout: TimeInterval = 20
    static let deleteTimeout: TimeInterval = 600
    static let thinTimeout: TimeInterval = 1_800

    /// tmutil's urgency scale for thinning. deleted(8) itself purges at 3 when the
    /// Finder needs room; 4 is the most urgent tmutil accepts.
    static let urgencyRange = 1...4

    typealias Runner = (_ arguments: [String], _ timeout: TimeInterval) async throws -> SnapshotRunner.Output
    typealias AdminRunner = (_ script: String) async throws -> String

    enum Failure: Error, Equatable, LocalizedError {
        case toolFailed(String)
        /// The user dismissed the administrator prompt of the fallback — expected.
        case cancelled

        var errorDescription: String? {
            switch self {
            case .toolFailed(let message): return message
            case .cancelled: return "Administrator authorization was cancelled."
            }
        }
    }

    struct Outcome: Sendable, Equatable {
        let snapshot: LocalSnapshot
        /// nil = deleted; otherwise why not.
        let failure: String?
        /// Plain free space gained while this snapshot was removed — sampled just
        /// before tmutil ran and again after a short settle, because APFS frees a
        /// snapshot's blocks in the background. The only per-snapshot size macOS
        /// lets anyone but Disk Utility see, and only after the fact. nil when it
        /// could not be measured: a failed delete, the privileged batch (one script
        /// for all, nothing to attribute), or no free-space figure available.
        let freedBytes: Int64?

        init(snapshot: LocalSnapshot, failure: String?, freedBytes: Int64? = nil) {
            self.snapshot = snapshot
            self.failure = failure
            self.freedBytes = freedBytes
        }
    }

    /// How long APFS gets to finish removing a snapshot's blocks before the
    /// after-sample is taken. Oakley timed ~7 s for a 95 GB snapshot; hourly
    /// snapshots are far smaller, and a figure that lags simply shows up on the
    /// next snapshot's line or in the batch total.
    static let settleAfterDelete: TimeInterval = 3

    typealias FreeSpaceSampler = () -> Int64?

    /// Plain free space on the boot volume — deliberately NOT
    /// `volumeAvailableCapacityForImportantUsage`, which already counts purgeable
    /// space (snapshots included) and lags by many minutes; this is the figure that
    /// actually moves when a snapshot is gone.
    static func volumeFreeBytes() -> Int64? {
        let root = URL(fileURLWithPath: mountPoint)
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// The per-snapshot figure: bytes gained between the two samples, never negative
    /// (something else may have written to the disk meanwhile), nil if either
    /// sample was unavailable.
    static func freed(before: Int64?, after: Int64?) -> Int64? {
        guard let before, let after else { return nil }
        return max(0, after - before)
    }

    /// What `tmutil listlocalsnapshots` reported: Time Machine's local snapshots
    /// (the only ones RepoMen manages) plus the names of every other snapshot on
    /// the volume, which RepoMen shows but never touches.
    struct Listing: Sendable, Equatable {
        let snapshots: [LocalSnapshot]
        /// Non-Time-Machine snapshot names, in listing order, deduplicated.
        let otherNames: [String]

        static let empty = Listing(snapshots: [], otherNames: [])
    }

    struct ThinResult: Sendable, Equatable {
        /// What tmutil printed (it names the snapshots it thinned, if any).
        let output: String
        /// True when the unprivileged run was refused and the admin prompt was used.
        let usedAdministratorPrivileges: Bool
    }

    // MARK: Arguments (pure)

    static var listArguments: [String] { [listVerb, mountPoint] }

    static func deleteArguments(for snapshot: LocalSnapshot) -> [String] {
        [deleteVerb, snapshot.dateToken]
    }

    /// `bytes` is clamped to at least 1, `urgency` to tmutil's 1…4.
    static func thinArguments(bytes: Int64, urgency: Int) -> [String] {
        [thinVerb, mountPoint, String(max(1, bytes)), String(clampedUrgency(urgency))]
    }

    static func clampedUrgency(_ urgency: Int) -> Int {
        min(max(urgency, urgencyRange.lowerBound), urgencyRange.upperBound)
    }

    /// Why `arguments` must not reach tmutil, or nil if they may. This whitelist IS
    /// the feature's reach: one of three verbs, each with its exact operands, always
    /// the boot volume.
    static func validate(arguments: [String]) -> String? {
        guard let verb = arguments.first else { return "no tmutil verb" }
        switch verb {
        case listVerb:
            guard arguments == [listVerb, mountPoint] else {
                return "\(listVerb) takes only the boot volume"
            }
        case deleteVerb:
            guard arguments.count == 2 else { return "\(deleteVerb) takes exactly one date" }
            guard LocalSnapshot(dateToken: arguments[1]) != nil else {
                return "not a Time Machine snapshot date"
            }
        case thinVerb:
            guard arguments.count == 4, arguments[1] == mountPoint else {
                return "\(thinVerb) takes the boot volume, an amount and an urgency"
            }
            guard let bytes = Int64(arguments[2]), bytes >= 1 else {
                return "the amount must be a positive byte count"
            }
            guard let urgency = Int(arguments[3]), urgencyRange.contains(urgency) else {
                return "the urgency must be 1–4"
            }
        default:
            return "tmutil verb \(verb) is not allowed"
        }
        return nil
    }

    // MARK: Parsing (pure)

    /// Parses `tmutil listlocalsnapshots` output: a `Snapshots for disk /:` header
    /// (older releases print none), then one snapshot name per line — Time Machine's
    /// and anyone else's. Names never contain whitespace, which is what separates
    /// them from the header. Time Machine local snapshots come back deduplicated and
    /// oldest first (the order to delete in: removing a middle snapshot frees less
    /// than expected while older ones still hold the data); every other name is
    /// kept verbatim in `otherNames`.
    static func parseListing(_ output: String) -> Listing {
        var seen = Set<String>()
        var snapshots: [LocalSnapshot] = []
        var others: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
                  seen.insert(trimmed).inserted else { continue }
            if let snapshot = LocalSnapshot(name: trimmed) {
                snapshots.append(snapshot)
            } else {
                others.append(trimmed)
            }
        }
        return Listing(snapshots: snapshots.sorted { $0.date < $1.date }, otherNames: others)
    }

    /// The Time Machine local snapshots alone (see `parseListing`).
    static func parseList(_ output: String) -> [LocalSnapshot] {
        parseListing(output).snapshots
    }

    /// Who made a snapshot RepoMen leaves alone, from its name prefix — so the
    /// pane can say "1 snapshot by Arq" instead of printing an opaque identifier.
    static func ownerLabel(forForeignName name: String) -> String {
        let lower = name.lowercased()
        if lower.hasPrefix("com.bombich.ccc") { return "Carbon Copy Cloner" }
        if lower.hasPrefix("com_haystacksoftware") || lower.hasPrefix("com.haystacksoftware") { return "Arq" }
        if lower.hasPrefix("com.apple.os.update") { return "a macOS update" }
        if lower.hasPrefix("com.apple.timemachine") { return "Time Machine (not a local snapshot)" }
        if lower.hasPrefix("com.apple.") { return "macOS" }
        return "another app"
    }

    /// Date token → status from the batch delete script's decoded output.
    /// Malformed records are dropped; their snapshots then fail safe ("no result").
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

    // MARK: Privileged fallback (pure)

    /// The same tmutil invocation as one POSIX sh line for `PrivilegedRunner`,
    /// every word single-quoted. nil for anything `validate` refuses.
    static func privilegedScript(arguments: [String]) -> String? {
        guard validate(arguments: arguments) == nil else { return nil }
        return ([SnapshotRunner.toolPath] + arguments)
            .map(PrivilegedRunner.shellQuote)
            .joined(separator: " ")
    }

    /// One admin prompt for a whole batch. Per date: `OK` (deleted) or `ERR`
    /// (tmutil failed even as root); records are `STATUS\tDATE`, NUL-separated and
    /// base64-wrapped exactly like the SystemAreas scripts. tmutil's own chatter is
    /// discarded — the verdict per date is what matters.
    static func privilegedDeleteScript(for snapshots: [LocalSnapshot]) -> String {
        let tool = PrivilegedRunner.shellQuote(SnapshotRunner.toolPath)
        var lines = ["("]
        for snapshot in snapshots {
            let q = PrivilegedRunner.shellQuote(snapshot.dateToken)
            lines.append("if \(tool) \(deleteVerb) \(q) >/dev/null 2>&1;"
                + " then printf 'OK\\t%s\\0' \(q); else printf 'ERR\\t%s\\0' \(q); fi")
        }
        lines.append(") | /usr/bin/base64")
        return lines.joined(separator: "\n")
    }

    // MARK: Operations

    /// Everything on the boot volume: Time Machine's local snapshots (oldest first)
    /// and the names of the others. Listing never needs privileges; a failure is
    /// thrown with tmutil's message.
    static func listAll(runner: Runner = SnapshotRunner.run) async throws -> Listing {
        let output = try await runner(listArguments, listTimeout)
        guard output.succeeded else { throw Failure.toolFailed(output.message) }
        return parseListing(output.stdout)
    }

    /// The Time Machine local snapshots alone, oldest first.
    static func list(runner: Runner = SnapshotRunner.run) async throws -> [LocalSnapshot] {
        try await listAll(runner: runner).snapshots
    }

    /// Deletes `snapshots` one by one (in the order given — callers pass oldest
    /// first). Failures are reported per snapshot, never thrown. Honors task
    /// cancellation between snapshots. If tmutil refuses the unprivileged delete for
    /// lack of privileges, this and every remaining snapshot go through ONE
    /// administrator prompt instead. Each successful unprivileged delete is
    /// bracketed by `freeSpace` samples (with `settle` in between) so the outcome
    /// carries what that snapshot actually freed; both are injectable for tests.
    static func delete(_ snapshots: [LocalSnapshot],
                       runner: Runner = SnapshotRunner.run,
                       adminRunner: AdminRunner = PrivilegedRunner.run,
                       freeSpace: FreeSpaceSampler = volumeFreeBytes,
                       settle: () async -> Void = {
                           try? await Task.sleep(nanoseconds: UInt64(settleAfterDelete * 1_000_000_000))
                       },
                       progress: ((_ current: Int, _ total: Int, _ snapshot: LocalSnapshot) -> Void)? = nil)
        async -> [Outcome] {
        var outcomes: [Outcome] = []
        var index = 0
        while index < snapshots.count {
            let snapshot = snapshots[index]
            if Task.isCancelled {
                outcomes += snapshots[index...].map {
                    Outcome(snapshot: $0, failure: "stopped before this snapshot was reached")
                }
                break
            }
            progress?(index + 1, snapshots.count, snapshot)
            do {
                let before = freeSpace()
                let output = try await runner(deleteArguments(for: snapshot), deleteTimeout)
                if output.succeeded {
                    await settle()
                    let freedBytes = freed(before: before, after: freeSpace())
                    Log.snapshots.info("deleted \(snapshot.name, privacy: .public), freed \(freedBytes ?? -1) bytes")
                    outcomes.append(Outcome(snapshot: snapshot, failure: nil, freedBytes: freedBytes))
                } else if output.looksLikePrivilegeFailure {
                    Log.snapshots.info("tmutil refused an unprivileged delete — retrying as administrator")
                    outcomes += await deletePrivileged(Array(snapshots[index...]), adminRunner: adminRunner)
                    break
                } else {
                    Log.snapshots.error("failed \(snapshot.name, privacy: .public): \(output.message, privacy: .public)")
                    outcomes.append(Outcome(snapshot: snapshot, failure: output.message))
                }
            } catch {
                Log.snapshots.error("failed \(snapshot.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                outcomes.append(Outcome(snapshot: snapshot, failure: error.localizedDescription))
            }
            index += 1
        }
        return outcomes
    }

    private static func deletePrivileged(_ snapshots: [LocalSnapshot],
                                         adminRunner: AdminRunner) async -> [Outcome] {
        do {
            let output = try await adminRunner(privilegedDeleteScript(for: snapshots))
            guard let records = PrivilegedRunner.decodePayload(output) else {
                throw Failure.toolFailed("The privileged delete returned unreadable output.")
            }
            let statuses = parseStatuses(records)
            return snapshots.map { snapshot -> Outcome in
                let failure: String?
                switch statuses[snapshot.dateToken] {
                case "OK": failure = nil
                case "ERR": failure = "tmutil could not delete it, even as administrator"
                default: failure = "the privileged helper reported no result"
                }
                if let failure {
                    Log.snapshots.error("failed \(snapshot.name, privacy: .public): \(failure, privacy: .public)")
                } else {
                    Log.snapshots.info("deleted \(snapshot.name, privacy: .public) (privileged)")
                }
                return Outcome(snapshot: snapshot, failure: failure)
            }
        } catch {
            let reason = (error as? PrivilegedRunner.Failure) == .cancelled
                ? "administrator authorization was cancelled"
                : error.localizedDescription
            Log.snapshots.warning("privileged delete did not run: \(reason, privacy: .public)")
            return snapshots.map { Outcome(snapshot: $0, failure: reason) }
        }
    }

    /// Asks Time Machine to thin its local snapshots on the boot volume until about
    /// `bytes` are free, at `urgency` — Apple's supported hook for the purge deleted(8)
    /// should perform on its own. Time Machine decides which snapshots go (oldest
    /// first) and may remove none. Same privilege fallback as `delete`.
    static func thin(bytes: Int64, urgency: Int,
                     runner: Runner = SnapshotRunner.run,
                     adminRunner: AdminRunner = PrivilegedRunner.run) async throws -> ThinResult {
        let arguments = thinArguments(bytes: bytes, urgency: urgency)
        let output = try await runner(arguments, thinTimeout)
        if output.succeeded {
            Log.snapshots.info("thinned local snapshots for \(bytes) bytes at urgency \(clampedUrgency(urgency))")
            return ThinResult(output: output.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                              usedAdministratorPrivileges: false)
        }
        guard output.looksLikePrivilegeFailure,
              let script = privilegedScript(arguments: arguments) else {
            Log.snapshots.error("thinning failed: \(output.message, privacy: .public)")
            throw Failure.toolFailed(output.message)
        }
        Log.snapshots.info("tmutil refused an unprivileged thin — retrying as administrator")
        do {
            let privileged = try await adminRunner(script)
            return ThinResult(output: privileged.trimmingCharacters(in: .whitespacesAndNewlines),
                              usedAdministratorPrivileges: true)
        } catch let failure as PrivilegedRunner.Failure where failure == .cancelled {
            throw Failure.cancelled
        }
    }
}
