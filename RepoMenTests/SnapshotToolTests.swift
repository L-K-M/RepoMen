import XCTest
@testable import RepoMen

/// tmutil never runs here — runners are injected. Covers the argument whitelist, the
/// list parser, the privileged fallback scripts, and the per-snapshot verdicts of
/// delete and thin, including the one-prompt fallback when tmutil wants root.
final class SnapshotToolTests: XCTestCase {

    private let older = LocalSnapshot(dateToken: "2026-09-06-091500")!
    private let newer = LocalSnapshot(dateToken: "2026-09-07-101010")!

    private func output(_ status: Int32, stdout: String = "", stderr: String = "") -> SnapshotRunner.Output {
        SnapshotRunner.Output(status: status, stdout: stdout, stderr: stderr)
    }

    /// STATUS\tDATE records, NUL-separated, base64-armored — what the batch script emits.
    private func payload(_ statuses: [(String, String)]) -> String {
        statuses
            .map { Data("\($0.0)\t\($0.1)".utf8) + Data([0]) }
            .reduce(Data(), +)
            .base64EncodedString()
    }

    // MARK: Parsing

    func testParseListSkipsHeaderAndForeignSnapshotsAndSortsOldestFirst() {
        let listing = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-09-07-101010.local
        com.apple.TimeMachine.2026-09-06-091500.local
        com.bombich.ccc.17F859C6-0BB0-4601-9F64-0A6EFABCA484.2026-09-07-041500
        com.apple.os.update-6E8F2A1B
        com.apple.TimeMachine.2026-09-07-101010.local

        """
        XCTAssertEqual(SnapshotTool.parseList(listing).map(\.dateToken),
                       ["2026-09-06-091500", "2026-09-07-101010"],
                       "oldest first, deduplicated, nothing foreign")
    }

    func testParseListOfEmptyOutputIsEmpty() {
        XCTAssertTrue(SnapshotTool.parseList("").isEmpty)
        XCTAssertTrue(SnapshotTool.parseList("Snapshots for disk /:\n").isEmpty)
    }

    func testParseStatusesMapsDatesToVerdicts() throws {
        let data = try XCTUnwrap(PrivilegedRunner.decodePayload(
            payload([("OK", older.dateToken), ("ERR", newer.dateToken), ("garbage", "")])))
        let statuses = SnapshotTool.parseStatuses(data)
        XCTAssertEqual(statuses[older.dateToken], "OK")
        XCTAssertEqual(statuses[newer.dateToken], "ERR")
    }

    // MARK: Arguments

    func testArgumentBuildersProduceExactlyTheThreeAllowedInvocations() {
        XCTAssertEqual(SnapshotTool.listArguments, ["listlocalsnapshots", "/"])
        XCTAssertEqual(SnapshotTool.deleteArguments(for: older),
                       ["deletelocalsnapshots", "2026-09-06-091500"])
        XCTAssertEqual(SnapshotTool.thinArguments(bytes: 5_000_000_000, urgency: 3),
                       ["thinlocalsnapshots", "/", "5000000000", "3"])
        XCTAssertEqual(SnapshotTool.thinArguments(bytes: -7, urgency: 9),
                       ["thinlocalsnapshots", "/", "1", "4"],
                       "amount and urgency are clamped, never passed through raw")
        for arguments in [SnapshotTool.listArguments,
                          SnapshotTool.deleteArguments(for: older),
                          SnapshotTool.thinArguments(bytes: 1, urgency: 1)] {
            XCTAssertNil(SnapshotTool.validate(arguments: arguments), "\(arguments) must validate")
        }
    }

    func testValidateRefusesEverythingOutsideTheWhitelist() {
        let refused: [[String]] = [
            [],
            ["localsnapshot"],                                      // creating snapshots
            ["deletelocalsnapshots", "/"],                          // whole-volume wipe — not offered
            ["deletelocalsnapshots", "/System/Volumes/Data"],
            ["deletelocalsnapshots", "2026-09-06-091500", "2026-09-07-101010"],
            ["deletelocalsnapshots", "2026-13-06-091500"],
            ["deletelocalsnapshots", "com.apple.TimeMachine.2026-09-06-091500.local"],
            ["listlocalsnapshots", "/Volumes/Backup"],
            ["listlocalsnapshots"],
            ["thinlocalsnapshots", "/"],
            ["thinlocalsnapshots", "/Volumes/Backup", "1", "4"],
            ["thinlocalsnapshots", "/", "0", "4"],
            ["thinlocalsnapshots", "/", "1", "5"],
            ["thinlocalsnapshots", "/", "1e9", "4"],
            ["delete", "/Volumes/Backup/Backups.backupdb"],         // a Time Machine BACKUP
            ["disable"],
            ["-c", "rm -rf /"],
        ]
        for arguments in refused {
            XCTAssertNotNil(SnapshotTool.validate(arguments: arguments), "\(arguments) must be refused")
        }
    }

    // MARK: Privileged fallback scripts

    func testPrivilegedScriptQuotesEveryWordAndRefusesInvalidArguments() {
        XCTAssertEqual(SnapshotTool.privilegedScript(arguments: SnapshotTool.thinArguments(bytes: 42, urgency: 4)),
                       "'/usr/bin/tmutil' 'thinlocalsnapshots' '/' '42' '4'")
        XCTAssertNil(SnapshotTool.privilegedScript(arguments: ["delete", "/Volumes/Backup"]),
                     "the whitelist applies to the privileged path too")
    }

    func testPrivilegedDeleteScriptReportsPerDateAndOnlyEverCallsTmutil() {
        let script = SnapshotTool.privilegedDeleteScript(for: [older, newer])
        XCTAssertTrue(script.contains("'/usr/bin/tmutil' deletelocalsnapshots '2026-09-06-091500'"))
        XCTAssertTrue(script.contains("'/usr/bin/tmutil' deletelocalsnapshots '2026-09-07-101010'"))
        XCTAssertTrue(script.contains("printf 'OK\\t%s\\0' '2026-09-06-091500'"))
        XCTAssertTrue(script.contains("printf 'ERR\\t%s\\0' '2026-09-06-091500'"))
        XCTAssertTrue(script.hasSuffix(") | /usr/bin/base64"))
        XCTAssertFalse(script.contains("rm "), "the script only ever calls tmutil")
    }

    // MARK: Privilege-failure heuristic

    func testPrivilegeFailureHeuristicOnlyFiresOnFailedRunsThatMentionPrivileges() {
        XCTAssertTrue(output(1, stderr: "tmutil: deletelocalsnapshots requires root privileges.").looksLikePrivilegeFailure)
        XCTAssertTrue(output(1, stderr: "Operation not permitted").looksLikePrivilegeFailure)
        XCTAssertFalse(output(0, stdout: "Deleted local snapshot '2026-09-06-091500'").looksLikePrivilegeFailure,
                       "a success never triggers the admin prompt, whatever it printed")
        XCTAssertFalse(output(1, stderr: "Failed to delete local snapshot '2026-09-06-091500'").looksLikePrivilegeFailure,
                       "a plain failure is reported, not escalated")
        XCTAssertEqual(output(3).message, "tmutil exited with status 3",
                       "silence still yields a reportable reason")
    }

    // MARK: list

    func testListParsesASuccessfulRun() async throws {
        let snapshots = try await SnapshotTool.list(runner: { arguments, _ in
            XCTAssertEqual(arguments, ["listlocalsnapshots", "/"])
            return self.output(0, stdout: "Snapshots for disk /:\ncom.apple.TimeMachine.2026-09-07-101010.local\n")
        })
        XCTAssertEqual(snapshots, [newer])
    }

    func testListThrowsTmutilsMessageOnFailure() async {
        do {
            _ = try await SnapshotTool.list(runner: { _, _ in
                self.output(1, stderr: "tmutil: something went wrong")
            })
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? SnapshotTool.Failure, .toolFailed("tmutil: something went wrong"))
        }
    }

    // MARK: delete

    func testDeleteRunsOneTmutilPerSnapshotInOrderAndReportsEach() async {
        var seen: [[String]] = []
        let outcomes = await SnapshotTool.delete([older, newer], runner: { arguments, _ in
            seen.append(arguments)
            return arguments[1] == self.older.dateToken
                ? self.output(0)
                : self.output(1, stderr: "Failed to delete local snapshot")
        }, adminRunner: { _ in
            XCTFail("no administrator prompt for an ordinary failure")
            return ""
        })
        XCTAssertEqual(seen, [["deletelocalsnapshots", older.dateToken],
                              ["deletelocalsnapshots", newer.dateToken]])
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertNil(outcomes[0].failure)
        XCTAssertEqual(outcomes[1].failure, "Failed to delete local snapshot")
    }

    func testDeleteFallsBackToOneAdministratorPromptWhenTmutilWantsRoot() async {
        var unprivilegedCalls = 0
        var adminScripts: [String] = []
        let outcomes = await SnapshotTool.delete([older, newer], runner: { _, _ in
            unprivilegedCalls += 1
            return self.output(1, stderr: "tmutil: deletelocalsnapshots requires root privileges.")
        }, adminRunner: { script in
            adminScripts.append(script)
            return self.payload([("OK", self.older.dateToken), ("ERR", self.newer.dateToken)])
        })
        XCTAssertEqual(unprivilegedCalls, 1, "after the first refusal the rest goes straight to the admin path")
        XCTAssertEqual(adminScripts.count, 1, "one password prompt for the whole batch")
        XCTAssertTrue(adminScripts.first?.contains(older.dateToken) ?? false)
        XCTAssertTrue(adminScripts.first?.contains(newer.dateToken) ?? false)
        XCTAssertNil(outcomes[0].failure)
        XCTAssertEqual(outcomes[1].failure, "tmutil could not delete it, even as administrator")
    }

    func testDeleteFailsSafeWhenTheHelperReportsNothing() async {
        let outcomes = await SnapshotTool.delete([older], runner: { _, _ in
            self.output(1, stderr: "requires root")
        }, adminRunner: { _ in
            self.payload([])
        })
        XCTAssertEqual(outcomes.first?.failure, "the privileged helper reported no result")
    }

    func testDeleteReportsACancelledAdministratorPromptPerSnapshot() async {
        let outcomes = await SnapshotTool.delete([older, newer], runner: { _, _ in
            self.output(1, stderr: "requires root")
        }, adminRunner: { _ in
            throw PrivilegedRunner.Failure.cancelled
        })
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes.allSatisfy { $0.failure?.contains("cancelled") ?? false })
    }

    func testDeleteReportsARunnerErrorAsThatSnapshotsFailure() async {
        let outcomes = await SnapshotTool.delete([older], runner: { _, _ in
            throw SnapshotRunner.Failure.timedOut(600)
        }, adminRunner: { _ in
            XCTFail("a timeout is not a privilege problem")
            return ""
        })
        XCTAssertEqual(outcomes.first?.failure, SnapshotRunner.Failure.timedOut(600).errorDescription)
    }

    func testDeleteReportsProgressBeforeEachSnapshot() async {
        var progress: [String] = []
        _ = await SnapshotTool.delete([older, newer], runner: { _, _ in
            self.output(0)
        }, adminRunner: { _ in
            ""
        }, progress: { current, total, snapshot in
            progress.append("\(current)/\(total) \(snapshot.dateToken)")
        })
        XCTAssertEqual(progress, ["1/2 2026-09-06-091500", "2/2 2026-09-07-101010"])
    }

    // MARK: thin

    func testThinReturnsTmutilsOutputOnSuccess() async throws {
        let result = try await SnapshotTool.thin(bytes: 10_000_000_000, urgency: 4, runner: { arguments, _ in
            XCTAssertEqual(arguments, ["thinlocalsnapshots", "/", "10000000000", "4"])
            return self.output(0, stdout: "Thinned local snapshots:\n2026-09-06-091500\n")
        }, adminRunner: { _ in
            XCTFail("no prompt on success")
            return ""
        })
        XCTAssertEqual(result, SnapshotTool.ThinResult(output: "Thinned local snapshots:\n2026-09-06-091500",
                                                       usedAdministratorPrivileges: false))
    }

    func testThinEscalatesOnlyPrivilegeFailures() async throws {
        let result = try await SnapshotTool.thin(bytes: 1, urgency: 2, runner: { _, _ in
            self.output(1, stderr: "Operation not permitted")
        }, adminRunner: { script in
            XCTAssertEqual(script, "'/usr/bin/tmutil' 'thinlocalsnapshots' '/' '1' '2'")
            return "Thinned local snapshots:\n"
        })
        XCTAssertTrue(result.usedAdministratorPrivileges)

        do {
            _ = try await SnapshotTool.thin(bytes: 1, urgency: 2, runner: { _, _ in
                self.output(1, stderr: "Thinning failed: no snapshots")
            }, adminRunner: { _ in
                XCTFail("an ordinary failure must not escalate")
                return ""
            })
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? SnapshotTool.Failure, .toolFailed("Thinning failed: no snapshots"))
        }
    }

    func testThinSurfacesACancelledPromptAsCancelled() async {
        do {
            _ = try await SnapshotTool.thin(bytes: 1, urgency: 4, runner: { _, _ in
                self.output(1, stderr: "requires root")
            }, adminRunner: { _ in
                throw PrivilegedRunner.Failure.cancelled
            })
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? SnapshotTool.Failure, .cancelled)
        }
    }

    // MARK: Runner guard

    func testRunnerRefusesArgumentsOutsideTheWhitelistBeforeSpawning() async {
        do {
            _ = try await SnapshotRunner.run(arguments: ["delete", "/Volumes/Backup"], timeout: 1)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? SnapshotRunner.Failure,
                           .refusedArguments("tmutil verb delete is not allowed"))
        }
    }
}
