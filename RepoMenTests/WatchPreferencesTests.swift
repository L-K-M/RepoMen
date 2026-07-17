import XCTest
@testable import RepoMen

/// Watch-mode persistence: watched folders, the master switch, and the last-run
/// record round-trip through UserDefaults.
final class WatchPreferencesTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "RepoMenWatchTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testWatchedFoldersRoundTrip() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.watchedFolders, [])
        XCTAssertFalse(preferences.watchAutoTrash,
                       "auto-clean is opt-in: off until the user arms it")

        preferences.watchedFolders = [
            WatchedFolder(path: "/Users/x/dev", maxIdleDays: 14),
            WatchedFolder(path: "/Users/x/work", maxIdleDays: 45, isEnabled: false),
        ]
        preferences.watchAutoTrash = true

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.watchedFolders, preferences.watchedFolders)
        XCTAssertTrue(reloaded.watchAutoTrash)
    }

    func testWatchFolderDedupesAndArmsMenuBar() {
        let preferences = Preferences(defaults: defaults)
        preferences.idleDays = 21

        preferences.watchFolder(path: "/Users/x/dev")
        preferences.watchFolder(path: "/Users/x/dev")

        XCTAssertEqual(preferences.watchedFolders.count, 1, "watching is deduped by path")
        XCTAssertEqual(preferences.watchedFolders.first?.maxIdleDays, 21,
                       "a new watched folder inherits the current idle threshold")
        XCTAssertTrue(preferences.showInMenuBar,
                      "watching arms the menu-bar presence so checks actually run")
    }

    func testLastWatchRunRoundTrips() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertNil(preferences.lastWatchRun)

        let record = WatchRunRecord(date: Date(timeIntervalSince1970: 1_700_000_000),
                                    dryRun: false, candidateCount: 5,
                                    candidateBytes: 1_024, reclaimedCount: 4,
                                    reclaimedBytes: 1_000, failureCount: 1)
        preferences.lastWatchRun = record

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.lastWatchRun, record)
    }
}
