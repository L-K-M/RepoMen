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
  `SnapshotRow` (table row: a Time Machine snapshot, or a foreign one shown greyed),
  `SnapshotModel` (main-actor state for the Snapshots pane).
- `RepoMen/Watch` — watched-folders automation: `WatchedFolder` (+`WatchRunRecord`),
  `WatchEngine` (pure eligibility), `WatchManager` (periodic check → trash),
  `WatchNotifier` (notifications).
- `RepoMen/UI` — SwiftUI views: sidebar, table, snapshots pane, settings, empty
  state, menu bar.
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
    snapshots are never even modelled — `LocalSnapshot` refuses them; note that
    `tmutil listlocalsnapshots` lists EVERY snapshot on the volume, so the filter is
    load-bearing, and foreign names are shown as "left alone", never checkable),
    never the whole-volume `deletelocalsnapshots /`. Explicit action in the
    Snapshots pane (sidebar → Time Machine) only — never a scan, never watch mode;
    deletion is always permanent and the dialog says so; the admin prompt is a
    fallback used only after an unprivileged run was refused. No per-snapshot size
    is ever shown: macOS exposes none to apps.
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

<!-- shared-rules:start -->

## Working practices

- Follow explicit task instructions over the default workflow below.
- Writing the code is not finishing the task. A task is finished when
  its changes are merged to main through a PR that passed CI and review,
  or when the user explicitly accepts a different end state.
- Before editing, inspect the branch and working tree, fetch remote updates,
  and fast-forward where safe. Never overwrite existing work to update.
- Resolve ambiguity before making consequential changes. State low-risk
  assumptions; ask when scope, safety, or expected behavior is unclear.
- Keep changes focused. Do not modify unrelated code, formatting, or comments.
- Prefer surgical edits over whole-file rewrites when the result is equivalent.
- Stage only intended files. Inspect the diff before committing.

## Communication

- Be concise, factual, and direct. Preserve necessary context and uncertainty.
- Avoid praise, motivational filler, emojis, and em dashes in new prose.
- Address the reader directly in user-facing copy.
- Report what was verified and what remains unverified. Never imply that an
  unavailable check passed.

## Code design

- Prefer early returns and shallow nesting. Separate logical blocks with
  blank lines.
- Use descriptive constants or enums for meaningful or repeated values.
  Use existing standard definitions for protocol/specification constants.
  Keep obvious, one-off values inline.
- Use enums for behavioral modes that would otherwise require ambiguous
  boolean arguments.
- Default members to private. Widen visibility only for required consumers,
  and review the change as an API design decision.
- Follow the repository's declared dependency boundaries. UI and controllers
  must use application services rather than directly accessing databases,
  subprocesses, sockets, or other low-level mechanisms.
- Encapsulate low-level mechanics behind domain-oriented interfaces.
- Reuse genuinely shared logic. Avoid speculative abstractions and layers
  that only forward calls.
- Prefer pure functions for business rules and immutable data where practical.
  Isolate side effects; document non-obvious state ownership or synchronization.
- Explain non-obvious intent, constraints, and tradeoffs in comments.
  Do not narrate obvious code. Add examples or diagrams when they clarify it.

## Validation and errors

- Validate untrusted input at entry points. Where practical, represent valid
  states in types and enforce persistent invariants in database schemas.
- Represent absence and failure explicitly.
- Use assertions for internal programming invariants, not external-input
  validation or required runtime error handling.
- Prefer explicit, actionable errors over silent failure or undocumented
  fallback. Document intentional recovery behavior.
- Never report a skipped or failed operation as successful.

## Bug fixes

1. Identify the root cause and define an observable success criterion.
2. Add a regression test and observe the relevant failure before fixing it.
3. Implement the fix and observe the test passing.
4. Check surrounding behavior for regressions and architectural consistency.

If an automated regression test is impractical, document the reproduction
and verification procedure. State any inability to reproduce the failure.

## Verification

- Run relevant tests and lint after changes.
- Choose coverage by affected behavior and risk, not patch size.
- Use integration or end-to-end tests for critical workflows and boundaries;
  test isolated business rules at the lowest effective level.
- Run broader suites for cross-cutting or high-risk changes, and the full
  required release checks before releasing.
- Validate the requested command, options, platform, and configuration.
  Unrelated green CI is not proof that the reported problem is fixed.
- Recheck after the final edit. Distinguish local checks from CI results.

## Commit messages

- Use a capitalized, imperative subject without a final period.
- Target 50 characters; never exceed 72.
- Separate the subject and body with one blank line.
- Wrap body text at 72 characters.
- Explain what changed and why. Leave implementation mechanics to the code.

## Implementation and review

Unless explicitly instructed otherwise:

1. Work on a focused branch and open a PR against main before reporting
   the task as done.
2. Inspect CI results and completed review feedback for the latest commit.
   A successful reviewer job does not mean the review found no problems.
3. Address important findings or explain why they do not apply. Handle minor
   findings according to the stopping rules below.
4. Evaluate each fix in the surrounding project, add regression coverage,
   and rerun affected checks before pushing.
5. Repeat until a stopping criterion is met.
6. Merge without asking again once the stopping criterion is met, required
   checks pass on the latest commit, and no unresolved blockers or required
   human review requests remain.

### Reviewer context limits

The automated PR reviewer does not see the user's original prompt or
conversation. It may suggest changes that go against or beyond what the
user asked for. Do not implement such suggestions. Note each conflict and
report it to the user at the end of the thread.

### Automated review stopping rules

Judge findings by verified impact, not the reviewer's severity label.
Important findings concern correctness, security, data loss, broken builds,
or materially degraded behavior/performance.

Track completed review rounds and consecutive rounds without important
findings. Reruns of the same revision and integration failures do not count.

- No applicable actionable feedback: finish immediately.
- First minor-only round: optionally fix worthwhile, low-risk findings.
  Do not manufacture another push merely to obtain another review.
- Two consecutive rounds without important findings: stop responding to
  automated nitpicks, even if actionable minor suggestions remain.
  Defer worthwhile leftovers rather than continuing the cycle.
- A confirmed important finding resets the minor-only streak. Address it
  and verify the fix before continuing.

After ten completed rounds, enter stabilization:

- Stop optional cleanup, refactoring, and nitpick fixes.
- One completed review without confirmed important findings is sufficient
  to finish, even if minor suggestions remain.
- Continue only for confirmed important defects. If resolving them stalls,
  report the blockers rather than continuing indefinitely.

These limits end optional automated-feedback work. They do not waive
confirmed blockers, unresolved human review requests, or required checks.

### Reviewer integration failures

After two consecutive reviewer-integration failures, stop and report the
review gap. Do not treat failures as approval. An explicit user instruction
may waive review; report that waiver rather than claiming review passed.

## Ending a task

- A task ends with its changes merged to main — not with code written,
  and not with a PR merely opened. An open PR is work in progress:
  monitor CI on the latest commit, address review findings per the
  stopping rules, and merge once the criteria are met.
- Never finish with uncommitted changes or unpushed commits in the
  worktree. Commit, push, and open or update the PR first.
- If a step is impossible (missing push access, CI failure, reviewer
  outage), report the exact blocker instead. Never present unreviewed or
  unmerged work as finished.
- Before finishing, confirm: the requested behavior is implemented
  without unrelated changes; relevant checks pass on the latest code;
  important review findings are addressed or rejected with reasons;
  deferred suggestions, remaining risks, and validation gaps are
  disclosed.
- The final response states where the work stands: branch, PR, CI
  status, review rounds completed, and whether it is merged.

<!-- shared-rules:end -->

