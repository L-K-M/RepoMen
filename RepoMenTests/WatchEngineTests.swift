import XCTest
@testable import RepoMen

/// Watch-mode eligibility: the pure decision of what a watched folder would
/// auto-trash right now.
final class WatchEngineTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(path: String, idleDays: Double, measured: Bool = true) -> CleanableItem {
        var item = CleanableItem(label: URL(fileURLWithPath: path).lastPathComponent,
                                 kind: .rustTarget, path: path,
                                 anchorPaths: [path + "/../Cargo.toml"], isKnownCache: false)
        item.isMeasured = measured
        item.lastModified = now.addingTimeInterval(-idleDays * 86_400)
        return item
    }

    func testMostSpecificFolderGoverns() {
        let outer = WatchedFolder(path: "/Users/x/dev", maxIdleDays: 60)
        let inner = WatchedFolder(path: "/Users/x/dev/hot", maxIdleDays: 7)
        let governed = WatchEngine.governingFolder(
            for: "/Users/x/dev/hot/proj/target", folders: [outer, inner])
        XCTAssertEqual(governed?.path, inner.path,
                       "the deepest watched folder's threshold wins for its subtree")
    }

    func testDisabledFolderDoesNotGovern() {
        let disabled = WatchedFolder(path: "/Users/x/dev", maxIdleDays: 7, isEnabled: false)
        XCTAssertNil(WatchEngine.governingFolder(for: "/Users/x/dev/p/target",
                                                 folders: [disabled]))
    }

    func testEligibilityRespectsThresholdAndMeasurement() {
        let folder = WatchedFolder(path: "/Users/x/dev", maxIdleDays: 30)
        let stale = item(path: "/Users/x/dev/a/target", idleDays: 45)
        let fresh = item(path: "/Users/x/dev/b/target", idleDays: 3)
        let unmeasured = item(path: "/Users/x/dev/c/target", idleDays: 999, measured: false)
        let outside = item(path: "/Users/x/other/d/target", idleDays: 999)

        let eligible = WatchEngine.eligibleItems(
            items: [stale, fresh, unmeasured, outside], folders: [folder], now: now)
        XCTAssertEqual(eligible.map(\.path), [stale.path],
                       "only measured, governed, idle-past-threshold items qualify")
    }

    func testNestedThresholdsApplyPerSubtree() {
        let outer = WatchedFolder(path: "/Users/x/dev", maxIdleDays: 60)
        let inner = WatchedFolder(path: "/Users/x/dev/hot", maxIdleDays: 7)
        // 20 days idle: stale for the inner folder (7), fresh for the outer (60).
        let innerItem = item(path: "/Users/x/dev/hot/p/target", idleDays: 20)
        let outerItem = item(path: "/Users/x/dev/calm/q/target", idleDays: 20)

        let eligible = WatchEngine.eligibleItems(
            items: [innerItem, outerItem], folders: [outer, inner], now: now)
        XCTAssertEqual(eligible.map(\.path), [innerItem.path])
    }

    func testSignatureIsOrderIndependentAndContentSensitive() {
        let a = item(path: "/Users/x/dev/a/target", idleDays: 40)
        let b = item(path: "/Users/x/dev/b/target", idleDays: 50)
        XCTAssertEqual(WatchEngine.signature(for: [a, b]),
                       WatchEngine.signature(for: [b, a]))
        var resized = a
        resized.sizeBytes += 1
        XCTAssertNotEqual(WatchEngine.signature(for: [a, b]),
                          WatchEngine.signature(for: [resized, b]))
    }
}
