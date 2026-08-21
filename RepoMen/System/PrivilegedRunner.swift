import Foundation

/// Runs a short POSIX-sh script as root via AppleScript's
/// `do shell script … with administrator privileges` — macOS shows its standard
/// admin-password dialog (naming osascript, which performs the request), and the
/// user can cancel it. For a non-sandboxed, directly-distributed app this is the
/// narrowest privileged bridge there is: one prompt, one script, no helper tool or
/// daemon installed or left behind.
///
/// Only the two vetted script builders may pass through here
/// (`SystemScanner.probeScript`, `SystemReclaimer.script(for:)`): every path they
/// embed comes from the `SystemAreas` catalog or is validated against it first,
/// and is quoted with `shellQuote`.
enum PrivilegedRunner {

    enum Failure: Error, Equatable, LocalizedError {
        /// The user dismissed the password dialog — expected, never alert-worthy.
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Administrator authorization was cancelled."
            case .failed(let message): return message
            }
        }
    }

    /// Runs `script` as root and returns its stdout. Task cancellation terminates
    /// the osascript process (taking a pending password dialog down with it).
    static func run(script: String) async throws -> String {
        let source = "do shell script \"\(escapeForAppleScript(script))\""
            + " with administrator privileges without altering line endings"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    // Both streams are small by construction — a base64 blob with
                    // one short record per catalog child, far below the 64 KB pipe
                    // buffer — so draining after exit cannot deadlock.
                    let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8) ?? ""
                    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8) ?? ""
                    if finished.terminationStatus == 0 {
                        continuation.resume(returning: out)
                    } else if err.contains("-128") {   // AppleScript "User canceled."
                        continuation.resume(throwing: Failure.cancelled)
                    } else {
                        let reason = err.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(throwing: Failure.failed(reason.isEmpty
                            ? "The privileged helper exited with status \(finished.terminationStatus)."
                            : reason))
                    }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: Failure.failed(error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: Pure helpers (unit-tested; the osascript spawn above is manual-verify)

    /// Quotes `string` for POSIX sh so it is always ONE literal word — no expansion,
    /// no splitting — whatever bytes the name contains. (NUL is the one byte sh
    /// cannot carry; POSIX paths cannot contain it and `SystemAreas.validate`
    /// rejects it.)
    static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes `script` for embedding in a double-quoted AppleScript string literal
    /// passed via `osascript -e`. Raw newlines are not legal inside AppleScript
    /// string literals, so they become `\n` escapes (supported since AppleScript
    /// 2.0); backslashes are escaped first so the later replacements survive.
    static func escapeForAppleScript(_ script: String) -> String {
        script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// Decodes the base64 payload the privileged scripts emit. They pipe their
    /// NUL-separated records through `/usr/bin/base64` because AppleScript strings
    /// cannot round-trip arbitrary bytes (and `do shell script` historically
    /// rewrites line endings) — base64 is pure ASCII and survives anything.
    /// Whitespace-tolerant on the way back in.
    static func decodePayload(_ output: String) -> Data? {
        Data(base64Encoded: String(output.filter { !$0.isWhitespace }))
    }
}
