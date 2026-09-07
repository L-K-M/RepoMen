# Working on RepoMen

RepoMen is a native macOS **windowed utility** (SwiftUI `App` lifecycle) that finds
regenerable build artifacts and developer caches, and moves the ones the user checks
to the Trash. See [PLAN.md](PLAN.md) for the design and, critically, the trust model.

## Layout

- `RepoMen/App` — entry point + minimal `AppDelegate` (update checker, quit-on-close).
- `RepoMen/Model` — `ArtifactKind` (every kind + its regeneration story),
  `CleanableItem`, `AppModel` (main-actor state machine: scan → measure → reclaim),
  `Preferences`.
- `RepoMen/Scan` — `RuleCatalog` (pure, data-driven anchor rules), `Scanner` (the
  walk), `KnownCaches` (fixed cache locations incl. browsers), `DirectorySizer`.
- `RepoMen/Reclaim` — `PathGuards` (pure validation), `Reclaimer` (re-verify + trash).
- `RepoMen/System` — root-owned system areas (RTCReporting logs etc., admin-gated):
  `SystemAreas` (fixed catalog + its own validate), `PrivilegedRunner` (osascript
  admin bridge + quoting/escaping), `SystemScanner` (probe + pure parser),
  `SystemReclaimer` (privileged, permanent delete).
- `RepoMen/Snapshots` — Time Machine local snapshots (the blocks that keep "freed"
  space allocated): `LocalSnapshot` (the one name shape allowed), `SnapshotRunner`
  (spawns `/usr/bin/tmutil` directly, unprivileged), `SnapshotTool` (argument
  whitelist, pure list parser, privileged fallback scripts, list/delete/thin),
  `SnapshotModel` (main-actor state for the Snapshots window).
- `RepoMen/Watch` — watched-folders automation: `WatchedFolder` (+`WatchRunRecord`),
  `WatchEngine` (pure eligibility), `WatchManager` (periodic check → trash),
  `WatchNotifier` (notifications).
- `RepoMen/UI` — SwiftUI views: sidebar, table, settings, empty state, menu bar.
- `RepoMen/Updates` — reusable GitHub release checker (shared verbatim with the
  sibling apps).
- `RepoMenTests` — pure-logic + temp-dir integration tests (no UI tests).

The Xcode project uses **file-system-synchronized groups**: new `.swift` files under
`RepoMen/` or `RepoMenTests/` are picked up automatically — no `project.pbxproj`
edits needed (except when adding a Swift Package).

## Conventions

- **One type per file**; the filename matches the primary type. Use `// MARK:` sections.
- Avoid force-unwraps outside tests.
- **Keep the safety invariants exact.** They are the product:
  - Nothing is deleted without a *currently existing* proof of regenerability: an
    anchor re-checked at reclaim time (`Reclaimer.verify`), a known-cache catalog
    root, or an unambiguous artifact name.
  - Every deletion goes through `PathGuards.validate` — inside home, ≥ 2 levels below
    it, denylist (Docker/OrbStack/Colima/Lima, Time Machine, photo libraries, Trash).
    Never weaken these to "fix" a false negative; add a better anchor instead.
  - Default reclaim method is the Trash. Permanent delete stays opt-in.
  - Nothing is ever pre-selected, and every reclaim passes a confirmation dialog.
  - System areas are the ONLY paths outside home, and they are locked down twice:
    every path must pass `SystemAreas.validate` (a direct child of one of the two
    catalog roots, nothing else), and the privileged script re-checks it as root
    before `rm`. System scans/reclaims run only on explicit user action (one admin
    prompt each), deletion is always permanent and says so in the UI, and watch
    mode never touches them. Never widen the catalog beyond locations that are
    disposable by macOS contract, and never route system items through `Reclaimer`
    (it refuses them) or normal items through `SystemReclaimer` (same).
  - Time Machine local snapshots are the only non-path things RepoMen deletes, and
    only through `tmutil`'s local-snapshot verbs: `SnapshotTool.validate` is the
    whitelist (list the boot volume; delete ONE validated date; thin the boot volume
    by an amount) and `SnapshotRunner` re-checks it before spawning. Never
    `diskutil apfs deleteSnapshot`, never a name other than
    `com.apple.TimeMachine.<date>.local` (third-party, macOS-update and `.backup`
    snapshots are never even modelled — `LocalSnapshot` refuses them), never the
    whole-volume `deletelocalsnapshots /`. Explicit action in the Snapshots window
    only — never a scan, never watch mode; deletion is always permanent and the
    dialog says so; the admin prompt is a fallback used only after an unprivileged
    run was refused. No per-snapshot size is ever shown: macOS exposes none to apps.
- **Adding a scan rule**: extend `RuleCatalog.rules` (and `neverDescend` if the name
  is unambiguous) + add `RuleCatalogTests`. A rule must name an anchor or an inner
  anchor unless its directory name is globally unambiguous.
- **Adding a known cache**: extend `KnownCaches.specs`/`browsers`. Only locations the
  owning tool rebuilds on demand; keep Docker & friends out (see PLAN.md non-goals).
  If a new location is outside `~/Library/Caches`, `allowedRoots` covers it
  automatically via the spec — verify with `KnownCachesTests.testAllowedRootsCoverEverySpec`.
- **Adding a system area**: extend `SystemAreas.roots` (and `culprits` if a running
  app keeps it growing) + `SystemAreasTests`. Only root-owned locations disposable
  by macOS contract; the probe and reclaimer pick up new roots automatically.
- Scanning/sizing/reclaiming run detached; UI state mutations happen on the main
  actor (`AppModel`).

## Testing

`xcodebuild -project RepoMen.xcodeproj -scheme RepoMen -destination 'platform=macOS' clean test`

Unit-test pure logic and the temp-dir integration paths (`Scanner`, `KnownCaches`,
`Reclaimer` — the latter uses `.delete` against a synthetic home so the real Trash
stays clean). `SnapshotTool` and the `System*` types take injected runner closures, so
their tests never spawn `tmutil` or `osascript`. The live UI, TCC prompts, the
password dialog, and trashing real artifacts or deleting real snapshots are
manual-verify items.
