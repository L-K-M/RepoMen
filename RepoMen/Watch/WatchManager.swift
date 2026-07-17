import AppKit
import Combine
import Foundation

/// The watched-folders loop: a check shortly after launch, then every few hours
/// while the app lives in the menu bar. Each check deep-scans the watched roots
/// (the same `Scanner` the window uses), measures what it finds, and — when the
/// user armed the master switch — moves anything idle past its folder's threshold
/// to the Trash. Auto-clean is *always* Trash, never permanent delete, and every
/// item still passes `Reclaimer`'s re-verification and `PathGuards` at trash time.
@MainActor
final class WatchManager: ObservableObject {
    static let shared = WatchManager()

    /// How often watched folders are re-checked while the app runs.
    static let checkInterval: TimeInterval = 6 * 3_600
    /// Settle time after launch before the first check (login launches shouldn't
    /// hit the disk while the machine is still waking).
    static let initialDelaySeconds: UInt64 = 30

    @Published private(set) var isChecking = false

    private let preferences: Preferences
    private var cancellables: Set<AnyCancellable> = []
    private var timer: Timer?
    private var started = false

    /// Terminate-safety, mirroring `AppModel`'s manual-reclaim deferral: the app
    /// must never die in the middle of an auto-reclaim batch either.
    private(set) static var activeReclaimCount = 0
    static var terminateAfterReclaim = false

    init(preferences: Preferences = .shared) {
        self.preferences = preferences
        // Watch mode can be armed mid-session (first folder added in Settings):
        // start lazily the moment any enabled folder exists. `dropFirst` skips the
        // subscription's synchronous replay — init-time state needs no reaction.
        preferences.$watchedFolders
            .dropFirst()
            .sink { [weak self] _ in self?.start() }
            .store(in: &cancellables)
    }

    var hasWatchedFolders: Bool {
        preferences.watchedFolders.contains { $0.isEnabled }
    }

    /// Idempotent. Arms the repeating timer and the delayed first check; a no-op
    /// until at least one enabled watched folder exists.
    func start() {
        guard !started, hasWatchedFolders else { return }
        started = true
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.runCheck() }
        }
        timer.tolerance = Self.checkInterval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.initialDelaySeconds * 1_000_000_000)
            self?.runCheck()
        }
    }

    // MARK: A check

    /// Runs one watch check (timer, launch delay, or "Check Now"). Overlapping
    /// checks are refused; the heavy work runs detached and reports back.
    func runCheck() {
        guard !isChecking else { return }
        let folders = preferences.watchedFolders.filter { $0.isEnabled }
        guard !folders.isEmpty else { return }
        isChecking = true
        let autoTrash = preferences.watchAutoTrash
        let config = ScanConfiguration(
            roots: folders.map { URL(fileURLWithPath: $0.path) },
            excludedPaths: Set(preferences.excludedPaths),
            enabledKinds: preferences.enabledKinds)

        Task.detached(priority: .utility) { [weak self] in
            let found = Scanner.scan(config)
            guard !Task.isCancelled else {
                await self?.finishCancelled()
                return
            }
            let measured = await Self.measure(found)
            let candidates = WatchEngine.eligibleItems(items: measured, folders: folders)

            var outcomes: [Reclaimer.Outcome]?
            if autoTrash, !candidates.isEmpty {
                await MainActor.run { Self.activeReclaimCount += 1 }
                let result = Reclaimer.reclaim(candidates, method: .trash)
                await MainActor.run {
                    Self.activeReclaimCount -= 1
                    // A quit requested mid-batch was deferred; release it now.
                    if Self.terminateAfterReclaim, Self.activeReclaimCount == 0 {
                        Self.terminateAfterReclaim = false
                        NSApplication.shared.reply(toApplicationShouldTerminate: true)
                    }
                }
                outcomes = result
            }
            await self?.finish(candidates: candidates, outcomes: outcomes)
        }
    }

    /// Applies a check's outcome on the main actor: the persisted run record, the
    /// lifetime tally, and a notification only when there is something to say.
    private func finish(candidates: [CleanableItem], outcomes: [Reclaimer.Outcome]?) {
        isChecking = false
        let reclaimed = (outcomes ?? []).filter { $0.failure == nil }
        let failures = (outcomes ?? []).compactMap(\.failure)
        let freedBytes = reclaimed.reduce(0) { $0 + $1.item.sizeBytes }
        if !reclaimed.isEmpty {
            preferences.lifetimeReclaimedBytes += freedBytes
            preferences.lifetimeReclaimedCount += reclaimed.count
        }
        let record = WatchRunRecord(
            date: Date(),
            dryRun: outcomes == nil,
            candidateCount: candidates.count,
            candidateBytes: candidates.reduce(0) { $0 + $1.sizeBytes },
            reclaimedCount: reclaimed.count,
            reclaimedBytes: freedBytes,
            failureCount: failures.count)
        preferences.lastWatchRun = record
        Log.watch.info("watch check: \(record.candidateCount) candidates, \(record.reclaimedCount) reclaimed (\(record.reclaimedBytes) bytes), \(record.failureCount) failed, dryRun=\(record.dryRun)")

        if outcomes != nil {
            if !reclaimed.isEmpty || !failures.isEmpty {
                WatchNotifier.postReclaim(record: record)
            }
        } else if !candidates.isEmpty {
            // Dry-run: notify once per *changed* candidate set, not every cycle.
            let signature = WatchEngine.signature(for: candidates)
            if signature != preferences.lastWatchDryRunSignature {
                preferences.lastWatchDryRunSignature = signature
                WatchNotifier.postDryRun(record: record)
            }
        }
    }

    private func finishCancelled() {
        isChecking = false
    }

    // MARK: Measuring

    /// Sizes the found artifacts with the same bounded concurrency as the window's
    /// scan (four walkers; incomplete measurements from cancellation are dropped).
    private nonisolated static func measure(_ items: [CleanableItem]) async -> [CleanableItem] {
        await withTaskGroup(of: (String, DirectorySizer.Measurement).self) { group in
            var iterator = items.makeIterator()
            func addNext() {
                guard let item = iterator.next() else { return }
                group.addTask {
                    (item.id, DirectorySizer.measure(item.url))
                }
            }
            for _ in 0..<4 { addNext() }
            var measurements: [String: DirectorySizer.Measurement] = [:]
            for await (id, measurement) in group {
                if Task.isCancelled { break }
                if measurement.isComplete { measurements[id] = measurement }
                addNext()
            }
            return items.map { item in
                guard let measurement = measurements[item.id] else { return item }
                var measured = item
                measured.sizeBytes = measurement.bytes
                measured.isMeasured = true
                measured.lastModified = measurement.newestModification
                return measured
            }
        }
    }
}
