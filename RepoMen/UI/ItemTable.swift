import AppKit
import SwiftUI

/// Sortable results table. Checkboxes (not row selection) decide what gets reclaimed —
/// row selection only feeds the context menu, so a stray click can never arm anything.
struct ItemTable: View {
    @EnvironmentObject private var model: AppModel
    @State private var tableSelection: Set<CleanableItem.ID> = []

    var body: some View {
        Table(model.visibleItems, selection: $tableSelection, sortOrder: $model.sortOrder) {
            TableColumn("") { (item: CleanableItem) in
                Toggle("", isOn: Binding(
                    get: { model.checkedIDs.contains(item.id) },
                    set: { model.setChecked($0, id: item.id) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            }
            .width(24)

            TableColumn("Item", value: \.label) { item in
                itemCell(item)
            }

            TableColumn("Size", value: \.sizeBytes) { item in
                Text(item.isMeasured ? Format.bytes(item.sizeBytes) : "…")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90, max: 120)

            TableColumn("Last built", value: \.lastModified) { item in
                Text(item.isMeasured ? Format.age(item.lastModified) : "…")
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110, max: 140)
        }
        .contextMenu(forSelectionType: CleanableItem.ID.self) { ids in
            Button("Reveal in Finder") { reveal(ids) }
            Button("Copy Path") { copyPaths(ids) }
            Divider()
            Button("Check") { setChecked(true, ids: ids) }
            Button("Uncheck") { setChecked(false, ids: ids) }
            Divider()
            Button("Exclude from Future Scans") { model.exclude(ids: ids) }
        }
    }

    private func itemCell(_ item: CleanableItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind.symbol)
                .foregroundStyle(item.category.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.label)
                        .lineLimit(1)
                    Text(item.kind.label)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(item.category.tint.opacity(0.16), in: Capsule())
                        .foregroundStyle(.secondary)
                    if item.kind.isSlowToRegenerate {
                        Text("slow to rebuild")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.yellow.opacity(0.25), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    if let warning = item.warning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                Text(Format.abbreviatePath(item.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .help(item.kind.regenerationHint)
    }

    private func setChecked(_ checked: Bool, ids: Set<String>) {
        for id in ids { model.setChecked(checked, id: id) }
    }

    private func reveal(_ ids: Set<String>) {
        let urls = model.items.filter { ids.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func copyPaths(_ ids: Set<String>) {
        let paths = model.items.filter { ids.contains($0.id) }.map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }
}
