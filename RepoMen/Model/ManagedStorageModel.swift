import AppKit
import Combine
import Foundation

@MainActor
final class ManagedStorageModel: ObservableObject {
    @Published private(set) var areas: [ManagedStorageArea]
    @Published private(set) var isMeasuring = false
    @Published var actionError: String?
    private var task: Task<Void, Never>?
    private var generation = 0
    private let areasProvider: @Sendable () -> [ManagedStorageArea]
    private let measurement: @Sendable (ManagedStorageArea) -> ManagedStorageArea.State

    init(areasProvider: @escaping @Sendable () -> [ManagedStorageArea] = { ManagedStorageCatalog.areas() },
         measurement: @escaping @Sendable (ManagedStorageArea) -> ManagedStorageArea.State = { ManagedStorageCatalog.measure($0) }) {
        self.areasProvider = areasProvider
        self.measurement = measurement
        areas = areasProvider()
    }

    func measure() {
        cancel()
        areas = areasProvider()
        let pending = areas
        let token = generation
        let measureArea = measurement
        isMeasuring = true
        task = Task.detached(priority: .utility) { [weak self] in
            for area in pending {
                guard !Task.isCancelled else { break }
                let state = measureArea(area)
                guard !Task.isCancelled else { break }
                await self?.update(id: area.id, state: state, generation: token)
            }
            await self?.finish(generation: token)
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        isMeasuring = false
    }

    private func update(id: String, state: ManagedStorageArea.State, generation token: Int) {
        guard generation == token, let index = areas.firstIndex(where: { $0.id == id }) else { return }
        areas[index].state = state
    }

    private func finish(generation token: Int) {
        guard generation == token else { return }
        isMeasuring = false
        task = nil
    }

    func openApplication(for area: ManagedStorageArea) {
        guard let url = area.applicationBundleIDs.compactMap({
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }).first else {
            actionError = "The owning app could not be found. Open your installed app and follow the instructions shown here."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            if let error {
                Task { @MainActor in self?.actionError = error.localizedDescription }
            }
        }
    }

    func reveal(_ area: ManagedStorageArea) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: area.path)])
    }

    func copyCommand(for area: ManagedStorageArea) {
        guard let command = area.command else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}
