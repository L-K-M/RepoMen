import XCTest
@testable import RepoMen

/// The pure halves of the privileged bridge: shell quoting, AppleScript escaping,
/// and payload decoding. (Actually spawning osascript shows a password dialog and
/// stays a manual-verify item.)
final class PrivilegedRunnerTests: XCTestCase {

    func testShellQuoteWrapsPlainStrings() {
        XCTAssertEqual(PrivilegedRunner.shellQuote("/private/var/root/Library/Logs"),
                       "'/private/var/root/Library/Logs'")
    }

    func testShellQuoteNeutralizesSingleQuotes() {
        XCTAssertEqual(PrivilegedRunner.shellQuote("don't"), "'don'\\''t'")
        XCTAssertEqual(PrivilegedRunner.shellQuote("a'b'c"), "'a'\\''b'\\''c'")
    }

    func testShellQuoteKeepsMetacharactersLiteral() {
        // Everything stays inside single quotes — nothing for sh to expand.
        XCTAssertEqual(PrivilegedRunner.shellQuote("$(rm -rf /) `x` \"y\" \n z"),
                       "'$(rm -rf /) `x` \"y\" \n z'")
    }

    func testAppleScriptEscapingHandlesQuotesBackslashesAndNewlines() {
        XCTAssertEqual(PrivilegedRunner.escapeForAppleScript("say \"hi\""),
                       "say \\\"hi\\\"")
        XCTAssertEqual(PrivilegedRunner.escapeForAppleScript("a\\b"), "a\\\\b")
        XCTAssertEqual(PrivilegedRunner.escapeForAppleScript("line1\nline2"),
                       "line1\\nline2")
        XCTAssertEqual(PrivilegedRunner.escapeForAppleScript("a\tb"), "a\\tb")
    }

    func testAppleScriptEscapingDoesNotDoubleEscape() {
        // A literal backslash-n in the input is an escaped backslash + n on the way
        // out — NOT collapsed with the newline replacement.
        XCTAssertEqual(PrivilegedRunner.escapeForAppleScript("\\n"), "\\\\n")
    }

    func testDecodePayloadToleratesWhitespaceAndRejectsGarbage() {
        let data = Data("OK\t/some/path\0".utf8)
        let wrapped = data.base64EncodedString(options: [.lineLength64Characters])
            + "\r\n"
        XCTAssertEqual(PrivilegedRunner.decodePayload(wrapped), data,
                       "base64 line wrapping and CRLFs must not break decoding")
        XCTAssertNil(PrivilegedRunner.decodePayload("definitely not base64 !!!"))
    }
}
