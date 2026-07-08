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
- `RepoMen/UI` — SwiftUI views: sidebar, table, settings, empty state.
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
- **Adding a scan rule**: extend `RuleCatalog.rules` (and `neverDescend` if the name
  is unambiguous) + add `RuleCatalogTests`. A rule must name an anchor or an inner
  anchor unless its directory name is globally unambiguous.
- **Adding a known cache**: extend `KnownCaches.specs`/`browsers`. Only locations the
  owning tool rebuilds on demand; keep Docker & friends out (see PLAN.md non-goals).
  If a new location is outside `~/Library/Caches`, `allowedRoots` covers it
  automatically via the spec — verify with `KnownCachesTests.testAllowedRootsCoverEverySpec`.
- Scanning/sizing/reclaiming run detached; UI state mutations happen on the main
  actor (`AppModel`).

## Testing

`xcodebuild -project RepoMen.xcodeproj -scheme RepoMen -destination 'platform=macOS' clean test`

Unit-test pure logic and the temp-dir integration paths (`Scanner`, `KnownCaches`,
`Reclaimer` — the latter uses `.delete` against a synthetic home so the real Trash
stays clean). The live UI, TCC prompts, and trashing real artifacts are manual-verify
items.
