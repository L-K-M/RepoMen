import XCTest
@testable import RepoMen

/// Sizing against a synthetic tree — in particular the hardlink dedup, which keeps
/// pnpm-style link farms from being counted once per link.
final class DirectorySizerTests: XCTestCase {

    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RepoMenDirectorySizerTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    private func patternData(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0) })
    }

    func testMeasuresRegularFilesAndCompletes() throws {
        try patternData(10_000).write(to: root.appendingPathComponent("a.bin"))
        let measurement = DirectorySizer.measure(root)
        XCTAssertTrue(measurement.isComplete)
        XCTAssertGreaterThanOrEqual(measurement.bytes, 10_000)
    }

    func testHardlinkedFilesCountOnce() throws {
        let original = root.appendingPathComponent("original.bin")
        try patternData(100_000).write(to: original)
        try fileManager.linkItem(at: original, to: root.appendingPathComponent("link1.bin"))
        try fileManager.linkItem(at: original, to: root.appendingPathComponent("link2.bin"))

        let measurement = DirectorySizer.measure(root)
        XCTAssertGreaterThanOrEqual(measurement.bytes, 100_000)
        XCTAssertLessThan(measurement.bytes, 200_000,
                          "three directory entries share one inode — count it once")
    }

    func testNewestModificationTracked() throws {
        try patternData(1).write(to: root.appendingPathComponent("recent.txt"))
        let measurement = DirectorySizer.measure(root)
        XCTAssertGreaterThan(measurement.newestModification,
                             Date().addingTimeInterval(-60))
    }
}
