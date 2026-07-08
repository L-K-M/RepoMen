import XCTest
@testable import RepoMen

/// The last-line-of-defense guards. Every rule here is a thing RepoMen must never
/// delete no matter what a scan rule claims.
final class PathGuardsTests: XCTestCase {

    private let home = "/Users/test"

    private func violation(_ path: String) -> String? {
        PathGuards.validate(path: path, home: home)?.reason
    }

    func testAcceptsDeepArtifactPaths() {
        XCTAssertNil(violation("/Users/test/Documents/GitHub/proj/target"))
        XCTAssertNil(violation("/Users/test/Library/Caches/Homebrew/downloads"))
    }

    func testRejectsHomeItself() {
        XCTAssertNotNil(violation("/Users/test"))
        XCTAssertNotNil(violation("/Users/test/"))
    }

    func testRejectsTopLevelHomeFolders() {
        XCTAssertNotNil(violation("/Users/test/Documents"))
        XCTAssertNotNil(violation("/Users/test/Library"))
    }

    func testRejectsOutsideHome() {
        XCTAssertNotNil(violation("/"))
        XCTAssertNotNil(violation("/Users/otheruser/Documents/proj/target"))
        XCTAssertNotNil(violation("/Users/testify/deep/path"),
                        "a prefix of the string is not a prefix of the path")
    }

    func testRejectsRelativeComponents() {
        XCTAssertNotNil(violation("/Users/test/Documents/../../etc"))
        XCTAssertNotNil(violation("relative/path"))
    }

    func testRejectsProtectedAreas() {
        XCTAssertNotNil(violation("/Users/test/Library/Containers/com.docker.docker/Data/vms"))
        XCTAssertNotNil(violation("/Users/test/.orbstack/data/something"))
        XCTAssertNotNil(violation("/Users/test/.Trash/old/target"))
        XCTAssertNotNil(violation("/Users/test/Pictures/Photos Library.photoslibrary/originals"))
        XCTAssertNotNil(violation("/Users/test/.colima/default/disk"))
    }

    func testIsUnder() {
        XCTAssertTrue(PathGuards.isUnder("/a/b/c", root: "/a/b"))
        XCTAssertTrue(PathGuards.isUnder("/a/b", root: "/a/b"))
        XCTAssertFalse(PathGuards.isUnder("/a/bc", root: "/a/b"))
    }

    func testDedupeNestedKeepsOutermost() {
        let deduped = PathGuards.dedupeNested([
            "/u/t/proj/target",
            "/u/t/proj/target/debug",
            "/u/t/other/node_modules",
        ])
        XCTAssertEqual(deduped, ["/u/t/proj/target", "/u/t/other/node_modules"])
    }
}
