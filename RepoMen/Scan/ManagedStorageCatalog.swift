import Foundation

/// Read-only discovery. Neither this catalog nor its instructions authorize path
/// deletion; the owning applications coordinate their state and dependencies.
enum ManagedStorageCatalog {
    static func areas(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                      systemApplicationSupport: URL = URL(fileURLWithPath: "/Library/Application Support"),
                      fileManager: FileManager = .default) -> [ManagedStorageArea] {
        func area(_ title: String, _ path: URL, _ instructions: String, _ documentation: String,
                  apps: [String], command: String? = nil) -> ManagedStorageArea {
            guard let url = URL(string: documentation), url.scheme == "https" else {
                preconditionFailure("Invalid documentation URL in managed-storage catalog")
            }
            return ManagedStorageArea(id: path.path, title: title, path: path.path,
                                      instructions: instructions, documentationURL: url,
                                      applicationBundleIDs: apps, command: command)
        }

        var result = [
            area("Android SDK packages", home.appendingPathComponent("Library/Android/sdk"),
                 "Open Android Studio, then Tools > SDK Manager. In SDK Platforms or SDK Tools, clear unwanted packages and choose Apply. Review platforms, system images and NDK versions individually: removing a required package can stop builds or virtual devices until it is reinstalled.",
                 "https://developer.android.com/studio/intro/update#sdk-manager", apps: ["com.google.android.studio"]),
            area("Android virtual devices", home.appendingPathComponent(".android/avd"),
                 "Open Android Studio, then View > Tool Windows > Device Manager. Stop an unwanted device, then choose Delete from its menu. Deleting a device removes its installed apps, settings and stored data. Shared SDK system images are managed separately in SDK Manager.",
                 "https://developer.android.com/studio/run/managing-avds", apps: ["com.google.android.studio"]),
            area("uv cache", home.appendingPathComponent(".cache/uv"),
                 "Use uv cache prune to remove unused cache entries, or uv cache clean to clear the cache. Run uv cache dir to confirm the active location first. uv coordinates cleanup with its running processes; do not move its cache to the Trash or remove entries directly. Custom cache locations are not measured here.",
                 "https://docs.astral.sh/uv/concepts/cache/", apps: [], command: "uv cache prune"),
            area("Arq backup cache", systemApplicationSupport.appendingPathComponent("ArqAgent/cache.noindex"),
                 "Open Arq, then Help > View Cache Statistics (Arq 7.50 or later). Select a backup plan, then Backup Plan > Clear Cache to rebuild its cached database and backup metadata. The next backup downloads metadata from your destination and can cause substantial data transfer. This action does not clear activity logs. The size shown is the whole local cache, not a promise of space recovered by one plan.",
                 "https://www.arqbackup.com/documentation/arq7/English.lproj/clearCache.html", apps: ["com.haystacksoftware.Arq"]),
            area("Arq activity logs", systemApplicationSupport.appendingPathComponent("ArqAgent/logs"),
                 "These are diagnostic logs, separate from Arq's backup cache. Clear Cache does not clear these logs. Contact support@arqbackup.com for supported pruning guidance; RepoMen has not verified a safe deletion or retention policy. This footprint is not counted as reclaimable space.",
                 "https://www.arqbackup.com/", apps: ["com.haystacksoftware.Arq"]),
            area("JetBrains diagnostic logs", home.appendingPathComponent("Library/Logs/JetBrains"),
                 "In your JetBrains IDE, choose Help > Show Log in Finder to inspect diagnostics. Keep logs needed for troubleshooting and ask JetBrains Support about unexpected growth. RepoMen measures this directory but does not delete diagnostics or your IDE's Local History.",
                 "https://www.jetbrains.com/help/idea/directories-used-by-the-ide-to-store-settings-caches-plugins-and-logs.html#logs-directory",
                 apps: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]),
        ]

        let legacyUV = home.appendingPathComponent("Library/Caches/uv")
        if fileManager.fileExists(atPath: legacyUV.path) {
            result.append(area("uv cache (alternate location)", legacyUV,
                "Run uv cache dir to check which cache is active. To clean this location, use uv cache prune --cache-dir with this directory as its argument. Do not remove cache entries directly; uv must coordinate cleanup with other uv processes.",
                "https://docs.astral.sh/uv/concepts/cache/", apps: []))
        }

        let googleCaches = home.appendingPathComponent("Library/Caches/Google")
        for version in childDirectories(googleCaches, fileManager: fileManager)
        where version.lastPathComponent.hasPrefix("AndroidStudio") {
            result.append(area("Android Studio \(version.lastPathComponent)", version,
                "In Android Studio, choose File > Invalidate Caches, then Invalidate and Restart. Leave the Local History deletion option unchecked. This system directory contains both rebuildable caches and Local History, so its full size is not reclaimable cache. SDKs and virtual devices have their own managers.",
                "https://www.jetbrains.com/help/idea/invalidate-caches.html", apps: ["com.google.android.studio"]))
        }

        for vendor in childDirectories(home.appendingPathComponent("Library/Caches"), fileManager: fileManager) {
            let sparkle = vendor.appendingPathComponent("org.sparkle-project.Sparkle")
            guard !childDirectories(sparkle, fileManager: fileManager).isEmpty else { continue }
            result.append(area("Update staging: \(vendor.lastPathComponent)", sparkle,
                "Open the owning app and complete any pending update. Sparkle uses this directory while downloading, extracting and installing updates, including while waiting for the app to quit. It cleans stale staging as updates run. If it keeps growing, contact the app's support team. Age alone does not prove an installer is abandoned.",
                "https://github.com/sparkle-project/Sparkle/blob/2.x/Documentation/Installation.md",
                apps: [vendor.lastPathComponent]))
        }
        return result
    }

    private static func childDirectories(_ root: URL, fileManager: FileManager) -> [URL] {
        guard GitWorktrees.hasNoSymlinkComponents(root) else { return [] }
        return ((try? fileManager.contentsOfDirectory(at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? [])
            .filter {
                guard let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
                return values.isDirectory == true && values.isSymbolicLink != true
            }
            .sorted { $0.path < $1.path }
    }

    static func measure(_ area: ManagedStorageArea,
                        fileManager: FileManager = .default) -> ManagedStorageArea.State {
        let url = URL(fileURLWithPath: area.path)
        do {
            let attributes = try fileManager.attributesOfItem(atPath: area.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  GitWorktrees.hasNoSymlinkComponents(url) else {
                return .failed("This location is not a regular directory or contains a symbolic link. Inspect it with the owning app.")
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .failed(error.localizedDescription)
        }
        let measurement = DirectorySizer.measure(url, fileManager: fileManager)
        guard measurement.isComplete else { return .unmeasured }
        if measurement.unreadableEntries > 0 {
            return .partial(measurement.bytes, "Some entries could not be read. This is a lower bound.")
        }
        return .measured(measurement.bytes)
    }
}
