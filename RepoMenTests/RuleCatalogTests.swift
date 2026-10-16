import XCTest
@testable import RepoMen

/// Pure matching tests — the whole "is this really a build artifact" contract.
final class RuleCatalogTests: XCTestCase {

    private let allKinds = Set(ArtifactKind.allCases)

    private func match(_ name: String,
                       siblings: Set<String>,
                       contents: Set<String> = [],
                       enabled: Set<ArtifactKind>? = nil) -> RuleCatalog.Match? {
        RuleCatalog.match(directoryName: name,
                          parentPath: "/Users/test/dev/proj",
                          siblingNames: siblings.union([name]),
                          contents: { contents },
                          enabledKinds: enabled ?? allKinds)
    }

    // MARK: Anchored matches

    func testRustTargetNeedsCargoToml() {
        let hit = match("target", siblings: ["Cargo.toml", "src"])
        XCTAssertEqual(hit?.rule.kind, .rustTarget)
        XCTAssertEqual(hit?.anchorPaths, ["/Users/test/dev/proj/Cargo.toml"])

        XCTAssertNil(match("target", siblings: ["src", "README.md"]),
                     "a folder that merely happens to be called target must not match")
    }

    func testTargetWithPomIsMaven() {
        XCTAssertEqual(match("target", siblings: ["pom.xml"])?.rule.kind, .mavenTarget)
    }

    func testNodeModulesNeedsPackageJSON() {
        XCTAssertEqual(match("node_modules", siblings: ["package.json"])?.rule.kind, .nodeModules)
        XCTAssertNil(match("node_modules", siblings: ["index.html"]))
    }

    func testSwiftPMBuild() {
        XCTAssertEqual(match(".build", siblings: ["Package.swift"])?.rule.kind, .swiftPMBuild)
        XCTAssertNil(match(".build", siblings: []))
    }

    func testTagFileNameAloneDoesNotProveRegenerability() {
        XCTAssertNil(match("artifacts", siblings: [], contents: ["CACHEDIR.TAG"]))
        XCTAssertFalse(RuleCatalog.isUnambiguousArtifactName("artifacts"))
        XCTAssertNil(match("build", siblings: ["Package.swift"], contents: ["Sources", "Tests"]),
                     "a Swift manifest does not make a mixed build directory disposable")
    }

    func testValidCacheTagMatchesAnyNameAndRespectsKindToggle() {
        let hit = RuleCatalog.match(directoryName: "artifacts", parentPath: "/dev/project/build",
                                    siblingNames: [], contents: { [] }, enabledKinds: allKinds,
                                    cacheTagIsValid: { true })
        XCTAssertEqual(hit?.rule.kind, .taggedCache)
        XCTAssertEqual(hit?.anchorPaths, ["/dev/project/build/artifacts/CACHEDIR.TAG"])
        XCTAssertNil(RuleCatalog.match(directoryName: "artifacts", parentPath: "/dev/project/build",
                                       siblingNames: [], contents: { [] },
                                       enabledKinds: allKinds.subtracting([.taggedCache]),
                                       cacheTagIsValid: { true }))
    }

    func testXcodeBuildMatchesOnSuffixAnchor() {
        let hit = match("build", siblings: ["MyApp.xcodeproj"])
        XCTAssertEqual(hit?.rule.kind, .xcodeBuild)
        XCTAssertEqual(hit?.anchorPaths, ["/Users/test/dev/proj/MyApp.xcodeproj"])
    }

    func testGradleAnchors() {
        XCTAssertEqual(match("build", siblings: ["build.gradle.kts"])?.rule.kind, .gradleBuild)
        XCTAssertEqual(match(".gradle", siblings: ["settings.gradle"])?.rule.kind, .gradleBuild)
    }

    func testDotnetBinNeedsProjectFile() {
        XCTAssertEqual(match("bin", siblings: ["App.csproj"])?.rule.kind, .dotnetBuild)
        XCTAssertEqual(match("obj", siblings: ["App.fsproj"])?.rule.kind, .dotnetBuild)
        XCTAssertNil(match("bin", siblings: ["main.c"]),
                     "bin without a project file could be anything — leave it alone")
    }

    func testVendorNeedsComposerOrGoAnchor() {
        XCTAssertEqual(match("vendor", siblings: ["composer.json"])?.rule.kind, .phpVendor)
        XCTAssertEqual(match("vendor", siblings: ["go.mod"])?.rule.kind, .goVendor)
        XCTAssertNil(match("vendor", siblings: ["README.md"]),
                     "hand-vendored code without a manifest must never match")
    }

    func testTerraformNeedsLockfileOrTfAnchor() {
        XCTAssertEqual(match(".terraform", siblings: [".terraform.lock.hcl"])?.rule.kind,
                       .terraformCache)
        XCTAssertEqual(match(".terraform", siblings: ["main.tf"])?.rule.kind,
                       .terraformCache)
        XCTAssertNil(match(".terraform", siblings: ["notes.txt"]),
                     "a .terraform dir without a Terraform project next to it proves nothing")
    }

    func testNewJSBuildOutputsNeedPackageJSON() {
        for name in [".astro", ".expo", ".docusaurus", ".output", ".cache"] {
            XCTAssertEqual(match(name, siblings: ["package.json"])?.rule.kind, .jsBuildOutput,
                           "\(name) should match with a package.json anchor")
            XCTAssertNil(match(name, siblings: []),
                         "\(name) must not match without the anchor")
        }
    }

    // MARK: Inner anchors

    func testVenvNeedsPyvenvCfgInside() {
        XCTAssertEqual(match(".venv", siblings: [], contents: ["pyvenv.cfg", "bin"])?.rule.kind,
                       .pythonVenv)
        XCTAssertNil(match(".venv", siblings: [], contents: ["bin", "lib"]),
                     "a .venv without pyvenv.cfg is not provably a venv")
        let hit = match("venv", siblings: [], contents: ["pyvenv.cfg"])
        XCTAssertEqual(hit?.anchorPaths, ["/Users/test/dev/proj/venv/pyvenv.cfg"])
    }

    func testCMakeBuildNeedsCacheFileInside() {
        XCTAssertEqual(match("cmake-build-debug", siblings: [], contents: ["CMakeCache.txt"])?.rule.kind,
                       .cmakeBuild)
        XCTAssertEqual(match("build", siblings: [], contents: ["CMakeCache.txt"])?.rule.kind,
                       .cmakeBuild)
        XCTAssertNil(match("build", siblings: [], contents: ["something.o"]))
    }

    // MARK: Name-only matches

    func testUnambiguousNamesMatchAlone() {
        XCTAssertEqual(match("__pycache__", siblings: [])?.rule.kind, .pythonCache)
        XCTAssertEqual(match(".mypy_cache", siblings: [])?.rule.kind, .pythonCache)
        XCTAssertTrue(RuleCatalog.isUnambiguousArtifactName("__pycache__"))
        XCTAssertFalse(RuleCatalog.isUnambiguousArtifactName("target"))
        XCTAssertFalse(RuleCatalog.isUnambiguousArtifactName(".venv"),
                       "venv has an inner anchor, so the name alone proves nothing")
    }

    // MARK: Kind toggles

    func testDisabledKindDoesNotMatch() {
        let withoutRust = allKinds.subtracting([.rustTarget])
        XCTAssertNil(match("target", siblings: ["Cargo.toml"], enabled: withoutRust))
        // …but the same name still matches other enabled rules.
        XCTAssertEqual(match("target", siblings: ["Cargo.toml", "pom.xml"], enabled: withoutRust)?.rule.kind,
                       .mavenTarget)
    }

    // MARK: Descend policy

    func testNeverDescendCoversUnambiguousArtifacts() {
        XCTAssertTrue(RuleCatalog.neverDescend.contains("node_modules"))
        XCTAssertTrue(RuleCatalog.neverDescend.contains("__pycache__"))
        XCTAssertTrue(RuleCatalog.neverDescend.contains(".astro"))
        XCTAssertTrue(RuleCatalog.neverDescend.contains(".cache"))
        XCTAssertFalse(RuleCatalog.neverDescend.contains("build"),
                       "generic names might be ordinary folders — the scanner must descend")
        XCTAssertFalse(RuleCatalog.neverDescend.contains("target"))
        XCTAssertFalse(RuleCatalog.neverDescend.contains("vendor"),
                       "unanchored vendor dirs may hold real code — the scanner must descend")
    }
}
