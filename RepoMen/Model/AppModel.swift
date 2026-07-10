import AppKit
import Combine
import Foundation

/// What the sidebar can show.
enum SidebarEntry: Hashable {
    case all
    case category(ArtifactCategory)
}

/// Result of a reclaim run, presented as an alert.
struct ReclaimSummary: Identifiable, Sendable {
    let id = UUID()
    let freedBytes: Int64
    let reclaimedCount: Int
    /// "label: reason" for every skipped/failed item.
    let failures: [String]
    let trashed: Bool
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

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var items: [CleanableItem] = []
    @Published private(set) var scanStatus = ""
    @Published private(set) var isReclaiming = false
    @Published var checkedIDs: Set<String> = []
    @Published var sidebarSelection: SidebarEntry? = .all
    @Published var sortOrder: [KeyPathComparator<CleanableItem>] = [
        KeyPathComparator(\.sizeBytes, order: .reverse),
    ]
    @Published var searchText = ""
    @Published var summary: ReclaimSummary?

    let preferences: Preferences
    private var scanTask: Task<Void, Never>?
    /// Monotonic scan token, bumped on every start/cancel. Every main-actor write a
    /// detached scan task performs is guarded by it, so a superseded task (or its
    /// still-running sizers) can never publish into a newer scan's state.
    private var scanGeneration = 0
    /// Measurements waiting to be applied to `items` in one batch (id → measurement).
    private var pendingMeasurements: [String: DirectorySizer.Measurement] = [:]
    private var flushScheduled = false

    init(preferences: Preferences = .shared) {
        self.preferences = preferences
    }

    // MARK: Derived state

    var isBusy: Bool { phase == .scanning || phase == .measuring }

    /// While sizes stream in, rows keep a stable label/path order so they don't jump
    /// under the cursor mid-click; the user's sort applies once measuring completes.
    private static let measuringOrder: [KeyPathComparator<CleanableItem>] = [
        KeyPathComparator(\.label), KeyPathComparator(\.path),
    ]

    var visibleItems: [CleanableItem] {
        var filtered = items
        if case .category(let category)? = sidebarSelection {
            filtered = filtered.filter { $0.category == category }
        }
        if !searchText.isEmpty {
            filtered = filtered.filter {
                $0.label.localizedCaseInsensitiveContains(searchText)
                    || $0.path.localizedCaseInsensitiveContains(searchText)
            }
        }
        return filtered.sorted(using: phase == .measuring ? Self.measuringOrder : sortOrder)
    }

    func stats(for entry: SidebarEntry) -> (count: Int, bytes: Int64) {
        let matching: [CleanableItem]
        switch entry {
        case .all: matching = items
        case .category(let category): matching = items.filter { $0.category == category }
        }
        return (matching.count, matching.reduce(0) { $0 + $1.sizeBytes })
    }

    var checkedItems: [CleanableItem] { items.filter { checkedIDs.contains($0.id) } }
    var checkedBytes: Int64 { checkedItems.reduce(0) { $0 + $1.sizeBytes } }

    // MARK: Scanning

    func startScan() {
        guard !isReclaiming else { return }   // never walk the tree mid-deletion
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

        items = []
        checkedIDs = []
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
                self.items = discovered
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

    /// Sizes all items with bounded concurrency — sizing hammers the disk, and four
    /// walkers saturate an SSD without starving the UI. Cancelled (partial)
    /// measurements are discarded, never reported.
    private nonisolated static func measureAll(
        _ items: [CleanableItem],
        apply: @escaping @Sendable (String, DirectorySizer.Measurement) -> Void
    ) async {
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
            for _ in 0..<4 { addNext() }
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

    func reclaimChecked() {
        let targets = checkedItems
        guard !targets.isEmpty, !isReclaiming else { return }
        let method: Reclaimer.Method = preferences.moveToTrash ? .trash : .delete
        isReclaiming = true

        Task.detached(priority: .userInitiated) { [weak self] in
            let outcomes = Reclaimer.reclaim(targets, method: method)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isReclaiming = false
                let reclaimed = outcomes.filter { $0.failure == nil }
                self.items.removeAll { item in
                    reclaimed.contains { PathGuards.isUnder(item.path, root: $0.item.path) }
                }
                let remaining = Set(self.items.map(\.id))
                self.checkedIDs = self.checkedIDs.intersection(remaining)
                self.summary = ReclaimSummary(
                    freedBytes: reclaimed.reduce(0) { $0 + $1.item.sizeBytes },
                    reclaimedCount: reclaimed.count,
                    failures: outcomes.compactMap { outcome in
                        outcome.failure.map { "\(outcome.item.label): \($0)" }
                    },
                    trashed: method == .trash)
            }
        }
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
    }
}
