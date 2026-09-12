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

-- Pre-staged scheduled pushes.
--
-- The Worker holds no scheduling logic. A device computes its own upcoming
-- occurrences, encrypts each one as a complete dispatchOrder message, and
-- uploads it with the time it should go out. The cron simply sends what it was
-- given, so a scheduled directive arrives down the same path as a
-- director-dispatched one and needs no separate handling on the device.
CREATE TABLE IF NOT EXISTS schedules (
  topic    TEXT NOT NULL,
  rule_id  TEXT NOT NULL,
  due_at   INTEGER NOT NULL,
  payload  TEXT NOT NULL,
  PRIMARY KEY (topic, rule_id, due_at)
);

CREATE INDEX IF NOT EXISTS idx_schedules_due_at ON schedules (due_at);
