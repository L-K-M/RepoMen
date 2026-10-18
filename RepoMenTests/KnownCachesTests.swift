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

    // MARK: - New fixed-cache specs

    func testPnpmStoreDotLocalShare() throws {
        try make([".local/share/pnpm/store"])
        let found = items(enabled: [.pnpmStore])
        XCTAssertFalse(found.isEmpty, "should detect .local/share/pnpm/store")
        XCTAssertTrue(found.allSatisfy { $0.kind == .pnpmStore })
    }

    func testGradleWrapperDists() throws {
        try make([".gradle/wrapper/dists"])
        let found = items(enabled: [.gradleUserCache])
        XCTAssertFalse(found.isEmpty, "should detect .gradle/wrapper/dists")
        XCTAssertTrue(found.allSatisfy { $0.kind == .gradleUserCache })
    }

    func testNpmNpxCache() throws {
        try make([".npm/_npx"])
        let found = items(enabled: [.npmCache])
        XCTAssertFalse(found.isEmpty, "should detect .npm/_npx")
        XCTAssertTrue(found.allSatisfy { $0.kind == .npmCache })
    }

    // MARK: - Application caches

    func testSlackCacheAndCodeCache() throws {
        try make(["Library/Application Support/Slack/Cache",
                  "Library/Application Support/Slack/Code Cache"])
        let found = items(enabled: [.appCache])
        let slackItems = found.filter { $0.path.contains("/Slack/") }
        XCTAssertEqual(slackItems.count, 2, "should offer both Cache and Code Cache under Slack")
        XCTAssertTrue(slackItems.allSatisfy { $0.kind == .appCache })
    }

    func testSlackRunningWarning() throws {
        try make(["Library/Application Support/Slack/Cache"])
        let found = items(isRunning: { $0 == "com.tinyspeck.slackmacgap" })
        let slackItem = found.first { $0.path.contains("/Slack/") }
        XCTAssertNotNil(slackItem?.warning, "should warn when Slack is running")
        XCTAssertTrue((slackItem?.warning ?? "").contains("Slack"),
                      "warning should mention Slack")
    }

    func testClaudeCacheAndCodeCache() throws {
        try make(["Library/Application Support/Claude/Cache",
                  "Library/Application Support/Claude/Code Cache"])
        let found = items(enabled: [.appCache])
        let claudeItems = found.filter { $0.path.contains("/Claude/") }
        XCTAssertEqual(claudeItems.count, 2, "should offer both Cache and Code Cache under Claude")
        XCTAssertTrue(claudeItems.allSatisfy { $0.kind == .appCache })
    }

    func testClaudeRunningWarning() throws {
        try make(["Library/Application Support/Claude/Cache"])
        let found = items(isRunning: { $0 == "com.anthropic.claudefordesktop" })
        let claudeItem = found.first { $0.path.contains("/Claude/") }
        XCTAssertNotNil(claudeItem?.warning, "should warn when Claude is running")
    }

    func testOpenCodeCache() throws {
        try make([".cache/opencode"])
        let found = items(enabled: [.appCache])
        let ocItems = found.filter { $0.path.contains("/opencode") }
        XCTAssertFalse(ocItems.isEmpty, "should detect .cache/opencode")
        XCTAssertTrue(ocItems.allSatisfy { $0.kind == .appCache })
    }

    func testOpenCodeRunningWarning() throws {
        try make([".cache/opencode"])
        let found = items(isRunning: { $0 == "ai.opencode.desktop" })
        let ocItem = found.first { $0.path.contains("/opencode") }
        XCTAssertNotNil(ocItem?.warning, "should warn when OpenCode is running")
    }

    func testReclaimingApplicationCachesPreservesAppState() throws {
        let appRoots = ["Library/Application Support/Slack", "Library/Application Support/Claude"]
        let cachePaths = appRoots.flatMap { root in
            ["\(root)/Cache", "\(root)/Code Cache"]
        } + [".cache/opencode"]
        try make(cachePaths)
        var preserved: [URL] = []
        for root in appRoots {
            try make(["\(root)/Local Storage", "\(root)/IndexedDB"])
            preserved += ["\(root)/Local Storage/state.db", "\(root)/IndexedDB/state.db",
                          "\(root)/Cookies"].map { home.appendingPathComponent($0) }
        }
        try make([".local/share/opencode"])
        preserved.append(home.appendingPathComponent(".local/share/opencode/opencode.db"))
        for file in preserved {
            try Data("preserved state".utf8).write(to: file)
        }
        for path in cachePaths {
            try Data("regenerable cache".utf8).write(
                to: home.appendingPathComponent("\(path)/cache-entry"))
        }

        let found = items(enabled: [.appCache])
        XCTAssertEqual(Set(found.map(\.path)),
                       Set(cachePaths.map { home.appendingPathComponent($0).path }))
        let outcomes = Reclaimer.reclaim(found, method: .delete, home: home)
        XCTAssertEqual(outcomes.count, cachePaths.count)
        XCTAssertTrue(outcomes.allSatisfy { $0.failure == nil })
        XCTAssertTrue(found.allSatisfy { !fileManager.fileExists(atPath: $0.path) })
        for file in preserved {
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "preserved state")
        }
    }

    // MARK: - Zen browser

    func testZenBrowserProfileCache() throws {
        try make(["Library/Caches/zen/Profiles/abc123.default/cache2"])
        let found = items(enabled: [.browserCache])
        let zenItems = found.filter { $0.path.contains("/zen/") }
        XCTAssertFalse(zenItems.isEmpty, "should detect Zen browser profile cache2")
        XCTAssertTrue(zenItems.allSatisfy { $0.kind == .browserCache })
    }

    func testZenBrowserRunningWarning() throws {
        try make(["Library/Caches/zen/Profiles/abc123.default/cache2"])
        let found = items(isRunning: { $0 == "app.zen-browser.zen" })
        let zenItem = found.first { $0.path.contains("/zen/") }
        XCTAssertNotNil(zenItem?.warning, "should warn when Zen is running")
    }

    // MARK: - JetBrains safety regressions

    func testJetBrainsNeverOffersVersionRoot() throws {
        // Create a version directory and its children — only leaf dirs should appear.
        try make(["Library/Caches/JetBrains/2024.1/index",
                  "Library/Caches/JetBrains/2024.1/vcs-log",
                  "Library/Caches/JetBrains/2024.1/LocalHistory",
                  "Library/Caches/JetBrains/2024.1/jcef/cookies"])
        let found = items(enabled: [.ideCache])
        let jbItems = found.filter { $0.path.contains("/JetBrains/") }

        // The version root itself must never be offered.
        XCTAssertFalse(jbItems.contains { $0.path.hasSuffix("/JetBrains/2024.1") },
                       "version root must not be offered")

        // index and vcs-log leaves should be present.
        XCTAssertTrue(jbItems.contains { $0.path.hasSuffix("/JetBrains/2024.1/index") },
                      "index leaf should be offered")
        XCTAssertTrue(jbItems.contains { $0.path.hasSuffix("/JetBrains/2024.1/vcs-log") },
                      "vcs-log leaf should be offered")

        // LocalHistory and jcef/cookies must NOT be offered.
        XCTAssertFalse(jbItems.contains { $0.path.contains("/LocalHistory") },
                       "LocalHistory must not be offered")
        XCTAssertFalse(jbItems.contains { $0.path.contains("/jcef/cookies") },
                       "jcef cookies must not be offered")
    }

    func testJetBrainsAllowedRootsExcludeVersionParents() throws {
        let versionPath = "Library/Caches/JetBrains/IntelliJIdea2026.2"
        let safePaths = ["\(versionPath)/index", "\(versionPath)/vcs-log"]
        try make(safePaths + ["\(versionPath)/LocalHistory", "\(versionPath)/jcef/cookies"])
        let roots = KnownCaches.allowedRoots(home: home)
        let jetBrainsRoot = home.appendingPathComponent("Library/Caches/JetBrains").path
        XCTAssertEqual(Set(roots.filter { PathGuards.isUnder($0, root: jetBrainsRoot) }),
                       Set(safePaths.map { home.appendingPathComponent($0).path }))
        for path in ["Library/Caches/JetBrains", versionPath,
                     "\(versionPath)/LocalHistory", "\(versionPath)/jcef/cookies"] {
            let absolute = home.appendingPathComponent(path).path
            XCTAssertFalse(roots.contains { PathGuards.isUnder(absolute, root: $0) },
                           "\(path) must not be covered by an allowed root")
        }
    }

    func testJetBrainsBothBundleIDsTriggerWarning() throws {
        try make(["Library/Caches/JetBrains/2024.1/index"])
        let commercial = items(isRunning: { $0 == "com.jetbrains.intellij" })
            .first { $0.path.contains("/JetBrains/") }
        XCTAssertNotNil(commercial?.warning, "commercial IntelliJ should trigger warning")

        let ce = items(isRunning: { $0 == "com.jetbrains.intellij.ce" })
            .first { $0.path.contains("/JetBrains/") }
        XCTAssertNotNil(ce?.warning, "IntelliJ CE should trigger warning")
    }

    func testJetBrainsRespectsKindAndExclusions() throws {
        let safePaths = ["Library/Caches/JetBrains/IntelliJIdea2026.2/index",
                         "Library/Caches/JetBrains/IntelliJIdea2026.2/vcs-log"]
        try make(safePaths)
        XCTAssertTrue(items(enabled: [.browserCache]).isEmpty)
        let excluded = home.appendingPathComponent(safePaths[0]).path
        XCTAssertEqual(items(excluded: [excluded], enabled: [.ideCache]).map(\.path),
                       [home.appendingPathComponent(safePaths[1]).path])
        for item in items(enabled: [.ideCache]) {
            XCTAssertTrue(KnownCaches.allowedRoots(home: home).contains(item.path))
        }
    }

    func testJetBrainsRejectsSymlinkedCatalogRoot() throws {
        let realRoot = home.appendingPathComponent("OtherJetBrains")
        try fileManager.createDirectory(at: realRoot.appendingPathComponent("IntelliJIdea2026.2/index"),
                                        withIntermediateDirectories: true)
        try make(["Library/Caches"])
        let catalogRoot = home.appendingPathComponent("Library/Caches/JetBrains")
        try fileManager.createSymbolicLink(at: catalogRoot, withDestinationURL: realRoot)
        XCTAssertTrue(items(enabled: [.ideCache]).isEmpty)
        XCTAssertFalse(KnownCaches.allowedRoots(home: home).contains {
            PathGuards.isUnder($0, root: catalogRoot.path)
        })
    }

    func testJetBrainsRejectsSymlinkedVersionDir() throws {
        // Create a real directory and a symlink pointing to it.
        let realDir = home.appendingPathComponent("Library/Caches/JetBrains/2024.1")
        try fileManager.createDirectory(at: realDir.appendingPathComponent("index"),
                                        withIntermediateDirectories: true)
        let symlinkDir = home.appendingPathComponent("Library/Caches/JetBrains/2024.2")
        try fileManager.createSymbolicLink(at: symlinkDir, withDestinationURL: realDir)

        let found = items(enabled: [.ideCache])
        let jbItems = found.filter { $0.path.contains("/JetBrains/") }

        // The symlinked version dir's children must not appear.
        XCTAssertFalse(jbItems.contains { $0.path.contains("/2024.2") },
                       "symlinked version dir children must not be offered")
        let symlinkPath = symlinkDir.path
        XCTAssertFalse(KnownCaches.allowedRoots(home: home).contains {
            PathGuards.isUnder(symlinkPath, root: $0)
                || PathGuards.isUnder($0, root: symlinkPath)
        })
    }

    func testJetBrainsRejectsSymlinkedCacheLeaves() throws {
        let realIndex = home.appendingPathComponent("Library/Caches/JetBrains/2024.1/index")
        try fileManager.createDirectory(at: realIndex, withIntermediateDirectories: true)

        let fakeDir = home.appendingPathComponent("Library/Caches/JetBrains/2024.2")
        try fileManager.createDirectory(at: fakeDir, withIntermediateDirectories: true)
        let symlinkLeaf = fakeDir.appendingPathComponent("index")
        try fileManager.createSymbolicLink(at: symlinkLeaf, withDestinationURL: realIndex)

        let found = items(enabled: [.ideCache])
        let jbItems = found.filter { $0.path.contains("/JetBrains/") }

        XCTAssertFalse(jbItems.contains { $0.path.contains("/2024.2/index") },
                       "symlinked cache leaf must not be offered")
        XCTAssertFalse(KnownCaches.allowedRoots(home: home).contains {
            PathGuards.isUnder(symlinkLeaf.path, root: $0)
        })
    }

    // MARK: - uv cache removal

    func testUvCacheNotOffered() throws {
        try make(["Library/Caches/uv"])
        let found = items(enabled: [.uvCache])
        XCTAssertTrue(found.isEmpty, "uv cache should no longer appear as a known cache")
    }

    func testUvCacheNotInAllowedRoots() throws {
        let roots = KnownCaches.allowedRoots(home: home)
        XCTAssertFalse(roots.contains { $0.hasSuffix("/Library/Caches/uv") },
                       "uv must not be an allowed root")
    }

    // MARK: - Enabled kinds and exclusion filters for new specs

    func testNewSpecsRespectEnabledKinds() throws {
        try make([".local/share/pnpm/store",
                  ".gradle/wrapper/dists",
                  ".npm/_npx",
                  "Library/Application Support/Slack/Cache",
                  "Library/Application Support/Claude/Cache",
                  ".cache/opencode",
                  "Library/Caches/zen/Profiles/abc.default/cache2"])

        // Only pnpmStore enabled — only pnpm items should appear.
        let pnpmOnly = items(enabled: [.pnpmStore])
        XCTAssertTrue(pnpmOnly.allSatisfy { $0.kind == .pnpmStore })

        let appOnly = items(enabled: [.appCache])
        XCTAssertEqual(appOnly.count, 3)
        XCTAssertTrue(appOnly.allSatisfy { $0.kind == .appCache })
        XCTAssertTrue(appOnly.contains { $0.path.contains("/Slack/") })
        XCTAssertTrue(appOnly.contains { $0.path.contains("/Claude/") })
        XCTAssertTrue(appOnly.contains { $0.path.hasSuffix("/.cache/opencode") })
        XCTAssertTrue(items(enabled: [.ideCache, .nodeToolchainCache]).isEmpty)

        // Only browserCache enabled — only Zen should appear.
        let browserOnly = items(enabled: [.browserCache])
        XCTAssertTrue(browserOnly.allSatisfy { $0.kind == .browserCache })
    }

    func testNewSpecsRespectExcludedPaths() throws {
        try make([".local/share/pnpm/store",
                  ".gradle/wrapper/dists"])
        let excludedPnpm = home.appendingPathComponent(".local/share/pnpm/store").path
        let found = items(excluded: [excludedPnpm])
        XCTAssertFalse(found.contains { $0.path.contains("/pnpm/store") },
                       "excluded pnpm store should not appear")
        XCTAssertTrue(found.contains { $0.path.contains("/wrapper/dists") },
                      "non-excluded gradle dists should still appear")
    }

    // MARK: - Allowed roots cover all new safe leaves

    func testAllowedRootsCoverEverySpec() {
        let roots = KnownCaches.allowedRoots(home: home)
        for spec in KnownCaches.specs {
            let path = home.appendingPathComponent(spec.relativePath).path
            XCTAssertTrue(roots.contains { PathGuards.isUnder(path, root: $0) },
                          "\(spec.label) must be reclaimable under the allowed roots")
        }
    }

    func testAllowedRootsCoverNewSafeLeaves() throws {
        let roots = KnownCaches.allowedRoots(home: home)

        let pathsToCover: [String] = [
            ".local/share/pnpm/store",
            ".gradle/wrapper/dists",
            ".npm/_npx",
            "Library/Application Support/Slack/Cache",
            "Library/Application Support/Slack/Code Cache",
            "Library/Application Support/Claude/Cache",
            "Library/Application Support/Claude/Code Cache",
            ".cache/opencode",
        ]

        for relative in pathsToCover {
            let fullPath = home.appendingPathComponent(relative).path
            XCTAssertTrue(roots.contains { PathGuards.isUnder(fullPath, root: $0) },
                          "\(relative) must be covered by an allowed root")
        }
    }
}
