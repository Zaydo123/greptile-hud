# Greptile HUD backend ("vibecoders")

Devtime tracker + social leaderboard service for the Greptile HUD crew. A
single Go binary that:

- tracks devtime: the macOS app (or the small agent in `client/`) heartbeats
  while an editor/terminal is running, and the server accrues the time;
- exposes a devtime leaderboard and an "online now" feed over a small REST API;
- shares explicitly started crew statuses until their owners stop them, and
  keeps each user's completed status history;
- stores optional profile photos and per-day app/site usage totals.

Identity is trust-based: a user is just a self-chosen username. There is no
GitHub OAuth, no tokens, no sessions, and no GitHub activity tracking (no
commits, LOC, or PRs). Anyone can claim any username — we take your word for it.

The frontend is the Greptile HUD Swift app (this repo), not a website. The API
is consumed by the app and by `client/devtime.sh`. The landing page
(`site/index.html`) is embedded into the binary and served at `/`, so
`goathud.com` (CNAME → `greptile-hud.onrender.com`) serves marketing + API
from the same service.

## Stack

- Go (stdlib `net/http` + `database/sql`) and Postgres via `github.com/lib/pq`
  — the only dependency.
- Postgres is required: SQLite would not survive Render's ephemeral disk.
  The schema in `schema.sql` is applied automatically at startup.

## API

No auth headers anywhere — the username identifies the user.

| Method | Path                                   | Description                                  |
| ------ | -------------------------------------- | -------------------------------------------- |
| GET    | `/api/health`                          | liveness + db check                          |
| GET    | `/api/user?login=name&period=today\|week\|month\|all` | profile + activity totals, sprints, daily series, status activities |
| GET    | `/api/online`                          | users with a heartbeat in the last 5 minutes |
| GET    | `/api/leaderboard?period=today\|week\|month\|all` | devtime leaderboard (default `today`) |
| GET    | `/api/statuses`                        | all explicitly running crew statuses         |
| POST   | `/api/status`                          | set an active emoji/message status            |
| DELETE | `/api/status`                          | clear the active status                       |
| POST   | `/api/pulse`                           | activity heartbeat with username and app name |
| GET    | `/api/avatar?login=name[&v=…]`         | profile photo bytes (404 when none)           |
| PUT    | `/api/avatar`                          | upload/replace the profile photo              |
| DELETE | `/api/avatar`                          | remove the profile photo                      |
| POST   | `/api/usage`                           | add app/site usage seconds for today          |
| GET    | `/api/usage?login=name&period=…`       | one user's usage breakdown                    |
| GET    | `/api/usage/crew?period=…`             | crew-wide usage, top 25 items                 |
| POST   | `/api/status/history`                  | upsert completed status sessions              |
| GET    | `/api/status/history?login=name&limit=100` | completed sessions, newest first          |
| DELETE | `/api/status/history`                  | delete one completed session                  |

`POST /api/status` accepts `user`, `emoji`, `message`, and `started_at`.
`DELETE /api/status` accepts `user`. At least an emoji or message is required
when setting a status.

Every user-shaped object (`/api/user`'s `user`, and each entry of
`/api/online`, `/api/leaderboard` and `/api/statuses`) carries `avatar_url`: a
relative, cache-busted path such as `/api/avatar?login=zayd&v=1730100000`, or
`null` when the user has no photo.

### Profile photos

`PUT /api/avatar` takes `{"user", "image"}` where `image` is standard base64 of
a PNG or JPEG. The decoded file must be at most 300 KB and 16–1024 px on each
side, and the served `Content-Type` comes from the decoded format, never the
client. It responds with `{"ok": true, "avatar_url": "…"}`. `DELETE /api/avatar`
takes `{"user"}` and is idempotent. `GET /api/avatar` serves the bytes with a
one-day public cache; the `v` parameter only busts client caches.

### App and site usage

The Mac app maps the frontmost app or the active browser tab's host to a key
from a fixed catalog (`catalog.go`) on the Mac and sends only that key —
anything outside the catalog is sent as `other`. The server validates keys
against the same catalog and folds unknown ones into `other`.

`POST /api/usage` takes `{"user", "usage": [{"key", "seconds"}]}` about once a
minute. Each item is clamped to 0–600 seconds, zero items are dropped and
duplicate keys are summed; more than 64 items or a total above 900 seconds is
rejected with 400. Time is added to the current crew day. Usage is not
presence: it never updates `last_seen`.

`GET /api/usage?login=&period=` returns `total_seconds` and `items`
(`key`, `label`, `category`, `seconds`) sorted by seconds then key, and 404s
for an unknown user. `GET /api/usage/crew?period=` aggregates every user,
adds `people` (distinct users) per item, and lists the top 25 items.

### Status history

Completed status sessions are stored server-side so history follows the user
across Macs. `POST /api/status/history` takes `{"user", "sessions": [{"id",
"emoji", "message", "started_at", "ended_at"}]}` (1–200 sessions). `id` is the
app's UUID for the session, so re-uploads and renames upsert. Sessions with an
invalid UUID, emoji/message, a non-positive or over-7-day duration, or a start
more than 5 minutes in the future are skipped; the response reports
`stored` and `skipped`, and the request fails only when every session is
invalid. `DELETE /api/status/history` takes `{"user", "id"}`.
`GET /api/status/history?login=&limit=` (1–500, default 100) lists sessions
newest first; ids come back lowercased.

### Profile detail

`GET /api/user` also returns `daily` — devtime per crew day, including zero
days, covering every day of the selected period (the last 30 crew days for
`all`) — and `activities` — status time per emoji (`emoji`, `seconds`,
`count`) for history sessions overlapping the period plus the running status,
clipped to the period and to now.

## How devtime works

Heartbeats accrue the elapsed time between beats, capped at 10 minutes and
ignored under 30 seconds. Online = heartbeat within 5 minutes. The leaderboard
shows today's seconds by default. `period=week` uses Monday through Sunday,
`period=month` uses the Central Time calendar month, and `period=all` sums every
recorded day. All bounded periods use shared `America/Chicago` dates and include `period_start`,
`period_end`, and `timezone` so clients can display the exact boundary.

## How sprints work

A sprint is a continuous activity session. The first qualifying heartbeat opens
one, subsequent heartbeats extend it, and a gap longer than 10 minutes starts a
new sprint. Sprint data uses the last observed activity as the end time; no idle grace period is
added. Sprint history begins when this schema is deployed, cannot be
reconstructed from older daily totals, and is retained for 90 days. The server
stores session boundaries and duration, not individual heartbeat events, code,
keystrokes, or repository data. Profile responses return at most the latest 250
sprints of at least one minute in the selected period.

## Running locally

```bash
createdb vibecoders   # or point DATABASE_URL at any postgres
export DATABASE_URL=postgres://localhost:5432/vibecoders
go run .
```

Run the unit tests (pure logic, no database needed) with:

```bash
go test ./...
```

No GitHub app, no secrets, no tokens.

## Deploying on Render

The root `render.yaml` blueprint deploys everything (backend at
`https://greptile-hud.onrender.com`, landing page, Postgres) in one connect.
There are no manual secret steps: the blueprint wires `DATABASE_URL` and
enables the `/api/health` check automatically. If an old hand-made
`greptile-hud` service exists, delete it first so the blueprint can take over
the name (and URL). The Dockerfile deliberately lives at the repo root because
Render builds this service from the repository root (it ignores `rootDir` for
Docker build contexts).

## Devtime agent on your Mac

The agent is a shell script that heartbeats while a dev app runs:

```bash
VC_API_URL=https://greptile-hud.onrender.com \
VC_USER=zayd \
./client/devtime.sh
```

For it to survive reboots, install `client/launchd-example.plist` as a
LaunchAgent (edit the path, URL, and username first).

Watched apps: Cursor, VS Code (and Insiders), iTerm2, Terminal, Ghostty, Warp,
WezTerm, Alacritty, kitty, Neovide — override with `VC_APPS`.

## Notes and caveats

- Identity is unauthenticated on purpose: anyone can claim a username or add
  devtime to someone else's name. It's a vibes leaderboard, not a payroll
  system. If that ever matters, add real auth then.
- What the server stores: the username, devtime heartbeat timing, the active
  status (emoji, message, start time) while it runs, completed status sessions
  (emoji, message, start and end time — stored server-side at the user's
  request), an optional user-uploaded profile photo, and app/site usage.
- Usage is only catalog keys plus seconds per crew day. App names, bundle
  IDs, URLs, page titles and window titles never leave the Mac; anything
  outside the catalog is recorded as `other`.
- Profile photos are images the user chose to upload. They are public to anyone
  who knows the username, like everything else here.
- No code, keystrokes, or repo data is ever sent.
