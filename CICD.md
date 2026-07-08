# CI/CD

Two GitHub Actions workflows, both on `macos-14` with Xcode pinned to **16.2**. RepoMen
has no external package dependencies; nothing is resolved or vendored.

## CI — `.github/workflows/ci.yml`

Runs on pull requests and pushes to `main` (and `claude/**` working branches).

1. Checkout, select Xcode 16.2, install `xcbeautify`.
2. `xcodebuild clean test` with `CODE_SIGNING_ALLOWED=NO`.
3. On failure, upload `TestResults.xcresult`.

Hardening: `permissions: contents: read`, per-ref concurrency that only cancels
superseded **PR** runs (never an in-progress `main` run), and a job timeout.

Local equivalent:

```bash
set -o pipefail
xcodebuild -project RepoMen.xcodeproj -scheme RepoMen \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO clean test | xcbeautify
```

## Release — `.github/workflows/release.yml`

Triggered by pushing a `v*` tag (the tag is the source of truth for the version).

1. Derive `VERSION` from the tag (`v0.2.0` → `0.2.0`).
2. **Run the test suite** — a tag on a broken commit must not publish.
3. Build Release unsigned with the version baked in.
4. **Ad-hoc sign** (`codesign --force --deep --sign -`) — required to launch on Apple
   Silicon, but **not** a Developer ID signature and **not** notarized.
5. Package a `.zip` (`ditto`) and a `.dmg` (`create-dmg`).
6. Publish a GitHub Release with both assets and Gatekeeper-bypass notes. A tag
   containing a hyphen (e.g. `v0.2.0-beta.1`) publishes as a pre-release, which the
   in-app updater ignores.

No secrets, certificates, or notarization credentials are used — distribution is
intentionally unsigned (same model as the sibling apps).

## Cutting a release

```bash
scripts/release.sh 0.2.0 --push
```

This bumps `MARKETING_VERSION` (and the README marker), commits, tags `v0.2.0`, and
pushes — which triggers the release workflow.
