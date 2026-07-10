# fable.md — RepoMen 0.1.0 review

A full review of RepoMen as of commit `a7190a7`, produced by a multi-lens pass over the
entire codebase (scan/reclaim core, app layer, UI, updates module, CI/CD, docs), with
every objective claim adversarially re-verified against the source. Findings are grouped
by theme and numbered for cross-referencing; each carries a severity, a confidence, and
a plan (which PR implements it, or *future* if it stays on the backlog).

**Legend** — Severity: 🔴 high · 🟠 medium · 🟡 low. Confidence: **confirmed** (exact
code path traced), **plausible** (sound reasoning, runtime-dependent).

---

## 1. Correctness bugs

### B1. Default scan roots duplicate the same folder on case-insensitive APFS 🔴 confirmed
`Preferences.defaultScanRoots` probes `["Projects", "projects", "Code", "code", …]` with
`FileManager.fileExists`, which is case-insensitive on default APFS. A user with a single
`~/Projects` gets **both** `/Users/x/Projects` and `/Users/x/projects` as roots, and
`Scanner.normalizedRoots` only drops *nested* roots via case-sensitive prefix compare, so
both survive. The same tree is walked twice, every artifact appears twice (ids differ
only in case), sidebar/footer totals double, sizing work doubles, and reclaiming both
duplicates produces a spurious "no longer exists" failure for the second. Hits the
default configuration for anyone with `~/Projects` or `~/Code`.
**Fix:** dedupe candidates via the filesystem's canonical path (`.canonicalPathKey`),
and make `normalizedRoots` drop exact duplicates too. → **PR "scan roots"**

### B2. Cancelled/stale scan task can clobber a newer scan's state 🔴 confirmed
The detached scan task checks `Task.isCancelled` only on its own executor
(`AppModel.swift:115/129`); the `MainActor.run` blocks that publish `items`/`phase` never
re-check, and nothing verifies the task is still the *current* scan. Confirmed
interleavings: (1) Stop pressed just as discovery finishes → the stale block still sets
`items = discovered` and `phase = .measuring`; the final `guard` then returns without
ever setting `.ready`, leaving the app **stuck busy forever** (spinner, Scan disabled).
(2) Stop → Scan quickly → stale task A overwrites scan B's fresh `items = []` with A's
partial discovery, and A's sizers write into B's rows (ids are paths, so they collide).
(3) The progress callback guards on `phase == .scanning`, which can't distinguish scan A
from scan B.
**Fix:** a scan-generation token captured by the detached task; every main-actor
mutation (items publish, status, measurement applies, final `.ready`) checks it still
owns the current generation. → **PR "scan pipeline"**

### B3. Cancelled partial measurements are committed as final 🔴 confirmed
`DirectorySizer.measure` aborts at 512-entry checkpoints when cancelled and returns
partial bytes — its doc comment claims the result "is discarded with the scan", but
`measureAll`'s apply closure commits it unconditionally and sets `isMeasured = true`.
After pressing Stop during measuring, a 3 GB `node_modules` can permanently show 80 MB,
and `lastModified` reflects only the visited subset — so **"Select Idle 30+ Days" can
check a recently-built artifact** and the user reclaims it believing it idle. Nothing at
reclaim time re-checks age.
**Fix:** return a completeness flag from `measure` and drop incomplete measurements;
gate applies on the scan generation (B2). → **PR "scan pipeline"**

### B4. Scan and reclaim can run concurrently — trashed items resurrect as zombie rows 🟠 confirmed
`startScan()` has no `isReclaiming` guard and the Scan button/⌘R are enabled during a
reclaim (reclaim doesn't set `isBusy`). Scanning while a multi-GB trash operation runs
races the filesystem, and if the reclaim completion's `items.removeAll` runs before the
scan publishes its discovery, already-trashed paths reappear as zombie rows that later
fail with "no longer exists". Reverse direction: Reclaim is enabled during `.measuring`.
**Fix:** make the two mutually exclusive — guard `startScan()` on `isReclaiming` (→ **PR
"scan pipeline"**) and disable Scan UI while reclaiming, plus surface reclaim progress
(→ **PR "reclaim flow"**).

### B5. Quitting mid-reclaim silently kills the batch 🟠 confirmed
`applicationShouldTerminateAfterLastWindowClosed` returns true and there is no
`applicationShouldTerminate` override, so closing the window or ⌘Q during a reclaim
kills the process mid-loop: a silent partial reclaim, no summary, and in permanent-delete
mode a `removeItem` killed mid-recursion leaves a half-deleted tree.
**Fix:** return `.terminateLater` while a reclaim is in flight and reply when it
finishes. → **PR "reclaim flow"**

### B6. Hardlinked files are double-counted in sizes 🟠 confirmed
`DirectorySizer` sums `totalFileAllocatedSize` per enumerated file with no hardlink
dedup, so pnpm-style hardlinked trees count each link at full size (within one item and
across items). Verification nuance: on APFS, pnpm/uv default to *clonefile* copies which
no tool can attribute per-file (du/Finder share this limitation) — but the hardlink case
(non-APFS, hardlink modes, multi-link files inside one tree) is real and fixable.
**Fix:** fetch `.linkCountKey`/`.fileResourceIdentifierKey`; count multi-link files once
per measurement. Document that sizes are estimates where clones are involved. → **PR
"scan pipeline"**

### B7. 'Exclude from Future Scans' during an in-flight reclaim doesn't save the item 🟡 confirmed
The context menu stays fully enabled while a reclaim runs; excluding a row that is part
of the in-flight batch records the exclusion and removes the row — but the captured
targets array is unaffected and the path is trashed moments later. Worse, the only cue a
reclaim is running is the disabled Reclaim button (the footer spinner is gated on
`isBusy`, which reclaim doesn't set).
**Fix:** disable mutating context-menu entries while `isReclaiming` (→ **PR "table
polish"**); reclaim progress in the footer (→ **PR "reclaim flow"**).

### B8. Unmeasured items reclaim as "Zero KB" 🟡 confirmed
Reclaim is enabled during `.measuring`; unmeasured items carry `sizeBytes == 0`, so the
confirmation can read "Reclaim 1 item (Zero KB)?" and the summary reports Zero KB freed
after trashing gigabytes. The footer "Checked:" total is likewise understated.
**Fix:** mark totals as "at least X" when any checked item is unmeasured. → **PR
"reclaim flow"**

### B9. Arc browser caches are never found 🔴 (catalog accuracy)
Arc's Chromium user-data dir is `Arc/User Data`, so its caches live at
`~/Library/Caches/Arc/User Data/<profile>/Cache` — one level deeper than the spec's
`cachesSubpath: "Arc"` enumeration reaches. Arc caches (often GBs) are silently missed.
**Fix:** add an `Arc/User Data` browser spec (keeping `Arc` costs nothing — nonexistent
dirs are skipped). → **PR "catalog"**

---

## 2. Data-safety hardening

The trust model holds for the shipped happy path — these close gaps between the
documented invariants and what the code actually enforces.

### S1. Guards are purely lexical; symlinks void home-containment and the denylist 🔴 confirmed
`PathGuards.validate` inspects the raw path string; `Reclaimer.verify` re-checks
existence/anchors with `fileExists` (which **follows** symlinks) and then trashes the
same URL. Realistic scenario: after scanning, the user moves `~/Projects` to an external
disk and leaves `ln -s /Volumes/Big/Projects ~/Projects`; the stale listed items still
verify (anchor resolves through the symlink) and `trashItem` operates on the external
volume — the "strictly inside home" last line of defense is silently void. A symlink
into a denylisted tree bypasses the component denylist the same way.
**Fix:** canonicalize (`resolvingSymlinksInPath`) both the item path and home in
`Reclaimer.verify`, run the guards on resolved paths, and refuse items whose final
component is itself a symlink. → **PR "guards hardening"**

### S2. Scanner enters ~/Library when ~ is a scan root — PLAN's Containers invariant is unenforced 🔴 confirmed
`shouldDescend` skips only dot-prefixed names; `Library` is flag-hidden, not dot-hidden,
and the folder picker happily accepts `~`. The walk then descends into
`~/Library/Containers`, `Application Support`, `Mail`, … where apps legitimately keep
anchored artifact-shaped trees (e.g. Adobe CEP extensions ship `node_modules` +
`package.json` under Application Support). Those pass every guard and get trashed —
app-internal data the trust model promises never to touch. `npm install` does not
reconstruct app-shipped trees.
**Fix:** skip flag-hidden directories (`.isHiddenKey`) in the walk and hard-skip
`<home>/Library` in the deep scan (KnownCaches handles Library on its own). → **PR
"guards hardening"**

### S3. Known-cache verification accepts the ~/Library/Caches umbrella itself 🟠 confirmed
`allowedRoots` includes `Library/Caches` wholesale and `isUnder` accepts `path == root`,
so a hypothetical `CleanableItem(isKnownCache: true, path: ~/Library/Caches)` passes
`Reclaimer.verify` *and* `PathGuards.validate` (depth is exactly 2). Not constructible
today, but AGENTS.md frames these checks as the last line of defense against exactly
such a future catalog bug — and both layers share the same hole.
**Fix:** enumerate concrete roots (spec paths + browser vendor dirs) instead of the
umbrella, and teach PathGuards that umbrella dirs (`Library/Caches`, `Library/Developer`,
`Library/Application Support`, …) are never themselves reclaimable. → **PR "guards
hardening"**

### S4. Scan roots outside home scan fine but every reclaim fails, after confirmation 🟠 confirmed
The folder picker accepts `/Volumes/External/dev`; the scanner walks it, the table lists
items, the user confirms the destructive dialog — and every item fails "outside the home
folder", surfacing only in the post-confirmation summary. A guaranteed dead end for
external-volume dev setups (the app's audience), eroding exactly the trust the product
is built on. (Fails safe — no data loss.)
**Fix (short term):** warn at add time and in the folder list for roots outside home.
→ **PR "scan roots"**. **Decide (future):** whether PathGuards should allow paths under
an explicitly user-chosen scan root (with denylist + depth-below-root rules) so external
volumes become a real feature rather than a trap.

### S5. Denylist matching is case-sensitive on a case-insensitive filesystem 🟡 confirmed (hardening)
`denylistComponents`/`denylistSuffixes` compare exact-case while APFS is
case-insensitive; a first-creator-wins `~/orbstack` or `~/.DOCKER` spelling would evade
the hard block. Not reachable from a scan today (enumeration returns on-disk spelling);
pure defense-in-depth.
**Fix:** fold case (and unicode-normalize) before comparing. → **PR "guards hardening"**

---

## 3. Performance

### P1. One main-actor hop + one full `@Published` mutation per measurement 🔴 confirmed
`measureAll` spawns an unstructured `Task { @MainActor }` per measured item; each
`apply` mutates `items`, firing `objectWillChange` → SidebarView (5 × O(n) `stats`),
DetailView, and ItemTable (`visibleItems` = filter + O(n log n) sort) re-evaluate. Small
items (`__pycache__`) finish in bursts, so dozens of applies land per frame early in the
measuring phase; the app drops frames exactly when the user first tries to interact.
**Fix:** coalesce — buffer measurements and flush in one `items` mutation every ~150 ms.
→ **PR "scan pipeline"**

### P2. `apply()` does a linear `firstIndex` per measurement — O(n²) main-actor work 🟠 confirmed
Each of n measurements scans the items array by path-string compare. Real but secondary
to P1 (verifier downgraded from high); fixed for free by the batch flush using an
id→index map. → **PR "scan pipeline"**

### P3. Table live re-sorts by size while sizes stream in — rows jump under the cursor 🔴 confirmed
Default sort is size-descending and `visibleItems` re-sorts on every access, so during
measuring rows continuously leapfrog. The user aims at a checkbox, a bigger item's
measurement lands, the row shifts, and the click checks a **different item** — in an app
whose product is "only delete what you explicitly checked", a mis-aimed check is a trust
defect, not jank. (The checkbox state itself never transfers — ids are stable — but the
click lands on the wrong row, and the confirmation dialog currently shows no paths that
would catch it.)
**Fix:** freeze ordering while `phase == .measuring` (sort by label/path — stable keys),
apply the size sort once on `.ready`. → **PR "scan pipeline"**

### P4. `visibleItems` recomputed (filter + sort) on every published change, several times per render 🟠 confirmed
Uncached computed property, evaluated by ItemTable and the footer (plus
`checkAllVisible`/`checkIdleVisible`); `localizedCaseInsensitiveContains` over label AND
path per item per keystroke. Batching (P1) removes the worst driver; full memoization of
derived state (visibleItems, sidebar stats dictionary, incremental checkedBytes) is a
worthwhile follow-up refactor. → batching in **PR "scan pipeline"**; memoization
**future**.

### P5. Sidebar `stats(for:)` filters + reduces all items per row per update 🟠 confirmed
O(rows × n) per render pass (SwiftUI coalesces to per-frame, so cheaper than raw math
suggests, but still wasted work). **Fix:** one-pass category totals dictionary —
**future** (bundled with the P4 memoization refactor).

### P6. Reclaim completion removes items with O(n × m) nested prefix scan + per-pair string allocation 🟠 confirmed
`items.removeAll { reclaimed.contains { isUnder(...) } }` — `isUnder` allocates
`root + "/"` per pair. After reclaiming thousands of items the main thread stalls right
when the summary should appear.
**Fix:** Set-based exact-match fast path + precomputed `root + "/"` prefixes. → **PR
"scan pipeline"**

### P7. Every checkbox toggle re-sorts and re-diffs the whole table 🟠 confirmed
`checkedIDs` is `@Published`; a toggle re-evaluates everything including two
`visibleItems` sorts and 4+ O(n) checked-filter passes (the confirmation title alone
computes `checkedItems` twice plus `checkedBytes`). Fully fixed only by the P4
memoization; mitigated by P1's batching. → **future** (with P4).

### P8. `exclude(ids:)` does one UserDefaults array serialization per excluded path 🟡 confirmed
Excluding 200 rows fires 200 `didSet` writes and O(200 × e) contains-scans.
**Fix:** Set-difference once, single `append(contentsOf:)`. → **PR "scan pipeline"**

### P9. Discovery walk is single-threaded across roots 🟠 plausible
Sizing is 4-way parallel but discovery is serial; the phase designed to feel instant is
the one that can't be parallelized as shipped. Verifier note: the walk prunes matched
artifacts/hidden dirs, so directory counts are far lower than raw file counts — a
minute-long blank phase needs unusually broad trees. **Fix:** bounded task-group walk
over top-level subdirs — **future** (needs profiling first).

### P10. `measureAll` width hardcoded to 4 🟡 confirmed
Defensible SSD choice; an adaptive `2...8` clamp from `activeProcessorCount` would serve
M-series Macs better. → **future** (revisit with P9).

---

## 4. UX

### U1. Checked-but-hidden items are silently included in reclaim 🔴
`reclaimChecked` operates on all checked items, not visible ones. Check a few browser
caches, switch category, filter, review the screen, confirm — hidden items are deleted
too; the only hint is the easy-to-miss footer count. The largest trust gap in the app.
**Fix:** confirmation states "includes N items hidden by the current filter" (and lists
top items — see U2). → **PR "reclaim flow"**

### U2. Confirmation dialog never shows WHAT will be deleted 🔴
"Reclaim 14 items (32.9 GB)?" is abstract at the exact moment of commitment; warnings
("Chrome is running") and slow-to-rebuild flags are invisible here too. PLAN's pitch is
"shows exactly what it found" — the final step shows nothing.
**Fix:** list the top checked items by size in the dialog message ("• mega-app/node_modules
— 12.1 GB … and 9 more"), plus warning/slow callouts. → **PR "reclaim flow"**

### U3. No progress or cancel during reclaim 🔴
`isReclaiming` only disables the Reclaim button; trashing 50 GB of DerivedData looks
like a hang (footer shows idle text — the spinner is gated on `isBusy`).
**Fix:** per-item progress callback from `Reclaimer` → "Reclaiming X of N — label" in the
footer; disable Scan while reclaiming. Cancel support: **future**. → **PR "reclaim flow"**

### U4. No keyboard path to Reclaim — ⌘⌫ is the idiomatic chord 🟠
Scan has ⌘R, Stop has ⌘.; the primary action is mouse-only. ⌘⌫ (Finder's "Move to
Trash") should open the confirmation — it arms the dialog, never bypasses it.
→ **PR "reclaim flow"**

### U5. Spacebar can't toggle checkboxes on selected rows 🟠
Multi-row selection exists but only feeds the context menu; Space should toggle the
selection's checkboxes (macOS 14+ `onKeyPress`, availability-gated). → **PR "table polish"**

### U6. A clean scan lands back on the first-launch welcome screen 🟠
`items.isEmpty && !isBusy` shows the pre-scan pitch after a scan that found nothing — no
acknowledgement a scan ran, and a TCC-denied empty result is indistinguishable from a
clean disk. `phase == .ready` already distinguishes the states.
**Fix:** post-scan variant: "Scan complete — nothing to reclaim" + rescan button + a
folder-access hint. → **PR "empty states"**

### U7. Browser-running warnings go stale 🟠
Running apps are snapshotted once at scan start. Quit Chrome after scanning → scary stale
badge; launch Chrome after scanning → no badge and reclaim proceeds wordlessly.
**Fix:** re-snapshot when the confirmation opens and call out affected items in the
dialog; refresh badges on window focus. → confirmation re-check in **PR "reclaim flow"**;
live badge refresh **future**.

### U8. Reclaim button tooltip says "Move to Trash" even in permanent-delete mode 🟡
A wrong tooltip about deletion semantics in a trust-first app.
**Fix:** conditional help text. → **PR "reclaim flow"**

### U9. Checkbox toggles unlabeled for VoiceOver; "…" reads literally; hints are hover-only 🟠
`Toggle("")` announces an anonymous checkbox that arms deletion; the size/age "…"
placeholders read as "ellipsis"; `regenerationHint` lives only in a tooltip.
**Fix:** `.accessibilityLabel("Reclaim \(label)")`, accessibility values for measuring
cells. → **PR "table polish"**

### U10. Row actions exist only in the context menu 🟡
No menu-bar equivalents, no shortcuts, nothing hints right-click exists — "Exclude from
Future Scans" is undiscoverable. → **future** (an Items menu bound to table selection).

### U11. Empty category / no-match filter shows a bare table 🟡
Selecting a category with zero items or filtering to nothing renders blank rows with no
message. **Fix:** placeholder overlay (custom view — `ContentUnavailableView` is
macOS 14+, target is 13). → **PR "reclaim flow"** (DetailView).

### U12. Select > None clears hidden checks while All Visible is scoped 🟡
Asymmetric scope compounds U1. **Fix:** "Uncheck All (N)" naming with global count.
→ **PR "reclaim flow"**

### U13. Exclude is instant, silent, and only reversible deep in Settings 🟡
**Fix (future):** transient undo affordance; for now the action is at least reversible
via Settings → Folders.

### U14. "Choose Folders…" uses private selectors and can't target the Folders tab 🟡
`SettingsLink` is macOS 14+; the current fallback works. **Future:** present the folder
picker directly from the empty state.

---

## 5. Visual & layout

### V1. Item-cell top line has no overflow strategy 🟠
Label + kind capsule + slow badge + warning share one HStack, all `lineLimit(1)` with no
priorities: at narrow widths the *item name* truncates first while decorative badges keep
full width, and the safety-relevant warning truncates without a tooltip of its own.
**Fix:** `layoutPriority(1)` on the label; warning gets `.help(warning)`. → **PR "table
polish"**

### V2. Size column is text-only — space hogs don't pop 🟠
38 GB and 214 MB look typographically identical. **Fix:** proportional tinted bar behind
the size text (sqrt scale, category tint, hidden until measured). → **PR "table polish"**

### V3. "Last built" carries no staleness signal 🟡
The idle threshold drives a quick action but is invisible in the table. **Fix:** tint
ages past `idleDays` orange (predicting exactly what "Select Idle" will grab). → **PR
"table polish"**

### V4. Sidebar icons untinted while table rows are tinted 🟡
The category color language is taught in the table but absent where categories live.
**Fix:** tint sidebar glyphs with `category.tint`. → **PR "table polish"**

### V5. "slow to rebuild" capsule: raw yellow at 0.25 opacity + duplicated badge styling 🟡
Murky in dark mode, off-recipe vs the kind capsule (0.16), inconsistent casing.
**Fix:** shared badge helper, one opacity, consistent casing. → **PR "table polish"**

### V6. Summary alert titled "Space repossessed" even when nothing was reclaimed 🟡
The joke lands wrong on failure. **Fix:** "Nothing to repossess" / partial-success
variants. → **PR "reclaim flow"**

### V7. Footer: full-size Select menu next to caption text; "Checked: 0 · Zero KB" permanent noise 🟡
**Fix:** `.controlSize(.small)`, hide the checked summary at zero. → **PR "reclaim flow"**

### V8. SF Symbol audit 🟡
`wind` for Flutter is a weather glyph; seven package-manager kinds share `shippingbox`
(the category icon — zero information per row); `terminal` for pythonCache is generic.
→ **PR "catalog"** (touches ArtifactKind anyway).

### V9. Settings window height jumps between tabs; Rules tab hard-codes 440 pt 🟡
**Future** — cosmetic; Apple's own Settings resize per pane.

---

## 6. Catalog gaps (missing rules & caches)

High-value additions, all honoring the trust model (fixed home-relative locations, or
anchored project rules). Existing-path verification: pnpm store, Yarn v1, Homebrew,
Firefox `cache2`, Chrome-family paths are all correct; Arc is wrong (B9).

**Well-known caches → PR "catalog":**

| # | Location | Notes |
|---|---|---|
| K1 | `~/Library/Caches/ms-playwright` | Playwright browser builds, per-version children; GBs |
| K2 | `~/Library/Caches/Cypress` | Cypress binaries per version |
| K3 | `~/Library/Caches/electron`, `…/electron-builder`, `…/node-gyp`, `~/.cache/puppeteer` | Node toolchain downloads |
| K4 | `~/Library/Caches/deno`, `~/.bun/install/cache` | Deno / Bun caches |
| K5 | `~/.composer/cache`, `~/Library/Caches/pypoetry` | Composer / Poetry |
| K6 | `~/Library/Caches/ccache`, `~/.ccache`, `~/Library/Caches/Mozilla.sccache` | compiler caches; slow-to-regenerate flag |
| K7 | `~/.pub-cache` | Dart/Flutter pub cache; slow flag |
| K8 | `~/.yarn/berry/cache` | Yarn Berry global mirror (v1 entry covers classic only) |
| K9 | `~/.pnpm-store` | legacy pnpm store location |
| K10 | `~/.cargo/registry/src`, `~/.cargo/git/checkouts` | often larger than the cached .crates already listed |
| K11 | `~/Library/Developer/Xcode/UserData/Previews/Simulator Devices` | Xcode Previews data, 5–20 GB for the target audience |
| K12 | `visionOS DeviceSupport` | alongside iOS/watchOS/tvOS |
| K13 | `~/Library/Caches/JetBrains`, `~/Library/Caches/Google/AndroidStudio*` | per-product-version IDE caches; slow flag (re-index) |
| K14 | VS Code `Cache`, `CachedData`, `Code Cache`, `CachedExtensionVSIXs` under `~/Library/Application Support/Code` | narrowly-scoped; running-app warning (`com.microsoft.VSCode`) |

**Project rules → PR "catalog":**
- K15: `vendor/` + `composer.json` (PHP) and `vendor/` + `go.mod` (Go) — regenerated by
  `composer install` / `go mod vendor`. Hint caveat: some teams commit vendor/.
- K16: jsBuildOutput += `.astro`, `.expo`, `.docusaurus`, `.output`, `.cache` (Gatsby)
  — package.json anchor already required; add to `neverDescend`.
- K17: Maven hint overstates regenerability (locally-`mvn install`ed artifacts must be
  rebuilt, not re-downloaded) — amend hint. pnpm hint: note hardlinked sizes.

**Deferred (documented, not implemented):**
- K18: Go module cache `~/go/pkg/mod` — huge, but Go writes it read-only; `removeItem`
  fails mid-tree. Needs a chmod pre-pass or a "use `go clean -modcache`" pathway first.
- K19: Terraform `.terraform` (+ `.tf` anchor) — regenerable via `terraform init`, but
  workspace selection resets; wants a visible caveat.
- K20: Hugging Face hub `~/.cache/huggingface/hub` — frequently the largest cache on an
  ML machine; slow, sometimes gated re-downloads. Deliberate decision needed.
- K21: Ruby `vendor/bundle` — needs a parent-sibling anchor (`Gemfile` next to `vendor`'s
  parent), which the rule engine can't express yet.
- K22: CMake preset layouts (`out/build/<preset>/CMakeCache.txt`) miss the current
  one-level `innerAnchors` probe.

---

## 7. Updates module & CI/CD

### D1. SemanticVersion compares prerelease identifiers lexically 🟠 confirmed
`beta.10 < beta.9` lexically, so with `allowPrereleases` a user on `beta.9` is never
offered `beta.10`, and `latestRelease` picks the wrong "newest" via the same comparator.
**Fix:** semver-correct dot-split identifier comparison (numeric < alphanumeric). → **PR
"updates"**

### D2. `isChecking` mutated off the main actor 🟠 confirmed (latent)
`performCheck` sets the `@Published` guard synchronously on the caller thread while the
reset happens on the main actor. All current call sites are main-thread; the class is
advertised as drop-in reusable, so harden anyway.
**Fix:** move guard+set inside the `@MainActor` task (full `@MainActor` class is the
long-term shape). → **PR "updates"**

### D3. Check Now reports "You're up to date" when version parsing failed 🟡 confirmed
An unparseable tag (`latest`, date-style) yields a false positive instead of an error.
→ **PR "updates"**

### D4. Daily-check throttle can skip timer fires (tolerance > latency window) 🟡 confirmed
**Fix:** compare against `interval - tolerance` slack. → **PR "updates"**

### D5. 404 always mapped to "No published releases were found" 🟡 confirmed
Deleted/private repo reads as a permanent-sounding "no releases". (Renames 301-redirect,
so that half of the original claim was refuted.) **Fix:** wording that covers both.
→ **PR "updates"**

### D6. ci.yml concurrency still cancels queued main-branch runs 🟡 confirmed
GitHub always cancels the *pending* run in a group; per-ref grouping on push means a
3-push burst leaves commit B permanently cancelled — exactly what the comment says it
prevents. **Fix:** per-SHA group for pushes. → **PR "ci"**

### D7. Release workflow's gating test run uploads no diagnostics on failure 🟡 confirmed
**Fix:** `-resultBundlePath` + failure-gated artifact upload, mirroring ci.yml. → **PR "ci"**

### D8. README "unsigned" wording / missing right-click-Open path 🟡 (partial)
Verifier: "unsigned" is the repo's consistent shorthand and macOS 15 weakened
right-click-Open, so the xattr instruction is arguably the better primary. Worth a
one-line clarification that the build is ad-hoc signed but not notarized. → **PR "ci"**

---

## 8. Ideas — delight & polish

### I1. Lifetime repossession counter — "1.2 TB repossessed since install" ⭐ S
The best theme-fit available: a repo man keeps a tally. Persist lifetime bytes/count in
Preferences, show quietly in the footer and in the summary alert ("…bringing your
lifetime total to 1.2 TB"). → **PR "reclaim flow"**

### I2. Free-disk-space delta in the summary — "Disk free: 89 GB → 122 GB" ⭐ S
Proof, not promise. Capture volume free space before/after the reclaim; when trashing,
say "X GB will free up once you empty the Trash" — which honestly teaches the Trash
subtlety. → **PR "reclaim flow"**

### I3. Confirmation lists top checked items ⭐ S
(Same as U2 — the delight framing: the dialog proves the app knows what it's about to
take.) → **PR "reclaim flow"**

### I4. Proportional size bars in the Size column ⭐ S
(Same as V2.) → **PR "table polish"**

### I5. Staleness heat on "Last built" ⭐ S
(Same as V3.) → **PR "table polish"**

### I6. ⌘⌫ to reclaim ⭐ S
(Same as U4.) → **PR "reclaim flow"**

### I7. "Open Trash" + Put Back guidance after a trashed reclaim ⭐ S
The trust model's crown jewel ("a mistake is a drag back") made actionable at the moment
of mild deleter's remorse. → **PR "reclaim flow"**

### I8. Biggest-offender callout when a scan completes — M, future
"Biggest offender: mega-app/node_modules — 12.1 GB, last built 7 months ago" in the
footer, click to reveal. Gives the scan a punchline.

### I9. Repossession receipt — M, future
"Copy Receipt" after a reclaim: an itemized, repo-man-voiced plain-text report (devs will
paste it in Slack; doubles as an audit trail). Needs ReclaimSummary to carry item details.

### I10. Group project artifacts by repository with subtotals — M/L, future
Answers "which *project* is eating my disk"; `Table(of:children:)` is macOS 14+, so this
also interacts with the deployment target.

### I11. Disk-free gauge in the empty state — S, future
Replace the static drive icon with a small used/free Gauge — the first thing the user
sees is the problem RepoMen solves.

### I12. Reclaim sound + rotating repo-man flavor lines — S, future
"Asset recovered." Needs a sounds preference; keep failure summaries dry.

### I13. de-CH localization — M/L, future
String Catalogs; byte counts already localize. Best done before more strings accrete.
(Bonus easter egg: a Schwiizerdütsch flavor-line voice.)

### I14. Menu-bar reclaimable total — consciously rejected
Recorded so it isn't rediscovered: a *useful* menu-bar number implies background
scanning, colliding with the "deliberate tool you run" non-goal; a stale number is
honest but low-value. If ever done: last-scan total + timestamp + "Open RepoMen", nothing
more.

---

## 9. Reviewed and rejected

- **DirectorySizer per-entry `Date()` allocation** — refuted: short-circuit evaluation
  means it only runs on new-maximum mtimes; Date is an allocation-free value type.
- **"trashItem falls back to permanent delete across volumes"** — refuted: it lands in
  the target volume's `.Trashes` or throws (and the error is reported per item).
- **Case-crafted paths evading the denylist from a scan** — not reachable: enumeration
  returns on-disk spelling; only symlinks (S1) realize the bypass.

---

## Implementation plan

Nine branches, each off `main`, grouped to keep diffs disjoint (AppModel is split:
scan-side changes in *scan pipeline*, reclaim-side in *reclaim flow*):

| Branch | Contents | Files |
|---|---|---|
| `claude/scan-pipeline` | B2 B3 B4(guard) B6 P1 P2 P3 P6 P8 | AppModel, DirectorySizer |
| `claude/reclaim-flow` | B5 B8 U1 U2 U3 U4 U8 U11 U12 V6 V7 I1 I2 I3 I6 I7 + U7(dialog) | DetailView, AppModel(reclaim), Reclaimer(progress), Preferences, RepoMenApp, AppDelegate |
| `claude/catalog` | B9 K1–K17 V8 | ArtifactKind, RuleCatalog, KnownCaches, tests |
| `claude/guards-hardening` | S1 S2 S3 S5 | PathGuards, Reclaimer, KnownCaches(allowedRoots), Scanner(walk), tests |
| `claude/scan-roots` | B1 S4(warning) | Preferences, Scanner(normalizedRoots), SettingsView, tests |
| `claude/table-polish` | U5 U9 B7(menu) V1 V2 V3 V4 V5 | ItemTable, SidebarView |
| `claude/empty-states` | U6 | EmptyStateView |
| `claude/updates` | D1–D5 | Updates/*, tests |
| `claude/ci` | D6 D7 D8 | workflows, README |

Left for future work (kept in ANALYSIS.md): P4/P5/P7 memoization refactor, P9/P10
parallel discovery, U7 live badge refresh, U10 Items menu, U13 exclude-undo, U14,
V9, K18–K22, I8–I13, S4 external-volume design decision, reclaim cancel (U3).
