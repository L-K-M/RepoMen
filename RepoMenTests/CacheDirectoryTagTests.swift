import XCTest
@testable import RepoMen

final class CacheDirectoryTagTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default
    private let signature = "Signature: 8a477f597d28d172789f06886806bc55"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("RepoMenCacheTagTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: try root.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
                   ?? root.path)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    private func writeTag(_ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent("CACHEDIR.TAG"))
    }

    func testAcceptsExactSignatureWithOrWithoutComment() throws {
        try writeTag(signature)
        XCTAssertTrue(CacheDirectoryTag.isValid(in: root))
        try writeTag(signature + "\n# Rebuilt by scripts/build.sh.\n")
        XCTAssertTrue(CacheDirectoryTag.isValid(in: root))
    }

    func testRejectsMissingTruncatedOrIncorrectSignature() throws {
        XCTAssertFalse(CacheDirectoryTag.isValid(in: root))
        for invalid in ["", String(signature.dropLast()), signature.lowercased(),
                        " " + signature, "# " + signature, "not a cache"] {
            try writeTag(invalid)
            XCTAssertFalse(CacheDirectoryTag.isValid(in: root), invalid)
        }
    }

    func testRejectsDirectoryAndSymlinkTags() throws {
        let tag = root.appendingPathComponent("CACHEDIR.TAG")
        try fileManager.createDirectory(at: tag, withIntermediateDirectories: false)
        XCTAssertFalse(CacheDirectoryTag.isValid(in: root))
        try fileManager.removeItem(at: tag)
        let other = root.appendingPathComponent("other-tag")
        try Data(signature.utf8).write(to: other)
        try fileManager.createSymbolicLink(at: tag, withDestinationURL: other)
        XCTAssertFalse(CacheDirectoryTag.isValid(in: root))
    }

    func testRejectsSourceCheckoutEvenWithValidTag() throws {
        try writeTag(signature)
        try fileManager.createDirectory(at: root.appendingPathComponent(".git"),
                                        withIntermediateDirectories: false)
        XCTAssertFalse(CacheDirectoryTag.isValid(in: root))
        try fileManager.removeItem(at: root.appendingPathComponent(".git"))
        try Data("gitdir: elsewhere".utf8).write(to: root.appendingPathComponent(".git"))
        XCTAssertFalse(CacheDirectoryTag.isValid(in: root))
    }

    func testFindsTaggedOutputInsideMixedBuildTreeWithoutSelectingSourceCopies() throws {
        let source = root.appendingPathComponent("project/build/wt-feature/Sources")
        let output = root.appendingPathComponent("project/build/artifacts")
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: output.appendingPathComponent("debug"),
                                        withIntermediateDirectories: true)
        try Data(signature.utf8).write(to: output.appendingPathComponent("CACHEDIR.TAG"))
        let config = ScanConfiguration(roots: [root], excludedPaths: [],
                                       enabledKinds: Set(ArtifactKind.allCases))
        let items = Scanner.scan(config)
        XCTAssertEqual(items.map(\.path), [output.path])
        XCTAssertEqual(items.first?.kind.rawValue, "taggedCache")
        XCTAssertTrue(fileManager.fileExists(atPath: source.path))
    }

    func testReclaimRechecksTagContentsAndPreservesSourceSiblings() throws {
        let output = root.appendingPathComponent("dev/project/build/artifacts")
        let source = root.appendingPathComponent("dev/project/build/wt-feature/Sources")
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        let tag = output.appendingPathComponent("CACHEDIR.TAG")
        try Data(signature.utf8).write(to: tag)
        let items = Scanner.scan(ScanConfiguration(roots: [root], excludedPaths: [],
                                                   enabledKinds: Set(ArtifactKind.allCases)))
        XCTAssertEqual(items.count, 1)
        try Data("This directory now contains source files.".utf8).write(to: tag)
        let refused = Reclaimer.reclaim(items, method: .delete, home: root)
        XCTAssertNotNil(refused.first?.failure)
        XCTAssertTrue(fileManager.fileExists(atPath: output.path))
        try Data(signature.utf8).write(to: tag)
        let accepted = Reclaimer.reclaim(items, method: .delete, home: root)
        XCTAssertEqual(accepted.count, 1)
        XCTAssertNil(accepted.first?.failure)
        XCTAssertFalse(fileManager.fileExists(atPath: output.path))
        XCTAssertTrue(fileManager.fileExists(atPath: source.path))
    }

    func testReclaimRefusesMissingAndSymlinkTags() throws {
        let output = root.appendingPathComponent("dev/project/artifacts")
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        let tag = output.appendingPathComponent("CACHEDIR.TAG")
        try Data(signature.utf8).write(to: tag)
        let items = Scanner.scan(ScanConfiguration(roots: [root], excludedPaths: [],
                                                   enabledKinds: Set(ArtifactKind.allCases)))
        XCTAssertEqual(items.count, 1)
        try fileManager.removeItem(at: tag)
        XCTAssertNotNil(Reclaimer.reclaim(items, method: .delete, home: root).first?.failure)
        let otherTag = root.appendingPathComponent("other-tag")
        try Data(signature.utf8).write(to: otherTag)
        try fileManager.createSymbolicLink(at: tag, withDestinationURL: otherTag)
        XCTAssertNotNil(Reclaimer.reclaim(items, method: .delete, home: root).first?.failure)
        XCTAssertTrue(fileManager.fileExists(atPath: output.path))
    }

    func testNeverReportsGitMetadataTrashOrAppBundlesEvenWhenTagged() throws {
        for name in [".git", ".svn", ".hg", ".Trash", "Example.app"] {
            let directory = root.appendingPathComponent("project/" + name)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(signature.utf8).write(to: directory.appendingPathComponent("CACHEDIR.TAG"))
        }
        let items = Scanner.scan(ScanConfiguration(roots: [root], excludedPaths: [],
                                                   enabledKinds: Set(ArtifactKind.allCases)))
        XCTAssertTrue(items.isEmpty)
    }

    func testReclaimRefusesTaggedOutputThatBecameCheckout() throws {
        let output = root.appendingPathComponent("dev/project/artifacts")
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        try Data(signature.utf8).write(to: output.appendingPathComponent("CACHEDIR.TAG"))
        let items = Scanner.scan(ScanConfiguration(roots: [root], excludedPaths: [],
                                                   enabledKinds: Set(ArtifactKind.allCases)))
        XCTAssertEqual(items.count, 1)
        try Data("gitdir: elsewhere".utf8).write(to: output.appendingPathComponent(".git"))
        XCTAssertNotNil(Reclaimer.reclaim(items, method: .delete, home: root).first?.failure)
        XCTAssertTrue(fileManager.fileExists(atPath: output.path))
    }
}
