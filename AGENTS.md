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

- `Sources/Theme.swift`: the Tokyo Night palette (`Tokyo`) and the Cowboy Bebop
  flavour text (`Bebop`). All HUD colors come from here — do not reintroduce raw
  `.blue`/`.purple`/`.white.opacity(…)` colors in views.
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

- The overlay opens at `828 × 608` points (the `HUDMetrics` defaults) and is
  **user**-resizable from there: corner grip, window edges, and drag-to-move,
  with the frame remembered in UserDefaults.
- That is the only sizing input. Do not restore fitting-size measurement or size
  the panel from PR count, stale visibility, error text, or the presence of
  Actions runs — content never moves the window.
- `HUDMetrics.minContentWidth` is pinned to the default width on purpose: the
  header and tab bar clip below it. If you make that chrome compress cleanly,
  lower the floor then — not before.
- Lists should scroll inside the fixed canvas.
- Keep primary controls comfortably clickable. Disclosure rows and other
  full-row actions should use an explicit content shape and a hit height around
  40 points or more.
- Preserve safe URL handling: GitHub-provided links should only open through the
  existing HTTP/HTTPS validation helper.
- Colors come from `Tokyo` in `Sources/Theme.swift`, never from raw SwiftUI
  system colors or white overlays.
- The header is width-critical when the Actions column is visible: pills and
  badges there need `.fixedSize()` so they can't wrap or collapse. Put new
  flavour text in the footer, not the header.

## Actions column

The repo set for `PRStore.refreshRuns` is deliberately wider than "repos with an
open PR": open-PR repos, then recently merged repos, then (only if both are
empty) repos from your push events. An Actions column that goes dark the moment
your last PR merges is a bug, not a simplification. Keep the 8-repo cap — this
runs every 60 seconds.

Step detail (`GH.fetchRunProgress`) is one API call per run, so fetch it only
for runs that are running or failed, keep the per-refresh cap, and always render
the run list before enriching it — the column must never wait on step lookups.

The Mine/Everyone actor toggle is persisted in UserDefaults and re-fetches on
change. "Everyone" drops the `actor=` query filter; it must not drop the
human-trigger event filter, or the column fills with cron noise.

Run stacking lives in `RunStack.stacks(from:)` (Models.swift), not the view, so
it stays testable. Runs only ever collapse within the same repo + workflow +
state; never merge differing states into one row.

## Loading states

Anything that fetches on click must say so in place: skeleton rows for a first
load (`PRCardSkeleton` / `RunRowSkeleton`), `IndeterminateBar` under a section
re-fetching, or an inline spinner on the control that was clicked. Don't leave a
clicked control looking idle while its request is in flight.

## Stacked pull requests

Stack mode is built entirely from base-branch changes (`PATCH /repos/…/pulls/{n}`
with `base`) — that *is* GitHub's definition of a stack, so no preview API is
involved. Hold the line on these:

- Stacking must never merge anything or rewrite a branch. The only mutation is
  each PR's base, which is what makes `flatten` a complete undo. If you find
  yourself force-pushing a contributor's branch to "rebase the stack", stop —
  that belongs in the official `gh stack` CLI, which has a local clone.
- The HUD cannot rebase, so it produces a logical chain, not a rebased one. Don't
  claim in UI or docs that GitHub's one-shot stack merge is guaranteed to apply.
- `detectedStacks` reconstructs chains from live PR data (a PR whose base is
  another open PR's head). Keep the cycle guard on the walk.
- Combine mode stays the guaranteed one-pipeline path; don't remove it in favour
  of stacks while stacked PRs are in public preview.

## Overlay show/hide invariants

- A short Right-Shift hold is a peek: shown on press, hidden on release.
- Pressing Right Shift while the HUD is latched closes it — the key toggles.
- Holding past `HUDState.latchDelay` (1.2s) latches the overlay open so it
  survives the release. Unlatching is deliberately *not* a hold — one click on
  the pin (or Esc, or ✕). The latch is the same `pinned` state the menu item and
  Esc already drive; don't add a second source of truth.
- `HUDState` mirrors that state (plus `holdStartedAt`) purely so the header can
  draw the fill ring. It is display state — the app delegate owns the behavior.

## Merge and merge-train invariants

Merging is irreversible and outward-facing, so:

- The card **Merge** button appears only when `PR.canQuickMerge` holds — a
  perfect Greptile score, GitHub-mergeable, and not mid-review. Do not widen
  that condition without an explicit request.
- Both merge entry points stay two-step: the card button arms then confirms;
  a train is assembled only from an explicit selection plus a **Build train**
  click. Never merge or open a PR as a side effect of a refresh, a hover, or a
  tab switch. The one deliberate exception is the assembled train itself: once
  the combined PR exists (via that explicit Build train click), landing it is
  one click — the **Merge train** button on the result card or its Open-train
  card. Don't extend one-click merging beyond the combined train PR.
- A train doesn't end at assembly. `PRStore.activeTrains` remembers open
  trains across launches; when a combined PR lands (here or merged on the web,
  noticed by `syncTrains`), still-open source PRs are closed with a
  "Landed via merge train" comment and the scratch branch is deleted.
  `GH.mergeTrain` prefers a real merge commit so GitHub marks source PRs
  merged itself, falling back to squash (then explicit closes) on squash-only
  repos. Trains are dropped after 7 days, or at once if their combined PR
  closes unmerged.
- Train assembly must stay self-cleaning: if no PR lands, or the combined PR
  can't be opened, delete the scratch branch (`greptile-hud/train-<stamp>`)
  before returning. A single conflicting PR is skipped and reported, not fatal.
- Train candidates are grouped by repo **and** base branch; compatibility is
  file-overlap based (`PRStore.overlap`). Building is blocked while
  `selectionConflicts` is non-empty.
- The head GraphQL query asks for `mergeStateStatus` behind the merge-info
  preview header and falls back to a query without it. Keep that fallback —
  losing the query outright would also lose the commit date and review state.

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
4. preserves the zip and checksum as a 30-day workflow artifact; and
5. creates the tag at the exact triggering commit and publishes the assets when
   release write access is available.

The workflow uses only the short-lived repository token. Do not add a personal
release token; repository policy should grant the workflow contents write access.
Publication failure must leave the verified artifact available and produce a
workflow warning instead of failing the completed build.

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
