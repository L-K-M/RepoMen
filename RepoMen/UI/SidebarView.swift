import SwiftUI

/// Category list with live per-category totals — the "where did my disk go" overview.
struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: $model.sidebarSelection) {
            row(for: .all, label: "Everything", symbol: "internaldrive")

            Section("Categories") {
                ForEach(ArtifactCategory.allCases) { category in
                    row(for: .category(category), label: category.label, symbol: category.symbol)
                }
            }
        }
        .listStyle(.sidebar)
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
