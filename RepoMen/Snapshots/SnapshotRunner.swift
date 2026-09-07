import Foundation

/// Runs Apple's `tmutil` (`/usr/bin/tmutil`) directly — no shell, arguments as an
/// array — as the current user. The local-snapshot verbs are not among those the
/// tmutil man page marks "Requires root and Full Disk Access privileges", so
/// listing, deleting and thinning normally cost no password. Should tmutil refuse
/// for lack of privileges anyway (`Output.looksLikePrivilegeFailure`), `SnapshotTool`
/// falls back to a single `PrivilegedRunner` prompt.
///
/// Only `SnapshotTool` calls this. Every argument list is re-checked against
/// `SnapshotTool.validate(arguments:)` here, so no future caller can hand tmutil an
/// arbitrary verb.
enum SnapshotRunner {

    struct Output: Sendable, Equatable {
        let status: Int32
        let stdout: String
        let stderr: String

        var succeeded: Bool { status == 0 }

        /// Everything tmutil said, trimmed — stderr first, that is where it complains.
        var message: String {
            let text = (stderr + "\n" + stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "tmutil exited with status \(status)" : text
        }

        /// "Refused for this user, not broken": a failed run whose complaint mentions
        /// privileges. Only then is an administrator prompt worth showing — any other
        /// failure is reported as is.
        var looksLikePrivilegeFailure: Bool {
            guard !succeeded else { return false }
            let text = (stdout + " " + stderr).lowercased()
            return Self.privilegeMarkers.contains { text.contains($0) }
        }

        static let privilegeMarkers = [
            "root", "privilege", "not permitted", "permission denied", "administrator",
        ]
    }

    enum Failure: Error, Equatable, LocalizedError {
        case toolMissing
        case refusedArguments(String)
        case launchFailed(String)
        case timedOut(TimeInterval)

        var errorDescription: String? {
            switch self {
            case .toolMissing:
                return "/usr/bin/tmutil is not available on this Mac."
            case .refusedArguments(let reason):
                return "Refused to run tmutil: \(reason)."
            case .launchFailed(let reason):
                return "tmutil could not be started: \(reason)"
            case .timedOut(let seconds):
                return "tmutil did not finish within \(Int(seconds)) seconds and was stopped."
            }
        }
    }

    static let toolPath = "/usr/bin/tmutil"

    /// Runs tmutil with `arguments`, stopping it after `timeout` seconds. Task
    /// cancellation terminates the process as well.
    static func run(arguments: [String], timeout: TimeInterval) async throws -> Output {
        if let reason = SnapshotTool.validate(arguments: arguments) {
            throw Failure.refusedArguments(reason)
        }
        guard FileManager.default.isExecutableFile(atPath: toolPath) else {
            throw Failure.toolMissing
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let watchdog = Watchdog()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                process.terminationHandler = { finished in
                    watchdog.disarm()
                    // Drained after exit: tmutil prints one short line per snapshot,
                    // far below the ~64 KB pipe buffer (see PrivilegedRunner).
                    let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    if watchdog.fired {
                        continuation.resume(throwing: Failure.timedOut(timeout))
                    } else {
                        continuation.resume(returning: Output(status: finished.terminationStatus,
                                                              stdout: out, stderr: err))
                    }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: Failure.launchFailed(error.localizedDescription))
                    return
                }
                watchdog.arm(after: timeout) {
                    if process.isRunning { process.terminate() }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// The timeout timer plus a thread-safe "it fired" flag, so the termination
    /// handler can tell a timeout from a normal exit.
    private final class Watchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var didFire = false
        private var work: DispatchWorkItem?

        var fired: Bool {
            lock.lock(); defer { lock.unlock() }
            return didFire
        }

        func arm(after seconds: TimeInterval, terminate: @escaping () -> Void) {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.didFire = true; self.lock.unlock()
                terminate()
            }
            lock.lock(); work = item; lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: item)
        }

        func disarm() {
            lock.lock(); defer { lock.unlock() }
            work?.cancel()
            work = nil
        }
    }
}
