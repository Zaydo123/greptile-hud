# Greptile HUD

A hold-to-peek macOS control center for all your open PRs' Greptile reviews.

The repo also contains `backend/`: a Go + Postgres service ("vibecoders") that
tracks devtime and GitHub activity leaderboards for the crew, deployed on
Render. See `backend/README.md` for setup and API docs.

## Landing page and hosting

- `site/` — a static landing page (the funny one) with a download button that
  always points at the latest GitHub Release via
  `releases/latest/download/GreptileHUD.zip`. Point `goathud.com` at its Render
  URL (or use the default `*.onrender.com`).
- `render.yaml` — a Render Blueprint that deploys the whole stack in one
  "connect repo" step: the Go backend, the landing page, and Postgres.
  See `backend/README.md` for the GitHub OAuth app setup it expects.

**Hold Right Shift** → a translucent overlay appears showing every open PR you
authored, with its latest Greptile **Confidence Score**, whether it's **currently
re-reviewing** (👀), and **how long** it's been reviewing. Release Right Shift to
hide. Click a row to open the PR; click the ↻ button to trigger a fresh review
(posts `@greptile`).

No tokens to paste — it uses your existing `gh` CLI auth.

## What each card shows

| Element | Meaning |
|---|---|
| Big number badge | Latest `Confidence Score: N/M` (green ≥80%, yellow ≥60%, orange ≥40%, red below). `—` = no review yet, spinner = first review running |
| `owner/repo #123` | The PR, click anywhere on the row to open it in your browser |
| `· N reviews` | How many times Greptile has reviewed (from its summary footer) |
| Blue **reviewing · 2m 13s** + spinner | A 👀 reaction is live on a comment — Greptile is re-reviewing right now; timer counts from when the 👀 appeared |
| ↻ button | Posts an `@greptile` comment to re-trigger a review |

PRs that are actively re-reviewing sort to the top.

> **Latest review, not duplicate reviews.** Re-tagging `@greptile` sometimes makes
> it post a *second* review comment instead of editing the first, leaving two
> Greptile comments on the PR. The HUD reads the score/review-count from whichever
> Greptile comment was **edited (`updated_at`) most recently** — Greptile revises its
> review in place — so you always see the current one, not whichever was posted last.

## Your Actions column (GitHub Actions / CI)

When you have CI runs you kicked off — a **merge**, push, PR, or manual dispatch — a
**Your Actions** column appears on the right listing them:

| Element | Meaning |
|---|---|
| Workflow name + commit/PR title | The run; click to open it on GitHub |
| Blue **running** + spinner + timer | In-flight — the timer counts up from when the run started |
| Green **success** / red **failure** + duration | Finished — shows how long it took (kept ~30 min) |
| Tooltip | `branch · event` (e.g. `main · push`) |

Running actions sort to the top. Cron/`schedule` and other non-you triggers are
filtered out, so it's only the work you set off.

## Requirements

- `gh` CLI, logged in (`gh auth status` should show ✓) — already set up on this machine
- macOS 13+

## Build

```bash
./build.sh
open GreptileHUD.app
```

## Updates and releases

Greptile HUD checks GitHub Releases shortly after launch and every six hours
while it remains open. You can also use the menu-bar icon ▸ **Check for
Updates…**. Choose **Install Update** and the app downloads the release from
GitHub, verifies its SHA-256 checksum, bundle identity, version, and signature,
replaces itself safely, and relaunches. There is no zip extraction or manual app
swapping, and no update server is required.

Pull requests and non-main branches are compiled by `.github/workflows/ci.yml`.
When an app change reaches `main`, `.github/workflows/release.yml` automatically:

- chooses the next patch version after the latest GitHub Release;
- builds and validates the universal Intel/Apple Silicon app;
- creates the version tag and GitHub Release; and
- uploads `GreptileHUD.zip` and its checksum for the updater.

Routine releases need no manual tagging. For an intentional major/minor release,
update both version values in `Info.plist` before merging; CI continues patch
versions within that release line automatically.

## First run — grant Accessibility (one time)

Detecting a global key-hold requires Accessibility access. On first launch the
app asks for it:

1. **System Settings ▸ Privacy & Security ▸ Accessibility**
2. Enable **GreptileHUD**
3. Quit and relaunch the app (menu-bar eyes icon ▸ Quit, then `open GreptileHUD.app`)

That's the only setup. After that, just hold Right Shift anywhere.

## Menu-bar icon (the 👀)

- **Show HUD (pinned)** — keep the overlay open so you can click around without
  holding Shift (Esc or the ✕ closes it)
- **Refresh now** — force a resync (it also auto-refreshes every 60s and on every peek)
- **Check for Updates…** — check immediately; background checks also run every six hours
- **Quit**

## How it works

Everything comes from the GitHub API via `gh`:

- `gh search prs --author=@me --state=open` → your open PRs
- per PR, the issue comments from `greptile-apps[bot]` are parsed for
  `Confidence Score: N/M` and the `Reviews (N)` footer
- any comment carrying a 👀 reaction marks the PR as "reviewing"; the reaction's
  timestamp drives the live clock
- the ↻ button posts `@greptile` as an issue comment
- `repos/<repo>/actions/runs?actor=<you>` per open-PR repo → your CI runs for the
  **Your Actions** column (filtered to merge/push/PR/dispatch events)

## Tuning

- **Hotkey**: Right Shift is keyCode `60` in `Sources/main.swift` → `handleFlags`.
  Left Shift is `56`, Right Option is `61`, etc.
- **Refresh interval**: `30` seconds in `applicationDidFinishLaunching`.
- **Score regex / parsing**: `commentsJQ` in `Sources/GitHub.swift`.
