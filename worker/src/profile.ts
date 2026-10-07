/**
 * A player's public page: one link that always shows their current timer,
 * however many timers come and go - subtaskmanager.com/p/<id>.
 *
 * The player's app makes it once and keeps its key, then tells it about each
 * timer it is the player on. Which of those show is decided here, each time
 * the page is asked for: only a timer whose public link is on - and, on a
 * director's timer, only if the director gave the player the link. So a
 * timer joins when its link is switched on and leaves when it is switched
 * off, its link is replaced, it is deleted from the player's device, or the
 * Worker deletes it 30 days after it ends.
 *
 * Two ids: the profile's own, which the app uses and which never changes,
 * and the public one in the link, which "New link" replaces.
 */
import type { PublicView } from './embed.ts';

export interface ProfileRow {
  id: string;
  public_id: string;
  key_hash: string;
  name: string | null;
  show_history: number;
}

/** What /p/<id>/state answers: the page's whole picture. */
export interface ProfileState {
  profile: true;
  name: string | null;
  /** The timer shown in full: the most recently added that is running. */
  featured: (PublicView & { publicId: string }) | null;
  /** Any others running at the same time. */
  others: (PublicView & { publicId: string })[];
  /** Finished ones, newest first - only if the player shows them. */
  history: { startAt: number; closedAt: number; status: string }[];
  now: number;
}

/** Longest display name. */
export const PROFILE_NAME_MAX = 40;

/** Timers one profile may know of; old finished ones go first beyond it. */
const PROFILE_TIMERS_MAX = 200;

/** How many finished timers the page lists. */
const HISTORY_SHOWN = 20;

let tablesReady = false;

export async function ensureProfileTables(db: D1Database): Promise<void> {
  if (tablesReady) return;
  await db.exec(
    'CREATE TABLE IF NOT EXISTS profiles (id TEXT PRIMARY KEY, public_id TEXT NOT NULL UNIQUE, key_hash TEXT NOT NULL, name TEXT, show_history INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)',
  );
  // A finished timer's summary is kept here once seen: it never changes, so
  // the page does not ask its timer again on every load.
  await db.exec(
    'CREATE TABLE IF NOT EXISTS profile_timers (profile_id TEXT NOT NULL, timer_id TEXT NOT NULL, added_at INTEGER NOT NULL, ended_status TEXT, start_at INTEGER, closed_at INTEGER, PRIMARY KEY (profile_id, timer_id))',
  );
  tablesReady = true;
}

/** A display name: one line of plain text, or none. */
export function cleanName(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const text = raw
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, PROFILE_NAME_MAX)
    .trim();
  return text.length > 0 ? text : null;
}

export async function profileByPublicId(db: D1Database, publicId: string): Promise<ProfileRow | null> {
  await ensureProfileTables(db);
  return db.prepare('SELECT * FROM profiles WHERE public_id = ?').bind(publicId).first<ProfileRow>();
}

/** The profile, if [key] is its key. */
export async function profileWithKey(
  db: D1Database,
  id: string,
  key: string | null,
  hash: (s: string) => Promise<string>,
): Promise<ProfileRow | null> {
  if (!key) return null;
  await ensureProfileTables(db);
  const row = await db.prepare('SELECT * FROM profiles WHERE id = ?').bind(id).first<ProfileRow>();
  return row && row.key_hash === (await hash(key)) ? row : null;
}

/**
 * Everything the page shows. [publicView] asks a timer for what its public
 * page would show, or null if it is not to be shown on a profile.
 */
export async function profileState(
  db: D1Database,
  row: ProfileRow,
  publicView: (timerId: string, publicId: string) => Promise<PublicView | null>,
): Promise<ProfileState> {
  await ensureProfileTables(db);
  // Only timers whose public link is on: one with none is not shown at all.
  const { results } = await db
    .prepare(
      `SELECT pt.timer_id, pt.ended_status, pt.start_at, pt.closed_at, tl.public_id
         FROM profile_timers pt JOIN timer_links tl ON tl.timer_id = pt.timer_id
        WHERE pt.profile_id = ?
        ORDER BY pt.added_at DESC
        LIMIT ?`,
    )
    .bind(row.id, PROFILE_TIMERS_MAX)
    .all<{ timer_id: string; ended_status: string | null; start_at: number | null; closed_at: number | null; public_id: string }>();

  const running: (PublicView & { publicId: string })[] = [];
  const history: ProfileState['history'] = [];
  for (const t of results ?? []) {
    if (t.ended_status) {
      history.push({ startAt: t.start_at ?? 0, closedAt: t.closed_at ?? 0, status: t.ended_status });
      continue;
    }
    const view = await publicView(t.timer_id, t.public_id);
    if (!view) continue;
    if (view.status === 'running') {
      running.push({ ...view, publicId: t.public_id });
      continue;
    }
    const closedAt = view.closedAt ?? view.now;
    history.push({ startAt: view.startAt ?? closedAt, closedAt, status: view.status });
    await db
      .prepare('UPDATE profile_timers SET ended_status = ?, start_at = ?, closed_at = ? WHERE profile_id = ? AND timer_id = ?')
      .bind(view.status, view.startAt ?? closedAt, closedAt, row.id, t.timer_id)
      .run();
  }
  history.sort((a, b) => b.closedAt - a.closedAt);
  return {
    profile: true,
    name: row.name,
    featured: running[0] ?? null,
    others: running.slice(1),
    history: row.show_history ? history.slice(0, HISTORY_SHOWN) : [],
    now: Date.now(),
  };
}

/** Adds a timer the player is on. Beyond the limit, the oldest go. */
export async function addProfileTimer(db: D1Database, profileId: string, timerId: string): Promise<void> {
  await ensureProfileTables(db);
  await db
    .prepare('INSERT OR IGNORE INTO profile_timers (profile_id, timer_id, added_at) VALUES (?, ?, ?)')
    .bind(profileId, timerId, Date.now())
    .run();
  await db
    .prepare(
      `DELETE FROM profile_timers WHERE profile_id = ?1 AND timer_id NOT IN
         (SELECT timer_id FROM profile_timers WHERE profile_id = ?1 ORDER BY added_at DESC LIMIT ?2)`,
    )
    .bind(profileId, PROFILE_TIMERS_MAX)
    .run();
}

export async function removeProfileTimer(db: D1Database, profileId: string, timerId: string): Promise<void> {
  await ensureProfileTables(db);
  await db.prepare('DELETE FROM profile_timers WHERE profile_id = ? AND timer_id = ?').bind(profileId, timerId).run();
}

/** What the player's app is told about its profile. */
export async function profileSummary(db: D1Database, row: ProfileRow) {
  const { results } = await db
    .prepare('SELECT timer_id FROM profile_timers WHERE profile_id = ?')
    .bind(row.id)
    .all<{ timer_id: string }>();
  return {
    profileId: row.id,
    publicId: row.public_id,
    name: row.name,
    showHistory: row.show_history === 1,
    timers: (results ?? []).map((r) => r.timer_id),
  };
}
