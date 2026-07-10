import Foundation
import Combine

/// App-wide settings, persisted to `UserDefaults` and observable by SwiftUI.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults: UserDefaults

    private enum Key {
        static let scanRoots = "scanRoots"
        static let excludedPaths = "excludedPaths"
        static let moveToTrash = "moveToTrash"
        static let idleDays = "idleDays"
        static let disabledKinds = "disabledKinds"
    }

    /// Folders whose trees are deep-scanned for project artifacts (absolute paths).
    @Published var scanRoots: [String] {
        didSet { defaults.set(scanRoots, forKey: Key.scanRoots) }
    }

    /// Paths the user told us to never suggest again (absolute paths).
    @Published var excludedPaths: [String] {
        didSet { defaults.set(excludedPaths, forKey: Key.excludedPaths) }
    }

    /// Reclaim by moving to the Trash (default, reversible) instead of deleting.
    @Published var moveToTrash: Bool {
        didSet { defaults.set(moveToTrash, forKey: Key.moveToTrash) }
    }

    /// Age threshold (days) used by the "Select idle" quick action.
    @Published var idleDays: Int {
        didSet { defaults.set(idleDays, forKey: Key.idleDays) }
    }

    /// Kinds the user switched off in Settings → Rules (raw values).
    @Published var disabledKinds: Set<String> {
        didSet { defaults.set(Array(disabledKinds).sorted(), forKey: Key.disabledKinds) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.scanRoots = defaults.stringArray(forKey: Key.scanRoots)
            ?? Self.defaultScanRoots()
        self.excludedPaths = defaults.stringArray(forKey: Key.excludedPaths) ?? []
        self.moveToTrash = defaults.object(forKey: Key.moveToTrash) as? Bool ?? true
        self.idleDays = defaults.object(forKey: Key.idleDays) as? Int ?? 30
        self.disabledKinds = Set(defaults.stringArray(forKey: Key.disabledKinds) ?? [])
    }

    var enabledKinds: Set<ArtifactKind> {
        Set(ArtifactKind.allCases.filter { !disabledKinds.contains($0.rawValue) })
    }

    func isEnabled(_ kind: ArtifactKind) -> Bool {
        !disabledKinds.contains(kind.rawValue)
    }

    func setEnabled(_ enabled: Bool, kind: ArtifactKind) {
        if enabled {
            disabledKinds.remove(kind.rawValue)
        } else {
            disabledKinds.insert(kind.rawValue)
        }
    }

    /// The dev folders people actually use, filtered to those that exist — so a first
    /// scan finds code without any setup. Users refine the list in Settings → Folders.
    static func defaultScanRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 fileManager: FileManager = .default) -> [String] {
        let candidates = [
            "Documents/GitHub", "Documents/GitLab", "Developer", "Projects", "projects",
            "Code", "code", "src", "repos", "git", "work", "dev",
        ]
        var roots: [String] = []
        var seenCanonical = Set<String>()
        for candidate in candidates {
            let url = home.appendingPathComponent(candidate)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            // fileExists is case-insensitive on default APFS, so probing "Projects"
            // AND "projects" finds the same physical folder twice — which used to
            // double every scan result. Dedupe on (and keep) the on-disk spelling.
            let canonical = (try? url.resourceValues(forKeys: [.canonicalPathKey]))?
                .canonicalPath ?? url.path
            guard seenCanonical.insert(canonical).inserted else { continue }
            roots.append(canonical)
        }
        // No recognizable dev folder: fall back to ~/Documents rather than nothing.
        if roots.isEmpty {
            let documents = home.appendingPathComponent("Documents")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: documents.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                roots.append(documents.path)
            }
        }
        return roots
    }
}
