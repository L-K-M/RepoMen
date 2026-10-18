import XCTest
@testable import RepoMen

final class ManagedStorageCatalogTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ManagedStorage-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: try root.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
                   ?? root.path)
    }

    override func tearDownWithError() throws {
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? fileManager.removeItem(at: root)
    }

    private func areas() -> [ManagedStorageArea] {
        ManagedStorageCatalog.areas(home: root,
            systemApplicationSupport: root.appendingPathComponent("SystemSupport"))
    }

    func testCatalogSeparatesAndroidDevicesAndSDKsFromArqCacheAndLogs() {
        let paths = Set(areas().map(\.path))
        for path in ["Library/Android/sdk", ".android/avd", ".cache/uv",
                     "SystemSupport/ArqAgent/cache.noindex", "SystemSupport/ArqAgent/logs"] {
            XCTAssertTrue(paths.contains(root.appendingPathComponent(path).path), path)
        }
        XCTAssertEqual(Set(areas().map(\.id)).count, areas().count)
        XCTAssertTrue(areas().allSatisfy { $0.state == .unmeasured })
        XCTAssertTrue(areas().allSatisfy { $0.documentationURL.scheme == "https" })
    }

    func testDiscoversVersionedAndroidStudioAndSparkleStagingOnly() throws {
        for relative in ["Library/Caches/Google/AndroidStudio2026.1/index",
                         "Library/Caches/Google/Chrome/Default/Cache",
                         "Library/Caches/com.example.editor/org.sparkle-project.Sparkle/Installation/staging"] {
            try fileManager.createDirectory(at: root.appendingPathComponent(relative), withIntermediateDirectories: true)
        }
        let found = areas()
        XCTAssertTrue(found.contains { $0.path.hasSuffix("Google/AndroidStudio2026.1") })
        XCTAssertTrue(found.contains { $0.path.hasSuffix("com.example.editor/org.sparkle-project.Sparkle") })
        XCTAssertFalse(found.contains { $0.path.hasSuffix("Google/Chrome") })
    }

    func testMeasurementDistinguishesMissingAndEmptyWithoutWriting() throws {
        let area = try XCTUnwrap(areas().first { $0.title == "uv cache" })
        XCTAssertEqual(ManagedStorageCatalog.measure(area), .missing)
        let url = URL(fileURLWithPath: area.path)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertEqual(ManagedStorageCatalog.measure(area), .measured(0))
        let data = Data((0..<16_384).map { UInt8(truncatingIfNeeded: $0) })
        let entry = url.appendingPathComponent("cache-entry")
        try data.write(to: entry)
        guard case .measured(let bytes) = ManagedStorageCatalog.measure(area) else {
            return XCTFail("Expected an allocated size")
        }
        XCTAssertGreaterThanOrEqual(bytes, 16_384)
        XCTAssertEqual(try Data(contentsOf: entry), data)
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: url.path), ["cache-entry"])
    }

    func testRefusesSymlinkedMeasurementAndDiscovery() throws {
        let area = try XCTUnwrap(areas().first { $0.title == "Android SDK packages" })
        let link = URL(fileURLWithPath: area.path)
        try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: root)
        guard case .failed = ManagedStorageCatalog.measure(area) else {
            return XCTFail("A symlink must not produce an apparently complete size")
        }
        let target = root.appendingPathComponent("elsewhere/org.sparkle-project.Sparkle/Installation")
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let caches = root.appendingPathComponent("Library/Caches")
        try fileManager.createDirectory(at: caches, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: caches.appendingPathComponent("com.example.link"),
                                          withDestinationURL: target.deletingLastPathComponent().deletingLastPathComponent())
        XCTAssertFalse(areas().contains { $0.path.contains("com.example.link") })
    }

    func testUnreadableEntriesArePartialRatherThanZeroSuccess() throws {
        let area = try XCTUnwrap(areas().first { $0.title == "uv cache" })
        let url = URL(fileURLWithPath: area.path)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
        guard case .partial = ManagedStorageCatalog.measure(area) else {
            return XCTFail("An unreadable directory must be reported as a partial size")
        }
    }
}
