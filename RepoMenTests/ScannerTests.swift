import XCTest
@testable import RepoMen

/// Integration tests for the walk itself, against a synthetic project tree in a temp
/// directory — the pruning/descend policy is where deep-scan bugs would live.
final class ScannerTests: XCTestCase {

    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        // Resolved, because the scanner canonicalizes its roots: on macOS the temp
        // dir is /var/folders/…, a symlink to /private/var/folders/…, and expected
        // paths built from the unresolved spelling never match what the scan reports.
        root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("RepoMenScannerTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        if let path = try root.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            root = URL(fileURLWithPath: path)
        }
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    private func make(dirs: [String], files: [String]) throws {
        for dir in dirs {
            try fileManager.createDirectory(at: root.appendingPathComponent(dir),
                                            withIntermediateDirectories: true)
        }
        for file in files {
            let url = root.appendingPathComponent(file)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    private func scan(exclude: Set<String> = []) -> [CleanableItem] {
        Scanner.scan(ScanConfiguration(
            roots: [root],
            excludedPaths: exclude,
            enabledKinds: Set(ArtifactKind.allCases)))
    }

    /// Mirrors Git's reciprocal registration: the common directory names the
    /// worktree's `.git` file, and that file names its administrative directory.
    private func registerWorktree(_ relativePath: String,
                                  commonDirectory: String = "project/.git",
                                  name: String = "editor") throws {
        let worktree = root.appendingPathComponent(relativePath)
        let registration = root.appendingPathComponent(commonDirectory)
            .appendingPathComponent("worktrees/\(name)")
        try make(dirs: [relativePath, commonDirectory + "/worktrees/\(name)"], files: [])
        try Data("gitdir: \(registration.path)\n".utf8)
            .write(to: worktree.appendingPathComponent(".git"))
        try Data("\(worktree.appendingPathComponent(".git").path)\n".utf8)
            .write(to: registration.appendingPathComponent("gitdir"))
        try Data("../..\n".utf8).write(to: registration.appendingPathComponent("commondir"))
    }

    func testFindsRegisteredHiddenWorktreesWithoutEnteringOtherHiddenTrees() throws {
        try registerWorktree("project/.claude/worktrees/editor")
        try make(dirs: ["project/.claude/worktrees/editor/.build",
                        "project/.claude/unregistered/.build",
                        "project/.git/nested/.build"],
                 files: ["project/.claude/worktrees/editor/Package.swift",
                         "project/.claude/unregistered/Package.swift",
                         "project/.git/nested/Package.swift"])

        XCTAssertEqual(scan().map(\.path),
                       [root.appendingPathComponent("project/.claude/worktrees/editor/.build").path])
    }

    func testFindsOtherHiddenWorktreesFromALinkedWorktree() throws {
        try registerWorktree("linked", name: "linked")
        try registerWorktree("linked/.claude/worktrees/editor")
        try make(dirs: ["linked/.claude/worktrees/editor/.build"],
                 files: ["linked/.claude/worktrees/editor/Package.swift"])
        let found = Scanner.scan(ScanConfiguration(
            roots: [root.appendingPathComponent("linked")], excludedPaths: [],
            enabledKinds: Set(ArtifactKind.allCases)))

        XCTAssertEqual(found.map(\.path),
                       [root.appendingPathComponent("linked/.claude/worktrees/editor/.build").path])
    }

    func testHiddenWorktreeDiscoveryStaysWithinConfiguredRoots() throws {
        try registerWorktree("outside/.hidden/editor")
        try make(dirs: ["outside/.hidden/editor/.build"],
                 files: ["outside/.hidden/editor/Package.swift"])
        let found = Scanner.scan(ScanConfiguration(
            roots: [root.appendingPathComponent("project")], excludedPaths: [],
            enabledKinds: Set(ArtifactKind.allCases)))

        XCTAssertTrue(found.isEmpty)
    }

    func testHiddenWorktreeDiscoveryHonorsExcludedAncestorsAndRoot() throws {
        try registerWorktree("project/.claude/worktrees/editor")
        try make(dirs: ["project/.claude/worktrees/editor/.build"],
                 files: ["project/.claude/worktrees/editor/Package.swift"])

        for excluded in ["project", "project/.claude", "project/.claude/worktrees/editor"] {
            XCTAssertTrue(scan(exclude: [root.appendingPathComponent(excluded).path]).isEmpty,
                          "excluded ancestor: \(excluded)")
        }
    }

    func testHiddenWorktreeDiscoveryRejectsStaleAndForgedRegistrations() throws {
        try registerWorktree("project/.hidden/editor")
        try make(dirs: ["project/.hidden/editor/.build"],
                 files: ["project/.hidden/editor/Package.swift"])
        let gitFile = root.appendingPathComponent("project/.hidden/editor/.git")
        try Data("gitdir: /unrelated/metadata\n".utf8).write(to: gitFile)
        XCTAssertTrue(scan().isEmpty, "the worktree must point back to its registration")

        try fileManager.removeItem(at: gitFile)
        XCTAssertTrue(scan().isEmpty, "a stale registration does not authorize hidden traversal")
    }

    func testHiddenWorktreeDiscoveryAcceptsRelativePointersAndRejectsWrongCommonDirectory() throws {
        try registerWorktree("project/.claude/worktrees/editor")
        try make(dirs: ["project/.claude/worktrees/editor/.build"],
                 files: ["project/.claude/worktrees/editor/Package.swift"])
        let gitFile = root.appendingPathComponent("project/.claude/worktrees/editor/.git")
        let registration = root.appendingPathComponent("project/.git/worktrees/editor")
        try Data("gitdir: ../../../.git/worktrees/editor\n".utf8).write(to: gitFile)
        try Data("../../../.claude/worktrees/editor/.git\n".utf8)
            .write(to: registration.appendingPathComponent("gitdir"))
        XCTAssertEqual(scan().count, 1)

        try Data("../../..\n".utf8).write(to: registration.appendingPathComponent("commondir"))
        XCTAssertTrue(scan().isEmpty, "commondir must identify this registration's Git common directory")
    }

    func testHiddenWorktreeDiscoveryRejectsSymlinkedRegistrationDirectories() throws {
        try registerWorktree("project/.hidden/editor")
        try make(dirs: ["project/.hidden/editor/.build"],
                 files: ["project/.hidden/editor/Package.swift"])
        let registration = root.appendingPathComponent("project/.git/worktrees/editor")
        let moved = root.appendingPathComponent("moved-registration")
        try fileManager.moveItem(at: registration, to: moved)
        try fileManager.createSymbolicLink(at: registration, withDestinationURL: moved)

        XCTAssertTrue(scan().isEmpty)
    }

    func testHiddenWorktreeDiscoveryRejectsSymlinkedMetadataAndPaths() throws {
        try registerWorktree("real/editor")
        try make(dirs: ["real/editor/.build"], files: ["real/editor/Package.swift"])
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("project/.hidden"),
                                          withDestinationURL: root.appendingPathComponent("real"))
        let registration = root.appendingPathComponent("project/.git/worktrees/editor")
        let linkedGitFile = root.appendingPathComponent("project/.hidden/editor/.git")
        try Data("\(linkedGitFile.path)\n".utf8)
            .write(to: registration.appendingPathComponent("gitdir"))

        // Scan only project so the real, visible directory is out of scope.
        let config = ScanConfiguration(roots: [root.appendingPathComponent("project")],
                                      excludedPaths: [], enabledKinds: Set(ArtifactKind.allCases))
        XCTAssertTrue(Scanner.scan(config).isEmpty)

        try fileManager.removeItem(at: root.appendingPathComponent("project/.hidden"))
        try registerWorktree("project/.hidden/editor")
        try make(dirs: ["project/.hidden/editor/.build"],
                 files: ["project/.hidden/editor/Package.swift"])
        let gitFile = root.appendingPathComponent("project/.hidden/editor/.git")
        try fileManager.moveItem(at: gitFile, to: root.appendingPathComponent("git-pointer"))
        try fileManager.createSymbolicLink(at: gitFile,
                                          withDestinationURL: root.appendingPathComponent("git-pointer"))
        XCTAssertTrue(Scanner.scan(config).isEmpty)
    }

    func testHiddenWorktreeDiscoveryNeverEntersPackagesOrArtifacts() throws {
        for (index, ancestor) in ["bundle.app", ".git", ".Trash", "node_modules", "target"].enumerated() {
            try registerWorktree("project/\(ancestor)/.hidden/editor", name: "editor\(index)")
            try make(dirs: ["project/\(ancestor)/.hidden/editor/.build"],
                     files: ["project/\(ancestor)/.hidden/editor/Package.swift"])
        }
        try make(dirs: [], files: ["project/Cargo.toml", "project/package.json"])

        let found = scan()
        XCTAssertFalse(found.contains { $0.path.hasSuffix("/editor/.build") })
        XCTAssertEqual(Set(found.map(\.kind)), [.rustTarget, .nodeModules])
    }

    func testHiddenWorktreeDiscoveryHonorsDepthCap() throws {
        try registerWorktree("project/.claude/worktrees/editor")
        try make(dirs: ["project/.claude/worktrees/editor/.build"],
                 files: ["project/.claude/worktrees/editor/Package.swift"])
        let found = Scanner.scan(ScanConfiguration(
            roots: [root], excludedPaths: [], enabledKinds: Set(ArtifactKind.allCases), maxDepth: 3))
        XCTAssertTrue(found.isEmpty)

        let worktree = root.appendingPathComponent("project/.claude/worktrees/editor")
        let explicit = Scanner.scan(ScanConfiguration(
            roots: [root, worktree], excludedPaths: [],
            enabledKinds: Set(ArtifactKind.allCases), maxDepth: 0))
        XCTAssertEqual(explicit.map(\.path), [worktree.appendingPathComponent(".build").path])
    }

    func testExplicitNestedHiddenRootIsScannedAndResultsAreUnique() throws {
        try registerWorktree("project/.claude/worktrees/editor")
        try make(dirs: ["project/.claude/worktrees/editor/.build", "project/visible/.build"],
                 files: ["project/.claude/worktrees/editor/Package.swift", "project/visible/Package.swift"])
        let worktree = root.appendingPathComponent("project/.claude/worktrees/editor")
        let found = Scanner.scan(ScanConfiguration(
            roots: [root, worktree, root.appendingPathComponent("project/visible")],
            excludedPaths: [], enabledKinds: Set(ArtifactKind.allCases)))

        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Set(found.map(\.path)).count, 2)
        XCTAssertTrue(found.contains { $0.path == worktree.appendingPathComponent(".build").path })
    }

    func testExplicitNestedHiddenRootDoesNotRequireRegistration() throws {
        try make(dirs: ["project/.hidden/editor/.build"],
                 files: ["project/.hidden/editor/Package.swift"])
        let worktree = root.appendingPathComponent("project/.hidden/editor")
        let found = Scanner.scan(ScanConfiguration(
            roots: [root, worktree], excludedPaths: [], enabledKinds: Set(ArtifactKind.allCases)))

        XCTAssertEqual(found.map(\.path), [worktree.appendingPathComponent(".build").path])
    }

    func testFindsDeeplyNestedAnchoredArtifacts() throws {
        try make(
            dirs: ["group/sub/rustproj/target/debug", "group/sub/rustproj/src",
                   "webapp/node_modules/leftpad"],
            files: ["group/sub/rustproj/Cargo.toml", "webapp/package.json"])

        let found = scan()
        let paths = Set(found.map(\.path))
        XCTAssertTrue(paths.contains(root.appendingPathComponent("group/sub/rustproj/target").path))
        XCTAssertTrue(paths.contains(root.appendingPathComponent("webapp/node_modules").path))
        XCTAssertEqual(found.count, 2)

        let rust = found.first { $0.kind == .rustTarget }
        XCTAssertEqual(rust?.label, "rustproj/target")
        XCTAssertEqual(rust?.anchorPaths,
                       [root.appendingPathComponent("group/sub/rustproj/Cargo.toml").path])
        XCTAssertFalse(rust?.isKnownCache ?? true)
    }

    func testUnanchoredArtifactNamesAreIgnored() throws {
        // A `target` dir with no Cargo.toml/pom.xml might be someone's real folder…
        try make(dirs: ["misc/target/notes"], files: ["misc/target/notes/todo.txt"])
        // …and can even contain a real project the scanner should still find.
        try make(dirs: ["misc/target/notes/tool/node_modules"],
                 files: ["misc/target/notes/tool/package.json"])

        let found = scan()
        XCTAssertEqual(found.map(\.kind), [.nodeModules],
                       "descend through unanchored generic names, report nothing for them")
    }

    func testNeverDescendsIntoMatchedArtifacts() throws {
        // A node_modules inside a matched target must not become a second item.
        try make(dirs: ["proj/target/tool/node_modules"],
                 files: ["proj/Cargo.toml", "proj/target/tool/package.json"])

        let found = scan()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.kind, .rustTarget)
    }

    func testInnerAnchors() throws {
        try make(dirs: ["pyproj/.venv/bin", "pyproj/fake-venv-dir/.venv"],
                 files: ["pyproj/.venv/pyvenv.cfg"])

        let found = scan()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.kind, .pythonVenv)
        XCTAssertEqual(found.first?.path, root.appendingPathComponent("pyproj/.venv").path)
    }

    func testExcludedPathsAreSkipped() throws {
        try make(dirs: ["proj/target/debug"], files: ["proj/Cargo.toml"])
        let excluded = root.appendingPathComponent("proj/target").path
        XCTAssertTrue(scan(exclude: [excluded]).isEmpty)
    }

    func testExcludedPathsUseTheSameCanonicalSpellingAsRoots() throws {
        try make(dirs: ["proj/target/debug"], files: ["proj/Cargo.toml"])
        // Foundation standardization can rewrite /private/var to its /var alias.
        let excluded = root.appendingPathComponent("proj").standardizedFileURL.path
        XCTAssertTrue(scan(exclude: [excluded]).isEmpty)
    }

    func testSkipsSymlinks() throws {
        try make(dirs: ["real/proj/target"], files: ["real/proj/Cargo.toml"])
        // A symlink loop back to the root must neither recurse nor duplicate findings.
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("loop"),
            withDestinationURL: root)

        let found = scan()
        XCTAssertEqual(found.count, 1)
    }

    func testHiddenDirsAreNotDescended() throws {
        try make(dirs: [".hidden/proj/target"], files: [".hidden/proj/Cargo.toml"])
        XCTAssertTrue(scan().isEmpty,
                      "hidden trees (like .git) are out of scope for the deep scan")
    }

    func testFlagHiddenDirsAreNotDescended() throws {
        // ~/Library is hidden via the filesystem flag, not a dot prefix — the walk
        // must treat flag-hidden trees exactly like dot-hidden ones.
        try make(dirs: ["flagged/proj/target"], files: ["flagged/proj/Cargo.toml"])
        var flagged = root.appendingPathComponent("flagged")
        var values = URLResourceValues()
        values.isHidden = true
        try flagged.setResourceValues(values)

        XCTAssertTrue(scan().isEmpty)
    }

    func testNormalizedRootsDropNestedRoots() {
        let outer = URL(fileURLWithPath: "/a/b")
        let inner = URL(fileURLWithPath: "/a/b/c")
        let sibling = URL(fileURLWithPath: "/a/bc")
        XCTAssertEqual(Scanner.normalizedRoots([outer, inner, sibling]).map(\.path),
                       ["/a/b", "/a/bc"])
    }

    func testNormalizedRootsDropExactDuplicates() {
        let a = URL(fileURLWithPath: "/a/b")
        let b = URL(fileURLWithPath: "/a/b")
        XCTAssertEqual(Scanner.normalizedRoots([a, b]).map(\.path), ["/a/b"])
    }

    func testNormalizedRootsCollapseCaseVariantsOfExistingDirs() throws {
        // The temp root exists, so canonicalization can resolve the true spelling.
        try make(dirs: ["Projects"], files: [])
        let upper = root.appendingPathComponent("Projects")
        let lower = root.appendingPathComponent("projects")
        let normalized = Scanner.normalizedRoots([upper, lower])
        // On a case-insensitive filesystem both spellings are one folder; on a
        // case-sensitive one only the created spelling exists and the other stays.
        let existing = normalized.filter {
            fileManager.fileExists(atPath: $0.path)
        }
        XCTAssertEqual(existing.count, 1,
                       "one physical folder must survive normalization once: \(normalized)")
    }
}
