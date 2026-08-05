# Greptile HUD backend ("vibecoders")

Activity tracker + social leaderboard service for the Greptile HUD crew. A
single Go binary that:

- authenticates with GitHub OAuth (`read:org repo` scopes) and syncs commit,
  LOC, and merged-PR stats from every org the user belongs to;
- tracks devtime: the macOS app (or the small agent in `client/`) heartbeats
  while an editor/terminal is running, and the server accrues the time;
- exposes leaderboards and an "online now" feed over a small REST API.

The frontend is the Greptile HUD Swift app (this repo), not a website. The API
is consumed by the app and by `client/devtime.sh`.

## Stack

- Go (stdlib `net/http` + `database/sql`) and Postgres via `github.com/lib/pq`
  — the only dependency.
- Postgres is required: SQLite would not survive Render's ephemeral disk.
  The schema in `schema.sql` is applied automatically at startup.

## API

Auth: Bearer token (`Authorization: Bearer <token>`). Tokens are minted by the
OAuth flow (`greptilehud://oauth/callback?token=...`) or `POST /api/tokens`.
Session cookies work too and are handy for curl testing.

| Method | Path                      | Description                                     |
| ------ | ------------------------- | ----------------------------------------------- |
| GET    | `/auth/login`             | start GitHub OAuth                              |
| GET    | `/auth/callback`          | OAuth callback → `greptilehud://oauth/callback?token=&login=` |
| GET    | `/api/health`             | liveness + db check                             |
| GET    | `/api/me`                 | current user: profile, stats, devtime, tokens   |
| GET    | `/api/online`             | users with a heartbeat in the last 5 minutes    |
| GET    | `/api/leaderboard?metric=devtime\|commits\|loc\|prs&period=30d\|all` | ranked rows |
| GET    | `/api/profile/{login}`    | public profile                                  |
| POST   | `/api/pulse`              | devtime heartbeat (body `{"app":"Cursor"}`)     |
| POST   | `/api/sync`               | trigger a background GitHub stats refresh       |
| GET    | `/api/tokens`             | list your API tokens                            |
| POST   | `/api/tokens`             | mint a new API token                            |
| DELETE | `/api/tokens/{token}`     | revoke a token                                  |

## How the leaderboards are computed

- **commits / lines added**: for each of the user's orgs → repos → GraphQL
  `defaultBranchRef.history`, up to 500 commits per repo, counting only commits
  authored by that user. `lines added` = commit `additions`.
- **PRs merged**: GitHub search API (`org:X is:pr author:Y is:merged`), all time
  and merged in the last 30 days.
- **devtime**: heartbeats accrue the elapsed time between beats, capped at 10
  minutes and ignored under 30 seconds. Online = heartbeat within 5 minutes.
- Sync runs after login, every 6 hours, and on demand via `POST /api/sync`.

## Running locally

```bash
# one-time: create a GitHub OAuth app (https://github.com/settings/developers)
#   Homepage URL:  http://localhost:8080
#   Callback URL:  http://localhost:8080/auth/callback

createdb vibecoders   # or point DATABASE_URL at any postgres
export DATABASE_URL=postgres://localhost:5432/vibecoders
export GITHUB_CLIENT_ID=...
export GITHUB_CLIENT_SECRET=...
export SESSION_SECRET=$(openssl rand -hex 24)
export GITHUB_REDIRECT_URL=http://localhost:8080/auth/callback
go run .
```

Test the flow without the Swift app by setting
`OAUTH_REDIRECT_SCHEME=http` — the callback then redirects to
`http://oauth/callback?token=...` which you can paste into a browser to copy
the token.

## Deploying on Render

The root `render.yaml` blueprint deploys everything (backend at
`https://greptile-hud.onrender.com`, landing page, Postgres) in one connect.
Only two steps are manual, because they involve secrets that cannot live in
the repo:

1. Create a GitHub OAuth app (github.com/settings/developers) with callback
   URL `https://greptile-hud.onrender.com/auth/callback`.
2. In Render: **New → Blueprint** → select the repo. If an old hand-made
   `greptile-hud` service exists, delete it first so the blueprint can take
   over the name (and URL). After the first deploy, paste `GITHUB_CLIENT_ID`
   and `GITHUB_CLIENT_SECRET` into the backend service's Environment tab.

The blueprint generates `SESSION_SECRET`, wires `DATABASE_URL` to the
Postgres instance, sets the OAuth redirect URL, and enables the `/api/health`
check automatically.

## Devtime agent on your Mac

The agent is a shell script that heartbeats while a dev app runs. Get a token
from the app (`/api/me`), then:

```bash
VC_API_URL=https://greptile-hud-backend.onrender.com \
VC_API_TOKEN=<your token> \
./client/devtime.sh
```

For it to survive reboots, install `client/launchd-example.plist` as a
LaunchAgent (edit the path, URL, and token first).

Watched apps: Cursor, VS Code (and Insiders), iTerm2, Terminal, Ghostty, Warp,
WezTerm, Alacritty, kitty, Neovide — override with `VC_APPS`.

## Notes and caveats

- Stats reflect the default branch only; pushes to feature branches don't
  count, and LOC counts only `additions`.
- Very active repos get their history capped at 500 commits per sync; the cap
  only trims results that fall outside the sampled window.
- GitHub search (PR counts) is rate-limited to ~30 requests/minute per token;
  syncs are sequential per user, so many users × many orgs takes a while.
- Tokens stored in the DB are the user's GitHub OAuth tokens; they are never
  exposed through the API or logs.
