import Foundation

/// The fixed, well-known cache locations RepoMen offers without any deep scanning.
/// Everything here is a cache *by the owning tool's contract* — if a location's tool
/// doesn't rebuild it on demand, it doesn't belong in this catalog.
///
/// Docker/OrbStack/VM disk images are deliberately absent (and hard-blocked in
/// `PathGuards`): stopped containers look like debris and aren't. See PLAN.md.
enum KnownCaches {

    struct Spec: Sendable {
        let kind: ArtifactKind
        let label: String
        /// Relative to the home directory.
        let relativePath: String
        /// Report one item per child directory (DerivedData per project, DeviceSupport
        /// per OS version) instead of one item for the whole location.
        let expandChildren: Bool
        /// When one of these apps is running, items get a warning badge (same
        /// mechanism as browsers). `appName` is the human name for that warning.
        let appName: String?
        let bundleIDs: [String]

        init(_ kind: ArtifactKind, _ label: String, _ relativePath: String,
             expandChildren: Bool = false,
             appName: String? = nil, bundleIDs: [String] = []) {
            self.kind = kind
            self.label = label
            self.relativePath = relativePath
            self.expandChildren = expandChildren
            self.appName = appName
            self.bundleIDs = bundleIDs
        }
    }

    static let specs: [Spec] = [
        Spec(.derivedData, "Xcode DerivedData", "Library/Developer/Xcode/DerivedData", expandChildren: true),
        Spec(.deviceSupport, "iOS DeviceSupport", "Library/Developer/Xcode/iOS DeviceSupport", expandChildren: true),
        Spec(.deviceSupport, "watchOS DeviceSupport", "Library/Developer/Xcode/watchOS DeviceSupport", expandChildren: true),
        Spec(.deviceSupport, "tvOS DeviceSupport", "Library/Developer/Xcode/tvOS DeviceSupport", expandChildren: true),
        Spec(.deviceSupport, "visionOS DeviceSupport", "Library/Developer/Xcode/visionOS DeviceSupport", expandChildren: true),
        Spec(.simulatorCache, "CoreSimulator caches", "Library/Developer/CoreSimulator/Caches"),
        Spec(.previewsCache, "Xcode Previews data", "Library/Developer/Xcode/UserData/Previews/Simulator Devices", expandChildren: true),
        Spec(.swiftPMCache, "SwiftPM cache", "Library/Caches/org.swift.swiftpm"),
        Spec(.testBrowserCache, "Playwright browsers", "Library/Caches/ms-playwright", expandChildren: true),
        Spec(.testBrowserCache, "Cypress versions", "Library/Caches/Cypress", expandChildren: true),
        Spec(.testBrowserCache, "Puppeteer browsers", ".cache/puppeteer", expandChildren: true),
        Spec(.nodeToolchainCache, "Electron downloads", "Library/Caches/electron"),
        Spec(.nodeToolchainCache, "electron-builder cache", "Library/Caches/electron-builder"),
        Spec(.nodeToolchainCache, "node-gyp headers", "Library/Caches/node-gyp"),
        Spec(.compilerCache, "ccache", "Library/Caches/ccache"),
        Spec(.compilerCache, "ccache (legacy location)", ".ccache"),
        Spec(.compilerCache, "sccache", "Library/Caches/Mozilla.sccache"),
        Spec(.ideCache, "JetBrains caches", "Library/Caches/JetBrains", expandChildren: true),
        Spec(.ideCache, "VS Code cache", "Library/Application Support/Code/Cache",
             appName: "VS Code", bundleIDs: ["com.microsoft.VSCode"]),
        Spec(.ideCache, "VS Code code cache", "Library/Application Support/Code/Code Cache",
             appName: "VS Code", bundleIDs: ["com.microsoft.VSCode"]),
        Spec(.ideCache, "VS Code cached data", "Library/Application Support/Code/CachedData",
             appName: "VS Code", bundleIDs: ["com.microsoft.VSCode"]),
        Spec(.ideCache, "VS Code extension downloads", "Library/Application Support/Code/CachedExtensionVSIXs",
             appName: "VS Code", bundleIDs: ["com.microsoft.VSCode"]),
        Spec(.homebrewCache, "Homebrew downloads", "Library/Caches/Homebrew/downloads"),
        Spec(.homebrewCache, "Homebrew casks", "Library/Caches/Homebrew/Cask"),
        Spec(.npmCache, "npm cache", ".npm/_cacache"),
        Spec(.yarnCache, "Yarn cache", "Library/Caches/Yarn"),
        Spec(.yarnCache, "Yarn Berry cache", ".yarn/berry/cache"),
        Spec(.pnpmStore, "pnpm store", "Library/pnpm/store"),
        Spec(.pnpmStore, "pnpm store (legacy location)", ".pnpm-store"),
        Spec(.pipCache, "pip cache", "Library/Caches/pip"),
        Spec(.uvCache, "uv cache", "Library/Caches/uv"),
        Spec(.goBuildCache, "Go build cache", "Library/Caches/go-build"),
        Spec(.cargoRegistryCache, "Cargo registry cache", ".cargo/registry/cache"),
        Spec(.cargoRegistryCache, "Cargo registry sources", ".cargo/registry/src"),
        Spec(.cargoRegistryCache, "Cargo git checkouts", ".cargo/git/checkouts"),
        Spec(.gradleUserCache, "Gradle caches", ".gradle/caches"),
        Spec(.mavenLocalRepo, "Maven local repository", ".m2/repository"),
        Spec(.cocoaPodsCache, "CocoaPods cache", "Library/Caches/CocoaPods"),
        Spec(.denoCache, "Deno cache", "Library/Caches/deno"),
        Spec(.bunCache, "Bun install cache", ".bun/install/cache"),
        Spec(.composerCache, "Composer cache", ".composer/cache"),
        Spec(.poetryCache, "Poetry cache", "Library/Caches/pypoetry"),
        Spec(.pubCache, "Dart pub cache", ".pub-cache"),
    ]

    /// Chromium-family (+ Firefox) per-profile caches. Only the `Cache`/`Code Cache`
    /// subdirectories are offered — never profile data (bookmarks, cookies, sessions).
    struct BrowserSpec: Sendable {
        let name: String
        /// Vendor directory, relative to `~/Library/Caches`.
        let cachesSubpath: String
        /// Cache directory names looked for in the vendor dir and each profile dir.
        let cacheDirNames: [String]
        let bundleIDs: [String]
    }

    static let browsers: [BrowserSpec] = [
        BrowserSpec(name: "Chrome", cachesSubpath: "Google/Chrome",
                    cacheDirNames: ["Cache", "Code Cache"], bundleIDs: ["com.google.Chrome"]),
        BrowserSpec(name: "Chrome Canary", cachesSubpath: "Google/Chrome Canary",
                    cacheDirNames: ["Cache", "Code Cache"], bundleIDs: ["com.google.Chrome.canary"]),
        BrowserSpec(name: "Brave", cachesSubpath: "BraveSoftware/Brave-Browser",
                    cacheDirNames: ["Cache", "Code Cache"], bundleIDs: ["com.brave.Browser"]),
        BrowserSpec(name: "Edge", cachesSubpath: "Microsoft Edge",
                    cacheDirNames: ["Cache", "Code Cache"], bundleIDs: ["com.microsoft.edgemac"]),
        BrowserSpec(name: "Chromium", cachesSubpath: "Chromium",
                    cacheDirNames: ["Cache", "Code Cache"], bundleIDs: ["org.chromium.Chromium"]),
        BrowserSpec(name: "Vivaldi", cachesSubpath: "Vivaldi",
                    cacheDirNames: ["Cache", "Code Cache"], bundleIDs: ["com.vivaldi.Vivaldi"]),
        // Arc keeps a Chromium "User Data" level inside its vendor dir, so its
        // profiles live one directory deeper than the other Chromium browsers.
        // The plain "Arc" spec stays as a fallback; nonexistent paths cost nothing.
        BrowserSpec(name: "Arc", cachesSubpath: "Arc/User Data",
                    cacheDirNames: ["Cache", "Code Cache"], bundleIDs: ["company.thebrowser.Browser"]),
        BrowserSpec(name: "Arc", cachesSubpath: "Arc",
                    cacheDirNames: ["Cache", "Code Cache"], bundleIDs: ["company.thebrowser.Browser"]),
        BrowserSpec(name: "Firefox", cachesSubpath: "Firefox/Profiles",
                    cacheDirNames: ["cache2"], bundleIDs: ["org.mozilla.firefox"]),
    ]

    /// Enumerates every known-cache item that currently exists. `isRunning` answers
    /// whether an app with the given bundle id is open (injected so tests need no
    /// AppKit); browser cache items get a warning while their browser runs.
    static func items(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                      excludedPaths: Set<String>,
                      enabledKinds: Set<ArtifactKind>,
                      fileManager: FileManager = .default,
                      isRunning: (String) -> Bool = { _ in false }) -> [CleanableItem] {
        var items: [CleanableItem] = []

        for spec in specs where enabledKinds.contains(spec.kind) {
            let root = home.appendingPathComponent(spec.relativePath)
            guard directoryExists(root, fileManager) else { continue }
            let warning: String? = {
                guard let appName = spec.appName,
                      spec.bundleIDs.contains(where: isRunning) else { return nil }
                return "\(appName) is running — quit it before reclaiming"
            }()
            if spec.expandChildren {
                let children = (try? fileManager.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
                for child in children where directoryExists(child, fileManager) {
                    append(&items, label: "\(spec.label) · \(child.lastPathComponent)",
                           kind: spec.kind, path: child.path, excludedPaths: excludedPaths,
                           warning: warning)
                }
            } else {
                append(&items, label: spec.label, kind: spec.kind, path: root.path,
                       excludedPaths: excludedPaths, warning: warning)
            }
        }

        guard enabledKinds.contains(.browserCache) else { return dedupedByPath(items) }
        let cachesRoot = home.appendingPathComponent("Library/Caches")
        for browser in browsers {
            let vendor = cachesRoot.appendingPathComponent(browser.cachesSubpath)
            guard directoryExists(vendor, fileManager) else { continue }
            let warning = browser.bundleIDs.contains(where: isRunning)
                ? "\(browser.name) is running — quit it before reclaiming" : nil

            // Cache dirs directly in the vendor dir (single-profile setups)…
            for cacheName in browser.cacheDirNames {
                let cache = vendor.appendingPathComponent(cacheName)
                if directoryExists(cache, fileManager) {
                    append(&items, label: "\(browser.name) · \(cacheName)",
                           kind: .browserCache, path: cache.path,
                           excludedPaths: excludedPaths, warning: warning)
                }
            }
            // …and per profile ("Default", "Profile 14", Firefox profile hashes).
            let profiles = (try? fileManager.contentsOfDirectory(
                at: vendor, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
            for profile in profiles where directoryExists(profile, fileManager) {
                for cacheName in browser.cacheDirNames {
                    let cache = profile.appendingPathComponent(cacheName)
                    if directoryExists(cache, fileManager) {
                        append(&items, label: "\(browser.name) · \(profile.lastPathComponent) · \(cacheName)",
                               kind: .browserCache, path: cache.path,
                               excludedPaths: excludedPaths, warning: warning)
                    }
                }
            }
        }
        return dedupedByPath(items)
    }

    /// Different catalog entries can legitimately resolve to the same directory (Arc
    /// ships two vendor layouts, for example). One path must yield one item — item ids
    /// ARE paths, and duplicate ids corrupt table identity. First occurrence wins.
    private static func dedupedByPath(_ items: [CleanableItem]) -> [CleanableItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.path).inserted }
    }

    /// Roots a known-cache item must live under to be reclaimable — the `Reclaimer`'s
    /// re-verification that a stored path really came from this catalog.
    /// `~/Library/Caches` covers the browser vendors and every `Library/Caches` spec.
    static func allowedRoots(home: URL) -> [String] {
        var roots = ["Library/Caches"]
        roots += specs.map(\.relativePath).filter { !$0.hasPrefix("Library/Caches/") }
        return roots.map { home.appendingPathComponent($0).path }
    }

    private static func append(_ items: inout [CleanableItem], label: String,
                               kind: ArtifactKind, path: String,
                               excludedPaths: Set<String>, warning: String? = nil) {
        guard !excludedPaths.contains(path) else { return }
        items.append(CleanableItem(label: label, kind: kind, path: path,
                                   anchorPaths: [], isKnownCache: true, warning: warning))
    }

    private static func directoryExists(_ url: URL, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
