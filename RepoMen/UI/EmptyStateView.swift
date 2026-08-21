import SwiftUI

/// The empty detail surface wears two hats: before the first scan it is the welcome
/// pitch (what RepoMen will and won't do); after a scan that found nothing it must say
/// so — landing back on the identical welcome text reads as "did anything happen?",
/// and a TCC-denied folder would be indistinguishable from a genuinely clean disk.
struct EmptyStateView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: Preferences

    @State private var diskFreeBytes: Int64?
    @State private var diskTotalBytes: Int64?

    /// A completed scan with zero findings leaves the model in `.ready`; before any
    /// scan (or after cancelling an empty one) it is `.idle`.
    private var scanCameUpEmpty: Bool { model.phase == .ready }

    var body: some View {
        VStack(spacing: 14) {
            if scanCameUpEmpty {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
            } else if let free = diskFreeBytes, let total = diskTotalBytes, total > 0 {
                // The welcome icon earns its place: the first thing a new user sees
                // is the problem RepoMen exists to solve. Read once; no monitoring.
                Gauge(value: Double(total - free), in: 0...Double(total)) {
                    Image(systemName: "internaldrive")
                } currentValueLabel: {
                    Text(Format.bytes(free))
                        .font(.caption2)
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(Double(free) < Double(total) * 0.1 ? .orange : .teal)
                .help("\(Format.bytes(free)) of \(Format.bytes(total)) free")
            } else {
                Image(systemName: "internaldrive")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
            }
            Text(scanCameUpEmpty ? "Nothing to repossess" : "Repossess your disk")
                .font(.title2)
                .bold()
            if scanCameUpEmpty {
                Text("""
                    The scan finished and found no regenerable build artifacts or \
                    stale caches in the configured folders. That's a clean machine.
                    """)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
                Text("""
                    Expected results? macOS may have denied folder access — check \
                    System Settings › Privacy & Security › Files and Folders — or add \
                    more folders in Settings.
                    """)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: 440)
            } else {
                Text("""
                    RepoMen finds regenerable build artifacts — Rust targets, node_modules, \
                    DerivedData, stale caches — even deep inside your project trees, and \
                    reclaims only what you check. Nothing is pre-selected, everything goes \
                    to the Trash, and Docker is never touched.
                    """)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
            }

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
                Button(scanCameUpEmpty ? "Scan Again" : "Scan Now") { model.startScan() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preferences.scanRoots.isEmpty)
                Button("Choose Folders…") { SettingsOpener.open() }
            }

            Text("""
                Disk still mysteriously full? Root-owned system logs (like \
                rtcreportingd's RTCReporting logs) hide outside your home folder — \
                run System Scan from the toolbar to check them. macOS asks for your \
                administrator password.
                """)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
        .task {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            let values = try? home.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
            ])
            diskFreeBytes = values?.volumeAvailableCapacityForImportantUsage
            diskTotalBytes = (values?.volumeTotalCapacity).map(Int64.init)
        }
    }
}
