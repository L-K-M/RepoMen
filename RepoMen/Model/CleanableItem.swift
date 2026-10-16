import Foundation

/// One reclaimable directory found by a scan. The `id` is the path, so a rescan
/// naturally replaces earlier findings and the selection survives size updates.
struct CleanableItem: Identifiable, Hashable, Sendable {
    /// Short human label — "Baegun/target" for project artifacts, or the catalog label
    /// ("Chrome · Profile 14 · Cache") for well-known caches.
    let label: String
    let kind: ArtifactKind
    let path: String

    /// Paths of which at least one must *still exist* at reclaim time — the anchor that
    /// proved this directory regenerable (`…/Cargo.toml`, `…/.venv/pyvenv.cfg`). Empty
    /// for well-known caches, which are re-verified against the static catalog roots
    /// instead. See `Reclaimer`.
    /// Tagged caches additionally re-validate their tag's signature and file type.
    let anchorPaths: [String]
    let isKnownCache: Bool

    /// Allocated bytes; 0 until `isMeasured` (the table shows a placeholder meanwhile).
    var sizeBytes: Int64 = 0
    var isMeasured: Bool = false
    /// Newest modification time observed while measuring — effectively "last built".
    var lastModified: Date = .distantPast
    /// A reason for caution ("Chrome is running"), shown as a badge; never blocks.
    var warning: String?
    /// A root-owned `SystemAreas` item (RTCReporting logs and friends): found by the
    /// admin-gated probe, already measured on arrival, and reclaimed by
    /// `SystemReclaimer` (permanent delete as root) — never by `Reclaimer`, whose
    /// home-only guards it could not pass.
    var isSystemArea: Bool = false

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var category: ArtifactCategory { kind.category }
}
