import XCTest
@testable import RepoMen

final class ManagedStorageGuardTests: XCTestCase {
    private let home = "/Users/test"

    func testRefusesToolManagedPathsAndTheirAncestors() {
        for relative in [".cache/uv", ".cache/uv/archive-v0/pkg", "Library/Caches/uv",
                         "Library/Android", "Library/Android/sdk/ndk/27",
                         ".android/avd/Pixel.avd"] {
            XCTAssertNotNil(PathGuards.validate(path: home + "/" + relative, home: home), relative)
        }
        XCTAssertNil(PathGuards.validate(path: home + "/Library/AndroidProjects/build", home: home))
        XCTAssertNil(PathGuards.validate(path: home + "/.cache/uv-other/output", home: home))
    }

    func testValidTagCannotAuthorizeDeletingUVCache() throws {
        let fm = FileManager.default
        let temporaryHome = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ManagedGuard-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporaryHome) }
        let cache = temporaryHome.appendingPathComponent(".cache/uv")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try CacheDirectoryTag.signature.write(to: cache.appendingPathComponent("CACHEDIR.TAG"))
        let item = CleanableItem(label: "uv", kind: .taggedCache, path: cache.path,
                                 anchorPaths: [], isKnownCache: false)
        let outcomes = Reclaimer.reclaim([item], method: .delete, home: temporaryHome)
        XCTAssertNotNil(outcomes.first?.failure)
        XCTAssertTrue(fm.fileExists(atPath: cache.path))
    }

    func testScannerDoesNotOfferUVTagOrDescendantArtifacts() throws {
        let fm = FileManager.default
        let temporaryHome = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ManagedScan-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporaryHome) }
        let cache = temporaryHome.appendingPathComponent(".cache/uv")
        let package = cache.appendingPathComponent("archive-v0/pkg/__pycache__")
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        try CacheDirectoryTag.signature.write(to: cache.appendingPathComponent("CACHEDIR.TAG"))
        for scanRoot in [cache.deletingLastPathComponent(), cache, package.deletingLastPathComponent()] {
            let configuration = ScanConfiguration(roots: [scanRoot], excludedPaths: [],
                enabledKinds: Set(ArtifactKind.allCases), home: temporaryHome)
            XCTAssertTrue(Scanner.scan(configuration).isEmpty, scanRoot.path)
        }
    }

    func testRejectsStaleJetBrainsVersionSelection() throws {
        let fm = FileManager.default
        let temporaryHome = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ManagedIDE-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporaryHome) }
        let version = temporaryHome.appendingPathComponent("Library/Caches/JetBrains/IntelliJIdea2026.2")
        let history = version.appendingPathComponent("LocalHistory/changes.dat")
        try fm.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: version.appendingPathComponent("index"), withIntermediateDirectories: true)
        try Data("uncommitted recovery data".utf8).write(to: history)
        let item = CleanableItem(label: "IDE", kind: .ideCache, path: version.path,
                                 anchorPaths: [], isKnownCache: true)
        XCTAssertNotNil(Reclaimer.reclaim([item], method: .delete, home: temporaryHome).first?.failure)
        XCTAssertTrue(fm.fileExists(atPath: history.path))
    }
}
