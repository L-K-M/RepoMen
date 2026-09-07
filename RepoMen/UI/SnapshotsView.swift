import SwiftUI

/// The Time Machine Snapshots window: lists the boot volume's local snapshots,
/// deletes the checked ones, or asks Time Machine to thin by an amount. Both actions
/// pass a confirmation dialog that says "permanent". There is no size column: macOS
/// gives no per-snapshot size to anything but Disk Utility (its Private Size
/// column), so the window says so and offers to open Disk Utility rather than guess.
struct SnapshotsView: View {
    @EnvironmentObject private var model: SnapshotModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            explanation
            table
            controls
            Divider()
            releaseSection
            footnote
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 460)
        .onAppear {
            if !model.isWorking { model.refresh() }
        }
        .confirmationDialog(deleteTitle, isPresented: $model.confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) { model.deleteChecked() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
        .confirmationDialog(thinTitle, isPresented: $model.confirmingThin,
                            titleVisibility: .visible) {
            Button("Release Space", role: .destructive) { model.thinNow() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(thinMessage)
        }
        .alert(
            "Could not list snapshots",
            isPresented: Binding(
                get: { model.loadError != nil },
                set: { if !$0 { model.loadError = nil } })
        ) {
            Button("OK") { model.loadError = nil }
        } message: {
            Text(model.loadError ?? "")
        }
        .alert(
            model.report?.title ?? "",
            isPresented: Binding(
                get: { model.report != nil },
                set: { if !$0 { model.report = nil } }),
            presenting: model.report
        ) { _ in
            Button("OK") { model.report = nil }
        } message: { report in
            Text(report.message)
        }
    }

    // MARK: Sections

    private var explanation: some View {
        Text("""
            Time Machine keeps hourly local snapshots of this disk for about 24 hours. \
            Files you delete stay allocated until every snapshot that references them \
            is gone — so free space can stay flat after emptying the Trash, and macOS \
            purges snapshots on its own only unreliably. Listed here are Time Machine's \
            local snapshots only; snapshots made by other apps are never shown or touched.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var table: some View {
        Table(model.snapshots) {
            TableColumn("") { (snapshot: LocalSnapshot) in
                Toggle("", isOn: Binding(
                    get: { model.checkedIDs.contains(snapshot.id) },
                    set: { model.setChecked($0, id: snapshot.id) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Delete snapshot from \(created(snapshot))")
            }
            .width(24)

            TableColumn("Snapshot") { (snapshot: LocalSnapshot) in
                Text(snapshot.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            TableColumn("Created") { (snapshot: LocalSnapshot) in
                Text(created(snapshot))
            }
            .width(min: 150, ideal: 180, max: 220)

            TableColumn("Age") { (snapshot: LocalSnapshot) in
                Text(Format.age(snapshot.date))
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100, max: 130)
        }
        .overlay {
            if model.snapshots.isEmpty && model.hasLoaded && !model.isLoading {
                Text("No Time Machine local snapshots on this disk right now.")
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoading || model.isWorking)

            if model.isLoading || model.isWorking {
                ProgressView()
                    .controlSize(.small)
                Text(model.isLoading ? "Listing snapshots…" : model.workStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if model.isWorking {
                Button("Stop") { model.cancelWork() }
                    .controlSize(.small)
                    .help("Stop after the snapshot currently being removed")
            }

            Spacer()

            Button("Check All") { model.checkAll() }
                .disabled(model.snapshots.isEmpty || model.isWorking)
            Button("Uncheck All") { model.clearChecked() }
                .disabled(model.checkedIDs.isEmpty)
            Button(role: .destructive) {
                model.confirmingDelete = true
            } label: {
                Label("Delete Checked…", systemImage: "trash")
            }
            .disabled(model.checkedSnapshots.isEmpty || model.isWorking || model.isLoading)
            .help("Permanently delete the checked snapshots — macOS cannot undo this")
        }
    }

    private var releaseSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Release space held by snapshots")
                .font(.headline)
            Text("""
                Asks Time Machine to thin its own local snapshots, oldest first, until \
                about this much is free — the supported way to trigger the purge macOS \
                should perform by itself, without picking snapshots by hand.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("GB", value: $model.thinGigabytes,
                          format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
                Text("GB")
                Picker("Urgency", selection: $model.thinUrgency) {
                    ForEach(SnapshotTool.urgencyRange, id: \.self) { level in
                        Text(urgencyLabel(level)).tag(level)
                    }
                }
                .frame(maxWidth: 260)
                .help("tmutil's 1–4 scale; macOS itself purges at 3 when the Finder needs room")
                Spacer()
                Button {
                    model.confirmingThin = true
                } label: {
                    Label("Release…", systemImage: "clock.arrow.circlepath")
                }
                .disabled(model.isWorking || model.isLoading || model.thinBytes <= 0)
            }
        }
    }

    private var footnote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("""
                macOS reports no per-snapshot size to apps. Disk Utility (View › Show APFS \
                Snapshots) shows each snapshot's Private Size — roughly what deleting it frees.
                """)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Open Disk Utility") { SnapshotModel.openDiskUtility() }
                .controlSize(.small)
        }
    }

    // MARK: Copy

    private func created(_ snapshot: LocalSnapshot) -> String {
        snapshot.date.formatted(date: .abbreviated, time: .shortened)
    }

    private func urgencyLabel(_ level: Int) -> String {
        switch level {
        case 1: return "1 — gentlest"
        case 3: return "3 — what macOS uses"
        case 4: return "4 — most urgent"
        default: return "\(level)"
        }
    }

    private var deleteTitle: String {
        let count = model.checkedSnapshots.count
        return "Delete \(count) snapshot\(count == 1 ? "" : "s") permanently?"
    }

    /// The last look: names what goes, and says what deleting a Time Machine local
    /// snapshot actually costs — no more, no less.
    private var deleteMessage: String {
        let checked = model.checkedSnapshots
        var lines = checked.prefix(5).map { "• \($0.name) — \(Format.age($0.date))" }
        if checked.count > lines.count {
            lines.append("…and \(checked.count - lines.count) more")
        }
        lines.append("Deleting by date removes that date's Time Machine snapshot on every mounted disk it exists on, not just this one.")
        lines.append("Files can no longer be restored from these snapshots while your backup disk is away. If one is the snapshot of your last backup, the next backup may take longer. Your backup disk itself is untouched.")
        lines.append("Snapshots cannot go to the Trash — this cannot be undone. macOS may ask for your administrator password.")
        return lines.joined(separator: "\n")
    }

    private var thinTitle: String {
        "Ask Time Machine to release \(Format.bytes(model.thinBytes))?"
    }

    private var thinMessage: String {
        """
        Time Machine thins its local snapshots on this disk, oldest first, until about \
        \(Format.bytes(model.thinBytes)) is free, at urgency \(model.thinUrgency). It may \
        remove fewer snapshots than that needs — or none, if it judges the space unnecessary. \
        Removed snapshots cannot be restored. Snapshots made by other apps are never touched. \
        macOS may ask for your administrator password.
        """
    }
}
