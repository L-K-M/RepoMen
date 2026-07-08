import SwiftUI

/// Pre-scan welcome: says what RepoMen will (and won't) do and shows which folders a
/// scan would cover, so the first click is informed.
struct EmptyStateView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "internaldrive")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Repossess your disk")
                .font(.title2)
                .bold()
            Text("""
                RepoMen finds regenerable build artifacts — Rust targets, node_modules, \
                DerivedData, stale caches — even deep inside your project trees, and \
                reclaims only what you check. Nothing is pre-selected, everything goes \
                to the Trash, and Docker is never touched.
                """)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)

            if preferences.scanRoots.isEmpty {
                Text("No scan folders configured yet — add one in Settings.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                Text("Scans: " + preferences.scanRoots.map { Format.abbreviatePath($0) }.joined(separator: "  ·  "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 480)
            }

            HStack(spacing: 12) {
                Button("Scan Now") { model.startScan() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preferences.scanRoots.isEmpty)
                Button("Choose Folders…") { SettingsOpener.open() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}
