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

    func testParseListingKeepsForeignSnapshotsSeparateAndVerbatim() {
        // Real output from a Mac with an Arq agent snapshot and no Time Machine ones,
        // plus a Time Machine snapshot and a Carbon Copy Cloner one for good measure.
        let listing = SnapshotTool.parseListing("""
        Snapshots for disk /:
        com_haystacksoftware_arqagent_E8663CFC-7DA8-4766-BB2F-30B617AD172C_6
        com.apple.TimeMachine.2026-09-07-101010.local
        com.bombich.ccc.17F859C6-0BB0-4601-9F64-0A6EFABCA484.2026-09-07-041500
        com.apple.TimeMachine.2026-09-07-101010.local

        """)
        XCTAssertEqual(listing.snapshots, [newer], "only Time Machine local snapshots are modelled")
        XCTAssertEqual(listing.otherNames, [
            "com_haystacksoftware_arqagent_E8663CFC-7DA8-4766-BB2F-30B617AD172C_6",
            "com.bombich.ccc.17F859C6-0BB0-4601-9F64-0A6EFABCA484.2026-09-07-041500",
        ], "the header is not a snapshot; foreign names come back once, in order, untouched")
    }

    func testOwnerLabelsForForeignSnapshots() {
        XCTAssertEqual(SnapshotTool.ownerLabel(forForeignName: "com_haystacksoftware_arqagent_E8663CFC_6"), "Arq")
        XCTAssertEqual(SnapshotTool.ownerLabel(forForeignName: "com.bombich.ccc.17F859C6.2026-09-07-041500"), "Carbon Copy Cloner")
        XCTAssertEqual(SnapshotTool.ownerLabel(forForeignName: "com.apple.os.update-6E8F2A1B"), "a macOS update")
        XCTAssertEqual(SnapshotTool.ownerLabel(forForeignName: "com.apple.TimeMachine.2026-09-07-101010.backup"),
                       "Time Machine (not a local snapshot)")
        XCTAssertEqual(SnapshotTool.ownerLabel(forForeignName: "com.apple.somethingelse"), "macOS")
        XCTAssertEqual(SnapshotTool.ownerLabel(forForeignName: "org.example.snap"), "another app")
    }

    func testListAllReportsForeignSnapshotsWhileListStaysTimeMachineOnly() async throws {
        let stdout = "Snapshots for disk /:\ncom_haystacksoftware_arqagent_E8663CFC_6\n"
        let listing = try await SnapshotTool.listAll(runner: { _, _ in self.output(0, stdout: stdout) })
        XCTAssertTrue(listing.snapshots.isEmpty)
        XCTAssertEqual(listing.otherNames, ["com_haystacksoftware_arqagent_E8663CFC_6"])
        let onlyTimeMachine = try await SnapshotTool.list(runner: { _, _ in self.output(0, stdout: stdout) })
        XCTAssertTrue(onlyTimeMachine.isEmpty, "a foreign snapshot must never become deletable")
    }

    func testRowsPutTimeMachineFirstAndMarkForeignOnesUncheckable() {
        let listing = SnapshotTool.Listing(
            snapshots: [older, newer],
            otherNames: ["com_haystacksoftware_arqagent_E8663CFC_6"])
        let rows = SnapshotRow.rows(from: listing)
        XCTAssertEqual(rows.map(\.name), [older.name, newer.name, "com_haystacksoftware_arqagent_E8663CFC_6"])
        XCTAssertEqual(rows.map(\.isTimeMachine), [true, true, false])
        XCTAssertEqual(rows.map(\.owner), ["Time Machine", "Time Machine", "Arq"])
        XCTAssertNil(rows[2].snapshot, "a foreign row carries nothing that could be deleted")
        XCTAssertEqual(Set(rows.map(\.id)).count, 3, "ids stay unique across both kinds")
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

    func testDeleteMeasuresWhatEachSnapshotActuallyFreed() async {
        var samples: [Int64?] = [100, 130, 130, 135]   // before/after, per snapshot
        var settles = 0
        let outcomes = await SnapshotTool.delete([older, newer], runner: { _, _ in
            self.output(0)
        }, adminRunner: { _ in
            XCTFail("no prompt on success")
            return ""
        }, freeSpace: {
            samples.isEmpty ? nil : samples.removeFirst()
        }, settle: {
            settles += 1
        })
        XCTAssertEqual(outcomes.map(\.freedBytes), [30, 5])
        XCTAssertEqual(settles, 2, "APFS gets a moment before every after-sample")
    }

    func testDeleteLeavesTheSizeUnknownWhenItCannotBeMeasured() async {
        let outcomes = await SnapshotTool.delete([older, newer], runner: { arguments, _ in
            arguments[1] == self.older.dateToken
                ? self.output(0)
                : self.output(1, stderr: "Failed to delete local snapshot")
        }, adminRunner: { _ in
            ""
        }, freeSpace: {
            nil
        }, settle: {})
        XCTAssertEqual(outcomes.map(\.freedBytes), [nil, nil],
                       "no free-space figure and a failed delete both mean 'unknown', never 0")

        let privileged = await SnapshotTool.delete([older], runner: { _, _ in
            self.output(1, stderr: "requires root")
        }, adminRunner: { _ in
            self.payload([("OK", self.older.dateToken)])
        }, freeSpace: {
            100
        }, settle: {})
        XCTAssertNil(privileged.first?.freedBytes, "one script for the whole batch — nothing to attribute per snapshot")
        XCTAssertNil(privileged.first?.failure)
    }

    func testFreedIsNeverNegativeAndNeedsBothSamples() {
        XCTAssertEqual(SnapshotTool.freed(before: 100, after: 130), 30)
        XCTAssertEqual(SnapshotTool.freed(before: 100, after: 90), 0, "another writer can shrink free space meanwhile")
        XCTAssertNil(SnapshotTool.freed(before: nil, after: 90))
        XCTAssertNil(SnapshotTool.freed(before: 100, after: nil))
    }

    func testDeleteReportsProgressBeforeEachSnapshot() async {
        var progress: [String] = []
        _ = await SnapshotTool.delete([older, newer], runner: { _, _ in
            self.output(0)
        }, adminRunner: { _ in
            ""
        }, settle: {}, progress: { current, total, snapshot in
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
