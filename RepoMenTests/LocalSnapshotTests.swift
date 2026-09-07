import XCTest
@testable import RepoMen

/// The one shape RepoMen will ever call a snapshot: `com.apple.TimeMachine.<date>.local`.
/// Everything else — third-party, macOS-update, `.backup` — must fail to parse, so it
/// can never be named, listed, or deleted.
final class LocalSnapshotTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    func testParsesTimeMachineLocalSnapshotNames() throws {
        let snapshot = try XCTUnwrap(LocalSnapshot(name: "com.apple.TimeMachine.2026-09-07-101010.local"))
        XCTAssertEqual(snapshot.dateToken, "2026-09-07-101010")
        XCTAssertEqual(snapshot.id, "2026-09-07-101010")
        XCTAssertEqual(snapshot.name, "com.apple.TimeMachine.2026-09-07-101010.local")
        XCTAssertEqual(snapshot.date, calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 7, hour: 10, minute: 10, second: 10)))
    }

    func testRejectsEverythingThatIsNotALocalTimeMachineSnapshot() {
        let impostors = [
            "com.apple.TimeMachine.2026-09-07-101010.backup",      // lives on a backup disk
            "com.apple.TimeMachine.2026-09-07-101010",             // no .local suffix
            "com.apple.os.update-6E8F2A1B",                        // macOS update snapshot
            "com.bombich.ccc.17F859C6-0BB0-4601-9F64-0A6EFABCA484.2021-11-09-041500",
            "com.apple.TimeMachine.2026-13-07-101010.local",       // month 13
            "com.apple.TimeMachine.2026-09-07-10101.local",        // too short
            "com.apple.TimeMachine.2026-09-07-1010100.local",      // too long
            "com.apple.TimeMachine.2026-09-07-10101a.local",       // not a digit
            "com.apple.TimeMachine.2026-09-07-101010.local ",      // the parser trims lines; the type does not
            "com.apple.TimeMachine..local",
            "Snapshots for disk /:",
            "",
        ]
        for name in impostors {
            XCTAssertNil(LocalSnapshot(name: name), "must not model \(name)")
        }
    }

    func testDateTokenNeedsShapeAndPlausibleFields() {
        XCTAssertNotNil(LocalSnapshot(dateToken: "2026-01-31-235959"))
        XCTAssertNotNil(LocalSnapshot(dateToken: "2026-12-01-000000"))
        let rejected = [
            "2026-01-31-245959",           // hour 24
            "2026-00-31-235959",           // month 0
            "2026-01-32-235959",           // day 32
            "2026-01-31-236059",           // minute 60
            "2026-01-31-235960",           // second 60
            "2026/01/31-235959",
            "2026-01-31 235959",
            "../../etc",
            "2026-01-31-235959; rm -rf /",
            "٢٠٢٦-01-31-235959",           // non-ASCII digits
            " 2026-01-31-235959",
        ]
        for token in rejected {
            XCTAssertNil(LocalSnapshot(dateToken: token), "must reject \(token)")
        }
    }

    func testIsWellFormedIsShapeOnlyAndComponentsAddRanges() {
        XCTAssertTrue(LocalSnapshot.isWellFormed("2026-13-99-999999"),
                      "shape passes; field ranges are the next check")
        XCTAssertFalse(LocalSnapshot.isWellFormed("2026-13-99-99999"))
        XCTAssertNil(LocalSnapshot.components(of: "2026-13-99-999999"))
        XCTAssertEqual(LocalSnapshot.components(of: "2026-09-07-101010"),
                       DateComponents(year: 2026, month: 9, day: 7, hour: 10, minute: 10, second: 10))
    }
}
