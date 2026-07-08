import Foundation

/// Everything a scan needs, snapshotted up front so the walk runs detached from the UI.
struct ScanConfiguration: Sendable {
    var roots: [URL]
    var excludedPaths: Set<String>
    var enabledKinds: Set<ArtifactKind>
    /// Levels below each root; deep enough for monorepos, a stop for pathological trees.
    var maxDepth: Int = 16
}

/// Walks the configured dev roots and reports every directory the `RuleCatalog`
/// recognizes as a regenerable build artifact. Discovery only — sizes are measured
/// separately (`DirectorySizer`) so results appear immediately.
///
/// Walk rules (the "find more, risk less" contract — see PLAN.md):
/// - never follows symlinks, never enters file packages (`.app`, `.photoslibrary`, …),
/// - a matched artifact is one item; we never descend into it,
/// - hidden directories are checked against the catalog (`.build`, `.venv`, …) but not
///   otherwise descended into (`.git` alone would dwarf the rest of the walk),
/// - unambiguous artifact names that failed to anchor are skipped, generic ones
///   (`build`, `target`) are descended — they might be ordinary folders.
enum Scanner {

    /// Directories never worth entering regardless of rules.
    private static let alwaysSkip: Set<String> = [".git", ".svn", ".hg", ".Trash"]

    /// Synchronous walk — call from a background task; honors `Task` cancellation.
    /// `progress` is invoked on the walking thread with the directory being visited.
    static func scan(_ config: ScanConfiguration,
                     fileManager: FileManager = .default,
                     progress: ((String) -> Void)? = nil) -> [CleanableItem] {
        var items: [CleanableItem] = []
        for root in normalizedRoots(config.roots) {
            walk(directory: root, depth: 0, config: config,
                 fileManager: fileManager, progress: progress, into: &items)
            if Task.isCancelled { break }
        }
        return items
    }

    /// Drops roots nested inside other roots so nothing is scanned (or reported) twice.
    static func normalizedRoots(_ roots: [URL]) -> [URL] {
        let standardized = roots.map { $0.standardizedFileURL }
        return standardized.filter { candidate in
            !standardized.contains { other in
                other.path != candidate.path
                    && candidate.path.hasPrefix(other.path + "/")
            }
        }
    }

    private static func walk(directory: URL,
                             depth: Int,
                             config: ScanConfiguration,
                             fileManager: FileManager,
                             progress: ((String) -> Void)?,
                             into items: inout [CleanableItem]) {
        guard depth <= config.maxDepth, !Task.isCancelled else { return }
        progress?(directory.path)

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: []) else { return }

        let siblingNames = Set(children.map { $0.lastPathComponent })
        let parentName = directory.lastPathComponent

        for child in children {
            guard !Task.isCancelled else { return }
            let values = try? child.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }

            let name = child.lastPathComponent
            let childPath = child.path
            guard !config.excludedPaths.contains(childPath) else { continue }

            if let match = RuleCatalog.match(
                directoryName: name,
                parentPath: directory.path,
                siblingNames: siblingNames,
                contents: { namesInside(child, fileManager: fileManager) },
                enabledKinds: config.enabledKinds) {
                items.append(CleanableItem(
                    label: "\(parentName)/\(name)",
                    kind: match.rule.kind,
                    path: childPath,
                    anchorPaths: match.anchorPaths,
                    isKnownCache: false))
                continue    // the whole artifact is one item — never descend into it
            }

            guard shouldDescend(into: name, isPackage: values?.isPackage == true) else { continue }
            walk(directory: child, depth: depth + 1, config: config,
                 fileManager: fileManager, progress: progress, into: &items)
        }
    }

    private static func shouldDescend(into name: String, isPackage: Bool) -> Bool {
        if isPackage { return false }
        if alwaysSkip.contains(name) { return false }
        if RuleCatalog.neverDescend.contains(name) { return false }
        if name.hasPrefix(".") { return false }   // catalog rules for hidden names ran above
        return true
    }

    private static func namesInside(_ url: URL, fileManager: FileManager) -> Set<String> {
        Set((try? fileManager.contentsOfDirectory(atPath: url.path)) ?? [])
    }
}
