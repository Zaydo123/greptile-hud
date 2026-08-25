# Greptile HUD backend ("vibecoders")

Devtime tracker + social leaderboard service for the Greptile HUD crew. A
single Go binary that:

- tracks devtime: the macOS app (or the small agent in `client/`) heartbeats
  while an editor/terminal is running, and the server accrues the time;
- exposes a devtime leaderboard and an "online now" feed over a small REST API.

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
| GET    | `/api/user?login=name`                 | profile (created on first sight) + today/all-time devtime |
| GET    | `/api/online`                          | users with a heartbeat in the last 5 minutes |
| GET    | `/api/leaderboard?period=today\|all`   | devtime leaderboard (default `today`)        |
| POST   | `/api/pulse`                           | devtime heartbeat (body `{"user":"zayd","app":"Cursor"}`) |

## How devtime works

Heartbeats accrue the elapsed time between beats, capped at 10 minutes and
ignored under 30 seconds. Online = heartbeat within 5 minutes. The leaderboard
shows today's seconds by default; `period=all` sums every recorded day. A Crew
day is the shared UTC calendar day (`00:00` through `24:00` UTC). Today responses
include `period_start`, `period_end`, and `timezone` so clients can display the
exact boundary.

## Running locally

```bash
createdb vibecoders   # or point DATABASE_URL at any postgres
export DATABASE_URL=postgres://localhost:5432/vibecoders
go run .
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
- Nothing leaves the app except the username, the app name, and heartbeat
  timing. No code, no keystrokes, no repo data.
