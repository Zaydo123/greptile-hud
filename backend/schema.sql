-- Vibecoders (Greptile HUD backend) schema. Applied automatically at startup.
--
-- Identity is trust-based: a user is just a self-chosen username. There is no
-- OAuth, no API token, and no GitHub data. Shared data is: devtime, explicitly
-- started active statuses, completed status history (stored server-side at the
-- user's request so it follows them across Macs), optional user-uploaded
-- profile photos, and app/site usage. Usage is only fixed catalog keys
-- (e.g. "youtube", "other") plus seconds per crew day — never app names, URLs,
-- or window titles.

CREATE TABLE IF NOT EXISTS users (
    id         BIGSERIAL PRIMARY KEY,
    login      TEXT UNIQUE NOT NULL,
    name       TEXT,
    last_seen  TIMESTAMPTZ,
    status_emoji      TEXT,
    status_message    TEXT,
    status_started_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS devtime (
    user_id            BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    day                DATE NOT NULL,
    seconds            BIGINT NOT NULL DEFAULT 0,
    last_heartbeat_at  TIMESTAMPTZ,
    PRIMARY KEY (user_id, day)
);

CREATE INDEX IF NOT EXISTS idx_devtime_day ON devtime (day);

-- Forward-only activity sessions. Individual heartbeats are not retained;
-- each row stores only the first and most recent qualifying activity times.
CREATE TABLE IF NOT EXISTS sprints (
    id                BIGSERIAL PRIMARY KEY,
    user_id           BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    started_at        TIMESTAMPTZ NOT NULL,
    last_active_at    TIMESTAMPTZ NOT NULL,
    ended_at          TIMESTAMPTZ,
    duration_seconds  BIGINT NOT NULL DEFAULT 0,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sprints_user_started
    ON sprints (user_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_sprints_last_active
    ON sprints (last_active_at);
CREATE UNIQUE INDEX IF NOT EXISTS idx_sprints_one_open_per_user
    ON sprints (user_id) WHERE ended_at IS NULL;

-- Usernames compare case-insensitively so "Zayd" and "zayd" can't split into
-- two people on the leaderboard.
CREATE UNIQUE INDEX IF NOT EXISTS users_login_lower_idx ON users (lower(login));

-- Status columns for databases created before crew statuses shipped.
ALTER TABLE users ADD COLUMN IF NOT EXISTS status_emoji TEXT,
                  ADD COLUMN IF NOT EXISTS status_message TEXT,
                  ADD COLUMN IF NOT EXISTS status_started_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_users_active_status
    ON users (status_started_at DESC) WHERE status_started_at IS NOT NULL;

-- Migrations for databases created before the trust-based model (GitHub OAuth
-- users, github_stats, and api_tokens are gone; nothing depends on them).
ALTER TABLE users DROP COLUMN IF EXISTS github_id,
                  DROP COLUMN IF EXISTS avatar_url,
                  DROP COLUMN IF EXISTS access_token,
                  DROP COLUMN IF EXISTS orgs,
                  DROP COLUMN IF EXISTS last_sync_at;

DROP TABLE IF EXISTS github_stats;
DROP TABLE IF EXISTS api_tokens;

-- Optional profile photo, uploaded by the user. Validated server-side as a
-- PNG or JPEG of bounded size and dimensions; one row per user. User-shaped
-- API responses LEFT JOIN this table for updated_at only (never the bytes).
CREATE TABLE IF NOT EXISTS avatars (
    user_id      BIGINT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    content_type TEXT NOT NULL,
    data         BYTEA NOT NULL,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- App/site usage per crew day. key is always a catalog key (catalog.go);
-- anything else is folded into "other" before it reaches this table.
CREATE TABLE IF NOT EXISTS app_usage (
    user_id  BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    day      DATE NOT NULL,
    key      TEXT NOT NULL,
    seconds  BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, day, key)
);

CREATE INDEX IF NOT EXISTS idx_app_usage_day ON app_usage (day);

-- Completed status sessions. client_id is the Mac app's own UUID for the
-- session, so re-uploads (and renames) upsert instead of duplicating.
CREATE TABLE IF NOT EXISTS status_history (
    id          BIGSERIAL PRIMARY KEY,
    user_id     BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    client_id   UUID NOT NULL,
    emoji       TEXT NOT NULL,
    message     TEXT NOT NULL,
    started_at  TIMESTAMPTZ NOT NULL,
    ended_at    TIMESTAMPTZ NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, client_id)
);

CREATE INDEX IF NOT EXISTS idx_status_history_user_started
    ON status_history (user_id, started_at DESC);
