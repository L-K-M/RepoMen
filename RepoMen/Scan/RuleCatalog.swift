import Foundation

/// How a directory proves it is a regenerable build artifact.
enum Anchor: Hashable, Sendable {
    /// A sibling entry with exactly this name (e.g. `Cargo.toml`).
    case sibling(String)
    /// A sibling entry whose name ends in this suffix (e.g. `.xcodeproj`).
    case siblingSuffix(String)
}

/// One anchor-based detection rule. A directory is reported only when its name matches
/// AND at least one anchor holds — that's what keeps a random folder called `build`
/// safe from us (see PLAN.md's trust model).
struct ProjectArtifactRule: Sendable {
    let kind: ArtifactKind
    /// Exact directory names this rule applies to.
    let directoryNames: Set<String>
    /// Prefix-matched directory names (CLion's `cmake-build-<profile>`).
    let directoryNamePrefixes: [String]
    /// Any-of anchors that must exist NEXT TO the directory. Empty means the name
    /// alone is unambiguous (`__pycache__`) or an inner anchor decides.
    let anchors: [Anchor]
    /// Any-of entry names that must exist INSIDE the directory (`pyvenv.cfg`,
    /// `CMakeCache.txt`). Empty means no content check.
    let innerAnchors: [String]

    init(kind: ArtifactKind,
         directoryNames: Set<String>,
         directoryNamePrefixes: [String] = [],
         anchors: [Anchor] = [],
         innerAnchors: [String] = []) {
        self.kind = kind
        self.directoryNames = directoryNames
        self.directoryNamePrefixes = directoryNamePrefixes
        self.anchors = anchors
        self.innerAnchors = innerAnchors
    }

    func appliesTo(directoryName: String) -> Bool {
        directoryNames.contains(directoryName)
            || directoryNamePrefixes.contains { directoryName.hasPrefix($0) }
    }
}

/// The data-driven catalog of project-artifact rules, plus the pure matching logic
/// (unit-tested; the `Scanner` only walks and feeds it directory listings).
enum RuleCatalog {

    static let rules: [ProjectArtifactRule] = [
        .init(kind: .rustTarget, directoryNames: ["target"],
              anchors: [.sibling("Cargo.toml")]),
        .init(kind: .nodeModules, directoryNames: ["node_modules"],
              anchors: [.sibling("package.json")]),
        .init(kind: .jsBuildOutput,
              directoryNames: [".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit",
                               ".angular", ".astro", ".expo", ".docusaurus", ".output",
                               ".cache"],
              anchors: [.sibling("package.json")]),
        .init(kind: .swiftPMBuild, directoryNames: [".build"],
              anchors: [.sibling("Package.swift")]),
        .init(kind: .xcodeBuild, directoryNames: ["build", "DerivedData"],
              anchors: [.siblingSuffix(".xcodeproj"), .siblingSuffix(".xcworkspace")]),
        .init(kind: .cocoaPods, directoryNames: ["Pods"],
              anchors: [.sibling("Podfile")]),
        .init(kind: .gradleBuild, directoryNames: ["build", ".gradle"],
              anchors: [.sibling("build.gradle"), .sibling("build.gradle.kts"),
                        .sibling("settings.gradle"), .sibling("settings.gradle.kts")]),
        .init(kind: .mavenTarget, directoryNames: ["target"],
              anchors: [.sibling("pom.xml")]),
        .init(kind: .flutterBuild, directoryNames: ["build", ".dart_tool"],
              anchors: [.sibling("pubspec.yaml")]),
        .init(kind: .pythonCache,
              directoryNames: ["__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"]),
        .init(kind: .pythonCache, directoryNames: [".tox"],
              anchors: [.sibling("tox.ini"), .sibling("setup.py"), .sibling("pyproject.toml")]),
        .init(kind: .pythonVenv, directoryNames: [".venv", "venv"],
              innerAnchors: ["pyvenv.cfg"]),
        .init(kind: .cmakeBuild, directoryNames: ["build", "out"],
              directoryNamePrefixes: ["cmake-build-"],
              innerAnchors: ["CMakeCache.txt"]),
        .init(kind: .dotnetBuild, directoryNames: ["bin", "obj"],
              anchors: [.siblingSuffix(".csproj"), .siblingSuffix(".fsproj")]),
        .init(kind: .elixirBuild, directoryNames: ["_build", "deps"],
              anchors: [.sibling("mix.exs")]),
        .init(kind: .haskellBuild, directoryNames: [".stack-work"],
              anchors: [.sibling("stack.yaml")]),
        .init(kind: .haskellBuild, directoryNames: ["dist-newstyle"],
              anchors: [.siblingSuffix(".cabal")]),
        .init(kind: .zigBuild, directoryNames: ["zig-cache", ".zig-cache", "zig-out"],
              anchors: [.sibling("build.zig")]),
        // `vendor` is a generic name: without one of these anchors it might hold real,
        // hand-vendored code — so the anchor is the whole safety story here.
        .init(kind: .phpVendor, directoryNames: ["vendor"],
              anchors: [.sibling("composer.json")]),
        .init(kind: .goVendor, directoryNames: ["vendor"],
              anchors: [.sibling("go.mod")]),
    ]

    /// Directory names that are always build debris and never worth descending into,
    /// even when no anchor matched (an orphan `node_modules` is still not interesting
    /// to walk). Generic names (`build`, `target`) are deliberately NOT here — without
    /// an anchor they might be ordinary folders holding real projects.
    static let neverDescend: Set<String> = [
        "node_modules", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
        ".tox", ".build", ".dart_tool", ".stack-work", "dist-newstyle", ".next",
        ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit", ".angular", ".astro",
        ".expo", ".docusaurus", ".output", ".cache", "zig-cache",
        ".zig-cache", ".venv", "venv", "Pods", ".gradle",
    ]

    /// Names that match on the name alone (no anchors at all) — the reclaimer's
    /// fallback verification for items without anchor paths.
    static func isUnambiguousArtifactName(_ name: String) -> Bool {
        rules.contains { $0.anchors.isEmpty && $0.innerAnchors.isEmpty && $0.appliesTo(directoryName: name) }
    }

    /// A successful match: the rule plus the concrete anchor paths that proved it
    /// (re-verified by `Reclaimer` before anything is deleted).
    struct Match: Sendable {
        let rule: ProjectArtifactRule
        let anchorPaths: [String]
    }

    /// Pure matching for one directory. `siblingNames` are the names in the parent
    /// directory (including the directory itself); `contents` lazily lists the names
    /// inside the directory, only consulted when a candidate rule has inner anchors.
    static func match(directoryName: String,
                      parentPath: String,
                      siblingNames: Set<String>,
                      contents: () -> Set<String>,
                      enabledKinds: Set<ArtifactKind>) -> Match? {
        var innerNames: Set<String>?
        for rule in rules where rule.appliesTo(directoryName: directoryName) {
            guard enabledKinds.contains(rule.kind) else { continue }

            var anchorPaths: [String] = []
            if !rule.anchors.isEmpty {
                for anchor in rule.anchors {
                    switch anchor {
                    case .sibling(let name):
                        if siblingNames.contains(name) {
                            anchorPaths.append(parentPath + "/" + name)
                        }
                    case .siblingSuffix(let suffix):
                        for sibling in siblingNames where sibling.hasSuffix(suffix) {
                            anchorPaths.append(parentPath + "/" + sibling)
                        }
                    }
                }
                guard !anchorPaths.isEmpty else { continue }
            }

            if !rule.innerAnchors.isEmpty {
                let names = innerNames ?? contents()
                innerNames = names   // list the directory once, however many rules ask
                let present = rule.innerAnchors.filter { names.contains($0) }
                guard !present.isEmpty else { continue }
                anchorPaths.append(contentsOf: present.map { parentPath + "/" + directoryName + "/" + $0 })
            }

            // A rule with neither anchors nor inner anchors matches on name alone
            // (unambiguous names like __pycache__): anchorPaths stays empty and the
            // reclaimer falls back to re-checking the name.
            return Match(rule: rule, anchorPaths: anchorPaths)
        }
        return nil
    }
}
