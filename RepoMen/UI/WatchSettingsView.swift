import AppKit
import SwiftUI

/// Settings → Watch: the directories RepoMen keeps clean on its own. Each watched
/// folder has its own idle threshold; the master switch decides whether a check
/// trashes stale artifacts (always to the Trash) or only reports them.
struct WatchSettingsView: View {
    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var watchManager: WatchManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Move stale artifacts to the Trash automatically", isOn: $preferences.watchAutoTrash)
            Text(preferences.watchAutoTrash
                 ? "Stale artifacts in watched folders go to the Trash (never permanent delete) after every check."
                 : "Watch checks only report what could be repossessed — nothing is trashed until you arm this.")
                .font(.caption)
                .foregroundStyle(preferences.watchAutoTrash ? Color.secondary : Color.orange)

            Text("Watched folders:")
                .padding(.top, 6)
            List {
                ForEach($preferences.watchedFolders) { $folder in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $folder.isEnabled)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .help("Pause watching this folder without removing it")
                        Text(Format.abbreviatePath(folder.path))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Stepper(value: $folder.maxIdleDays, in: 1...365) {
                            Text("\(folder.maxIdleDays) d")
                                .monospacedDigit()
                        }
                        .help("Trash artifacts idle longer than this")
                    }
                }
                .onDelete { preferences.watchedFolders.remove(atOffsets: $0) }
            }
            .frame(minHeight: 120)
            HStack {
                Button("Add Folder…") { addFolder() }
                Menu("Watch a Scan Folder") {
                    ForEach(unwatchedScanRoots, id: \.self) { root in
                        Button(Format.abbreviatePath(root)) { watch(root) }
                    }
                }
                .disabled(unwatchedScanRoots.isEmpty)
                .help("One tap to watch a folder you already scan")
            }

            Divider()
                .padding(.vertical, 4)

            HStack(spacing: 8) {
                Button("Check Now") { watchManager.runCheck() }
                    .disabled(watchManager.isChecking || !watchManager.hasWatchedFolders)
                if watchManager.isChecking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(lastRunText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var unwatchedScanRoots: [String] {
        let watched = Set(preferences.watchedFolders.map(\.path))
        return preferences.scanRoots.filter { !watched.contains($0) }
    }

    private var lastRunText: String {
        guard let run = preferences.lastWatchRun else {
            return watchManager.hasWatchedFolders
                ? "Checks run shortly after launch and every 6 hours while RepoMen is open."
                : "Add a folder and RepoMen will check it shortly after launch, then every 6 hours."
        }
        let age = Format.age(run.date)
        if run.dryRun {
            return run.candidateCount == 0
                ? "Last check \(age): nothing stale."
                : "Last check \(age): \(run.candidateCount) stale artifacts (\(Format.bytes(run.candidateBytes))) would be repossessed."
        }
        return "Last check \(age): repossessed \(Format.bytes(run.reclaimedBytes)) across \(run.reclaimedCount) items."
    }

    private func watch(_ path: String) {
        preferences.watchFolder(path: path)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        panel.message = "Choose folders for RepoMen to keep clean automatically"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { watch(url.path) }
    }
}
