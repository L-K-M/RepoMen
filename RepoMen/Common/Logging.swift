import Foundation
import os

/// Namespaced loggers (never log user file *contents*; paths are fine — this is a
/// local utility and paths are the whole point of its logs).
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "ch.lkmc.RepoMen"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let scan = Logger(subsystem: subsystem, category: "scan")
    static let reclaim = Logger(subsystem: subsystem, category: "reclaim")
}
