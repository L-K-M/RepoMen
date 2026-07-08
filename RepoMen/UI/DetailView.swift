import SwiftUI

/// The working surface: the item table with scan/reclaim toolbar, a status footer,
/// and the confirmation + summary dialogs. Reclaiming always passes through the
/// confirmation dialog — there is no one-click path to deletion.
struct DetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmingReclaim = false

    var body: some View {
        Group {
            if model.items.isEmpty && !model.isBusy {
                EmptyStateView()
            } else {
                VStack(spacing: 0) {
                    ItemTable()
                    Divider()
                    footer
                }
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Filter by name or path")
        .toolbar { toolbarContent }
        .confirmationDialog(
            "Reclaim \(model.checkedItems.count) item\(model.checkedItems.count == 1 ? "" : "s") (\(Format.bytes(model.checkedBytes)))?",
            isPresented: $confirmingReclaim,
            titleVisibility: .visible
        ) {
            Button(model.preferences.moveToTrash ? "Move to Trash" : "Delete Permanently",
                   role: .destructive) {
                model.reclaimChecked()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.preferences.moveToTrash
                 ? "Everything is re-verified first and goes to the Trash — you can put it back."
                 : "Everything is re-verified first, then deleted immediately. This cannot be undone.")
        }
        .alert(
            "Space repossessed",
            isPresented: Binding(
                get: { model.summary != nil },
                set: { if !$0 { model.summary = nil } }),
            presenting: model.summary
        ) { _ in
            Button("OK") { model.summary = nil }
        } message: { summary in
            Text(summaryText(summary))
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isBusy {
                Button {
                    model.cancelScan()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .help("Stop the scan")
            } else {
                Button {
                    model.startScan()
                } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                }
                .help("Scan the configured folders (⌘R)")
            }

            Button {
                confirmingReclaim = true
            } label: {
                Label("Reclaim…", systemImage: "trash")
            }
            .disabled(model.checkedItems.isEmpty || model.isReclaiming)
            .help("Move the checked items to the Trash")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                Text(model.scanStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                let visible = model.visibleItems
                Text("\(visible.count) item\(visible.count == 1 ? "" : "s") · \(Format.bytes(visible.reduce(0) { $0 + $1.sizeBytes })) reclaimable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            Menu("Select") {
                Button("All Visible") { model.checkAllVisible() }
                Button("Idle \(model.preferences.idleDays)+ Days") { model.checkIdleVisible() }
                Button("None") { model.clearChecked() }
            }
            .fixedSize()

            Text("Checked: \(model.checkedItems.count) · \(Format.bytes(model.checkedBytes))")
                .font(.caption)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func summaryText(_ summary: ReclaimSummary) -> String {
        var text: String
        if summary.reclaimedCount == 0 {
            text = "Nothing was reclaimed."
        } else {
            let items = "\(summary.reclaimedCount) item\(summary.reclaimedCount == 1 ? "" : "s")"
            text = "Reclaimed \(items) — \(Format.bytes(summary.freedBytes)) "
                + (summary.trashed ? "moved to the Trash." : "deleted.")
        }
        if !summary.failures.isEmpty {
            text += "\n\nSkipped:\n" + summary.failures.prefix(8).joined(separator: "\n")
            if summary.failures.count > 8 {
                text += "\n…and \(summary.failures.count - 8) more"
            }
        }
        return text
    }
}
