import XCTest
@testable import RepoMen

final class PreferencesTests: XCTestCase {

    private var home: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RepoMenPreferencesTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    func testDefaultScanRootsDeduplicateCaseVariants() throws {
        // On default (case-insensitive) APFS, probing both "Projects" and "projects"
        // used to return the same physical folder twice, doubling every scan result.
        try fileManager.createDirectory(at: home.appendingPathComponent("Projects"),
                                        withIntermediateDirectories: true)

        let roots = Preferences.defaultScanRoots(home: home)
        XCTAssertEqual(roots.count, 1, "one physical folder must yield one root: \(roots)")
        XCTAssertTrue(roots[0].hasSuffix("/Projects"),
                      "the on-disk spelling is the one to keep: \(roots)")
    }

    func testDefaultScanRootsKeepDistinctFolders() throws {
        try fileManager.createDirectory(at: home.appendingPathComponent("Developer"),
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: home.appendingPathComponent("repos"),
                                        withIntermediateDirectories: true)

        XCTAssertEqual(Preferences.defaultScanRoots(home: home).count, 2)
    }
}
