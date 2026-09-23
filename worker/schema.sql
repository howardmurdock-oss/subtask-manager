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

-- What the cron actually did with each staged row.
--
-- Without this a missed scheduled directive is indistinguishable from end to
-- end: the row is deleted once attempted, FCM's answer was discarded, and the
-- device keeps no note of what arrived. Several days of testing produced only
-- "it didn't come", with no way to say which link broke. No payloads here -
-- timing and outcome only.
CREATE TABLE IF NOT EXISTS deliveries (
  topic    TEXT NOT NULL,
  rule_id  TEXT NOT NULL,
  due_at   INTEGER NOT NULL,
  fired_at INTEGER NOT NULL,
  devices  INTEGER NOT NULL,
  sent     INTEGER NOT NULL,
  detail   TEXT
);

CREATE INDEX IF NOT EXISTS idx_deliveries_topic ON deliveries (topic, fired_at);

-- Payloads too large to travel as a data message.
--
-- FCM caps a data message at 4KB, and a proof photo is roughly 120KB by the
-- time it is compressed, base64'd and encrypted. Those used to go to the
-- public relay instead, which a dozing Android device does not hear at all, so
-- a photo arrived whenever its recipient next opened the app - if the relay
-- had not expired the attachment first.
--
-- The device stores the ciphertext here and sends a pointer to it. What is
-- kept is exactly what would have been in the message, and is no more readable
-- here than it was there.
CREATE TABLE IF NOT EXISTS blobs (
  id         TEXT PRIMARY KEY,
  topic      TEXT NOT NULL,
  payload    TEXT NOT NULL,
  stored_at  INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);

-- Swept by the cron.
CREATE INDEX IF NOT EXISTS idx_blobs_expiry ON blobs (expires_at);
