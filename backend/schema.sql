-- Vibecoders (Greptile HUD backend) schema. Applied automatically at startup.

CREATE TABLE IF NOT EXISTS users (
    id             BIGSERIAL PRIMARY KEY,
    github_id      BIGINT UNIQUE NOT NULL,
    login          TEXT UNIQUE NOT NULL,
    name           TEXT,
    avatar_url     TEXT,
    access_token   TEXT NOT NULL,
    orgs           TEXT NOT NULL DEFAULT '[]',
    last_seen      TIMESTAMPTZ,
    last_sync_at   TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS github_stats (
    user_id     BIGINT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    commits_30d BIGINT NOT NULL DEFAULT 0,
    commits_all BIGINT NOT NULL DEFAULT 0,
    loc_30d     BIGINT NOT NULL DEFAULT 0,
    loc_all     BIGINT NOT NULL DEFAULT 0,
    prs_30d     BIGINT NOT NULL DEFAULT 0,
    prs_all     BIGINT NOT NULL DEFAULT 0,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS devtime (
    user_id            BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    day                DATE NOT NULL,
    seconds            BIGINT NOT NULL DEFAULT 0,
    last_heartbeat_at  TIMESTAMPTZ,
    PRIMARY KEY (user_id, day)
);

CREATE TABLE IF NOT EXISTS api_tokens (
    token      TEXT PRIMARY KEY,
    user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_devtime_day ON devtime (day);
