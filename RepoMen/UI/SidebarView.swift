import SwiftUI

/// Category list with live per-category totals — the "where did my disk go" overview.
struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var snapshotModel: SnapshotModel

    var body: some View {
        List(selection: $model.sidebarSelection) {
            row(for: .all, label: "Everything", symbol: "internaldrive")

            Section("Categories") {
                ForEach(ArtifactCategory.allCases) { category in
                    row(for: .category(category), label: category.label, symbol: category.symbol)
                }
            }

            Section("Time Machine") {
                snapshotsRow
            }

            Section("Managed cleanup") {
                HStack {
                    Label {
                        Text("Managed cleanup")
                    } icon: {
                        Image(systemName: "shippingbox.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(SidebarEntry.managedStorage)
            }
        }
        .listStyle(.sidebar)
    }

    /// Snapshots are not paths and have no byte total (macOS exposes none to apps),
    /// so this row carries a count once the pane has listed them — never a size,
    /// and never a share of "Everything".
    private var snapshotsRow: some View {
        let count = snapshotModel.snapshots.count
        return HStack {
            Label {
                Text("Local snapshots")
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Color.purple)
            }
            Spacer()
            if snapshotModel.hasLoaded {
                Text("\(count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help(count == 1 ? "1 Time Machine local snapshot"
                                     : "\(count) Time Machine local snapshots")
            }
        }
        .tag(SidebarEntry.snapshots)
    }

    private func row(for entry: SidebarEntry, label: String, symbol: String) -> some View {
        let stats = model.stats(for: entry)
        return HStack {
            // Category glyphs carry their tint here too — the color language the
            // table rows speak is taught where the categories live.
            Label {
                Text(label)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(tint(for: entry))
            }
            Spacer()
            if stats.count > 0 {
                Text(Format.bytes(stats.bytes))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .tag(entry)
    }

    private func tint(for entry: SidebarEntry) -> Color {
        if case .category(let category) = entry { return category.tint }
        return .secondary
    }
}
