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
            Label(label, systemImage: symbol)
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
}
