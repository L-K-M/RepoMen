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
///   otherwise descended into, except explicitly configured roots and worktrees
///   verified through Git's reciprocal registration metadata,
/// - unambiguous artifact names that failed to anchor are skipped, generic ones
///   (`build`, `target`) are descended — they might be ordinary folders.
enum Scanner {

    /// Directories never worth entering regardless of rules.
    private static let alwaysSkip: Set<String> = [".git", ".svn", ".hg", ".trash"]

    /// The real user Library: the deep scan never enters it, whatever the configured
    /// roots say — `KnownCaches` owns the reclaimable spots under it, and everything
    /// else there (Containers, Mail, Application Support) is app data that can look
    /// exactly like a build artifact (an app-shipped node_modules with its
    /// package.json). PLAN.md's "never enters ~/Library/Containers", enforced.
    private static let userLibraryPath = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent("Library").path

    /// Synchronous walk — call from a background task; honors `Task` cancellation.
    /// `progress` is invoked on the walking thread with the directory being visited.
    static func scan(_ config: ScanConfiguration,
                     fileManager: FileManager = .default,
                     progress: ((String) -> Void)? = nil) -> [CleanableItem] {
        var items: [CleanableItem] = []
        var visited = Set<String>()
        var effectiveConfig = config
        effectiveConfig.excludedPaths = Set(config.excludedPaths.map {
            canonicalRoot(URL(fileURLWithPath: $0)).path
        })
        let scopeRoots = config.roots.map(canonicalRoot)
        for root in normalizedRoots(scopeRoots) {
            guard scanRootDepth(root, scopeRoots: scopeRoots, config: effectiveConfig,
                                fileManager: fileManager) != nil else { continue }
            walk(directory: root, depth: 0, scopeRoots: scopeRoots, config: effectiveConfig,
                 fileManager: fileManager, progress: progress, visited: &visited, into: &items)
            if Task.isCancelled { break }
        }
        return items
    }

    /// Drops duplicate roots and ordinary nested roots. An explicit root beneath a
    /// hidden directory must survive because the outer walk cannot reach it.
    /// Existing paths are canonicalized to their true on-disk
    /// spelling first, so case-variant duplicates on (default, case-insensitive) APFS
    /// collapse too — item ids are paths, and one physical folder must yield one id.
    static func normalizedRoots(_ roots: [URL]) -> [URL] {
        let canonical = roots.map(canonicalRoot)
        var seen = Set<String>()
        return canonical.filter { candidate in
            guard seen.insert(candidate.path).inserted else { return false }
            return !canonical.contains { other in
                other.path != candidate.path
                    && candidate.path.hasPrefix(other.path + "/")
                    && !hasHiddenComponent(candidate, below: other)
            }
        }
    }

    private static func walk(directory: URL,
                             depth: Int,
                             scopeRoots: [URL],
                             config: ScanConfiguration,
                             fileManager: FileManager,
                             progress: ((String) -> Void)?,
                             visited: inout Set<String>,
                             into items: inout [CleanableItem]) {
        guard depth <= config.maxDepth, !Task.isCancelled,
              visited.insert(directory.path).inserted else { return }
        progress?(directory.path)

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
                                      .isHiddenKey]
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: []) else { return }

        let siblingNames = Set(children.map { $0.lastPathComponent })
        let parentName = directory.lastPathComponent

        if siblingNames.contains(".git") {
            for worktree in GitWorktrees.registeredWorktrees(in: directory, fileManager: fileManager) {
                guard !visited.contains(worktree.path),
                      let worktreeDepth = scanRootDepth(worktree, scopeRoots: scopeRoots,
                                                       config: config, fileManager: fileManager) else { continue }
                walk(directory: worktree, depth: worktreeDepth, scopeRoots: scopeRoots, config: config,
                     fileManager: fileManager, progress: progress, visited: &visited, into: &items)
            }
        }

        for child in children {
            guard !Task.isCancelled else { return }
            let values = try? child.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }

            let name = child.lastPathComponent
            let childPath = child.path
            guard !alwaysSkip.contains(name.lowercased()), values?.isPackage != true,
                  !isExcluded(childPath, config: config),
                  childPath != userLibraryPath else { continue }

            if let match = RuleCatalog.match(
                directoryName: name,
                parentPath: directory.path,
                siblingNames: siblingNames,
                contents: { namesInside(child, fileManager: fileManager) },
                enabledKinds: config.enabledKinds,
                cacheTagIsValid: { CacheDirectoryTag.isValid(in: child) }) {
                items.append(CleanableItem(
                    label: "\(parentName)/\(name)",
                    kind: match.rule.kind,
                    path: childPath,
                    anchorPaths: match.anchorPaths,
                    isKnownCache: false))
                continue    // the whole artifact is one item — never descend into it
            }

            guard shouldDescend(into: name, isPackage: values?.isPackage == true,
                                isHidden: values?.isHidden == true) else { continue }
            walk(directory: child, depth: depth + 1, scopeRoots: scopeRoots, config: config,
                 fileManager: fileManager, progress: progress, visited: &visited, into: &items)
        }
    }

    private static func shouldDescend(into name: String, isPackage: Bool,
                                      isHidden: Bool) -> Bool {
        if isPackage { return false }
        if alwaysSkip.contains(name.lowercased()) { return false }
        if RuleCatalog.neverDescend.contains(name) { return false }
        if name.hasPrefix(".") { return false }   // catalog rules for hidden names ran above
        if isHidden { return false }   // flag-hidden trees (~/Library) are equally out of scope
        return true
    }

    // MARK: - Scan root admission

    /// Git can register a path anywhere. It only grants access to a hidden worktree
    /// within the configured roots, without bypassing exclusions, depth or any
    /// package/artifact/protected ancestor that the ordinary walk would prune.
    private static func scanRootDepth(_ directory: URL, scopeRoots: [URL],
                                      config: ScanConfiguration, fileManager: FileManager) -> Int? {
        guard !PathGuards.isUnder(directory.path, root: userLibraryPath),
              !isExcluded(directory.path, config: config),
              GitWorktrees.hasNoSymlinkComponents(directory) else { return nil }
        let depths = scopeRoots.filter { PathGuards.isUnder(directory.path, root: $0.path) }
            .map { directory.pathComponents.count - $0.pathComponents.count }
        guard let depth = depths.min(), depth <= config.maxDepth else { return nil }

        var ancestor = directory
        while ancestor.path != "/" {
            let name = ancestor.lastPathComponent
            guard !alwaysSkip.contains(name.lowercased()), !RuleCatalog.neverDescend.contains(name),
                  let values = try? ancestor.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                  values.isDirectory == true, values.isPackage != true else { return nil }
            let parent = ancestor.deletingLastPathComponent()
            if RuleCatalog.match(
                directoryName: name, parentPath: parent.path,
                siblingNames: namesInside(parent, fileManager: fileManager),
                contents: { namesInside(ancestor, fileManager: fileManager) },
                enabledKinds: config.enabledKinds,
                cacheTagIsValid: { CacheDirectoryTag.isValid(in: ancestor) }) != nil { return nil }
            ancestor = parent
        }
        return depth
    }

    private static func isExcluded(_ path: String, config: ScanConfiguration) -> Bool {
        config.excludedPaths.contains { PathGuards.isUnder(path, root: $0) }
    }

    private static func canonicalRoot(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if let path = (try? standardized.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath {
            return URL(fileURLWithPath: path)
        }
        return standardized   // nonexistent paths keep their given spelling
    }

    private static func hasHiddenComponent(_ directory: URL, below root: URL) -> Bool {
        var current = directory
        while current.path != root.path {
            if current.lastPathComponent.hasPrefix(".")
                || (try? current.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true { return true }
            current.deleteLastPathComponent()
        }
        return false
    }

    private static func namesInside(_ url: URL, fileManager: FileManager) -> Set<String> {
        Set((try? fileManager.contentsOfDirectory(atPath: url.path)) ?? [])
    }
}
