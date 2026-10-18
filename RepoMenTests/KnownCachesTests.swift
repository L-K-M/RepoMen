import XCTest
@testable import RepoMen

/// The fixed-location catalog, exercised against a synthetic home directory.
final class KnownCachesTests: XCTestCase {

    private var home: URL!
    private let fileManager = FileManager.default
    private let codexCrashpadRoots = [
        "Library/Application Support/Codex/Crashpad",
        "Library/Application Support/com.openai.codex/web/Crashpad",
    ]
    private let crashReportBuckets = ["pending", "new", "completed", "attachments"]

    override func setUpWithError() throws {
        // Resolved for the same reason as ScannerTests: the catalog reports canonical
        // paths, and /var/folders/… is a symlink to /private/var/folders/… on macOS.
        home = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("RepoMenKnownCachesTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        if let path = try home.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            home = URL(fileURLWithPath: path)
        }
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

    func testNewToolCachesAppear() throws {
        try make(["Library/Caches/ms-playwright/chromium-1105",
                  "Library/Caches/ms-playwright/webkit-1857",
                  ".cargo/registry/src/index.crates.io-abc",
                  ".pub-cache/hosted"])
        let found = items()
        let labels = Set(found.map(\.label))
        XCTAssertTrue(labels.contains("Playwright browsers · chromium-1105"))
        XCTAssertTrue(labels.contains("Playwright browsers · webkit-1857"))
        XCTAssertTrue(labels.contains("Cargo registry sources"))
        XCTAssertTrue(labels.contains("Dart pub cache"))
    }

    func testRunningIDEGetsWarning() throws {
        try make(["Library/Application Support/Code/CachedData"])
        let found = items(isRunning: { $0 == "com.microsoft.VSCode" })
        XCTAssertEqual(found.first?.warning, "VS Code is running — quit it before reclaiming")
        XCTAssertNil(items().first?.warning)
    }

    func testCodexCrashReportsOnlyOfferReportBuckets() throws {
        let reportPaths = codexCrashpadRoots.flatMap { root in
            crashReportBuckets.map { "\(root)/\($0)" }
        }
        try make(reportPaths)
        try make(codexCrashpadRoots.map { "\($0)/metadata" } + [
            "Library/Application Support/Codex/Local Storage",
            "Library/Application Support/com.openai.codex/web/Session Storage",
            "Library/Application Support/OtherApp/Crashpad/pending",
        ])
        for path in reportPaths {
            try Data("dump".utf8).write(to: home.appendingPathComponent("\(path)/report.dmp"))
            try Data("{}".utf8).write(to: home.appendingPathComponent("\(path)/report_sidecar.json"))
        }

        let found = items()
        XCTAssertEqual(found.count, reportPaths.count)
        XCTAssertEqual(Set(found.map(\.path)), Set(reportPaths.map {
            home.appendingPathComponent($0).path
        }))
        XCTAssertTrue(found.allSatisfy { $0.kind == .crashReports && $0.isKnownCache })
        XCTAssertTrue(found.allSatisfy { $0.category == .developer && $0.warning == nil })
    }

    func testCodexCrashReportsRespectRuleAndExclusions() throws {
        let paths = codexCrashpadRoots.map { "\($0)/pending" }
        try make(paths)
        XCTAssertEqual(items(enabled: [.crashReports]).count, paths.count)
        XCTAssertTrue(items(enabled: Set(ArtifactKind.allCases).subtracting([.crashReports])).isEmpty)

        let excluded = home.appendingPathComponent(paths[0]).path
        XCTAssertEqual(items(excluded: [excluded], enabled: [.crashReports]).map(\.path),
                       [home.appendingPathComponent(paths[1]).path])
    }

    func testRunningCodexGetsCrashReportWarning() throws {
        try make(codexCrashpadRoots.map { "\($0)/pending" })
        let found = items(isRunning: { $0 == "com.openai.codex" })
        XCTAssertEqual(found.count, codexCrashpadRoots.count)
        XCTAssertTrue(found.allSatisfy {
            $0.warning == "Codex/ChatGPT is running — quit it before reclaiming"
        })
    }

    func testArcUserDataProfileCaches() throws {
        try make(["Library/Caches/Arc/User Data/Default/Cache"])
        let found = items()
        // The nested layout is reported once (via the "Arc/User Data" spec) even
        // though the fallback "Arc" spec also reaches the same directory.
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.kind, .browserCache)
        XCTAssertEqual(found.first?.path,
                       home.appendingPathComponent("Library/Caches/Arc/User Data/Default/Cache").path)
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
