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
- `Sources/Updater.swift`: GitHub Releases checking, validation, installation,
  and relaunch logic.
- `Info.plist`: bundle metadata and source-of-truth version for local builds.
- `build.sh`: universal macOS build and ad-hoc signing.
- `.github/workflows/release.yml`: tag-triggered GitHub Release publishing.
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

Before tagging a release:

1. Choose a version greater than the latest published release.
2. Set both `CFBundleVersion` and `CFBundleShortVersionString` in `Info.plist` to
   the same version without the `v` prefix.
3. Update relevant release or user documentation.
4. Run the full build and verification steps above.
5. Commit all intended source changes. The release tag must point at that commit.
6. Confirm the tag does not already exist locally or remotely.

Create and publish the release tag only when explicitly authorized to push:

```bash
git tag -a v1.2.0 -m "Greptile HUD 1.2.0"
git push origin HEAD
git push origin v1.2.0
```

Pushing the tag triggers `.github/workflows/release.yml`. The workflow strips the
leading `v`, injects that version into the built app, creates the universal zip
and checksum, then publishes both through GitHub Releases.

After publishing, verify the workflow and assets:

```bash
gh run list --workflow release.yml --limit 5
gh release view v1.2.0
```

Do not create, move, or delete tags, push commits, or publish releases unless the
user explicitly asks. Never reuse a published version tag; bump the version and
create a new tag instead.

## Signing note

Local and current CI builds are ad-hoc signed. Keep signature validation in place,
but do not describe the build as Developer ID signed or notarized. Adding Apple
Developer ID signing/notarization requires explicit certificate and secret setup
and should be handled as a separate release-engineering change.

## Documentation expectations

Update `README.md` whenever a user-visible workflow, requirement, hotkey, update
behavior, or release command changes. Keep this file focused on maintainer and
agent instructions; keep end-user explanations in the README.
