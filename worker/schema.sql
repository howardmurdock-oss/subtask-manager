-- Push-token registry.
--
-- Keyed by push_token rather than by topic so one pairing code can cover
-- several devices (phone plus tablet) without one registration evicting
-- another. Topics are already-hashed pairing codes, so no raw code is stored.
CREATE TABLE IF NOT EXISTS devices (
  push_token TEXT PRIMARY KEY,
  topic      TEXT NOT NULL,
  platform   TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_devices_topic ON devices (topic);

-- Supports pruning registrations that have gone quiet for months.
CREATE INDEX IF NOT EXISTS idx_devices_updated_at ON devices (updated_at);
