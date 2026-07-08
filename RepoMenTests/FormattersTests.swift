import XCTest
@testable import RepoMen

final class FormattersTests: XCTestCase {

    func testAgeBuckets() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func age(_ seconds: TimeInterval) -> String {
            Format.age(now.addingTimeInterval(-seconds), now: now)
        }
        XCTAssertEqual(age(45), "just now")
        XCTAssertEqual(age(90 * 60), "90 min ago")
        XCTAssertEqual(age(5 * 3_600), "5 h ago")
        XCTAssertEqual(age(3 * 86_400), "3 days ago")
        XCTAssertEqual(age(21 * 86_400), "3 weeks ago")
        XCTAssertEqual(age(92 * 86_400), "3 months ago")
        XCTAssertEqual(age(3 * 365 * 86_400), "2 years ago")
    }

    func testAgeEdgeCases() {
        XCTAssertEqual(Format.age(.distantPast), "—", "unmeasured items show a dash")
        let now = Date()
        XCTAssertEqual(Format.age(now.addingTimeInterval(60), now: now), "just now",
                       "clock skew must not produce negative ages")
    }

    func testAbbreviatePath() {
        XCTAssertEqual(Format.abbreviatePath("/Users/test/dev/proj", home: "/Users/test"),
                       "~/dev/proj")
        XCTAssertEqual(Format.abbreviatePath("/Users/test", home: "/Users/test"), "~")
        XCTAssertEqual(Format.abbreviatePath("/Users/testify/x", home: "/Users/test"),
                       "/Users/testify/x")
    }
}
