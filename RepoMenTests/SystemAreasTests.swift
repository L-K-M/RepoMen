import XCTest
@testable import RepoMen

/// The root-owned catalog and its guards. Everything the privileged scripts touch
/// passes `SystemAreas.validate` first — these rules are what keeps "clean up
/// RTCReporting logs" from ever meaning "rm -rf something else as root".
final class SystemAreasTests: XCTestCase {

    private func violation(_ path: String) -> String? {
        SystemAreas.validate(path: path)?.reason
    }

    func testAcceptsDirectChildrenOfCatalogRoots() {
        XCTAssertNil(violation("/private/var/root/Library/Logs/RTCReporting"))
        XCTAssertNil(violation("/private/var/root/Library/Caches/com.apple.rtcreporting"))
        XCTAssertNil(violation("/private/var/root/Library/Logs/.hidden"))
        XCTAssertNil(violation("/private/var/root/Library/Logs/we'ird name"))
    }

    func testRejectsTheRootsThemselves() {
        for root in SystemAreas.roots {
            XCTAssertNotNil(violation(root.path),
                            "\(root.path) itself must never be reclaimable")
            XCTAssertNotNil(violation(root.path + "/"))
        }
    }

    func testRejectsOutsideTheCatalog() {
        XCTAssertNotNil(violation("/"))
        XCTAssertNotNil(violation("/private/var/root/Library"))
        XCTAssertNotNil(violation("/private/var/root/Library/Preferences/x"))
        XCTAssertNotNil(violation("/Users/me/Library/Logs/x"))
        XCTAssertNotNil(violation("/private/var/root/Library/LogsEvil/x"),
                        "a prefix of the string is not a prefix of the path")
    }

    func testRejectsAnythingDeeperThanADirectChild() {
        XCTAssertNotNil(violation("/private/var/root/Library/Logs/RTCReporting/inner"))
        XCTAssertNotNil(violation("/private/var/root/Library/Caches/a/b/c"))
    }

    func testRejectsRelativeComponentsAndMalformedPaths() {
        XCTAssertNotNil(violation("relative/path"))
        XCTAssertNotNil(violation("/private/var/root/Library/Logs/.."))
        XCTAssertNotNil(violation("/private/var/root/Library/Logs/../Logs/x"))
        XCTAssertNotNil(violation("/private/var/root/Library/Logs/."))
        XCTAssertNotNil(violation("/private/var/root/Library/Logs/RTCReporting/"))
        XCTAssertNotNil(violation("/private/var/root/Library/Logs/bad\0name"))
    }

    func testCatalogRootsAreWellFormed() {
        for root in SystemAreas.roots {
            XCTAssertTrue(root.path.hasPrefix("/private/var/root/"),
                          "the catalog is scoped to root's home, physical spelling")
            XCTAssertFalse(root.path.hasSuffix("/"))
            XCTAssertEqual(root.kind.category, .system)
        }
    }

    func testRootContainingMatchesChildrenNotTheRootItself() {
        XCTAssertNil(SystemAreas.root(containing: "/private/var/root/Library/Logs"))
        XCTAssertEqual(
            SystemAreas.root(containing: "/private/var/root/Library/Logs/RTCReporting")?.kind,
            .systemLogs)
        XCTAssertEqual(
            SystemAreas.root(containing: "/private/var/root/Library/Caches/x")?.kind,
            .systemCaches)
    }

    func testCulpritWarningNamesDropboxForRTCReporting() {
        let warning = SystemAreas.culpritWarning(
            childName: "RTCReporting", isRunning: { $0 == "com.getdropbox.dropbox" })
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("Dropbox") ?? false)

        XCTAssertNil(SystemAreas.culpritWarning(childName: "RTCReporting",
                                                isRunning: { _ in false }),
                     "no warning while the culprit is not running")
        XCTAssertNil(SystemAreas.culpritWarning(childName: "SomethingElse",
                                                isRunning: { _ in true }),
                     "no warning for children without a known culprit")
    }
}
