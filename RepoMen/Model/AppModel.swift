import AppKit
import Combine
import Foundation

/// What the sidebar can show.
enum SidebarEntry: Hashable {
    case all
    case category(ArtifactCategory)
    /// Time Machine local snapshots — not paths, so the detail pane swaps the
    /// table for `SnapshotsView` while this is selected.
    case snapshots
}

/// Result of a reclaim run, presented as an alert.
struct ReclaimSummary: Identifiable, Sendable {
    let id = UUID()
    let freedBytes: Int64
    let reclaimedCount: Int
    /// How many reclaimed items had no finished measurement — `freedBytes` is then
    /// a floor, not the truth ("at least X"), and the summary must say so.
    let unmeasuredReclaimed: Int
    /// "label: reason" for every skipped/failed item.
    let failures: [String]
    /// Successfully reclaimed system-area items. Root-owned, so they were deleted
    /// permanently even in a Trash batch — the summary must say so.
    let systemDeleted: Int
    let trashed: Bool
    /// True when the user stopped the batch early — unprocessed items stay checked.
    let cancelled: Bool
    /// Volume free space sampled just before/after the run (nil if unreadable) —
    /// lets the summary show the delta the user actually cares about.
    let freeBytesBefore: Int64?
    let freeBytesAfter: Int64?
    /// The all-time tally including this run.
    let lifetimeReclaimedBytes: Int64
    /// Time Machine local snapshots present right after the run (empty when none,
    /// when nothing was reclaimed, or when tmutil could not be asked). They hold the
    /// blocks just freed, so the summary explains a flat free-space figure with them.
    let localSnapshots: [LocalSnapshot]
    /// Snapshots by other apps on the disk at the same moment — they hold freed
    /// blocks just the same, and RepoMen can only point at them.
    let otherSnapshotNames: [String]
}

/// Live position within a running reclaim batch, shown in the footer.
struct ReclaimProgress: Sendable {
    /// 1-based index of the item currently being reclaimed.
    let current: Int
    let total: Int
    let label: String
}

/// The window's state machine: scan → measure → review → reclaim. All UI state lives
/// here on the main actor; the walk, sizing, and deletion run detached and report back.
@MainActor
final class AppModel: ObservableObject {

    enum Phase: Equatable {
        case idle       // nothing scanned yet
        case scanning   // walking the roots
        case measuring  // items listed, sizes still streaming in
        case ready
    }

    @Published private(set) var phase: Phase = .idle {
        didSet { invalidateDerived() }   // measuring uses a stable row order
    }
    @Published private(set) var items: [CleanableItem] = [] {
        didSet { rebuildItemDerivedState() }
    }
    @Published private(set) var scanStatus = ""
    @Published private(set) var isReclaiming = false
    @Published var checkedIDs: Set<String> = []
    @Published var sidebarSelection: SidebarEntry? = .all {
        didSet { invalidateDerived() }
    }
    @Published var sortOrder: [KeyPathComparator<CleanableItem>] = [
        KeyPathComparator(\.sizeBytes, order: .reverse),
    ] {
        didSet { invalidateDerived() }
    }
    @Published var searchText = ""
    @Published var summary: ReclaimSummary?

    /// The table's row selection (checkboxes are separate — see `checkedIDs`).
    /// Lives here, not in the view, so the Items menu and the context menu act on
    /// the same rows.
    @Published var tableSelection: Set<String> = []

    let preferences: Preferences
    private var scanTask: Task<Void, Never>?
    /// Monotonic scan token, bumped on every start/cancel. Every main-actor write a
    /// detached scan task performs is guarded by it, so a superseded task (or its
    /// still-running sizers) can never publish into a newer scan's state.
    private var scanGeneration = 0
    /// Measurements waiting to be applied to `items` in one batch (id → measurement).
    private var pendingMeasurements: [String: DirectorySizer.Measurement] = [:]
    private var flushScheduled = false

    // MARK: Derived-state caches

    /// `visibleItems` is read several times per render pass (table, footer, dialogs)
    /// and was a full filter + O(n log n) sort *per read*. It is instead recomputed
    /// lazily, once, after any of its inputs change. Search goes through a 150 ms
    /// debounce so every keystroke doesn't sort ten thousand rows.
    private var cachedVisibleItems: [CleanableItem] = []
    private var derivedDirty = true
    /// The published debounced copy of `searchText` — also the signal that refreshes
    /// the table 150 ms after the user stops typing.
    @Published private var debouncedSearchText = "" {
        didSet { invalidateDerived() }
    }
    /// id → item and per-entry totals, rebuilt in one pass whenever `items` changes:
    /// `checkedItems` and the sidebar badges stop being O(n) scans per access.
    private var itemsByID: [String: CleanableItem] = [:]
    private var cachedStats: [SidebarEntry: (count: Int, bytes: Int64)] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(preferences: Preferences = .shared) {
        self.preferences = preferences
        // An explicit sink + retained cancellable: with `assign(to:)` the debounced
        // value silently never landed (no didSet, no invalidation) and the filter
        // stayed stuck on "" — search appeared to do nothing.
        $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] text in
                self?.debouncedSearchText = text
            }
            .store(in: &cancellables)
    }

    // MARK: Derived state

    var isBusy: Bool { phase == .scanning || phase == .measuring }

    /// While sizes stream in, rows keep a stable label/path order so they don't jump
    /// under the cursor mid-click; the user's sort applies once measuring completes.
    private static let measuringOrder: [KeyPathComparator<CleanableItem>] = [
        KeyPathComparator(\.label), KeyPathComparator(\.path),
    ]

    var visibleItems: [CleanableItem] {
        if derivedDirty { recomputeVisibleItems() }
        return cachedVisibleItems
    }

    private func invalidateDerived() {
        derivedDirty = true
    }

    private func recomputeVisibleItems() {
        var filtered = items
        switch sidebarSelection {
        case .category(let category)?:
            filtered = filtered.filter { $0.category == category }
        case .snapshots?:
            filtered = []   // the snapshots pane replaces the table entirely
        default:
            break
        }
        if !debouncedSearchText.isEmpty {
            filtered = filtered.filter {
                $0.label.localizedCaseInsensitiveContains(debouncedSearchText)
                    || $0.path.localizedCaseInsensitiveContains(debouncedSearchText)
            }
        }
        cachedVisibleItems = filtered.sorted(using: phase == .measuring ? Self.measuringOrder : sortOrder)
        derivedDirty = false
    }

    /// One O(n) pass per `items` mutation, replacing O(n)-per-access lookups.
    private func rebuildItemDerivedState() {
        itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var stats: [SidebarEntry: (count: Int, bytes: Int64)] = [:]
        var totalBytes: Int64 = 0
        for item in items {
            let entry = SidebarEntry.category(item.category)
            let current = stats[entry] ?? (0, 0)
            stats[entry] = (current.count + 1, current.bytes + item.sizeBytes)
            totalBytes += item.sizeBytes
        }
        stats[.all] = (items.count, totalBytes)
        cachedStats = stats
        invalidateDerived()
    }

    func stats(for entry: SidebarEntry) -> (count: Int, bytes: Int64) {
        cachedStats[entry] ?? (0, 0)
    }

    /// Path-sorted for determinism (a Set's iteration order must never decide the
    /// order of a deletion batch or a dialog's item list).
    var checkedItems: [CleanableItem] {
        checkedIDs.compactMap { itemsByID[$0] }.sorted { $0.path < $1.path }
    }
    var checkedBytes: Int64 { checkedItems.reduce(0) { $0 + $1.sizeBytes } }

    /// The largest measured item once a scan settles — every repo job has a prime
    /// target. The footer offers it as a one-click check; it disappears naturally
    /// once checked (or reclaimed).
    var biggestOffender: CleanableItem? {
        guard phase == .ready else { return nil }
        return items.filter { $0.isMeasured && $0.sizeBytes > 0 }
            .max { $0.sizeBytes < $1.sizeBytes }
    }

    // MARK: Scanning

    func startScan() {
        // Never walk the tree mid-deletion, and never race the privileged probe.
        guard !isReclaiming, !isSystemScanning else { return }
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        pendingMeasurements = [:]
        let config = ScanConfiguration(
            roots: preferences.scanRoots.map { URL(fileURLWithPath: $0) },
            excludedPaths: Set(preferences.excludedPaths),
            enabledKinds: preferences.enabledKinds)
        // Snapshot the open apps on the main thread; the walk runs detached.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

        // System-area rows survive a normal rescan: they came from a separate,
        // admin-gated probe, and dropping them would cost another password prompt
        // to get back. Everything else is replaced by this scan's findings.
        items = items.filter(\.isSystemArea)
        // The selection is NOT cleared: ids are stable paths, so a rescan keeps
        // whatever is still found (intersected with the new results below).
        phase = .scanning
        scanStatus = "Looking for artifacts…"
        Log.scan.info("scan started: \(config.roots.map(\.path).joined(separator: ", "), privacy: .public)")

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            var lastStatus = Date.distantPast
            let found = Scanner.scan(config) { path in
                let now = Date()
                guard now.timeIntervalSince(lastStatus) > 0.1 else { return }
                lastStatus = now
                let display = Format.abbreviatePath(path)
                Task { @MainActor [weak self] in
                    guard let self, self.scanGeneration == generation,
                          self.phase == .scanning else { return }
                    self.scanStatus = display
                }
            }
            let caches = KnownCaches.items(
                excludedPaths: config.excludedPaths,
                enabledKinds: config.enabledKinds,
                isRunning: { running.contains($0) })
            guard !Task.isCancelled else { return }

            let discovered = found + caches
            await MainActor.run { [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                self.items = discovered + self.items.filter(\.isSystemArea)
                // Keep the user's checks across the rescan for anything still found.
                self.checkedIDs = self.checkedIDs.intersection(self.items.map(\.id))
                self.phase = .measuring
                self.scanStatus = "Measuring \(discovered.count) items…"
            }

            await Self.measureAll(discovered) { id, measurement in
                Task { @MainActor [weak self] in
                    self?.enqueue(measurement, for: id, generation: generation)
                }
            }

            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                self.flushMeasurements()
                self.phase = .ready
                self.scanStatus = ""
                Log.scan.info("scan finished: \(self.items.count) items")
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanGeneration += 1        // orphan any in-flight status/measurement writes
        pendingMeasurements = [:]
        phase = items.isEmpty ? .idle : .ready
        scanStatus = ""
    }

    // MARK: System areas (admin-gated)

    /// True while the privileged probe runs (password dialog up, or `du` walking
    /// the root-owned trees).
    @Published private(set) var isSystemScanning = false
    @Published private(set) var systemScanStatus = ""
    /// A failed probe's message, presented as an alert. A cancelled password dialog
    /// stays silent — the user knows they cancelled.
    @Published var systemScanError: String?

    private var systemScanTask: Task<Void, Never>?

    /// Scans the root-owned `SystemAreas` catalog (RTCReporting logs and friends).
    /// Deliberately separate from `startScan`: it always costs an admin-password
    /// prompt, so it runs only when explicitly asked — never as part of a normal
    /// scan, and never from watch mode.
    func scanSystemAreas() {
        guard !isBusy, !isReclaiming, !isSystemScanning else { return }
        let excluded = Set(preferences.excludedPaths)
        let enabled = preferences.enabledKinds
        // Snapshot the open apps on the main thread, like startScan does.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        isSystemScanning = true
        systemScanStatus = "Scanning system areas — macOS asks for your administrator password…"
        Log.scan.info("system-area scan started")

        systemScanTask = Task { [weak self] in
            do {
                let found = try await SystemScanner.scan(
                    excludedPaths: excluded, enabledKinds: enabled,
                    isRunning: { running.contains($0) })
                guard let self else { return }
                // Stop pressed while the probe was finishing: results from a run the
                // user abandoned must not appear (same rule as the ordinary scan).
                guard !Task.isCancelled else {
                    self.finishSystemScan()
                    Log.scan.info("system-area scan cancelled")
                    return
                }
                self.items = self.items.filter { !$0.isSystemArea } + found
                self.checkedIDs = self.checkedIDs.intersection(self.items.map(\.id))
                self.finishSystemScan()
                Log.scan.info("system-area scan finished: \(found.count) items")
            } catch {
                guard let self else { return }
                self.finishSystemScan()
                if Task.isCancelled || (error as? PrivilegedRunner.Failure) == .cancelled {
                    Log.scan.info("system-area scan cancelled")
                } else {
                    let message = (error as? PrivilegedRunner.Failure)?.errorDescription
                        ?? error.localizedDescription
                    self.systemScanError = message
                    Log.scan.error("system-area scan failed: \(message, privacy: .public)")
                }
            }
        }
    }

    /// Terminates the probe (dismissing a pending password dialog with it).
    func cancelSystemScan() {
        systemScanTask?.cancel()
    }

    private func finishSystemScan() {
        isSystemScanning = false
        systemScanStatus = ""
    }

    /// Sizes all items with bounded concurrency — sizing hammers the disk, and a few
    /// walkers saturate an SSD without starving the UI. The width scales with the
    /// machine (half the cores, clamped 2…8) instead of a hardcoded four. Cancelled
    /// (partial) measurements are discarded, never reported.
    private nonisolated static func measureAll(
        _ items: [CleanableItem],
        apply: @escaping @Sendable (String, DirectorySizer.Measurement) -> Void
    ) async {
        let width = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        await withTaskGroup(of: Void.self) { group in
            var iterator = items.makeIterator()
            func addNext() {
                guard let item = iterator.next() else { return }
                group.addTask {
                    let measurement = DirectorySizer.measure(item.url)
                    // An aborted walk returns partial counts — dropping them keeps an
                    // undersized artifact from ever being presented as fully measured.
                    guard measurement.isComplete else { return }
                    apply(item.id, measurement)
                }
            }
            for _ in 0..<width { addNext() }
            for await _ in group {
                if Task.isCancelled { break }
                addNext()
            }
        }
    }

    /// Measurements arrive one at a time from four concurrent sizers; applying each
    /// individually would republish `items` (and re-render the window) once per item.
    /// They pool here instead and land in a single mutation per flush interval.
    private func enqueue(_ measurement: DirectorySizer.Measurement, for id: String,
                         generation: Int) {
        guard generation == scanGeneration else { return }
        pendingMeasurements[id] = measurement
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self else { return }
            self.flushScheduled = false
            self.flushMeasurements()
        }
    }

    /// Applies every pooled measurement in one `items` assignment. Safe to call at any
    /// time: scan boundaries clear the pool, so nothing stale can ever land here.
    private func flushMeasurements() {
        guard !pendingMeasurements.isEmpty else { return }
        let batch = pendingMeasurements
        pendingMeasurements = [:]
        var updated = items
        let indexByID = Dictionary(updated.enumerated().map { ($1.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        for (id, measurement) in batch {
            guard let index = indexByID[id] else { continue }
            updated[index].sizeBytes = measurement.bytes
            updated[index].isMeasured = true
            updated[index].lastModified = measurement.newestModification
        }
        items = updated
    }

    // MARK: Selection

    func setChecked(_ checked: Bool, id: String) {
        if checked { checkedIDs.insert(id) } else { checkedIDs.remove(id) }
    }

    func checkAllVisible() {
        checkedIDs.formUnion(visibleItems.map(\.id))
    }

    /// Checks the visible items whose newest content is older than the idle threshold —
    /// the "clean out what I haven't built in a month" one-click.
    func checkIdleVisible() {
        let cutoff = Date().addingTimeInterval(-Double(preferences.idleDays) * 86_400)
        checkedIDs.formUnion(visibleItems
            .filter { $0.isMeasured && $0.lastModified < cutoff }
            .map(\.id))
    }

    func clearChecked() {
        checkedIDs = []
    }

    // MARK: Reclaiming

    /// Set by the toolbar button and the ⌘⌫ menu command; `DetailView` presents the
    /// confirmation dialog while this is true. Only the dialog's destructive button
    /// calls `reclaimChecked()` — there is still no one-keystroke path to deletion.
    @Published var confirmingReclaim = false

    /// Non-nil while a reclaim batch runs; drives the footer's progress line.
    @Published private(set) var reclaimProgress: ReclaimProgress?

    /// Terminate-safety bookkeeping consulted by the app delegate: the app must never
    /// die in the middle of a deletion batch. When termination is requested mid-run,
    /// the delegate defers it and the finishing reclaim replies.
    private(set) static var activeReclaimCount = 0
    static var terminateAfterReclaim = false

    private var reclaimTask: Task<Void, Never>?

    /// Stops the batch after the item currently being processed finishes — items
    /// already reclaimed stay reclaimed and are reported; the rest stay checked so
    /// the user can pick up where they stopped.
    func cancelReclaim() {
        reclaimTask?.cancel()
    }

    func reclaimChecked() {
        let targets = checkedItems
        guard !targets.isEmpty, !isReclaiming, !isSystemScanning else { return }
        // Root-owned system items take the privileged path (one admin prompt for
        // the lot, permanent delete); everything else goes through Reclaimer.
        let systemTargets = targets.filter(\.isSystemArea)
        let normalTargets = targets.filter { !$0.isSystemArea }
        let method: Reclaimer.Method = preferences.moveToTrash ? .trash : .delete
        isReclaiming = true
        Self.activeReclaimCount += 1
        reclaimProgress = ReclaimProgress(current: 0, total: targets.count, label: "")
        let freeBefore = Self.volumeFreeBytes()

        reclaimTask = Task.detached(priority: .userInitiated) { [weak self] in
            var outcomes: [Reclaimer.Outcome] = []
            // System items first: their password prompt appears right after the
            // user confirms, not after a long normal batch they walked away from.
            if !systemTargets.isEmpty {
                Task { @MainActor [weak self] in
                    guard let self, self.isReclaiming else { return }
                    self.reclaimProgress = ReclaimProgress(
                        current: 1, total: targets.count,
                        label: "system areas (administrator password)")
                }
                outcomes += await SystemReclaimer.reclaim(systemTargets)
            }
            if !normalTargets.isEmpty {
                outcomes += Reclaimer.reclaim(normalTargets, method: method) { current, total, item in
                    Task { @MainActor [weak self] in
                        guard let self, self.isReclaiming else { return }
                        self.reclaimProgress = ReclaimProgress(
                            current: systemTargets.count + current,
                            total: systemTargets.count + total, label: item.label)
                    }
                }
            }
            let cancelled = Task.isCancelled
            // Best-effort, unprivileged, near-instant: only when something was freed
            // (a failed batch has nothing for snapshots to hold on to), and any
            // failure simply leaves the hint out.
            let listing = outcomes.contains { $0.failure == nil }
                ? ((try? await SnapshotTool.listAll()) ?? .empty) : .empty
            await MainActor.run { [weak self] in
                AppModel.activeReclaimCount -= 1
                defer {
                    // A quit requested mid-reclaim was deferred; release it now.
                    if AppModel.terminateAfterReclaim, AppModel.activeReclaimCount == 0 {
                        AppModel.terminateAfterReclaim = false
                        NSApplication.shared.reply(toApplicationShouldTerminate: true)
                    }
                }
                guard let self else { return }
                self.isReclaiming = false
                self.reclaimProgress = nil
                let reclaimed = outcomes.filter { $0.failure == nil }
                let reclaimedPaths = Set(reclaimed.map(\.item.path))
                let reclaimedPrefixes = reclaimed.map { $0.item.path + "/" }
                self.items.removeAll { item in
                    reclaimedPaths.contains(item.path)
                        || reclaimedPrefixes.contains { item.path.hasPrefix($0) }
                }
                let remaining = Set(self.items.map(\.id))
                self.checkedIDs = self.checkedIDs.intersection(remaining)
                let freedBytes = reclaimed.reduce(0) { $0 + $1.item.sizeBytes }
                if !reclaimed.isEmpty {
                    self.preferences.lifetimeReclaimedBytes += freedBytes
                    self.preferences.lifetimeReclaimedCount += reclaimed.count
                }
                self.summary = ReclaimSummary(
                    freedBytes: freedBytes,
                    reclaimedCount: reclaimed.count,
                    unmeasuredReclaimed: reclaimed.filter { !$0.item.isMeasured }.count,
                    failures: outcomes.compactMap { outcome in
                        outcome.failure.map { "\(outcome.item.label): \($0)" }
                    },
                    systemDeleted: reclaimed.filter(\.item.isSystemArea).count,
                    trashed: method == .trash,
                    cancelled: cancelled,
                    freeBytesBefore: freeBefore,
                    freeBytesAfter: Self.volumeFreeBytes(),
                    lifetimeReclaimedBytes: self.preferences.lifetimeReclaimedBytes,
                    localSnapshots: listing.snapshots,
                    otherSnapshotNames: listing.otherNames)
            }
        }
    }

    private static func volumeFreeBytes() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Exclusions

    /// "Never suggest this again": persists the paths and drops the rows.
    func exclude(ids: Set<String>) {
        let existing = Set(preferences.excludedPaths)
        let newPaths = items
            .filter { ids.contains($0.id) && !existing.contains($0.path) }
            .map(\.path)
        if !newPaths.isEmpty {
            // One assignment → one UserDefaults write, however many rows were excluded.
            preferences.excludedPaths.append(contentsOf: newPaths)
        }
        items.removeAll { ids.contains($0.id) }
        checkedIDs.subtract(ids)
        tableSelection.subtract(ids)
    }

    // MARK: Row actions (shared by the context menu and the Items menu)

    func setChecked(_ checked: Bool, ids: Set<String>) {
        for id in ids { setChecked(checked, id: id) }
    }

    func revealInFinder(ids: Set<String>) {
        let urls = items.filter { ids.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func copyPaths(ids: Set<String>) {
        let paths = items.filter { ids.contains($0.id) }.map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    /// Adds every selected project artifact's *project folder* to watch mode — the
    /// artifact itself can't be a watch root (a scan never descends into artifacts,
    /// so watching it would find nothing), but its project can, which keeps the
    /// whole project clean from now on. Known-cache rows are skipped: watching
    /// fixed cache locations isn't supported.
    func addToWatchedFolders(ids: Set<String>) {
        for item in items where ids.contains(item.id) && !item.isKnownCache {
            let project = URL(fileURLWithPath: item.path).deletingLastPathComponent().path
            preferences.watchFolder(path: project)
        }
    }

    /// True when any selected project artifact's project folder isn't watched yet —
    /// the enabled state of "Add to Watched Folders".
    func canWatchSelection(ids: Set<String>) -> Bool {
        let watched = Set(preferences.watchedFolders.map(\.path))
        return items.contains { item in
            ids.contains(item.id) && !item.isKnownCache
                && !watched.contains(URL(fileURLWithPath: item.path).deletingLastPathComponent().path)
        }
    }
}
