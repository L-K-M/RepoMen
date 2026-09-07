import AppKit
import Foundation

/// Outcome of a snapshot delete or thin run, presented as an alert.
struct SnapshotReport: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let message: String
}

/// State for the Snapshots pane (sidebar → Time Machine → Local snapshots): the
/// current list, the checks, and the two operations (delete checked, ask Time
/// Machine to thin). Like `AppModel`, UI state lives here on the main actor while
/// tmutil runs off it. Nothing here is ever triggered by a scan or by watch mode —
/// the pane's own buttons are the only entry points, nothing is pre-checked, and
/// both destructive actions pass a confirmation dialog that says "permanent" first.
@MainActor
final class SnapshotModel: ObservableObject {

    @Published private(set) var snapshots: [LocalSnapshot] = []
    /// Snapshots made by other apps (Arq, Carbon Copy Cloner, macOS updates): shown
    /// so their space is accounted for, never checkable, never touched.
    @Published private(set) var otherSnapshotNames: [String] = []
    @Published private(set) var isLoading = false
    /// True while a delete or thin runs (the Stop button's condition).
    @Published private(set) var isWorking = false
    @Published private(set) var workStatus = ""
    /// False until the first listing finished — the empty table must not claim
    /// "no snapshots" before it has looked.
    @Published private(set) var hasLoaded = false
    @Published var checkedIDs: Set<String> = []
    @Published var loadError: String?
    @Published var report: SnapshotReport?
    @Published var confirmingDelete = false
    @Published var confirmingThin = false
    /// The "release space" amount in decimal gigabytes, the unit macOS shows sizes in.
    @Published var thinGigabytes: Double = 10
    @Published var thinUrgency: Int = SnapshotTool.urgencyRange.upperBound

    /// Terminate-safety bookkeeping consulted by the app delegate, like `AppModel`'s:
    /// a delete or thin in flight finishes before the app quits.
    private(set) static var activeOperationCount = 0
    static var terminateAfterOperation = false

    private var loadTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?

    /// Checked snapshots in list order (oldest first — the order to delete in).
    var checkedSnapshots: [LocalSnapshot] {
        snapshots.filter { checkedIDs.contains($0.id) }
    }

    var thinBytes: Int64 {
        Int64((max(0, thinGigabytes) * 1_000_000_000).rounded())
    }

    // MARK: Listing

    func refresh() {
        guard !isWorking else { return }
        loadTask?.cancel()
        isLoading = true
        loadError = nil
        loadTask = Task { [weak self] in
            let result: Result<SnapshotTool.Listing, Error>
            do {
                result = .success(try await SnapshotTool.listAll())
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            self.isLoading = false
            self.hasLoaded = true
            switch result {
            case .success(let found):
                self.apply(found)
            case .failure(let error):
                Log.snapshots.error("listing failed: \(error.localizedDescription, privacy: .public)")
                self.loadError = error.localizedDescription
            }
        }
    }

    private func apply(_ listing: SnapshotTool.Listing) {
        snapshots = listing.snapshots
        otherSnapshotNames = listing.otherNames
        checkedIDs = checkedIDs.intersection(listing.snapshots.map(\.id))
    }

    /// Pre-fills the release amount from a reclaim (the summary's "Snapshots…"
    /// button): what was just freed is what the snapshots are most likely holding.
    func suggestThin(bytes: Int64) {
        guard bytes > 0 else { return }
        thinGigabytes = max(1, (Double(bytes) / 1_000_000_000).rounded(.up))
    }

    // MARK: Checks

    func setChecked(_ checked: Bool, id: String) {
        if checked { checkedIDs.insert(id) } else { checkedIDs.remove(id) }
    }

    func checkAll() {
        checkedIDs = Set(snapshots.map(\.id))
    }

    func clearChecked() {
        checkedIDs = []
    }

    // MARK: Deleting

    /// Only the confirmation dialog's destructive button calls this.
    func deleteChecked() {
        let targets = checkedSnapshots
        guard !targets.isEmpty, !isWorking, !isLoading else { return }
        begin(status: "Deleting \(targets.count) snapshot\(targets.count == 1 ? "" : "s")…")
        let freeBefore = Self.volumeFreeBytes()

        workTask = Task { [weak self] in
            let outcomes = await SnapshotTool.delete(targets, progress: { current, total, snapshot in
                Task { @MainActor [weak self] in
                    guard let self, self.isWorking else { return }
                    self.workStatus = "Deleting \(current) of \(total) — \(snapshot.name)"
                }
            })
            let remaining = await Self.settleAndList()
            let freeAfter = Self.volumeFreeBytes()
            guard let self else { Self.operationFinished(); return }

            let deleted = outcomes.filter { $0.failure == nil }.map(\.snapshot)
            if let remaining {
                self.apply(remaining)
            } else {
                self.apply(SnapshotTool.Listing(snapshots: self.snapshots.filter { !deleted.contains($0) },
                                                otherNames: self.otherSnapshotNames))
            }
            var text: String
            if deleted.isEmpty {
                text = "No snapshot was deleted."
            } else {
                text = "Deleted \(deleted.count) of \(targets.count) snapshot\(targets.count == 1 ? "" : "s") permanently."
            }
            text += Self.freeSpaceLine(before: freeBefore, after: freeAfter, expectGrowth: !deleted.isEmpty)
            let failures = outcomes.compactMap { outcome in
                outcome.failure.map { "\(outcome.snapshot.name): \($0)" }
            }
            if !failures.isEmpty {
                text += "\n\nSkipped:\n" + failures.prefix(8).joined(separator: "\n")
                if failures.count > 8 { text += "\n…and \(failures.count - 8) more" }
            }
            self.report = SnapshotReport(
                title: deleted.isEmpty ? "Nothing deleted"
                    : (failures.isEmpty ? "Snapshots deleted" : "Partially deleted"),
                message: text)
            self.end()
        }
    }

    // MARK: Thinning

    /// Only the confirmation dialog's destructive button calls this.
    func thinNow() {
        guard !isWorking, !isLoading, thinBytes > 0 else { return }
        let bytes = thinBytes
        let urgency = thinUrgency
        let before = snapshots
        begin(status: "Asking Time Machine to release \(Format.bytes(bytes))…")
        let freeBefore = Self.volumeFreeBytes()

        workTask = Task { [weak self] in
            let result: Result<SnapshotTool.ThinResult, Error>
            do {
                result = .success(try await SnapshotTool.thin(bytes: bytes, urgency: urgency))
            } catch {
                result = .failure(error)
            }
            let remaining = await Self.settleAndList()
            let freeAfter = Self.volumeFreeBytes()
            guard let self else { Self.operationFinished(); return }

            if let remaining { self.apply(remaining) }
            switch result {
            case .success(let thin):
                let removed = max(0, before.count - (remaining?.snapshots.count ?? before.count))
                var text: String
                if removed > 0 {
                    text = "Time Machine removed \(removed) local snapshot\(removed == 1 ? "" : "s") to release about \(Format.bytes(bytes))."
                } else {
                    text = "Time Machine kept every snapshot — it decided none had to go for \(Format.bytes(bytes)). Try a larger amount or a higher urgency, or delete specific snapshots from the list."
                }
                if thin.usedAdministratorPrivileges {
                    text += "\nThis needed administrator privileges."
                }
                text += Self.freeSpaceLine(before: freeBefore, after: freeAfter, expectGrowth: removed > 0)
                self.report = SnapshotReport(title: removed > 0 ? "Space released" : "Nothing released",
                                             message: text)
            case .failure(let error):
                // A dismissed password dialog is the user's choice, not an alert.
                if (error as? SnapshotTool.Failure) != .cancelled {
                    self.report = SnapshotReport(title: "Could not release space",
                                                 message: error.localizedDescription)
                }
            }
            self.end()
        }
    }

    /// Stops the running operation: tmutil is terminated; a delete batch keeps what
    /// it already removed and reports the rest as untouched.
    func cancelWork() {
        workTask?.cancel()
    }

    // MARK: Helpers

    private func begin(status: String) {
        isWorking = true
        workStatus = status
        Self.activeOperationCount += 1
    }

    private func end() {
        isWorking = false
        workStatus = ""
        Self.operationFinished()
    }

    private static func operationFinished() {
        activeOperationCount -= 1
        // A quit requested mid-operation was deferred; release it now.
        if terminateAfterOperation, activeOperationCount == 0 {
            terminateAfterOperation = false
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
    }

    /// Re-lists after giving APFS a moment: snapshot removal completes in the
    /// background ("can take several seconds"), so an immediate listing or free-space
    /// sample can still show the old state. nil when the listing failed.
    private nonisolated static func settleAndList() async -> SnapshotTool.Listing? {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return try? await SnapshotTool.listAll()
    }

    /// Plain free space on the boot volume — deliberately NOT
    /// `volumeAvailableCapacityForImportantUsage`, which already counts purgeable
    /// space (snapshots included) and lags by many minutes; this is the figure that
    /// actually moves when a snapshot is gone.
    private nonisolated static func volumeFreeBytes() -> Int64? {
        let root = URL(fileURLWithPath: SnapshotTool.mountPoint)
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    private static func freeSpaceLine(before: Int64?, after: Int64?, expectGrowth: Bool) -> String {
        guard let before, let after else { return "" }
        if after > before {
            return "\n\nDisk free: \(Format.bytes(before)) → \(Format.bytes(after))."
        }
        if expectGrowth {
            return "\n\nDisk free is still \(Format.bytes(after)) — APFS frees a deleted snapshot's blocks in the background, so check again in a moment."
        }
        return ""
    }

    /// Disk Utility is the one tool that shows each snapshot's Private Size.
    static func openDiskUtility() {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.DiskUtility") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
