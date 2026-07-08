import XCTest
@testable import RepoMen

/// Integration tests for the walk itself, against a synthetic project tree in a temp
/// directory — the pruning/descend policy is where deep-scan bugs would live.
final class ScannerTests: XCTestCase {

    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RepoMenScannerTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
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

    func testNormalizedRootsDropNestedRoots() {
        let outer = URL(fileURLWithPath: "/a/b")
        let inner = URL(fileURLWithPath: "/a/b/c")
        let sibling = URL(fileURLWithPath: "/a/bc")
        XCTAssertEqual(Scanner.normalizedRoots([outer, inner, sibling]).map(\.path),
                       ["/a/b", "/a/bc"])
    }
}
