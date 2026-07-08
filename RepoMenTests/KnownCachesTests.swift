import XCTest
@testable import RepoMen

/// The fixed-location catalog, exercised against a synthetic home directory.
final class KnownCachesTests: XCTestCase {

    private var home: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RepoMenKnownCachesTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    private func make(_ dirs: [String]) throws {
        for dir in dirs {
            try fileManager.createDirectory(at: home.appendingPathComponent(dir),
                                            withIntermediateDirectories: true)
        }
    }

    private func items(excluded: Set<String> = [],
                       enabled: Set<ArtifactKind>? = nil,
                       isRunning: (String) -> Bool = { _ in false }) -> [CleanableItem] {
        KnownCaches.items(home: home,
                          excludedPaths: excluded,
                          enabledKinds: enabled ?? Set(ArtifactKind.allCases),
                          isRunning: isRunning)
    }

    func testOnlyExistingLocationsAppear() throws {
        try make(["Library/Caches/Homebrew/downloads"])
        let found = items()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.kind, .homebrewCache)
        XCTAssertEqual(found.first?.label, "Homebrew downloads")
        XCTAssertTrue(found.first?.isKnownCache ?? false)
    }

    func testDerivedDataExpandsPerProject() throws {
        try make(["Library/Developer/Xcode/DerivedData/MyApp-abc123",
                  "Library/Developer/Xcode/DerivedData/Other-def456"])
        let labels = Set(items().map(\.label))
        XCTAssertEqual(labels, ["Xcode DerivedData · MyApp-abc123",
                                "Xcode DerivedData · Other-def456"])
    }

    func testChromeProfileCaches() throws {
        try make(["Library/Caches/Google/Chrome/Default/Cache",
                  "Library/Caches/Google/Chrome/Profile 14/Cache",
                  "Library/Caches/Google/Chrome/Profile 14/Code Cache"])
        let found = items()
        XCTAssertEqual(found.count, 3)
        XCTAssertTrue(found.allSatisfy { $0.kind == .browserCache })
        XCTAssertTrue(found.contains { $0.label == "Chrome · Profile 14 · Code Cache" })
        XCTAssertTrue(found.allSatisfy { $0.warning == nil })
    }

    func testRunningBrowserGetsWarning() throws {
        try make(["Library/Caches/Google/Chrome/Default/Cache"])
        let found = items(isRunning: { $0 == "com.google.Chrome" })
        XCTAssertEqual(found.first?.warning, "Chrome is running — quit it before reclaiming")
    }

    func testFirefoxProfileCache() throws {
        try make(["Library/Caches/Firefox/Profiles/abcd1234.default/cache2"])
        let found = items()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.label, "Firefox · abcd1234.default · cache2")
    }

    func testDisabledKindsAndExclusionsFilter() throws {
        try make(["Library/Caches/Homebrew/downloads", "Library/Caches/pip"])
        let withoutPip = Set(ArtifactKind.allCases).subtracting([.pipCache])
        XCTAssertEqual(items(enabled: withoutPip).map(\.kind), [.homebrewCache])

        let excluded = home.appendingPathComponent("Library/Caches/Homebrew/downloads").path
        XCTAssertEqual(items(excluded: [excluded]).map(\.kind), [.pipCache])
    }

    func testAllowedRootsCoverEverySpec() {
        let roots = KnownCaches.allowedRoots(home: home)
        for spec in KnownCaches.specs {
            let path = home.appendingPathComponent(spec.relativePath).path
            XCTAssertTrue(roots.contains { PathGuards.isUnder(path, root: $0) },
                          "\(spec.label) must be reclaimable under the allowed roots")
        }
    }
}
