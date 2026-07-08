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

See [PLAN.md](PLAN.md) for the full design and trust model.

## Install

Download the latest `.dmg` from [Releases](https://github.com/L-K-M/RepoMen/releases).
The app is **unsigned** (no Developer ID / notarization), so on first launch run
`xattr -dr com.apple.quarantine /Applications/RepoMen.app`

macOS will ask the standard Files-and-Folders question the first time RepoMen scans a
protected folder (e.g. `~/Documents`).

## Use

1. **Scan** (⌘R) — the sidebar fills with categories, the table with items, sizes
   stream in.
2. Check what you want gone — or use **Select → Idle 30+ Days** for the one-click
   "everything I haven't built in a month".
3. **Reclaim…** — confirm, and RepoMen reports how much it repossessed.

Right-click any row to reveal it in Finder or exclude it from future scans. Settings
(⌘,) manages scan folders, per-kind rule toggles, and Trash vs. permanent delete.

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
