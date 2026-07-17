import AppKit
import SwiftUI

/// Settings window (⌘,): General / Folders / Rules / Updates. The tab views are
/// implementation details of this scene and live here with it.
struct SettingsView: View {
    @ObservedObject var updateChecker: UpdateChecker

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            FoldersSettingsView()
                .tabItem { Label("Folders", systemImage: "folder") }
            WatchSettingsView()
                .tabItem { Label("Watch", systemImage: "eye") }
            RulesSettingsView()
                .tabItem { Label("Rules", systemImage: "checklist") }
            UpdatesSettingsView(updateChecker: updateChecker)
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        Form {
            Toggle("Move reclaimed items to the Trash", isOn: $preferences.moveToTrash)
            Text(preferences.moveToTrash
                 ? "Reversible — drag items back out of the Trash if you change your mind."
                 : "Items are deleted immediately and cannot be recovered.")
                .font(.caption)
                .foregroundStyle(preferences.moveToTrash ? Color.secondary : Color.orange)

            Stepper(value: $preferences.idleDays, in: 1...365) {
                Text("Consider artifacts idle after \(preferences.idleDays) days")
            }
            Text("Used by the “Select idle” quick action in the main window.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Scan automatically when RepoMen opens", isOn: $preferences.scanAtLaunch)
            Toggle("Open RepoMen automatically when you log in", isOn: $preferences.launchAtLogin)
            Toggle("Show RepoMen in the menu bar", isOn: $preferences.showInMenuBar)
            Text("The menu bar extra shows watch status and quick actions. With watch folders armed and login launch on, RepoMen keeps them clean whenever your Mac is on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

private struct FoldersSettingsView: View {
    @EnvironmentObject private var preferences: Preferences
    @State private var selectedRoot: String?
    @State private var selectedExclusion: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scan these folders for project build artifacts:")
            List(selection: $selectedRoot) {
                ForEach(preferences.scanRoots, id: \.self) { root in
                    HStack(spacing: 6) {
                        Text(Format.abbreviatePath(root))
                        if isOutsideHome(root) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .help("Outside your home folder — findings here can be listed but never reclaimed")
                        }
                    }
                    .tag(root)
                }
            }
            .frame(minHeight: 110)
            if let warning = outsideHomeWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Add Folder…") { addRoots() }
                Button("Remove") {
                    preferences.scanRoots.removeAll { $0 == selectedRoot }
                    selectedRoot = nil
                }
                .disabled(selectedRoot == nil)
            }

            Divider()
                .padding(.vertical, 4)

            Text("Excluded paths (never suggested again):")
            List(selection: $selectedExclusion) {
                ForEach(preferences.excludedPaths, id: \.self) { path in
                    Text(Format.abbreviatePath(path)).tag(path)
                }
            }
            .frame(minHeight: 80)
            Button("Remove Exclusion") {
                preferences.excludedPaths.removeAll { $0 == selectedExclusion }
                selectedExclusion = nil
            }
            .disabled(selectedExclusion == nil)
        }
        .padding(20)
    }

    private func addRoots() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to scan for build artifacts"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !preferences.scanRoots.contains(url.path) {
            preferences.scanRoots.append(url.path)
        }
    }

    /// Reclaiming is restricted to the home folder (PathGuards); a root elsewhere
    /// scans fine but every find would fail at reclaim time — say so up front, in the
    /// list, not in a post-confirmation error.
    private func isOutsideHome(_ root: String) -> Bool {
        let home = NSHomeDirectory()
        return root != home && !root.hasPrefix(home + "/")
    }

    private var outsideHomeWarning: String? {
        let count = preferences.scanRoots.filter(isOutsideHome).count
        guard count > 0 else { return nil }
        let folders = count == 1 ? "1 folder is" : "\(count) folders are"
        return "\(folders) outside your home folder — findings there can be listed but never reclaimed."
    }
}

private struct RulesSettingsView: View {
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Uncheck a kind and RepoMen stops finding or suggesting it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(ArtifactCategory.allCases) { category in
                    GroupBox(category.label) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(kinds(in: category)) { kind in
                                Toggle(isOn: binding(for: kind)) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(kind.label)
                                        Text(kind.regenerationHint)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                }
            }
            .padding(20)
        }
        // Grow with the display instead of always scrolling inside a 440pt cap —
        // the rules list keeps gaining kinds.
        .frame(minHeight: 440, idealHeight: 560, maxHeight: 680)
    }

    private func kinds(in category: ArtifactCategory) -> [ArtifactKind] {
        ArtifactKind.allCases.filter { $0.category == category }
    }

    private func binding(for kind: ArtifactKind) -> Binding<Bool> {
        Binding(
            get: { preferences.isEnabled(kind) },
            set: { preferences.setEnabled($0, kind: kind) })
    }
}

private struct UpdatesSettingsView: View {
    @ObservedObject var updateChecker: UpdateChecker

    var body: some View {
        Form {
            Toggle("Check for updates automatically", isOn: $updateChecker.automaticChecksEnabled)
            HStack(spacing: 8) {
                Button("Check Now") { updateChecker.checkNow() }
                    .disabled(updateChecker.isChecking)
                if updateChecker.isChecking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let last = updateChecker.lastCheckDate {
                Text("Last checked \(Format.age(last))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }
}
