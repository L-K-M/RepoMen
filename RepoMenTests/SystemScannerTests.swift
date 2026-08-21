import XCTest
@testable import RepoMen

/// The privileged probe's script and its pure record parser. The parser must treat
/// every record as untrusted: only validated, catalog-covered paths become items.
final class SystemScannerTests: XCTestCase {

    private let logsChild = "/private/var/root/Library/Logs/RTCReporting"
    private let cachesChild = "/private/var/root/Library/Caches/com.apple.rtcreporting"

    /// One probe record: `<kb>\t<mtime>\t<path>` plus the NUL separator.
    private func record(_ kb: String, _ mtime: String, _ path: String) -> Data {
        Data("\(kb)\t\(mtime)\t\(path)".utf8) + Data([0])
    }

    private func items(_ records: Data,
                       excluded: Set<String> = [],
                       enabled: Set<ArtifactKind>? = nil,
                       isRunning: (String) -> Bool = { _ in false }) -> [CleanableItem] {
        SystemScanner.items(fromRecords: records,
                            excludedPaths: excluded,
                            enabledKinds: enabled ?? Set(ArtifactKind.allCases),
                            isRunning: isRunning)
    }

    func testParsesMeasuredItemsFromRecords() {
        let found = items(record("2048", "1700000000", logsChild)
                          + record("512", "1700000001", cachesChild))
        XCTAssertEqual(found.count, 2)

        let logs = found[0]
        XCTAssertEqual(logs.kind, .systemLogs)
        XCTAssertEqual(logs.label, "Root logs · RTCReporting")
        XCTAssertEqual(logs.path, logsChild)
        XCTAssertEqual(logs.sizeBytes, 2048 * 1024)
        XCTAssertTrue(logs.isMeasured, "probe items arrive pre-measured")
        XCTAssertEqual(logs.lastModified, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(logs.isSystemArea)
        XCTAssertTrue(logs.isKnownCache)
        XCTAssertNil(logs.warning)

        let caches = found[1]
        XCTAssertEqual(caches.kind, .systemCaches)
        XCTAssertEqual(caches.label, "Root caches · com.apple.rtcreporting")
    }

    func testUnknownModificationTimeShowsAsNever() {
        let found = items(record("1", "0", logsChild))
        XCTAssertEqual(found.first?.lastModified, .distantPast,
                       "epoch 0 means \"could not stat\", not \"built in 1970\"")
    }

    func testDropsRecordsThatFailCatalogValidation() {
        let hostile = record("1", "1", "/private/var/root/Library/Logs")            // the root
            + record("1", "1", "/private/var/root/Library/Logs/RTCReporting/deep")  // too deep
            + record("1", "1", "/private/var/root/Library/Logs/../Logs/x")          // traversal
            + record("1", "1", "/Users/me/Library/Logs/x")                          // outside
            + record("1", "1", "/private/var/root/Library/LogsEvil/x")              // prefix sibling
        XCTAssertTrue(items(hostile).isEmpty,
                      "no out-of-catalog record may ever become an item")
    }

    func testDropsMalformedRecordsAndDuplicates() {
        let noise = Data("nonsense".utf8) + Data([0])
            + Data("only\ttwo".utf8) + Data([0])
            + record("8", "1", logsChild)
            + record("9", "2", logsChild)   // duplicate path — first one wins
        let found = items(noise)
        XCTAssertEqual(found.map(\.path), [logsChild])
        XCTAssertEqual(found.first?.sizeBytes, 8 * 1024)
    }

    func testPathMayContainTabs() {
        let odd = "/private/var/root/Library/Logs/weird\tname"
        let found = items(record("4", "1", odd))
        XCTAssertEqual(found.first?.path, odd,
                       "the path is the last field — inner tabs must survive")
    }

    func testHonorsExclusionsAndDisabledKinds() {
        let both = record("1", "1", logsChild) + record("1", "1", cachesChild)
        XCTAssertEqual(items(both, excluded: [logsChild]).map(\.path), [cachesChild])

        let withoutLogs = Set(ArtifactKind.allCases).subtracting([.systemLogs])
        XCTAssertEqual(items(both, enabled: withoutLogs).map(\.kind), [.systemCaches])
    }

    func testCulpritWarningAppearsWhileDropboxRuns() {
        let found = items(record("1", "1", logsChild),
                          isRunning: { $0 == "com.getdropbox.dropbox" })
        XCTAssertTrue(found.first?.warning?.contains("Dropbox") ?? false)
    }

    func testProbeScriptCoversTheCatalogAndSurvivesTheRoundTrip() {
        let script = SystemScanner.probeScript
        for root in SystemAreas.roots {
            XCTAssertTrue(script.contains("'\(root.path)'"),
                          "every catalog root must be probed, shell-quoted")
        }
        XCTAssertTrue(script.contains("du -sk"), "sizes come from allocated blocks")
        XCTAssertTrue(script.contains("| /usr/bin/base64"),
                      "output must be base64-armored for the AppleScript round-trip")
        XCTAssertTrue(script.contains("[ -L \"$c\" ] && continue"),
                      "symlinked children are skipped, like the ordinary Scanner")
    }

    func testScanRunsProbeAndParses() async throws {
        let payload = record("16", "1700000000", logsChild).base64EncodedString()
        let found = try await SystemScanner.scan(
            excludedPaths: [], enabledKinds: Set(ArtifactKind.allCases),
            isRunning: { _ in false },
            runner: { script in
                XCTAssertEqual(script, SystemScanner.probeScript,
                               "the scan must run exactly the vetted probe script")
                return payload
            })
        XCTAssertEqual(found.map(\.path), [logsChild])
    }

    func testScanThrowsOnUnreadableProbeOutput() async {
        do {
            _ = try await SystemScanner.scan(
                excludedPaths: [], enabledKinds: Set(ArtifactKind.allCases),
                isRunning: { _ in false },
                runner: { _ in "not base64 !!!" })
            XCTFail("expected a failure")
        } catch {
            if case PrivilegedRunner.Failure.cancelled = error {
                XCTFail("unreadable output must not read as a user cancellation")
            }
        }
    }
}
