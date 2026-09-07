import Foundation

/// One row of the Snapshots pane's table: either a Time Machine local snapshot
/// (checkable, deletable) or a snapshot some other app made, shown greyed and
/// unticked so the user can see what else is holding space on the disk. Only the
/// former carries a `LocalSnapshot`; the latter is a name plus an owner guess, and
/// nothing in RepoMen can act on it.
struct SnapshotRow: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Set for Time Machine local snapshots only — the one kind RepoMen can delete.
    let snapshot: LocalSnapshot?
    /// Who made it: "Time Machine", or the owner guessed from the name prefix.
    let owner: String

    var isTimeMachine: Bool { snapshot != nil }

    /// Time Machine snapshots first (oldest first — the order to delete in), then
    /// everyone else's in listing order. Names are unique per volume, so they serve
    /// as ids.
    static func rows(from listing: SnapshotTool.Listing) -> [SnapshotRow] {
        listing.snapshots.map {
            SnapshotRow(id: $0.name, name: $0.name, snapshot: $0, owner: "Time Machine")
        } + listing.otherNames.map {
            SnapshotRow(id: $0, name: $0, snapshot: nil,
                        owner: SnapshotTool.ownerLabel(forForeignName: $0))
        }
    }
}
