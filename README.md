# Greptile HUD

A hold-to-peek macOS control center for all your open PRs' Greptile reviews.

The repo also contains `backend/`: a Go + Postgres service ("vibecoders") that
tracks a devtime leaderboard for the crew, deployed on Render. See
`backend/README.md` for setup and API docs.

## Landing page and hosting

- `backend/site/` — the landing page (the funny one), embedded into the Go
  binary and served at `/` alongside the API. Its download button always
  points at the latest GitHub Release via
  `releases/latest/download/GreptileHUD.zip`.
- `goathud.com` is a CNAME to `greptile-hud.onrender.com`; add the domain in
  Render's Custom Domains settings and the TLS cert is issued automatically.
- `render.yaml` — a Render Blueprint that deploys the whole stack in one
  "connect repo" step: the Go backend (API + landing page) and Postgres.
  See `backend/README.md` for the GitHub OAuth app setup it expects.

**Hold Right Shift** → a translucent overlay appears showing every open PR you
authored, with its latest Greptile **Confidence Score**, whether it's **currently
re-reviewing** (👀), and **how long** it's been reviewing. Release Right Shift to
hide — *unless* you keep holding: **hold for 1.2 seconds and the HUD latches
open** and stays up after you let go. A ring around the pin icon in the header
fills as you hold, then stays lit while latched. Unlatching is a single click on
that pin (or Esc, or the ✕) — no holding required. Click a row to open the PR; click the ↻ button to trigger a fresh review
(posts `@greptile`); click **Merge** on a perfect-score PR to squash-merge it.

The HUD wears **Tokyo Night**, with a live clock in the header and the session
uptime along the bottom.

**Move it and size it.** Drag the HUD by any empty part of its background to
reposition it, and drag the ⤡ grip in the bottom-right corner (or any window
edge) to resize. It reopens exactly where and how you left it; menu-bar ▸ **Reset
Position & Size** puts it back to centred and default-sized. Width has a floor at
the default — the header and tab bar can't compress further without clipping —
but it grows freely, and height shrinks too.

Slow fetches show their work: first load draws shimmering placeholder cards in
the shape of the real rows, the Actions column runs a sweep line under its header
while re-fetching, and anything you click that needs data (refresh, merge, build
train, the Mine/Everyone switch) shows a spinner in place.

No tokens to paste — it uses your existing `gh` CLI auth.

## What each card shows

| Element | Meaning |
|---|---|
| Big number badge | Latest `Confidence Score: N/M` (green ≥80%, yellow ≥60%, orange ≥40%, red below). `—` = no review yet, spinner = first review running |
| `owner/repo #123` | The PR, click anywhere on the row to open it in your browser |
| `· N reviews` | How many times Greptile has reviewed (from its summary footer) |
| Blue **reviewing · 2m 13s** + spinner | A 👀 reaction is live on a comment — Greptile is re-reviewing right now; timer counts from when the 👀 appeared |
| ↻ button | Posts an `@greptile` comment to re-trigger a review |
| Green **Merge** button | Only on a **perfect score** (e.g. 5/5) that GitHub will actually accept. Click once to arm, once more to confirm — it squash-merges the PR |
| Orange pill (`conflicts`, `blocked`, `draft`) | Why GitHub won't merge this one right now |

PRs that are actively re-reviewing sort to the top.

> **Latest review, not duplicate reviews.** Re-tagging `@greptile` sometimes makes
> it post a *second* review comment instead of editing the first, leaving two
> Greptile comments on the PR. The HUD reads the score/review-count from whichever
> Greptile comment was **edited (`updated_at`) most recently** — Greptile revises its
> review in place — so you always see the current one, not whichever was posted last.

## Merge trains (the Train tab)

Merging five PRs one at a time means five CI runs and five deploys stepping on
each other. The **Train** tab lands several PRs together instead, in one of two
modes.

### Stack — GitHub's stacked pull requests

Points each selected PR at the branch of the one below it, so they form a
[stacked pull request](https://docs.github.com/en/pull-requests/reference/stacked-pull-requests)
chain ending at the trunk. Every PR keeps its own diff, review and history, and
GitHub draws the stack map in each PR's merge box.

- **Order** is confidence-first: the highest Greptile score sits at the bottom,
  so if you land only part of the stack, the safest part lands first.
- **Nothing is merged and no branch is rewritten** — stacking only changes which
  branch each PR targets. **Flatten** points them all back at the trunk, so it's
  fully reversible.
- The HUD shows any stack it detects (including ones you made elsewhere) with its
  layers top-down, each layer's merge blockers, a link to the top PR, and Flatten.
- File overlap is a *warning* here rather than a blocker: nothing merges at
  stack time, and GitHub reports each layer's mergeability afterwards.

Two caveats worth knowing. Stacked PRs are **public preview** and same-repo only
(no cross-fork). And the HUD has no local clone, so it builds a *logical* chain —
it re-points bases but cannot rebase the branches onto each other. GitHub's
one-shot stack merge wants linear history between layers, so a HUD-built stack
may not qualify for it; for a genuinely rebased stack use the official
[`gh stack`](https://github.com/github/gh-stack) CLI extension, which does the
local rebases. If you want a guaranteed single pipeline, use Combine.

### Combine — one branch, one PR

Merges the selected PRs onto **one throwaway branch and one pull request**, so
the pipeline runs exactly once regardless of what GitHub supports.

- **Candidates** are grouped by *repo + base branch* — a train is one branch on
  one pipeline, so PRs targeting different bases can never combine. Groups with
  fewer than two mergeable PRs don't appear.
- **Compatibility** is decided by the files each PR touches: two PRs that change
  the same file are flagged (`shares 2 files with #41`) and the **Build train**
  button stays disabled until you drop one of them.
- **Smart select** takes the largest group and walks it confidence-first (5/5
  before 3/5), adding every PR that doesn't touch an already-claimed file. PRs
  with a review still running are skipped — their score isn't settled yet.
- **Build train** (Combine mode) then, entirely through the GitHub API:
  1. cuts `greptile-hud/train-<timestamp>` from the base branch;
  2. merges each selected PR's head branch into it server-side;
  3. opens one combined PR listing everything on board; and
  4. drops a "🚄 riding the merge train" comment on each source PR.

A PR that unexpectedly conflicts is left behind and reported rather than
failing the whole train. If nothing lands, or the combined PR can't be opened,
the scratch branch is deleted — no debris. The source PRs stay open and close
themselves as their commits reach the base branch.

## Your Actions column (GitHub Actions / CI)

When you have CI runs you kicked off — a **merge**, push, PR, or manual dispatch — a
**Your Actions** column appears on the right listing them:

| Element | Meaning |
|---|---|
| Workflow name + commit/PR title | The run; click to open it on GitHub |
| Blue **running** + spinner + timer | In-flight — the timer counts up from when the run started |
| Cyan **↳ step · 8/14** + bar | Which step it's on right now, and how far through the job |
| Red **⊘ step · 5/7** | For a failed run, the step it died on |
| **@login** chip | Who owns the run — blue for yours, yellow for other people's. Always shown in **Everyone** mode, and on other people's runs in either mode |
| **×3** badge | Repeat runs of the same workflow, stacked into one row |
| Green **success** / red **failure** + duration | Finished — shows how long it took (kept ~30 min) |
| Tooltip | `job — step` on the step line, `branch · event` on the row |

**Mine / Everyone toggle.** By default the column shows only runs you set off.
Flip it to **Everyone** to watch the whole queue — useful when your deploy is
stuck behind someone else's. The toggle then reads **Queue · N** with the number
of other people's runs currently in flight, and their rows carry an `@login`
chip. Your own runs still sort first. The choice sticks across launches.

Step detail costs one extra API call per run, so it's only fetched for runs that
are in flight or failed (capped at 10 per refresh, in-flight first).

**Stacked duplicates.** Busy repos fire the same workflow over and over, one per
push. Repeat runs of the same workflow *in the same state* collapse into a single
row showing the **oldest** of the bunch — the one furthest along and nearest the
front of the queue — badged `×3`, with the extras peeking out behind the card.
Failures never merge into the running pile, so a red run can't hide inside a blue
one. Rows sort in flight first, then failures, then successes; yours ahead of
other people's within each.

**While the HUD is open** it polls every 12 seconds instead of once a minute, so
run state and steps stay live. Only the Actions column re-fetches on that
cadence — the much more expensive PR sweep still runs about once a minute, which
keeps the whole thing well inside GitHub's rate limit.

Running actions sort to the top. Cron/`schedule` and other non-you triggers are
filtered out, so it's only the work you set off.

**Which repos it watches:** every repo with an open PR of yours, *plus* the repos
you recently merged into — the CI from a merge is the run you most want to watch,
and by then the PR that named the repo is closed. If you have neither (you pushed
straight to a branch), it falls back to the repos in your recent push events. The
list is capped at 8 repos per refresh.

## Requirements

- `gh` CLI, logged in (`gh auth status` should show ✓) — already set up on this machine
- macOS 13+

## Build

```bash
./build.sh
open GreptileHUD.app
```

## Vibecoders (the social layer)

The **Crew tab** in the HUD overlay (and a section in the menu-bar menu) is the
vibecoders integration with the `backend/` service:

- **Pick a username** — no GitHub sign-in, no OAuth, no tokens. You choose the
  name shown on the leaderboard and we take your word for it (there's no
  authentication or code tracking at all; identity lives only in
  UserDefaults, cleared by "Forget username").
- **Online now** — who's been active in the last 5 minutes, with today's
  devtime.
- **Leaderboard** — today's devtime, refreshed every minute.
- **Devtime tracking** — while Cursor, VS Code, iTerm2, Terminal, Ghostty, etc.
  are running, the app sends a heartbeat every 60s so the backend accrues
  devtime (this replaces the standalone `backend/client/devtime.sh` agent if
  you run the HUD app). The heartbeat sends only your username, the app name,
  and a timestamp — no code, no keystrokes, no repo data.

Menu-bar: Vibecoders ▸ Join the devtime leaderboard, Online now, Leaderboard,
Refresh, Change username, Forget username.

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
- one GraphQL call per PR fetches the head-commit time, the Greptile check-run
  state, and the merge metadata (base/head branch, `mergeable`,
  `mergeStateStatus`, changed files) behind the merge button and trains
- the ↻ button posts `@greptile` as an issue comment
- the merge button calls `PUT /repos/<repo>/pulls/<n>/merge` (squash)
- a merge train uses `POST /git/refs`, `POST /merges` per PR, then
  `POST /pulls` for the combined PR
- `repos/<repo>/actions/runs?actor=<you>` per open-PR repo → your CI runs for the
  **Your Actions** column (filtered to merge/push/PR/dispatch events)

## Tuning

- **Hotkey**: Right Shift is keyCode `60` in `Sources/main.swift` → `handleFlags`.
  Left Shift is `56`, Right Option is `61`, etc.
- **Hold-to-latch delay**: `HUDState.latchDelay` (1.2s) in `Sources/HUDView.swift`.
- **Actions step detail**: `GH.jobsJQ` / `fetchRunProgress` in `Sources/GitHub.swift`.
- **Refresh interval**: 60s background timer in `applicationDidFinishLaunching`;
  12s while the overlay is open (`startLiveRefresh` → `PRStore.refreshLive`).
- **Score regex / parsing**: `commentsJQ` in `Sources/GitHub.swift`.
- **Colors**: the whole palette lives in `Sources/Theme.swift` (`Tokyo`), so a
  re-tint is a one-file change.
- **Merge method**: `GH.mergePR` squash-merges; change `merge_method` there for
  merge commits or rebases.
- **Train compatibility rule**: `PRStore.overlap` in `Sources/GitHub.swift`.
- **Stack detection**: `PRStore.detectedStacks`; stack building is
  `GH.buildStack` / `GH.unstack` (both plain `PATCH …/pulls/{n}` base changes).
