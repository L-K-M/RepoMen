# ANALYSIS.md — RepoMen backlog & design notes

The living document for future work. It consolidates the 0.1.0 review
([fable.md](fable.md), commit `a7190a7`) and the second-pass review
([k3.md](k3.md), against post-#9 main) minus everything already implemented; the
reviews' finding IDs (B/S/P/U/V/K/D/I from fable, K1–K7 from k3) are kept so PRs
and history stay traceable.

**Severity:** 🔴 high · 🟠 medium · 🟡 low. Effort: S/M/L.

---

## Addressed by the 0.1.0 review PRs

Cleared from the backlog; listed so nothing has to be rediscovered. Details live in
fable.md and the PR descriptions.

| PR | Branch | Findings closed |
|---|---|---|
| [#1](https://github.com/L-K-M/RepoMen/pull/1) | `claude/scan-pipeline` | B2 scan-restart races, B3 partial measurements committed, B4 scan-during-reclaim guard, B6 hardlink double-counting, P1 per-item re-render storm, P2 O(n²) apply, P3 rows jumping while measuring, P8 per-path defaults writes |
| [#2](https://github.com/L-K-M/RepoMen/pull/2) | `claude/reclaim-flow` | B5 quit mid-reclaim, B8 "Zero KB" reclaims, P6 reclaim-removal cost, U1 hidden-checked items, U2/I3 confirmation shows items, U3 reclaim progress (cancel still open, below), U4/I6 ⌘⌫, U8 tooltip, U11 empty-filter placeholder, U12 Uncheck All scope, V6 summary titles, V7 footer polish, I1 lifetime counter, I2 free-space delta, I7 Open Trash + Put Back |
| [#3](https://github.com/L-K-M/RepoMen/pull/3) | `claude/catalog` | B9 Arc path, K1–K17 catalog additions & hint fixes, V8 symbol audit |
| [#4](https://github.com/L-K-M/RepoMen/pull/4) | `claude/guards-hardening` | S1 symlink-blind guards, S2 scan entering ~/Library, S3 umbrella allowedRoots, S5 case-sensitive denylist |
| [#5](https://github.com/L-K-M/RepoMen/pull/5) | `claude/scan-roots` | B1 case-duplicated default roots, S4 (warning half) |
| [#6](https://github.com/L-K-M/RepoMen/pull/6) | `claude/table-polish` | U5 space toggles, U9 VoiceOver labels, B7 (context-menu half), V1–V5 row layout/badges/bars/staleness/sidebar tints, I4, I5 |
| [#7](https://github.com/L-K-M/RepoMen/pull/7) | `claude/empty-states` | U6 clean-scan state |
| [#8](https://github.com/L-K-M/RepoMen/pull/8) | `claude/updates` | D1 semver prerelease, D2 isChecking race, D3 false "up to date", D4 throttle drift, D5 404 wording |
| [#9](https://github.com/L-K-M/RepoMen/pull/9) | `claude/ci` | D6 push concurrency, D7 release diagnostics, D8 README install notes |

Cross-PR notes: #2 and #4 both touch `Reclaimer.reclaim`'s preamble — if they conflict
on merge, keep both changes. #2 composes with #1's model-side scan/reclaim exclusion.

### k3 PRs

| PR | Branch | Findings closed |
|---|---|---|
| [#12](https://github.com/L-K-M/RepoMen/pull/12) | `k3/watch-folders` | k3-K5 watched folders + auto-trash + menu bar + notifications, k3-K6 scan-at-launch |
| [#13](https://github.com/L-K-M/RepoMen/pull/13) | `k3/derived-state-perf` | P4+P5+P7 derived-state caching + search debounce, P10 (width half) |
| [#14](https://github.com/L-K-M/RepoMen/pull/14) | `k3/ux-remainder` | k3-K1 selection survives rescans, k3-K2 unmeasured-summary honesty (fable B8 residual), k3-K3 icon-only row warning, U10 Items menu |
| [#15](https://github.com/L-K-M/RepoMen/pull/15) | `k3/launch-hang-hotfix` | launch unresponsiveness after #12–#14 (WindowGroup+MenuBarExtra activation; notification-center XPC at launch; menu-bar extra now opt-in) |
| [#16](https://github.com/L-K-M/RepoMen/pull/16) | `k3/menubar-loop-fix` | launch beachball: MenuBarExtra `isInserted` KVO writeback ↔ `@Published` republish feedback loop; deduping setter |
| [#17](https://github.com/L-K-M/RepoMen/pull/17) | `k3/context-menu-watch` | "Add to Watched Folders" from scan-results context/Items menus (adds the project folder; shared `Preferences.watchFolder`) |
| [#18](https://github.com/L-K-M/RepoMen/pull/18) | `k3/launch-at-login` | "Open at Login" toggle via SMAppService (no UserDefaults mirror); watch lifecycle copy clarified |

> **⚠ CI is not running in this repository.** Every Actions job — including the
> original `main` commit `a7190a7`, before any review changes — "fails" within ~2
> seconds with no runner assigned and no logs. That is the signature of macOS runners
> being unavailable to the account (this repo is private; macOS runners bill at 10×
> minutes, and an exhausted free tier or a zero spending limit fails jobs instantly).
> Until Actions billing/spending is sorted out in the GitHub account settings, none of
> the review PRs (claude's #1–#9 or k3's #12–#14) have been machine-verified: they
> were written without a local Xcode toolchain and reviewed by hand only. Run the
> suite locally (`xcodebuild … clean test`) or fix Actions before merging.

---

## Open: performance

### P9 — Parallel discovery walk 🟠 M (profile first)
Sizing is parallel; discovery is a single-threaded recursive walk, so the phase
meant to feel instant is the serial one. Verifier caution: the walk prunes matched
artifacts, hidden dirs and `.git`, so directory counts are far smaller than raw file
counts — profile before building. **Shape:** bounded task group over top-level (or
depth-2) subdirectories, per-worker item arrays merged at the end; alternatively
stream discovered items into the table during the walk.

### P10 (residual) — Sizing tail latency 🟡 S
PR #13 made the walker count adaptive (half the cores, clamped 2…8). What remains:
tail latency is bounded by the single largest artifact — splitting the biggest
directories across subtasks would shorten it. Revisit together with P9.

---

## Open: UX

### U7 (residual) — Live refresh of running-app badges 🟡 S/M
PR #2 surfaces recorded warnings in the confirmation dialog, but badges still reflect
the scan-time snapshot. Re-snapshot `NSWorkspace` when the window becomes key (and
ideally when the confirmation opens) and rewrite item warnings in place.

### U13 — Exclude is instant, silent, and far from reversible 🟡 S/M
A mis-click permanently hides a repo's artifacts; recovery requires knowing about
Settings → Folders → Remove Exclusion. **Shape:** transient in-place undo (toast or
footer link) after excluding; keep the action one-click.

### U14 — Settings deep-linking 🟡 S
"Choose Folders…" opens Settings via private selectors and lands on the General tab.
On macOS 14+ `SettingsLink` is the supported route; a published "requested tab" would
land directly on Folders — or skip Settings and present the folder picker straight from
the empty state. (Blocked on raising the deployment target, or availability-gate it.)

### S4 (design decision) — External-volume scan roots 🟠 M
PR #5 warns, but the underlying mismatch stands: scan roots outside home scan fine and
can never reclaim ("outside the home folder" is PathGuards' deliberate rule). Decide
deliberately: either restrict roots to the home volume, or extend PathGuards to allow
paths under an explicitly user-chosen scan root (denylist + depth-below-root rules
still applying, Trash landing in the volume's `.Trashes`). The app's target audience
keeps repos on external SSDs, so this is worth a real decision rather than a warning.

---

## Open: watch-mode follow-ups (created by PR #12)

### W1 — True background cleaning while the app is quit 🔴 feature, L
Watch mode covers "while the app is alive" (it parks in the menu bar). Fully
unattended cleaning needs a login-item helper (SMAppService) or LaunchAgent,
headless scan+clean, and conservative defaults. PLAN.md keeps this an explicit
non-goal until designed deliberately.

### W2 — Hide-Dock-icon agent mode 🟡 S/M
The app keeps its Dock icon while watching. A Settings toggle for
`.accessory` activation policy (menu-bar-only presence) needs care: the Settings
scene, alerts, and TCC prompts all behave differently without a Dock presence.

### W3 — Coordinate watch checks with window activity 🟡 S
`WatchManager` doesn't currently skip a check while a manual scan or reclaim is
running. Both paths are safe (read-only scan; per-item re-verified Trash), but a
timer firing mid-manual-reclaim can double-delete-race the same directory (loser
gets a reported "no longer exists") and thrash the disk. Skip checks while
`AppModel.isReclaiming`/`isBusy`.

### W4 — Watch checks never cover `KnownCaches` 🟡 decision
Watch mode only deep-scans watched roots (project artifacts). Auto-cleaning fixed
cache locations (browser caches with running-app warnings, slow-to-refill package
caches) is a separate trust decision — candidates would need warning-aware
eligibility (never auto-trash while the owning app runs).

### W5 — Per-folder watch presets/learning 🟡 idea
Suggest thresholds from observed build cadence ("this repo builds daily — 7 days
fits"), or offer "watch all current scan roots" as one tap (PR #12 has per-root
quick-add already).

---

## Open: catalog

### K18 — Go module cache `~/go/pkg/mod` 🔴 value, blocked on write-permission handling
Routinely 10–50 GB and fully regenerable, but Go writes it read-only (0444/0555):
`FileManager.removeItem` fails mid-tree in permanent-delete mode, and a trashed copy
resists emptying. Needs a chmod pre-pass or a dedicated "run `go clean -modcache`"
affordance — do not add naively.

### K20 — Hugging Face hub `~/.cache/huggingface/hub` 🟠 decide deliberately
Frequently the largest cache on an ML machine (tens of GB); re-downloads are slow and
gated models need re-auth. Either add with `expandChildren` + slow flag, or document as
out of scope like Docker.

### K21 — Ruby `vendor/bundle` — needs an engine extension
The anchor (`Gemfile`) sits next to `vendor`'s *parent*, which `Anchor` can't express;
matching bare `vendor` for Ruby is unsafe. Add a parent-sibling anchor case first.

### K22 — CMake preset layouts 🟡
`out/build/<preset>/CMakeCache.txt` (VS Code CMake Tools / CLion presets) sits one
level below where `innerAnchors` probes, so the outer tree never matches. Extend inner
anchors to probe one level deep (still an existence proof), or accept the smaller
inner matches.

### Android Studio caches 🟡
`~/Library/Caches/Google/AndroidStudio<version>` shares the `Google/` vendor dir with
Chrome, so a naive `expandChildren` spec would sweep Chrome's dirs. Needs per-child
prefix filtering in the spec model (`AndroidStudio*`).

---

## Open: ideas (delight)

### I9 — Repossession receipt — M
"Copy Receipt" after a reclaim: itemized plain-text/Markdown in the repo-man voice
("REPOSSESSION NOTICE — 14 items recovered · 32.9 GB"), doubling as an audit trail.
Needs `ReclaimSummary` to carry per-item details; a pure `receiptText()` formatter next
to `Format` keeps it testable. Optional: File → Export Scan Report (CSV) for the
pre-reclaim inventory.

### I10 — Group project artifacts by repository — M/L
A repo with a Rust workspace + web frontend scatters rows; a "group by project" mode
(project root derived from the anchor path) with per-project subtotals and a tri-state
group checkbox answers "which *project* is eating my disk". `Table(of:children:)` is
macOS 14+ — interacts with the deployment target.

### I12 — Reclaim sound + flavor lines — S
A short "moved to Trash"-style sound plus one rotating repo-man line ("Asset
recovered.") on successful reclaims. Needs a `playSounds` preference (default on);
keep failure-only summaries dry.

### I13 — de-CH localization — M/L
String Catalogs; replace hand-rolled plurals; route `Format.age` bucket templates
through the catalog while keeping bucket logic testable (byte counts localize already).
Best done before more strings accrete. Easter-egg idea: a Schwiizerdütsch flavor-line
voice for I12.

### Naming
The "should the app be renamed" question is parked in [k3.md](k3.md) §4 — shortlist
led by **Sawdust** (what building software leaves behind), with Rubble, Offcuts,
Jetsam, Ballast, Flotsam, Reclaim as alternates; "RepoMen" itself is defensible. No
code work until a decision lands.

---

## Considered and rejected (kept so they aren't rediscovered)

- **I14 — Menu-bar reclaimable total:** superseded in part by watch mode (PR #12):
  the menu bar now shows the last *watch* run and lifetime tally. Still rejected:
  a live "reclaimable right now" number, which implies constant background
  scanning beyond watch mode's 6-hour cadence.
- **DirectorySizer `Date()` per entry:** refuted — short-circuit evaluation runs it
  only on new-maximum mtimes, and `Date` is an allocation-free value type.
- **"trashItem falls back to permanent delete across volumes":** refuted — it lands in
  the target volume's `.Trashes` or throws, and the error is reported per item.
- **Case-crafted paths evading the denylist from a scan:** not reachable — enumeration
  returns on-disk spelling; only symlinks realized the bypass (closed by PR #4).

---

## Standing invariants for future work

Unchanged from AGENTS.md/PLAN.md, restated because several backlog items brush against
them: anchors are the safety story (never weaken one to fix a false negative); every
deletion passes `PathGuards.validate` — now on *resolved* paths; Trash stays the
default; nothing is ever pre-selected; Docker/OrbStack/backups/photo libraries stay
out; the deep scan stays out of `~/Library` (KnownCaches owns it). Watch mode (PR
#12) extends the model without changing it: automation is opt-in, auto-clean is
always Trash (never permanent delete), and every auto-reclaim passes the same
re-verification at trash time.
