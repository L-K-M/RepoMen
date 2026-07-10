import XCTest
@testable import RepoMen

final class SemanticVersionTests: XCTestCase {

    func testParsing() {
        XCTAssertEqual(SemanticVersion("v1.2.3")?.components, [1, 2, 3])
        XCTAssertEqual(SemanticVersion("1.4.0-beta.2")?.prerelease, "beta.2")
        XCTAssertNil(SemanticVersion("not-a-version"))
    }

    func testComparisonPadsComponents() {
        XCTAssertEqual(SemanticVersion("1.2")!, SemanticVersion("1.2.0")!)
        XCTAssertTrue(SemanticVersion("1.2.0")! < SemanticVersion("1.10.0")!)
        XCTAssertTrue(SemanticVersion("v0.9.0")! < SemanticVersion("0.10")!)
    }

    func testPrereleaseSortsBelowFinal() {
        XCTAssertTrue(SemanticVersion("1.2.0-beta")! < SemanticVersion("1.2.0")!)
    }

    func testPrereleaseNumericIdentifiersCompareNumerically() {
        // Lexically "beta.10" < "beta.9" — semver §11 requires numeric comparison.
        XCTAssertTrue(SemanticVersion("1.2.0-beta.9")! < SemanticVersion("1.2.0-beta.10")!)
        XCTAssertFalse(SemanticVersion("1.2.0-beta.10")! < SemanticVersion("1.2.0-beta.9")!)
        XCTAssertTrue(SemanticVersion("1.2.0-rc.2")! < SemanticVersion("1.2.0-rc.11")!)
    }

    func testPrereleaseMixedIdentifiers() {
        // Numeric identifiers sort below alphanumeric ones.
        XCTAssertTrue(SemanticVersion("1.0.0-alpha.1")! < SemanticVersion("1.0.0-alpha.beta")!)
        // Fewer identifiers sort lower when the shared ones are equal.
        XCTAssertTrue(SemanticVersion("1.0.0-alpha")! < SemanticVersion("1.0.0-alpha.1")!)
        // Plain ASCII ordering otherwise.
        XCTAssertTrue(SemanticVersion("1.0.0-alpha")! < SemanticVersion("1.0.0-beta")!)
    }
}
