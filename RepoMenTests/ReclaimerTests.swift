import XCTest
@testable import RepoMen

/// Reclaim-time re-verification: what actually gets deleted, and what refuses to.
/// Uses `.delete` against a synthetic home so tests don't fill the real Trash.
final class ReclaimerTests: XCTestCase {

    private var home: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RepoMenReclaimerTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    private func makeProject() throws -> CleanableItem {
        let target = home.appendingPathComponent("dev/proj/target")
        try fileManager.createDirectory(at: target.appendingPathComponent("debug"),
                                        withIntermediateDirectories: true)
        let anchor = home.appendingPathComponent("dev/proj/Cargo.toml")
        try Data("[package]".utf8).write(to: anchor)
        return CleanableItem(label: "proj/target", kind: .rustTarget, path: target.path,
                             anchorPaths: [anchor.path], isKnownCache: false)
    }

    func testReclaimsVerifiedArtifact() throws {
        let item = try makeProject()
        let outcomes = Reclaimer.reclaim([item], method: .delete, home: home)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertNil(outcomes.first?.failure)
        XCTAssertFalse(fileManager.fileExists(atPath: item.path))
    }

    func testRefusesWhenAnchorDisappeared() throws {
        let item = try makeProject()
        try fileManager.removeItem(atPath: item.anchorPaths[0])

        let outcomes = Reclaimer.reclaim([item], method: .delete, home: home)
        XCTAssertNotNil(outcomes.first?.failure)
        XCTAssertTrue(fileManager.fileExists(atPath: item.path),
                      "no anchor, no deletion — the project may have been moved")
    }

    func testRefusesPathsOutsideHome() throws {
        let elsewhere = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RepoMenOutside-\(UUID().uuidString)/proj/target")
        try fileManager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: elsewhere) }

        let item = CleanableItem(label: "x", kind: .rustTarget, path: elsewhere.path,
                                 anchorPaths: [elsewhere.path], isKnownCache: false)
        let outcomes = Reclaimer.reclaim([item], method: .delete, home: home)
        XCTAssertNotNil(outcomes.first?.failure)
        XCTAssertTrue(fileManager.fileExists(atPath: item.path))
    }

    func testKnownCacheMustBeUnderCatalogRoot() throws {
        let cache = home.appendingPathComponent("Library/Caches/pip")
        try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        let good = CleanableItem(label: "pip cache", kind: .pipCache, path: cache.path,
                                 anchorPaths: [], isKnownCache: true)

        let stray = home.appendingPathComponent("dev/important-data")
        try fileManager.createDirectory(at: stray, withIntermediateDirectories: true)
        let bad = CleanableItem(label: "impostor", kind: .pipCache, path: stray.path,
                                anchorPaths: [], isKnownCache: true)

        let outcomes = Reclaimer.reclaim([good, bad], method: .delete, home: home)
        XCTAssertNil(outcomes.first { $0.item.path == good.path }?.failure)
        XCTAssertNotNil(outcomes.first { $0.item.path == bad.path }?.failure,
                        "a known-cache flag on a non-catalog path must not delete it")
        XCTAssertTrue(fileManager.fileExists(atPath: stray.path))
    }

    func testAnchorlessItemFallsBackToUnambiguousName() throws {
        let pycache = home.appendingPathComponent("dev/proj/__pycache__")
        try fileManager.createDirectory(at: pycache, withIntermediateDirectories: true)
        let ok = CleanableItem(label: "proj/__pycache__", kind: .pythonCache,
                               path: pycache.path, anchorPaths: [], isKnownCache: false)

        let other = home.appendingPathComponent("dev/proj/data")
        try fileManager.createDirectory(at: other, withIntermediateDirectories: true)
        let notOK = CleanableItem(label: "proj/data", kind: .pythonCache,
                                  path: other.path, anchorPaths: [], isKnownCache: false)

        let outcomes = Reclaimer.reclaim([ok, notOK], method: .delete, home: home)
        XCTAssertNil(outcomes.first { $0.item.path == ok.path }?.failure)
        XCTAssertNotNil(outcomes.first { $0.item.path == notOK.path }?.failure)
    }

    func testNestedSelectionsCollapseToOutermost() throws {
        let item = try makeProject()
        let nested = CleanableItem(label: "proj/target/debug", kind: .rustTarget,
                                   path: item.path + "/debug",
                                   anchorPaths: item.anchorPaths, isKnownCache: false)
        let outcomes = Reclaimer.reclaim([nested, item], method: .delete, home: home)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.item.path, item.path)
    }
}
