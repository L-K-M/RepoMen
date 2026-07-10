import AppKit
import SwiftUI

/// Sortable results table. Checkboxes (not row selection) decide what gets reclaimed —
/// row selection only feeds the context menu and the space-bar toggle, so a stray
/// click can never arm anything.
struct ItemTable: View {
    @EnvironmentObject private var model: AppModel
    @State private var tableSelection: Set<CleanableItem.ID> = []

    var body: some View {
        let visible = model.visibleItems
        let maxVisibleBytes = visible.map(\.sizeBytes).max() ?? 0
        return Table(visible, selection: $tableSelection, sortOrder: $model.sortOrder) {
            TableColumn("") { (item: CleanableItem) in
                Toggle("", isOn: Binding(
                    get: { model.checkedIDs.contains(item.id) },
                    set: { model.setChecked($0, id: item.id) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                // The anonymous checkbox arms a deletion — VoiceOver must say whose.
                .accessibilityLabel("Reclaim \(item.label)")
            }
            .width(24)

            TableColumn("Item", value: \.label) { item in
                itemCell(item)
            }

            TableColumn("Size", value: \.sizeBytes) { item in
                sizeCell(item, maxVisibleBytes: maxVisibleBytes)
            }
            .width(min: 70, ideal: 90, max: 120)

            TableColumn("Last built", value: \.lastModified) { item in
                Text(item.isMeasured ? Format.age(item.lastModified) : "…")
                    .foregroundStyle(stalenessColor(item))
                    .accessibilityValue(item.isMeasured
                                        ? Format.age(item.lastModified) : "still measuring")
            }
            .width(min: 80, ideal: 110, max: 140)
        }
        .contextMenu(forSelectionType: CleanableItem.ID.self) { ids in
            Button("Reveal in Finder") { reveal(ids) }
            Button("Copy Path") { copyPaths(ids) }
            Divider()
            Button("Check") { setChecked(true, ids: ids) }
                .disabled(model.isReclaiming)
            Button("Uncheck") { setChecked(false, ids: ids) }
                .disabled(model.isReclaiming)
            Divider()
            // Disabled mid-reclaim: excluding a row cannot save it from a batch that
            // is already deleting, and pretending otherwise would lose data.
            Button("Exclude from Future Scans") { model.exclude(ids: ids) }
                .disabled(model.isReclaiming)
        }
        .modifier(SpaceTogglesChecked(selection: tableSelection))
    }

    // MARK: Cells

    private func itemCell(_ item: CleanableItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind.symbol)
                .foregroundStyle(item.category.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.label)
                        .lineLimit(1)
                        .layoutPriority(1)   // the name wins over decorative badges
                    badge(item.kind.label, tint: item.category.tint)
                    if item.kind.isSlowToRegenerate {
                        badge("slow to rebuild", tint: .yellow)
                    }
                    if let warning = item.warning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .help(warning)   // truncation must never hide a safety signal
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

    /// One shared recipe keeps the capsules visually in step in both appearances.
    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(.secondary)
    }

    /// Size text over a proportional bar — the 40 GB offender should scream while the
    /// 3 MB __pycache__ whispers. Square-root scale so smaller rows stay visible.
    private func sizeCell(_ item: CleanableItem, maxVisibleBytes: Int64) -> some View {
        Text(item.isMeasured ? Format.bytes(item.sizeBytes) : "…")
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 3)
            .background(alignment: .leading) {
                if item.isMeasured, maxVisibleBytes > 0, item.sizeBytes > 0 {
                    let fraction = (Double(item.sizeBytes) / Double(maxVisibleBytes)).squareRoot()
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(item.category.tint.opacity(0.18))
                            .frame(width: max(2, proxy.size.width * fraction))
                    }
                }
            }
            .accessibilityValue(item.isMeasured ? Format.bytes(item.sizeBytes) : "still measuring")
    }

    /// Ages past the user's idle threshold warm up — the column predicts exactly what
    /// "Select Idle N+ Days" would grab; three thresholds and beyond reads abandoned.
    private func stalenessColor(_ item: CleanableItem) -> Color {
        guard item.isMeasured, item.lastModified > .distantPast else { return .secondary }
        let idleSeconds = Double(model.preferences.idleDays) * 86_400
        let age = Date().timeIntervalSince(item.lastModified)
        if age > 3 * idleSeconds { return .red.opacity(0.75) }
        if age > idleSeconds { return .orange.opacity(0.9) }
        return .secondary
    }

    // MARK: Actions

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

/// Space toggles the checkboxes of the selected rows — the idiomatic "do the thing to
/// the selection" key (macOS 14+; earlier systems keep the click and context-menu
/// paths). Mixed selections check everything first.
private struct SpaceTogglesChecked: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let selection: Set<CleanableItem.ID>

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onKeyPress(.space) {
                guard !selection.isEmpty, !model.isReclaiming else { return .ignored }
                let allChecked = selection.allSatisfy { model.checkedIDs.contains($0) }
                for id in selection { model.setChecked(!allChecked, id: id) }
                return .handled
            }
        } else {
            content
        }
    }
}
