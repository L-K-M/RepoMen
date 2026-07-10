import AppKit
import SwiftUI

/// The working surface: the item table with scan/reclaim toolbar, a status footer,
/// and the confirmation + summary dialogs. Reclaiming always passes through the
/// confirmation dialog — there is no one-click path to deletion.
struct DetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.items.isEmpty && !model.isBusy {
                EmptyStateView()
            } else {
                VStack(spacing: 0) {
                    ZStack {
                        ItemTable()
                        if model.visibleItems.isEmpty && !model.items.isEmpty {
                            noMatchesPlaceholder
                        }
                    }
                    Divider()
                    footer
                }
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Filter by name or path")
        .toolbar { toolbarContent }
        .confirmationDialog(
            confirmationTitle,
            isPresented: $model.confirmingReclaim,
            titleVisibility: .visible
        ) {
            Button(model.preferences.moveToTrash ? "Move to Trash" : "Delete Permanently",
                   role: .destructive) {
                model.reclaimChecked()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
        .alert(
            summaryTitle,
            isPresented: Binding(
                get: { model.summary != nil },
                set: { if !$0 { model.summary = nil } }),
            presenting: model.summary
        ) { summary in
            if summary.trashed && summary.reclaimedCount > 0 {
                Button("Open Trash") { openTrash() }
            }
            Button("OK") { model.summary = nil }
        } message: { summary in
            Text(summaryText(summary))
        }
    }

    // MARK: Toolbar

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
                .disabled(model.isReclaiming)
                .help(model.isReclaiming
                      ? "Waiting for the reclaim to finish"
                      : "Scan the configured folders (⌘R)")
            }

            Button {
                model.confirmingReclaim = true
            } label: {
                Label("Reclaim…", systemImage: "trash")
            }
            .disabled(model.checkedItems.isEmpty || model.isReclaiming)
            .help(model.preferences.moveToTrash
                  ? "Move the checked items to the Trash (⌘⌫)"
                  : "Permanently delete the checked items (⌘⌫)")
        }
    }

    // MARK: Placeholders

    /// Shown over the empty table body when a category/filter matches nothing —
    /// a blank table reads as a bug, not as a clean result.
    private var noMatchesPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(model.searchText.isEmpty
                 ? emptyCategoryText
                 : "No items match “\(model.searchText)”")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var emptyCategoryText: String {
        if case .category(let category)? = model.sidebarSelection {
            return "No \(category.label.lowercased()) found — nothing to repossess here."
        }
        return "Nothing found."
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let progress = model.reclaimProgress {
                ProgressView(value: Double(progress.current),
                             total: Double(max(progress.total, 1)))
                    .controlSize(.small)
                    .frame(maxWidth: 160)
                Text(progress.label.isEmpty
                     ? "Reclaiming \(progress.total) item\(progress.total == 1 ? "" : "s")…"
                     : "Reclaiming \(progress.current) of \(progress.total) — \(progress.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Stop") { model.cancelReclaim() }
                    .controlSize(.small)
                    .help("Finish the current item, leave the rest untouched")
            } else if model.isBusy {
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
                if model.preferences.lifetimeReclaimedBytes > 0 {
                    Text("Lifetime: \(Format.bytes(model.preferences.lifetimeReclaimedBytes)) repossessed")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .help("Everything RepoMen has reclaimed for you since install")
                }
                if let offender = model.biggestOffender,
                   !model.checkedIDs.contains(offender.id) {
                    Button {
                        model.setChecked(true, id: offender.id)
                    } label: {
                        Label("Biggest offender: \(offender.label) — \(Format.bytes(offender.sizeBytes))",
                              systemImage: "scope")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Click to check it for reclaiming")
                }
            }

            Spacer()

            Menu("Select") {
                Button("All Visible") { model.checkAllVisible() }
                Button("Idle \(model.preferences.idleDays)+ Days") { model.checkIdleVisible() }
                Button("Uncheck All\(model.checkedIDs.isEmpty ? "" : " (\(model.checkedIDs.count))")") {
                    model.clearChecked()
                }
                .disabled(model.checkedIDs.isEmpty)
            }
            .controlSize(.small)
            .fixedSize()

            if !model.checkedIDs.isEmpty {
                Text("Checked: \(model.checkedItems.count) · \(checkedSizeText)")
                    .font(.caption)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// "at least X" while any checked item is still being sized — a hard 0 for a
    /// multi-GB tree would misinform exactly the number the user is deciding on.
    private var checkedSizeText: String {
        let bytes = Format.bytes(model.checkedBytes)
        return model.checkedItems.contains { !$0.isMeasured } ? "at least \(bytes)" : bytes
    }

    // MARK: Dialog copy

    private var confirmationTitle: String {
        let count = model.checkedItems.count
        return "Reclaim \(count) item\(count == 1 ? "" : "s") (\(checkedSizeText))?"
    }

    /// The last look: names the biggest items, calls out warnings, and counts
    /// anything the current filter is hiding — the user should never confirm the
    /// deletion of things they cannot see.
    private var confirmationMessage: String {
        let checked = model.checkedItems
        var lines: [String] = []

        let top = checked.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(5)
        lines.append(contentsOf: top.map { item in
            "• \(item.label) — \(item.isMeasured ? Format.bytes(item.sizeBytes) : "still measuring")"
        })
        if checked.count > top.count {
            lines.append("…and \(checked.count - top.count) more")
        }

        let visibleIDs = Set(model.visibleItems.map(\.id))
        let hidden = checked.filter { !visibleIDs.contains($0.id) }.count
        if hidden > 0 {
            lines.append("⚠︎ Includes \(hidden) checked item\(hidden == 1 ? "" : "s") hidden by the current filter or category.")
        }
        for warning in Set(checked.compactMap(\.warning)).sorted() {
            lines.append("⚠︎ \(warning)")
        }
        let slow = checked.filter(\.kind.isSlowToRegenerate).count
        if slow > 0 {
            lines.append("Includes \(slow) item\(slow == 1 ? "" : "s") that \(slow == 1 ? "is" : "are") slow to rebuild.")
        }

        lines.append(model.preferences.moveToTrash
             ? "Everything is re-verified first and goes to the Trash — you can put it back."
             : "Everything is re-verified first, then deleted immediately. This cannot be undone.")
        return lines.joined(separator: "\n")
    }

    private var summaryTitle: String {
        guard let summary = model.summary else { return "Space repossessed" }
        if summary.cancelled { return "Reclaim stopped" }
        if summary.reclaimedCount == 0 { return "Nothing to repossess" }
        if !summary.failures.isEmpty { return "Partially repossessed" }
        return "Space repossessed"
    }

    private func summaryText(_ summary: ReclaimSummary) -> String {
        var text: String
        if summary.reclaimedCount == 0 {
            text = "Nothing was reclaimed."
        } else {
            let items = "\(summary.reclaimedCount) item\(summary.reclaimedCount == 1 ? "" : "s")"
            text = "Reclaimed \(items) — \(Format.bytes(summary.freedBytes)) "
                + (summary.trashed ? "moved to the Trash." : "deleted.")
            if summary.trashed {
                text += "\n\nThe space frees up once you empty the Trash. Changed your mind? Right-click an item there and choose Put Back."
            } else if let before = summary.freeBytesBefore,
                      let after = summary.freeBytesAfter, after > before {
                text += "\n\nDisk free: \(Format.bytes(before)) → \(Format.bytes(after))."
            }
            if summary.lifetimeReclaimedBytes > summary.freedBytes {
                text += "\nLifetime total: \(Format.bytes(summary.lifetimeReclaimedBytes)) repossessed."
            }
        }
        if summary.cancelled {
            text += "\n\nYou stopped the batch early — the remaining items are untouched and still checked."
        }
        if !summary.failures.isEmpty {
            text += "\n\nSkipped:\n" + summary.failures.prefix(8).joined(separator: "\n")
            if summary.failures.count > 8 {
                text += "\n…and \(summary.failures.count - 8) more"
            }
        }
        return text
    }

    private func openTrash() {
        guard let trash = FileManager.default.urls(for: .trashDirectory,
                                                   in: .userDomainMask).first else { return }
        NSWorkspace.shared.open(trash)
    }
}
