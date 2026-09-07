# RepoMen

A native macOS app that **repossesses your disk space**: it hunts down the build
artifacts and developer caches that pile up when you build a lot of software — Rust
`target/` dirs buried deep in project trees, `node_modules/`, DerivedData, Homebrew
downloads, Chrome profile caches — and reclaims exactly what you tell it to, nothing
more.

**Version:** <!-- version -->0.1.0<!-- /version -->

## Why

Existing cleaners are either too shallow (they never find the `target/debug` four
levels deep in `~/Documents/GitHub`) or too aggressive (they "clean up" Docker
containers you still need). RepoMen sits deliberately in the middle:

- **Finds more** — a deep, recursive scan of your dev folders. A directory is reported
  only when it can *prove* it's regenerable: `target/` needs a sibling `Cargo.toml`,
  `node_modules/` a `package.json`, `.venv/` a `pyvenv.cfg` inside, and so on. A random
  folder named `build` is never touched.
- **Deletes less** — a scan is always a dry run. Nothing is pre-selected; you check
  items (with size and "last built" age in front of you), confirm, and they go to the
  **Trash** (permanent delete is opt-in). Before deleting, every path is re-verified:
  the anchor must still exist, and hard guards refuse anything outside safe areas.
- **Docker is never touched.** Neither are backups, photo libraries, browser profiles
  (only their `Cache` dirs), or Xcode archives. By design, not by luck.

## What it finds

- **Project artifacts** (deep scan, anchor-based): Rust, Node/JS, SwiftPM, Xcode,
  CocoaPods, Gradle, Maven, Flutter, Python (`__pycache__`, venvs), CMake, .NET,
  Elixir, Haskell, Zig.
- **Developer caches:** Xcode DerivedData (per project), device support, simulator
  caches, SwiftPM cache.
- **Package managers:** Homebrew, npm, Yarn, pnpm, pip, uv, Go, Cargo registry,
  Gradle, Maven, CocoaPods — the expensive-to-refill ones are labeled "slow to
  rebuild".
- **Browser caches:** per-profile `Cache`/`Code Cache` for Chrome, Brave, Edge, Arc,
  Vivaldi, Chromium, Firefox — with a warning badge while the browser is running.
- **System areas (opt-in, admin):** root-owned logs and caches that no unprivileged
  tool can even see — most notably the [runaway `rtcreportingd` logs](https://mjtsai.com/blog/2026/08/21/huge-rtcreporting-logs-and-dropbox/)
  that fill `/private/var/root/Library/Logs/RTCReporting` with 60–70+ GB (usually
  provoked by Dropbox), plus multi-GB caches under root's `Library/Caches`. A
  separate **System Scan** asks for your administrator password, lists each folder
  with its size, and warns while Dropbox is running (the logs regrow until it
  quits). Reclaiming these is always a permanent delete — root-owned files can't go
  to the Trash — re-verified as root right before removal.
- **Time Machine local snapshots:** the reason freed space often *doesn't come back*.
  Time Machine snapshots the boot volume hourly, and every block a snapshot references
  stays allocated until that snapshot is gone — macOS is supposed to purge them on
  demand but [often doesn't](https://mjtsai.com/blog/2026/08/28/arent-snapshots-purgeable/).
  After a reclaim, RepoMen says when snapshots are holding the space, and the
  **Local snapshots** pane (sidebar → Time Machine) lets you ask Time Machine to
  release an amount (`tmutil thinlocalsnapshots`) or delete specific snapshots —
  Time Machine's own local snapshots only. Snapshots made by other apps (Arq,
  Carbon Copy Cloner, macOS updates) are listed as left alone and never touched.

See [PLAN.md](PLAN.md) for the full design and trust model.

## Install

Download the latest `.dmg` from [Releases](https://github.com/L-K-M/RepoMen/releases/latest).
The app is ad-hoc signed but has **no Developer ID and is not notarized**, so
Gatekeeper warns on first launch. Either right-click the app → **Open** → **Open**
(on macOS 15+ additionally confirm under System Settings → Privacy & Security →
**Open Anyway**), or run
`xattr -dr com.apple.quarantine /Applications/RepoMen.app`

macOS will ask the standard Files-and-Folders question the first time RepoMen scans a
protected folder (e.g. `~/Documents`).

## Use

1. **Scan** (⌘R) — the sidebar fills with categories, the table with items, sizes
   stream in.
2. Check what you want gone — or use **Select → Idle 30+ Days** for the one-click
   "everything I haven't built in a month".
3. **Reclaim…** — confirm, and RepoMen reports how much it repossessed.

**System Scan** (⌘⇧R) covers the root-owned areas a normal scan can't reach
(RTCReporting logs and friends). macOS asks for your administrator password once
per scan and once per reclaim; checked system items are deleted permanently (the
Trash can't take root-owned files) after being re-verified as root.

**Time Machine → Local snapshots** in the sidebar (⌘⇧S, or the clock button in the
toolbar) shows the Time Machine local snapshots of your disk. Use **Release…** to have
Time Machine thin them until a given amount is free (the summary after a reclaim
pre-fills what you just freed), or check specific snapshots and **Delete Checked…**.
Both are permanent and normally need no password; if macOS insists on administrator
privileges, RepoMen asks once. There is no size column because macOS gives apps none —
Disk Utility (View › Show APFS Snapshots) shows each snapshot's Private Size.

Right-click any row to reveal it in Finder or exclude it from future scans. Settings
(⌘,) manages scan folders, per-kind rule toggles, and Trash vs. permanent delete.

**Watch mode** (Settings → Watch) keeps chosen folders clean on its own: give a
folder an idle threshold, arm the master switch, and — while RepoMen lives in your
menu bar — anything stale is moved to the Trash automatically after each periodic
check, with a notification of what was repossessed. Auto-clean is always Trash-only
and re-verified exactly like a manual reclaim; until you arm it, checks only report.

Sizes are allocated-space estimates: hardlinked files are counted once, but APFS
*clones* (how pnpm and uv share files across projects) can't be attributed per copy —
the same limitation `du` and Finder have — so the space actually freed can be less
than the number shown.

## Build

```bash
# Requires Xcode 16.2+. No external dependencies.
xcodebuild -project RepoMen.xcodeproj -scheme RepoMen -destination 'platform=macOS' build

# or an incremental Release build that reveals the product in Finder:
./scripts/build.sh
```

## Releasing

```bash
scripts/release.sh 0.2.0 --push    # bump version, tag v0.2.0, push → CI builds & publishes
```

See [CICD.md](CICD.md) for the pipeline.

## License

[The Unlicense](LICENSE) — public domain.