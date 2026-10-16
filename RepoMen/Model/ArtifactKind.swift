import SwiftUI

/// Sidebar grouping for everything RepoMen can find.
enum ArtifactCategory: String, CaseIterable, Identifiable, Sendable {
    case projects
    case developer
    case packageManagers
    case browsers
    case system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .projects: return "Project artifacts"
        case .developer: return "Developer caches"
        case .packageManagers: return "Package managers"
        case .browsers: return "Browser caches"
        case .system: return "System (root)"
        }
    }

    var symbol: String {
        switch self {
        case .projects: return "hammer"
        case .developer: return "wrench.and.screwdriver"
        case .packageManagers: return "shippingbox"
        case .browsers: return "globe"
        case .system: return "lock.shield"
        }
    }

    var tint: Color {
        switch self {
        case .projects: return .orange
        case .developer: return .blue
        case .packageManagers: return .brown
        case .browsers: return .teal
        case .system: return .red
        }
    }
}

/// Every kind of reclaimable thing RepoMen knows about. Each kind carries the one
/// sentence that justifies deleting it — if a kind can't state how the artifact comes
/// back, it doesn't belong in this enum (see PLAN.md's trust model).
enum ArtifactKind: String, CaseIterable, Codable, Identifiable, Sendable {
    // Project artifacts (anchor-based deep scan).
    case rustTarget
    case nodeModules
    case jsBuildOutput
    case swiftPMBuild
    case xcodeBuild
    case cocoaPods
    case gradleBuild
    case mavenTarget
    case flutterBuild
    case pythonCache
    case pythonVenv
    case cmakeBuild
    case dotnetBuild
    case elixirBuild
    case haskellBuild
    case zigBuild
    case phpVendor
    case goVendor
    case terraformCache
    case taggedCache

    // Developer caches (well-known locations).
    case derivedData
    case deviceSupport
    case simulatorCache
    case previewsCache
    case swiftPMCache
    case testBrowserCache
    case nodeToolchainCache
    case compilerCache
    case ideCache

    // Package-manager caches.
    case homebrewCache
    case npmCache
    case yarnCache
    case pnpmStore
    case pipCache
    case uvCache
    case goBuildCache
    case cargoRegistryCache
    case gradleUserCache
    case mavenLocalRepo
    case cocoaPodsCache
    case denoCache
    case bunCache
    case composerCache
    case poetryCache
    case pubCache

    // Browsers.
    case browserCache

    // Root-owned system areas (admin-gated scan — see SystemAreas).
    case systemLogs
    case systemCaches

    var id: String { rawValue }

    var category: ArtifactCategory {
        switch self {
        case .rustTarget, .nodeModules, .jsBuildOutput, .swiftPMBuild, .xcodeBuild,
             .cocoaPods, .gradleBuild, .mavenTarget, .flutterBuild, .pythonCache,
             .pythonVenv, .cmakeBuild, .dotnetBuild, .elixirBuild, .haskellBuild,
             .zigBuild, .phpVendor, .goVendor, .terraformCache, .taggedCache:
            return .projects
        case .derivedData, .deviceSupport, .simulatorCache, .previewsCache,
             .swiftPMCache, .testBrowserCache, .nodeToolchainCache, .compilerCache,
             .ideCache:
            return .developer
        case .homebrewCache, .npmCache, .yarnCache, .pnpmStore, .pipCache, .uvCache,
             .goBuildCache, .cargoRegistryCache, .gradleUserCache, .mavenLocalRepo,
             .cocoaPodsCache, .denoCache, .bunCache, .composerCache, .poetryCache,
             .pubCache:
            return .packageManagers
        case .browserCache:
            return .browsers
        case .systemLogs, .systemCaches:
            return .system
        }
    }

    var label: String {
        switch self {
        case .rustTarget: return "Rust build"
        case .nodeModules: return "node_modules"
        case .jsBuildOutput: return "JS build output"
        case .swiftPMBuild: return "SwiftPM build"
        case .xcodeBuild: return "Xcode build"
        case .cocoaPods: return "CocoaPods pods"
        case .gradleBuild: return "Gradle build"
        case .mavenTarget: return "Maven build"
        case .flutterBuild: return "Flutter build"
        case .pythonCache: return "Python cache"
        case .pythonVenv: return "Python venv"
        case .cmakeBuild: return "CMake build"
        case .dotnetBuild: return ".NET build"
        case .elixirBuild: return "Elixir build"
        case .haskellBuild: return "Haskell build"
        case .zigBuild: return "Zig build"
        case .phpVendor: return "PHP vendor"
        case .goVendor: return "Go vendor"
        case .terraformCache: return "Terraform cache"
        case .taggedCache: return "Tagged build/cache output"
        case .derivedData: return "DerivedData"
        case .deviceSupport: return "Device support"
        case .simulatorCache: return "Simulator cache"
        case .previewsCache: return "Xcode Previews"
        case .swiftPMCache: return "SwiftPM cache"
        case .testBrowserCache: return "Test browsers"
        case .nodeToolchainCache: return "Node toolchain"
        case .compilerCache: return "Compiler cache"
        case .ideCache: return "IDE caches"
        case .homebrewCache: return "Homebrew cache"
        case .npmCache: return "npm cache"
        case .yarnCache: return "Yarn cache"
        case .pnpmStore: return "pnpm store"
        case .pipCache: return "pip cache"
        case .uvCache: return "uv cache"
        case .goBuildCache: return "Go build cache"
        case .cargoRegistryCache: return "Cargo registry"
        case .gradleUserCache: return "Gradle caches"
        case .mavenLocalRepo: return "Maven repository"
        case .cocoaPodsCache: return "CocoaPods cache"
        case .denoCache: return "Deno cache"
        case .bunCache: return "Bun cache"
        case .composerCache: return "Composer cache"
        case .poetryCache: return "Poetry cache"
        case .pubCache: return "Dart pub cache"
        case .browserCache: return "Browser cache"
        case .systemLogs: return "System logs"
        case .systemCaches: return "System caches"
        }
    }

    var symbol: String {
        switch self {
        case .rustTarget: return "gearshape.2"
        case .nodeModules, .jsBuildOutput: return "curlybraces"
        case .swiftPMBuild, .swiftPMCache: return "swift"
        case .xcodeBuild, .derivedData: return "hammer"
        case .cocoaPods, .cocoaPodsCache: return "cube"
        case .gradleBuild, .gradleUserCache: return "gearshape"
        case .mavenTarget, .mavenLocalRepo: return "archivebox"
        case .flutterBuild: return "bird"
        case .pythonCache: return "memorychip"
        case .pythonVenv: return "leaf"
        case .cmakeBuild: return "square.stack.3d.up"
        case .dotnetBuild: return "square.grid.2x2"
        case .elixirBuild: return "drop"
        case .haskellBuild: return "function"
        case .zigBuild: return "bolt"
        case .phpVendor, .goVendor: return "puzzlepiece"
        case .terraformCache: return "building.columns"
        case .taggedCache: return "hammer"
        case .deviceSupport: return "iphone"
        case .simulatorCache: return "square.on.square"
        case .previewsCache: return "eye"
        case .testBrowserCache: return "testtube.2"
        case .nodeToolchainCache: return "hexagon"
        case .compilerCache: return "cpu"
        case .ideCache: return "macwindow"
        case .homebrewCache: return "mug"
        case .npmCache, .yarnCache, .goBuildCache: return "shippingbox"
        case .pnpmStore, .cargoRegistryCache: return "tray.full"
        case .pipCache, .uvCache: return "tray.2"
        case .denoCache: return "cube.transparent"
        case .bunCache: return "circle.grid.2x1"
        case .composerCache: return "music.note"
        case .poetryCache: return "text.book.closed"
        case .pubCache: return "wineglass"
        case .browserCache: return "globe"
        case .systemLogs: return "scroll"
        case .systemCaches: return "cylinder.split.1x2"
        }
    }

    /// One sentence shown in the UI explaining how this comes back after deletion.
    var regenerationHint: String {
        switch self {
        case .rustTarget: return "Recreated by the next cargo build."
        case .nodeModules: return "Recreated by npm/yarn/pnpm install."
        case .jsBuildOutput: return "Recreated by the next dev/build run."
        case .swiftPMBuild: return "Recreated by the next swift build."
        case .xcodeBuild: return "Recreated by the next Xcode build."
        case .cocoaPods: return "Recreated by pod install."
        case .gradleBuild: return "Recreated by the next Gradle build."
        case .mavenTarget: return "Recreated by the next mvn build."
        case .flutterBuild: return "Recreated by the next flutter build."
        case .pythonCache: return "Recreated automatically by Python tooling."
        case .pythonVenv: return "Recreate with python -m venv / uv — reinstalls packages."
        case .cmakeBuild: return "Recreated by the next CMake configure + build."
        case .dotnetBuild: return "Recreated by the next dotnet build."
        case .elixirBuild: return "Recreated by mix deps.get + mix compile."
        case .haskellBuild: return "Recreated by the next stack/cabal build."
        case .zigBuild: return "Recreated by the next zig build."
        case .phpVendor: return "Recreated by composer install (some teams commit vendor/)."
        case .goVendor: return "Recreated by go mod vendor."
        case .terraformCache: return "Recreated by terraform init — workspace selection resets to default."
        case .taggedCache: return "Declared regenerable by its owning tool through CACHEDIR.TAG."
        case .derivedData: return "Xcode rebuilds indexes and products on demand."
        case .deviceSupport: return "Re-copied from the device on next connect."
        case .simulatorCache: return "Recreated by the simulator on demand."
        case .previewsCache: return "Preview simulators are recreated on the next preview render."
        case .swiftPMCache: return "Packages are re-fetched on the next resolve."
        case .testBrowserCache: return "Re-downloaded by the test runner on its next run."
        case .nodeToolchainCache: return "Re-downloaded on the next build or install."
        case .compilerCache: return "Rebuilt transparently — the next builds recompile from scratch."
        case .ideCache: return "The IDE re-indexes on next launch — can be slow for big projects."
        case .homebrewCache: return "Downloads are re-fetched by brew on demand."
        case .npmCache, .yarnCache, .pipCache, .uvCache, .cargoRegistryCache,
             .cocoaPodsCache:
            return "Re-downloaded on the next install."
        case .pnpmStore: return "Re-downloaded on the next install — projects share it via links, so freed space may be less than shown."
        case .goBuildCache: return "Recreated by the next go build."
        case .gradleUserCache: return "Re-downloaded on the next build — can be slow."
        case .mavenLocalRepo: return "Re-downloaded on the next build — locally installed artifacts need mvn install again. Can be slow."
        case .denoCache: return "Re-fetched by deno on the next run."
        case .bunCache: return "Re-downloaded on the next bun install."
        case .composerCache: return "Re-downloaded on the next composer install."
        case .poetryCache: return "Re-downloaded on the next poetry install."
        case .pubCache: return "Re-downloaded by dart/flutter pub get — every project refills it."
        case .browserCache: return "The browser refills its cache while browsing."
        case .systemLogs: return "Diagnostic logs nothing reads back — the daemon (e.g. rtcreportingd) starts a fresh file when it next logs."
        case .systemCaches: return "Rebuilt on demand by the owning system service."
        }
    }

    /// Safe but *expensive* to rebuild (big re-downloads / reinstalls / re-indexing) —
    /// the UI adds a visible note so these aren't reclaimed casually.
    var isSlowToRegenerate: Bool {
        switch self {
        case .pythonVenv, .pnpmStore, .gradleUserCache, .mavenLocalRepo, .cocoaPods,
             .compilerCache, .ideCache, .pubCache:
            return true
        default:
            return false
        }
    }
}
