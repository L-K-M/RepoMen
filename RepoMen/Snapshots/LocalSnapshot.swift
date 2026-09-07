import Foundation

/// One Time Machine *local* snapshot of the boot volume, exactly as `tmutil` names
/// it: `com.apple.TimeMachine.YYYY-MM-DD-HHMMSS.local`. Nothing else is ever
/// modelled. Third-party snapshots (`com.bombich.ccc.…`), the snapshots macOS takes
/// before installing updates (`com.apple.os.update-…`) and Time Machine's `.backup`
/// snapshots on backup disks never become a `LocalSnapshot`, so nothing in RepoMen
/// can name — let alone delete — them.
///
/// Local snapshots are disposable by macOS contract: Time Machine takes one roughly
/// every hour, keeps it for about 24 hours, and deletes it itself "as space is
/// needed" (Apple, "About Time Machine local snapshots"); `tmutil` calls them
/// purgeable. Deleting one costs the ability to restore files from it while the
/// backup disk is away, and — if it was the snapshot of the last successful backup
/// — a slower next backup. The backup disk itself is never touched.
struct LocalSnapshot: Identifiable, Hashable, Sendable {

    static let namePrefix = "com.apple.TimeMachine."
    static let nameSuffix = ".local"

    /// `YYYY-MM-DD-HHMMSS` — the operand `tmutil deletelocalsnapshots` takes. ASCII
    /// digits and hyphens only, so it is trivially safe as a process argument.
    let dateToken: String
    /// The creation time the token spells out (tmutil names snapshots in local time).
    let date: Date

    var id: String { dateToken }
    var name: String { Self.namePrefix + dateToken + Self.nameSuffix }

    /// Parses a name as printed by `tmutil listlocalsnapshots`; nil for anything that
    /// is not a Time Machine local snapshot.
    init?(name: String) {
        guard name.hasPrefix(Self.namePrefix), name.hasSuffix(Self.nameSuffix),
              name.count > Self.namePrefix.count + Self.nameSuffix.count else { return nil }
        let token = String(name.dropFirst(Self.namePrefix.count).dropLast(Self.nameSuffix.count))
        self.init(dateToken: token)
    }

    /// Parses a bare date token (the `tmutil listlocalsnapshotdates` format).
    init?(dateToken: String) {
        guard let components = Self.components(of: dateToken) else { return nil }
        self.dateToken = dateToken
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        // A token inside a DST gap has no exact instant; the calendar shifts it
        // rather than failing, so a listed snapshot is never silently dropped.
        self.date = calendar.date(from: components) ?? .distantPast
    }

    /// Shape check only: 17 characters, `dddd-dd-dd-dddddd`, ASCII digits.
    static func isWellFormed(_ token: String) -> Bool {
        let scalars = Array(token.unicodeScalars)
        guard scalars.count == 17 else { return false }
        for (index, scalar) in scalars.enumerated() {
            if index == 4 || index == 7 || index == 10 {
                guard scalar == "-" else { return false }
            } else {
                guard scalar.value >= 0x30, scalar.value <= 0x39 else { return false }
            }
        }
        return true
    }

    /// Shape plus field ranges (month 1–12, day 1–31, hour 0–23, minute/second
    /// 0–59); nil when the token is not a plausible snapshot date.
    static func components(of token: String) -> DateComponents? {
        guard isWellFormed(token) else { return nil }
        let parts = token.split(separator: "-").map { Int($0) ?? -1 }
        guard parts.count == 4 else { return nil }
        let year = parts[0], month = parts[1], day = parts[2], time = parts[3]
        let hour = time / 10_000, minute = (time / 100) % 100, second = time % 100
        guard (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second)
        else { return nil }
        return DateComponents(year: year, month: month, day: day,
                              hour: hour, minute: minute, second: second)
    }
}
