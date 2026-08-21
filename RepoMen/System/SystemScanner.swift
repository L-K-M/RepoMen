import Foundation

/// Detection for `SystemAreas`: one privileged probe (one admin-password prompt)
/// lists each catalog root's direct child directories with their allocated size and
/// newest-activity timestamp; the parser turns validated records into ready-measured
/// `CleanableItem`s. Items arrive with `isMeasured == true` because the ordinary
/// `DirectorySizer` cannot read root-owned trees — the probe measures while it can.
/// Parsing is pure and separated from the privileged run, so tests cover everything
/// except the password dialog itself.
enum SystemScanner {

    /// POSIX sh (`do shell script` runs /bin/sh). One record per direct child
    /// directory of each catalog root: `<kilobytes>\t<mtime epoch>\t<absolute
    /// path>`, records NUL-separated, the whole stream base64-encoded so arbitrary
    /// filename bytes survive the AppleScript round-trip intact.
    ///
    /// Size is `du -sk` (allocated blocks — the same "what deleting frees" a
    /// `DirectorySizer` walk estimates). The timestamp is the newest modification
    /// within the top two levels (`find -maxdepth 2`): appends don't bump a
    /// directory's own mtime, but rtcreportingd keeps creating timestamped log
    /// files, so two levels track "last active" without a second full deep walk.
    /// Symlinked children are skipped, exactly like the ordinary `Scanner`.
    static var probeScript: String {
        let roots = SystemAreas.roots.map { PrivilegedRunner.shellQuote($0.path) }
            .joined(separator: " ")
        return """
        (for r in \(roots); do
        [ -d "$r" ] || continue
        for c in "$r"/* "$r"/.[!.]* "$r"/..?*; do
        [ -d "$c" ] || continue
        [ -L "$c" ] && continue
        k=$(du -sk "$c" 2>/dev/null | cut -f1)
        m=$(find "$c" -maxdepth 2 -exec stat -f %m {} + 2>/dev/null | sort -rn | head -n 1)
        printf '%s\\t%s\\t%s\\0' "${k:-0}" "${m:-0}" "$c"
        done
        done) | /usr/bin/base64
        """
    }

    /// Runs the probe with administrator privileges and returns the items found.
    /// `runner` is injected so tests never spawn osascript.
    static func scan(excludedPaths: Set<String>,
                     enabledKinds: Set<ArtifactKind>,
                     isRunning: (String) -> Bool,
                     runner: (String) async throws -> String = PrivilegedRunner.run)
        async throws -> [CleanableItem] {
        let output = try await runner(probeScript)
        guard let records = PrivilegedRunner.decodePayload(output) else {
            throw PrivilegedRunner.Failure.failed("The system probe returned unreadable output.")
        }
        return items(fromRecords: records, excludedPaths: excludedPaths,
                     enabledKinds: enabledKinds, isRunning: isRunning)
    }

    /// Pure record parser. Every path is re-validated against the catalog —
    /// a malformed, duplicate, or out-of-catalog record is dropped, never surfaced.
    static func items(fromRecords records: Data,
                      excludedPaths: Set<String>,
                      enabledKinds: Set<ArtifactKind>,
                      isRunning: (String) -> Bool) -> [CleanableItem] {
        var items: [CleanableItem] = []
        var seenPaths = Set<String>()
        for record in records.split(separator: 0) {
            guard let text = String(data: record, encoding: .utf8) else { continue }
            // The path is the LAST field and may itself contain tabs — split at
            // most twice so it comes through whole.
            let fields = text.split(separator: "\t", maxSplits: 2,
                                    omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let path = String(fields[2])
            guard SystemAreas.validate(path: path) == nil,
                  let root = SystemAreas.root(containing: path),
                  enabledKinds.contains(root.kind),
                  !excludedPaths.contains(path),
                  seenPaths.insert(path).inserted else { continue }
            let name = URL(fileURLWithPath: path).lastPathComponent
            let epoch = Int64(fields[1]) ?? 0
            items.append(CleanableItem(
                label: "\(root.labelPrefix) · \(name)",
                kind: root.kind,
                path: path,
                anchorPaths: [],
                isKnownCache: true,
                sizeBytes: 1024 * (Int64(fields[0]) ?? 0),
                isMeasured: true,
                lastModified: epoch > 0 ? Date(timeIntervalSince1970: TimeInterval(epoch))
                                        : .distantPast,
                warning: SystemAreas.culpritWarning(childName: name, isRunning: isRunning),
                isSystemArea: true))
        }
        return items
    }
}
