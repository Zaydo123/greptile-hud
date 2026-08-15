# Greptile HUD Development Guide

These instructions apply to the entire repository.

## Project overview

Greptile HUD is a native macOS menu-bar app written in Swift and SwiftUI. It is
built directly with `swiftc`; there is no Xcode project, Swift package, or
third-party dependency manager.

The app:

- uses the authenticated `gh` CLI for pull-request and GitHub Actions data;
- appears as a borderless overlay when Right Shift is held;
- can also be pinned from its menu-bar item;
- checks GitHub Releases for updates without a separate update server.

## Repository layout

- `Sources/main.swift`: app lifecycle, menu-bar item, overlay panel, hotkey, and
  updater entry points.
- `Sources/HUDView.swift`: SwiftUI layout and presentation.
- `Sources/Models.swift`: shared data models.
- `Sources/GitHub.swift`: `gh` command runner, GitHub queries, and `PRStore`.
- `Sources/Vibecoders.swift`: vibecoders store — devtime heartbeats, leaderboard
  fetches, and trust-based username handling (no OAuth, no tokens).
- `Sources/Updater.swift`: GitHub Releases checking, validation, installation,
  and relaunch logic.
- `backend/`: Go + Postgres "vibecoders" service (devtime leaderboard API and
  embedded landing page) deployed on Render via `render.yaml`. Identity is
  trust-based: users self-choose a username; there is deliberately no
  authentication, OAuth, or GitHub activity tracking. See `backend/README.md`.
- `Info.plist`: bundle metadata and source-of-truth version for local builds.
- `build.sh`: universal macOS build and ad-hoc signing.
- `scripts/next-version.sh`: deterministic automatic patch-version selection.
- `.github/workflows/ci.yml`: pull-request and branch build validation.
- `.github/workflows/release.yml`: automatic GitHub Release publishing from
  app changes on `main`.
- `README.md`: user-facing setup and release documentation.

`GreptileHUD.app/` is generated build output and must not be committed.

## Development workflow

1. Inspect the existing implementation before editing. Preserve unrelated user
   changes in a dirty worktree.
2. Keep the app compatible with Swift 5 language mode and macOS 13 or newer.
3. Avoid new dependencies unless the task genuinely requires one. The current
   single-script build is intentional.
4. Build using:

   ```bash
   ./build.sh
   ```

5. For a local smoke test:

   ```bash
   open GreptileHUD.app
   ```

   Be mindful that launching a fresh build may display the Accessibility
   permission prompt. Do not automate clicks in System Settings.

## Required verification

Run checks proportional to the change. Before handing off a normal code change,
at minimum run:

```bash
bash -n build.sh
plutil -lint Info.plist
./build.sh
codesign --verify --deep --strict GreptileHUD.app
git diff --check
```

For build, updater, deployment-target, or release changes, also verify:

```bash
file GreptileHUD.app/Contents/MacOS/GreptileHUD
vtool -show-build GreptileHUD.app/Contents/MacOS/GreptileHUD
```

The binary must contain both `arm64` and `x86_64`, and both slices must report a
minimum macOS version of `13.0`.

For updater or packaging changes, reproduce the release archive and validate the
extracted app:

```bash
rm -rf /tmp/greptile-hud-release-check /tmp/GreptileHUD.zip
mkdir -p /tmp/greptile-hud-release-check
ditto -c -k --sequesterRsrc --keepParent GreptileHUD.app /tmp/GreptileHUD.zip
shasum -a 256 /tmp/GreptileHUD.zip
ditto -x -k /tmp/GreptileHUD.zip /tmp/greptile-hud-release-check
codesign --verify --deep --strict /tmp/greptile-hud-release-check/GreptileHUD.app
```

## UI invariants

- The overlay has a fixed outer size of `828 × 608` points, derived from the
  constants in `HUDMetrics`.
- Do not restore fitting-size measurement or resize the panel based on PR count,
  stale visibility, error text, or the presence of Actions runs.
- Lists should scroll inside the fixed canvas.
- Keep primary controls comfortably clickable. Disclosure rows and other
  full-row actions should use an explicit content shape and a hit height around
  40 points or more.
- Preserve safe URL handling: GitHub-provided links should only open through the
  existing HTTP/HTTPS validation helper.

## GitHub updater invariants

The updater is intentionally tied to GitHub repository
`Zaydo123/greptile-hud` and expects every release to contain exactly:

- `GreptileHUD.zip`
- `GreptileHUD.zip.sha256`

Do not rename these assets in only one location. Any naming change must be made
together in `Sources/Updater.swift`, `.github/workflows/release.yml`, and the
documentation.

The updater must continue to:

- use HTTPS GitHub release URLs;
- compare the release tag against `CFBundleShortVersionString`;
- verify the SHA-256 checksum before extraction;
- verify the bundle identifier, version, executable, and code signature;
- stage the new app beside the installed app;
- preserve or restore the old bundle if the swap fails;
- relaunch only after the current process exits.

Automatic checks should stay quiet when there is no update or a background check
cannot reach GitHub. User-initiated checks should report their result.

## Versions, tags, and releases

Releases use semantic versions and tags in the form `vMAJOR.MINOR.PATCH`, for
example `v1.2.0`.

Routine releases are automatic. When app code, build configuration, metadata, or
the CI/release workflows change on `main`, `.github/workflows/release.yml`:

1. reads the major/minor release line from `Info.plist`;
2. chooses the next patch after the latest published release using
   `scripts/next-version.sh`;
3. builds and validates the app;
4. creates the tag at the exact triggering commit; and
5. publishes the zip and checksum through GitHub Releases.

Do not manually tag routine patch releases. For an intentional major or minor
release, set both `CFBundleVersion` and `CFBundleShortVersionString` in
`Info.plist` to the desired new baseline (for example `1.2.0`) before merging.
The release workflow will use that baseline, then auto-increment subsequent
patches.

After publishing, verify the workflow and assets:

```bash
gh run list --workflow release.yml --limit 5
gh release view --json tagName,url,assets
```

Do not create, move, or delete tags, push commits, or publish releases manually
unless the user explicitly asks for recovery or exceptional release work. Never
reuse a published version tag.

## Signing note

Local and current CI builds are ad-hoc signed. Keep signature validation in place,
but do not describe the build as Developer ID signed or notarized. Adding Apple
Developer ID signing/notarization requires explicit certificate and secret setup
and should be handled as a separate release-engineering change.

## Documentation expectations

Update `README.md` whenever a user-visible workflow, requirement, hotkey, update
behavior, or release command changes. Keep this file focused on maintainer and
agent instructions; keep end-user explanations in the README.
