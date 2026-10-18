import XCTest
@testable import RepoMen

/// Reclaim-time re-verification: what actually gets deleted, and what refuses to.
/// Uses `.delete` against a synthetic home so tests don't fill the real Trash.
final class ReclaimerTests: XCTestCase {

    private var home: URL!
    private let fileManager = FileManager.default
    private let codexCrashpadRoots = [
        "Library/Application Support/Codex/Crashpad",
        "Library/Application Support/com.openai.codex/web/Crashpad",
    ]

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RepoMenReclaimerTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    private func makeProject(name: String = "proj") throws -> CleanableItem {
        let target = home.appendingPathComponent("dev/\(name)/target")
        try fileManager.createDirectory(at: target.appendingPathComponent("debug"),
                                        withIntermediateDirectories: true)
        let anchor = home.appendingPathComponent("dev/\(name)/Cargo.toml")
        try Data("[package]".utf8).write(to: anchor)
        return CleanableItem(label: "\(name)/target", kind: .rustTarget, path: target.path,
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

    func testReclaimsCodexReportsAndPreservesAppState() throws {
        var preserved: [URL] = []
        for root in codexCrashpadRoots {
            let database = home.appendingPathComponent(root)
            for bucket in ["pending", "new", "completed", "attachments"] {
                let directory = database.appendingPathComponent(bucket)
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("dump".utf8).write(to: directory.appendingPathComponent("report.dmp"))
                try Data("{}".utf8).write(to: directory.appendingPathComponent("report_sidecar.json"))
            }
            let settings = database.appendingPathComponent("settings.dat")
            let appState = database.deletingLastPathComponent().appendingPathComponent("Preferences")
            try Data("keep".utf8).write(to: settings)
            try Data("keep".utf8).write(to: appState)
            preserved += [settings, appState]
        }

        let found = KnownCaches.items(home: home, excludedPaths: [], enabledKinds: [.crashReports])
        XCTAssertEqual(found.count, 8)
        let outcomes = Reclaimer.reclaim(found, method: .delete, home: home)
        XCTAssertEqual(outcomes.count, found.count)
        XCTAssertTrue(outcomes.allSatisfy { $0.failure == nil })
        XCTAssertTrue(found.allSatisfy { !fileManager.fileExists(atPath: $0.path) })
        for file in preserved {
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep")
        }
    }

    func testRefusesCodexAppStateAndCrashpadDatabase() throws {
        for root in codexCrashpadRoots {
            let database = home.appendingPathComponent(root)
            let refused = [database, database.deletingLastPathComponent(),
                           database.appendingPathComponent("metadata"),
                           database.appendingPathComponent("pending-backup"),
                           database.deletingLastPathComponent().appendingPathComponent("Local Storage")]
            for directory in refused {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let item = CleanableItem(label: "impostor", kind: .crashReports,
                                         path: directory.path, anchorPaths: [], isKnownCache: true)
                let outcomes = Reclaimer.reclaim([item], method: .delete, home: home)
                XCTAssertEqual(outcomes.count, 1)
                XCTAssertNotNil(outcomes.first?.failure, directory.path)
                XCTAssertTrue(fileManager.fileExists(atPath: directory.path))
            }
        }
    }

    func testRefusesRedirectedCodexCrashReports() throws {
        let database = home.appendingPathComponent(codexCrashpadRoots[0])
        try fileManager.createDirectory(at: database.appendingPathComponent("pending"),
                                        withIntermediateDirectories: true)
        let found = KnownCaches.items(home: home, excludedPaths: [], enabledKinds: [.crashReports])
        XCTAssertEqual(found.count, 1)

        let appState = database.deletingLastPathComponent().appendingPathComponent("Local Storage")
        let preserved = appState.appendingPathComponent("pending")
        try fileManager.createDirectory(at: preserved, withIntermediateDirectories: true)
        try fileManager.removeItem(at: database)
        try fileManager.createSymbolicLink(at: database, withDestinationURL: appState)

        let outcomes = Reclaimer.reclaim(found, method: .delete, home: home)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertNotNil(outcomes.first?.failure)
        XCTAssertTrue(fileManager.fileExists(atPath: preserved.path))
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

    func testCancelledTaskStopsBetweenItems() async throws {
        let a = try makeProject(name: "projA")
        let b = try makeProject(name: "projB")
        let home = self.home!

        let task = Task { () -> [Reclaimer.Outcome] in
            // Simulate Stop landing before the batch loop starts.
            withUnsafeCurrentTask { $0?.cancel() }
            return Reclaimer.reclaim([a, b], method: .delete, home: home)
        }
        let outcomes = await task.value
        XCTAssertTrue(outcomes.isEmpty, "a cancelled batch must not process items")
        XCTAssertTrue(fileManager.fileExists(atPath: a.path))
        XCTAssertTrue(fileManager.fileExists(atPath: b.path))
    }

    func testRefusesItemThatBecameASymlink() throws {
        // Between scan and reclaim the artifact path was replaced by a symlink.
        let target = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RepoMenSymlinkTarget-\(UUID().uuidString)")
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: target) }

        let item = try makeProject()
        try fileManager.removeItem(atPath: item.path)
        try fileManager.createSymbolicLink(atPath: item.path,
                                           withDestinationPath: target.path)

        let outcomes = Reclaimer.reclaim([item], method: .delete, home: home)
        XCTAssertNotNil(outcomes.first?.failure)
        XCTAssertTrue(fileManager.fileExists(atPath: target.path),
                      "the link target must survive")
    }

    func testRefusesPathEscapingHomeThroughSymlinkedParent() throws {
        // ~/dev/proj is now a symlink to a directory outside home; the item's lexical
        // path still reads as inside home, but the directory physically is not.
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RepoMenOutsideProj-\(UUID().uuidString)")
        try fileManager.createDirectory(at: outside.appendingPathComponent("target/debug"),
                                        withIntermediateDirectories: true)
        try Data("[package]".utf8).write(to: outside.appendingPathComponent("Cargo.toml"))
        defer { try? fileManager.removeItem(at: outside) }

        try fileManager.createDirectory(at: home.appendingPathComponent("dev"),
                                        withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: home.appendingPathComponent("dev/proj"),
            withDestinationURL: outside)
        let item = CleanableItem(
            label: "proj/target", kind: .rustTarget,
            path: home.appendingPathComponent("dev/proj/target").path,
            anchorPaths: [home.appendingPathComponent("dev/proj/Cargo.toml").path],
            isKnownCache: false)

        let outcomes = Reclaimer.reclaim([item], method: .delete, home: home)
        XCTAssertNotNil(outcomes.first?.failure,
                        "the resolved path leaves home — reclaim must refuse")
        XCTAssertTrue(fileManager.fileExists(atPath: outside.appendingPathComponent("target").path))
    }

    func testRefusesSystemAreaItems() throws {
        // System areas belong to SystemReclaimer; even if a routing bug sent one
        // here, the ordinary reclaimer must refuse it — whatever its path says.
        let dir = home.appendingPathComponent("dev/proj/logs-impostor")
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let item = CleanableItem(label: "Root logs · impostor", kind: .systemLogs,
                                 path: dir.path, anchorPaths: [], isKnownCache: true,
                                 isSystemArea: true)
        let outcomes = Reclaimer.reclaim([item], method: .delete, home: home)
        XCTAssertNotNil(outcomes.first?.failure)
        XCTAssertTrue(fileManager.fileExists(atPath: dir.path))
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
