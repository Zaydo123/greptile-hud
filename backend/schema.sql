-- Vibecoders (Greptile HUD backend) schema. Applied automatically at startup.
--
-- Identity is trust-based: a user is just a self-chosen username. There is no
-- OAuth, no API token, and no GitHub data; the only thing tracked is devtime.

CREATE TABLE IF NOT EXISTS users (
    id         BIGSERIAL PRIMARY KEY,
    login      TEXT UNIQUE NOT NULL,
    name       TEXT,
    last_seen  TIMESTAMPTZ,
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

-- Usernames compare case-insensitively so "Zayd" and "zayd" can't split into
-- two people on the leaderboard.
CREATE UNIQUE INDEX IF NOT EXISTS users_login_lower_idx ON users (lower(login));

-- Migrations for databases created before the trust-based model (GitHub OAuth
-- users, github_stats, and api_tokens are gone; nothing depends on them).
ALTER TABLE users DROP COLUMN IF EXISTS github_id,
                  DROP COLUMN IF EXISTS avatar_url,
                  DROP COLUMN IF EXISTS access_token,
                  DROP COLUMN IF EXISTS orgs,
                  DROP COLUMN IF EXISTS last_sync_at;

DROP TABLE IF EXISTS github_stats;
DROP TABLE IF EXISTS api_tokens;
