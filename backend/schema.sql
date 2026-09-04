-- Vibecoders (Greptile HUD backend) schema. Applied automatically at startup.
--
-- Identity is trust-based: a user is just a self-chosen username. There is no
-- OAuth, no API token, and no GitHub data. Devtime and explicitly started
-- active statuses are the only shared data; completed status history is local.

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
