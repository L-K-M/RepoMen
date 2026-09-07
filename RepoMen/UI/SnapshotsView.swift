import SwiftUI

/// The Snapshots pane (sidebar → Time Machine → Local snapshots): lists every
/// snapshot on the boot volume — Time Machine's as checkable rows, other apps' greyed
/// and marked "left alone" — deletes the checked ones, or asks Time Machine to thin
/// by an amount. Both actions pass a confirmation dialog that says "permanent". There
/// is no size column: macOS gives no per-snapshot size to anything but Disk Utility
/// (its Private Size column), so the pane says so and offers to open Disk Utility
/// rather than guess.
///
/// Layout note: the rows are a plain `ScrollView`, not a `Table`. Two `Table`-based
/// versions of this pane laid out as one giant table that swallowed the header, the
/// footer and the sidebar; a scroll view can never claim more than it is given, and
/// every text here has a line limit, so nothing can report an unbounded height.
struct SnapshotsView: View {
    @EnvironmentObject private var model: SnapshotModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            rowsList
            Divider()
            footer
        }
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

    // MARK: Header

    private var header: some View {
        Text("""
            Time Machine keeps hourly local snapshots of this disk for about 24 hours. \
            Files you delete stay allocated until every snapshot that references them \
            is gone — so free space can stay flat after emptying the Trash, and macOS \
            purges snapshots on its own only unreliably. Only Time Machine's snapshots \
            can be deleted here; snapshots made by other apps are listed greyed and \
            never touched.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
    }

    // MARK: Rows

    private var rowsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.rows.isEmpty {
                    Text(model.hasLoaded && !model.isLoading
                         ? "No snapshots on this disk right now — nothing is holding freed space."
                         : "Listing snapshots…")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                } else {
                    ForEach(model.rows) { row in
                        rowView(row)
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One snapshot: checkbox + name + a caption line, or — for another app's
    /// snapshot — a hand icon, the name greyed with a "left alone" badge, and who made it.
    private func rowView(_ row: SnapshotRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let snapshot = row.snapshot {
                Toggle("", isOn: Binding(
                    get: { model.checkedIDs.contains(snapshot.id) },
                    set: { model.setChecked($0, id: snapshot.id) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Delete snapshot from \(created(snapshot))")
            } else {
                Image(systemName: "hand.raised")
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                    .help("Made by \(row.owner) — RepoMen never touches it")
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !row.isTimeMachine {
                        badge("left alone")
                    }
                }
                Text(row.snapshot.map { "Time Machine · created \(created($0)) · \(Format.age($0.date))" }
                     ?? "Made by \(row.owner) — not managed by RepoMen; see that app or Disk Utility")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .opacity(row.isTimeMachine ? 1 : 0.7)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.16), in: Capsule())
            .foregroundStyle(.secondary)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls
            if !model.otherSnapshotNames.isEmpty {
                Text("Snapshots made by other apps are listed for completeness — they can hold freed blocks too. RepoMen never deletes them; manage them in that app or in Disk Utility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            releaseSection
            footnote
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                .help("Checks every Time Machine snapshot — other apps' rows cannot be checked")
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
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        lines.append("Snapshots cannot go to the Trash — this cannot be undone. No password is normally needed; if macOS insists on administrator privileges, RepoMen asks once.")
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
        No password is normally needed; if macOS insists on administrator privileges, RepoMen asks once.
        """
    }
}
