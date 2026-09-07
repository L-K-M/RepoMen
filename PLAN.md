# RepoMen — design

RepoMen repossesses disk space: a native macOS app that finds the build artifacts and
developer caches a working programmer's machine accumulates, shows exactly what it found
(size, age, why it's safe), and reclaims only what you explicitly select.

## Why another cleaner

Existing cleaners fail this use case from two directions:

- **They miss the real debris.** Rust `target/` dirs, `node_modules/`, `.build/`,
  Gradle `build/` dirs live *deeply nested* inside project trees
  (`~/Documents/GitHub/<repo>/<subcrate>/target/aarch64-apple-darwin/…`). Tools that
  only look at well-known top-level locations never find them.
- **They're too aggressive.** "Clean Docker" buttons that delete stopped-but-needed
  containers, "system junk" heuristics that guess. One bad guess and you stop trusting
  the tool.

RepoMen sits in the middle: it finds *more* than the cautious tools (deep, anchor-based
project scanning) and deletes *less* than the aggressive ones (only artifacts it can
prove are regenerable, only when you select them, to the Trash by default).

## The trust model

1. **Anchor-based detection.** A directory is only reported as a build artifact when a
   *proof of regenerability* sits next to it (or inside it): `target/` counts only with
   a sibling `Cargo.toml`, `node_modules/` only with a sibling `package.json`, `.venv/`
   only when it contains `pyvenv.cfg`, and so on. A random folder that happens to be
   called `build` is never touched.
2. **Nothing is pre-selected.** A scan is always a dry run. The table shows kind, path,
   size, and last-modified age; quick actions ("select idle > 30 days") help, but every
   deletion is an explicit checkbox plus a confirmation dialog.
3. **Trash by default.** Reclaiming moves items to the Trash (`FileManager.trashItem`),
   so a mistake is a drag back, not a lost weekend. Permanent delete is an opt-in
   setting.
4. **Re-verify before deleting.** Between scan and reclaim the world may change. The
   reclaimer re-checks the anchor (the `Cargo.toml` must still be there) and runs every
   path through `PathGuards` — inside the home folder, not the home folder itself, not
   a direct child of it (no trashing `~/Documents` whole), no denylisted components
   (Docker, OrbStack, Time Machine, Photos libraries, the Trash itself).
5. **Docker is out of scope. Deliberately.** Stopped containers/images/volumes look
   like debris and aren't. RepoMen never enters `~/Library/Containers`, and the
   denylist hard-blocks Docker/OrbStack paths even if a future rule went wrong.

## What it finds

### Project artifacts (deep scan of your dev folders)

Anchor-based rules, data-driven in `RuleCatalog` (all thresholds/names unit-tested):

| artifact dir | anchor (sibling unless noted) | kind |
|---|---|---|
| `target/` | `Cargo.toml` | Rust build |
| `node_modules/` | `package.json` | Node modules |
| `.next/ .nuxt/ .turbo/ .parcel-cache/ .svelte-kit/ .angular/` | `package.json` | JS build output |
| `.build/` | `Package.swift` | SwiftPM build |
| `build/`, `DerivedData/` | `*.xcodeproj` / `*.xcworkspace` | Xcode build |
| `Pods/` | `Podfile` | CocoaPods pods |
| `build/`, `.gradle/` | `build.gradle(.kts)` / `settings.gradle(.kts)` | Gradle build |
| `target/` | `pom.xml` | Maven build |
| `build/`, `.dart_tool/` | `pubspec.yaml` | Flutter/Dart build |
| `__pycache__/ .pytest_cache/ .mypy_cache/ .ruff_cache/` | *(unambiguous name)* | Python cache |
| `.tox/` | `tox.ini` | Python cache |
| `.venv/`, `venv/` | contains `pyvenv.cfg` | Python venv |
| `build/`, `out/`, `cmake-build-*` | contains `CMakeCache.txt` | CMake build |
| `bin/`, `obj/` | `*.csproj` / `*.fsproj` | .NET build |
| `_build/`, `deps/` | `mix.exs` | Elixir build |
| `.stack-work/` | `stack.yaml`; `dist-newstyle/` \| `*.cabal` | Haskell build |
| `zig-cache/ .zig-cache/ zig-out/` | `build.zig` | Zig build |

Scanner behavior: recursive walk of the configured dev roots (defaults auto-detected
from `~/Documents/GitHub`, `~/Developer`, `~/Projects`, …), never follows symlinks,
skips file packages (`.app`, `.photoslibrary`, …), skips `.git` and other hidden dirs
(artifact rules for hidden names like `.build` are checked *before* the descend
decision), depth-capped, and never descends into a matched artifact (the whole dir is
one item). A matched dir with no anchor is left alone; unambiguous artifact names
(`node_modules`, `__pycache__`, …) are also not descended into, while generic names
(`build`, `target`) are, since they might be ordinary folders.

### Well-known caches (fixed locations, no deep scan)

- **Xcode:** DerivedData (one item per project), iOS/watchOS/tvOS DeviceSupport (per
  OS version), CoreSimulator caches, SwiftPM cache.
- **Homebrew:** `~/Library/Caches/Homebrew/downloads` + `…/Cask`.
- **Browsers (Chromium family + Firefox):** per-profile `Cache` / `Code Cache` dirs
  (e.g. `…/Google/Chrome/Profile 14/Cache`). Items carry a "browser is running" warning
  when the matching app is open.
- **Package managers:** npm `_cacache`, yarn, pnpm store, pip, uv, go-build, Cargo
  registry cache, CocoaPods, Gradle `~/.gradle/caches`, Maven `~/.m2/repository` — the
  last few flagged "slow to re-download" so you think twice.

Everything here is a cache by contract: the owning tool rebuilds it on demand.

### System areas (root-owned, admin-gated)

The one place RepoMen looks outside your home folder — because a real failure mode
lives there: a busy `rtcreportingd` (typically kept busy by Dropbox's FileProvider
integration) fills `/private/var/root/Library/Logs/RTCReporting` with tens of
gigabytes of message logs, plus multi-GB event caches under root's
`Library/Caches` — all invisible to `du`, Finder, and every unprivileged cleaner
([the report that motivated this](https://mjtsai.com/blog/2026/08/21/huge-rtcreporting-logs-and-dropbox/)).

`SystemAreas` is a fixed two-root catalog (root's `Library/Logs` and
`Library/Caches`); both are disposable by macOS contract — logs are diagnostic
output nothing reads back, caches are rebuilt on demand. Because `/var/root` is
unreadable to the app, detection and deletion run as root through one AppleScript
`do shell script … with administrator privileges` per action (`PrivilegedRunner`):

- **Explicit only.** A System Scan is its own button/menu item — it never rides
  along with a normal scan, and watch mode never touches it. Every scan or reclaim
  costs exactly one admin-password prompt, and cancelling the prompt is a clean
  no-op.
- **Direct children only.** The probe reports (and the reclaimer accepts) only
  immediate subdirectories of the two catalog roots — never the roots themselves,
  never deeper paths, never anything outside. `SystemAreas.validate` enforces this
  on every path in both directions, and the privileged script re-checks each path
  as root (still a directory, not a symlink) right before `rm`.
- **Permanent delete, said out loud.** The Trash is per-user and can't take
  root-owned trees, so system items are always deleted permanently — the
  confirmation dialog and the summary both say so explicitly.
- **Culprit awareness.** While Dropbox is running, RTCReporting items carry a
  warning: the logs regrow immediately, and files the daemon holds open free no
  space until it lets go.

### Time Machine local snapshots (why freed space doesn't come back)

On a Mac with Time Machine on, deleting 30 GB of `target/` and emptying the Trash can
leave free space exactly where it was: Time Machine takes a local APFS snapshot of the
boot volume about every hour and keeps it for ~24 h, and every block a snapshot
references stays allocated until that snapshot is gone. macOS calls the space
purgeable and is supposed to purge it on demand, but Howard Oakley's tests show the
`deleted` daemon's Time Machine plug-in reporting 0 bytes purgeable for half an hour
or failing outright ([Why can purging snapshots fail?](https://eclecticlight.co/2026/08/27/why-can-purging-snapshots-fail/)).
His advice — delete the snapshots yourself — is what RepoMen offers, three ways:

- **The summary says so.** After a reclaim that freed anything, RepoMen lists the
  snapshots (`tmutil listlocalsnapshots /`, unprivileged, instant) and, if any
  exist — Time Machine's or another app's — the summary explains that the freed
  blocks stay allocated until they age out or are deleted, with a **Show Snapshots**
  button pre-filled with the amount.
- **Release space.** The Snapshots pane asks Time Machine to thin its own
  snapshots by an amount (`tmutil thinlocalsnapshots / <bytes> <urgency>`) — Apple's
  supported hook for the purge macOS should do by itself. Time Machine picks what
  goes, oldest first, and may decide nothing has to.
- **Delete specific snapshots.** The pane (sidebar → Time Machine → Local
  snapshots) lists Time Machine's local snapshots (name, creation time, age),
  nothing pre-checked; checked ones are deleted one by one with
  `tmutil deletelocalsnapshots <date>`. Snapshots made by other apps (Arq, Carbon
  Copy Cloner, macOS updates) are named as left alone — they hold freed blocks too —
  and can't be checked.

The trust model, applied to things that are not paths:

- **One name shape, three verbs.** `LocalSnapshot` accepts only
  `com.apple.TimeMachine.<date>.local`; Carbon Copy Cloner's snapshots, the ones
  macOS takes before updates, and Time Machine's `.backup` snapshots on backup disks
  cannot be represented, so they cannot be deleted — and that filter does real work,
  because `tmutil listlocalsnapshots` lists every snapshot on the volume, not just
  Time Machine's (an Arq agent snapshot showed up in the field). `SnapshotTool.validate` whitelists
  exactly three `tmutil` invocations (list the boot volume, delete one validated date,
  thin the boot volume), and `SnapshotRunner` re-checks before spawning. RepoMen never
  calls `diskutil apfs deleteSnapshot`, which could reach any snapshot.
- **Explicit, permanent, said out loud.** Snapshots never ride along with a scan or
  a reclaim and watch mode never touches them. Both actions pass a confirmation
  dialog that says the deletion is permanent, that deleting by date removes that
  date's Time Machine snapshot on every mounted disk, that files can no longer be
  restored from those snapshots while the backup disk is away, and that the backup
  disk itself is untouched.
- **No password unless needed.** The local-snapshot verbs are not among those the
  tmutil man page marks "Requires root and Full Disk Access", so RepoMen runs them as
  the user. Only if tmutil refuses for lack of privileges does it fall back to one
  administrator prompt (`PrivilegedRunner`, a whitelisted tmutil line).
- **No invented sizes.** macOS exposes no per-snapshot size to apps — Disk Utility's
  Private Size column comes from private API — so the pane shows none, says so,
  and offers to open Disk Utility. What it does report honestly is the boot volume's
  plain free space before and after (not `volumeAvailableCapacityForImportantUsage`,
  which already counts purgeable space and lags).

## App shape

Regular windowed SwiftUI app (unlike sibling Gans, which is a menu-bar agent):
`NavigationSplitView` with a category sidebar (All / Projects / Developer caches /
Package managers / Browsers, with per-category totals) and a sortable `Table`
(checkbox, item, size, last used). Toolbar: Scan + System Scan + Snapshots (selects
the sidebar row) + Reclaim. Time Machine snapshots get their own sidebar destination
whose pane replaces the table rather than rows in it: a snapshot has no path, no
measurable size and no Trash, so every row affordance (Reveal, Exclude, sizing,
watch) would be a lie, and its badge is a count, not a size. Footer: totals + quick
selection. Settings (⌘,): scan folders, rule toggles per kind, Trash vs. delete,
updates. `Updates/` is the GitHub-release checker shared verbatim with the sibling
apps (Gans et al.), pointed at `L-K-M/RepoMen`.

Sizes are computed after discovery (concurrent, cancellable, streamed into the UI), so
the list appears immediately and fills in. "Last used" is the newest modification time
seen while sizing — i.e. when that artifact was last built.

## Watch mode (opt-in automation)

Settings → Watch lists **watched folders**, each with its own idle threshold. While
RepoMen runs (it becomes menu-bar resident once any watch folder is enabled), a check
runs shortly after launch and every 6 hours: the watched roots are deep-scanned with
the same `Scanner`, measured, and anything idle past its folder's threshold is moved
to the Trash. The trust model is unchanged, just automated:

- **Automation is opt-in.** The master switch starts off; until then a check only
  *reports* (a notification, deduped so identical findings don't repeat).
- **Auto-clean is always Trash**, never permanent delete, regardless of the manual
  reclaim setting. Every item still passes `Reclaimer`'s anchor re-verification and
  `PathGuards` at trash time.
- **A check is never a surprise.** Notifications summarize every run that changed
  something ("14 squatters evicted — 2.3 GB repossessed"), and the menu-bar extra
  shows the last run at a glance.

## Non-goals

- Fully unattended cleaning (launchd/login-item helper that runs while the app is
  quit). Watch mode covers "while the app is alive"; headless background cleaning is
  a deliberate future step, not an accident to stumble into.
- Browser *profiles* (only `Cache`/`Code Cache` subdirs), and any system-wide
  cache/log cleaning beyond the fixed `SystemAreas` catalog (root's `Library/Logs`
  and `Library/Caches`, direct children only, admin-gated — see above). No
  `/Library`, no other users, no heuristic "system junk".
- Docker/OrbStack/VM images, simulator *runtimes* (only their caches), Xcode archives
  (they hold dSYMs for shipped builds).
- Sandboxing/App Store: direct distribution like the sibling apps (unsigned, ad-hoc
  signed in CI); the deep home-folder scan is the product.
