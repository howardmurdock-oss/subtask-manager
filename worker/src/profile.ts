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
import { sanitizePublicOrders } from './public_orders.ts';
import { advanceProfileOrders, profileOrdersPublic } from './profile_orders.ts';

export function randomToken(bytes = 24): string {
  const raw = crypto.getRandomValues(new Uint8Array(bytes));
  return btoa(String.fromCharCode(...raw)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export interface ProfileRow {
  id: string;
  public_id: string;
  key_hash: string;
  name: string | null;
  show_history: number;
  bio?: string | null;
  socials?: string | null; // JSON array of ProfileSocial
  orders_config?: string | null; // JSON of PublicOrdersConfig
  accept_messages?: number; // 0 or 1
  skips_left?: number;
  skips_day?: string | null;
  paused_until?: number | null;
}

export interface ProfileSocial {
  id: string;
  platform: string; // 'reddit' | 'discord' | 'onlyfans' | 'fansly' | 'twitter' | 'x' | 'instagram' | 'bluesky' | 'patreon' | 'twitch' | 'youtube' | 'tiktok' | 'custom'
  label: string;
  url: string;
}

export interface ProfileMessage {
  id: string;
  profileId: string;
  senderName: string | null;
  message: string;
  createdAt: number;
  readAt: number | null;
}

export interface ProfileChatMessage {
  id: string;
  profileId: string;
  visitorId: string;
  senderRole: 'visitor' | 'player';
  senderName: string;
  text: string;
  createdAt: number;
  readAt: number | null;
}

export interface ProfileChatThread {
  visitorId: string;
  visitorName: string;
  lastMessage: string;
  lastMessageAt: number;
  unreadCount: number;
  isBlocked?: boolean;
}

export function cleanVisitorId(raw: unknown): string {
  if (typeof raw !== 'string') return '';
  return raw.replace(/[^A-Za-z0-9_-]/g, '').slice(0, 64);
}

/** What /p/<id>/state answers: the page's whole picture. */
export interface ProfileState {
  profile: true;
  name: string | null;
  bio?: string | null;
  socials?: ProfileSocial[];
  acceptMessages?: boolean;
  /** The timer shown in full: the most recently added that is running. */
  featured: (PublicView & { publicId: string }) | null;
  /** Any others running at the same time. */
  others: (PublicView & { publicId: string })[];
  /** Finished ones, newest first - only if the player shows them. */
  history: { startAt: number; closedAt: number; status: string }[];
  orders?: any | null;
  now: number;
}

/** Longest display name. */
export const PROFILE_NAME_MAX = 40;
export const PROFILE_BIO_MAX = 250;
export const SOCIAL_LABEL_MAX = 60;
export const SOCIAL_URL_MAX = 300;
export const SOCIALS_MAX = 15;
export const MESSAGE_SENDER_MAX = 40;
export const MESSAGE_BODY_MAX = 500;
export const PROFILE_MESSAGES_MAX = 100;

/** Timers one profile may know of; old finished ones go first beyond it. */
const PROFILE_TIMERS_MAX = 200;

/** How many finished timers the page lists. */
const HISTORY_SHOWN = 20;

const ALLOWED_PLATFORMS = new Set([
  'reddit', 'discord', 'onlyfans', 'fansly', 'twitter', 'x', 'instagram',
  'bluesky', 'patreon', 'twitch', 'youtube', 'tiktok', 'custom',
]);

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

  const columns = [
    'bio TEXT',
    'socials TEXT',
    'orders_config TEXT',
    'accept_messages INTEGER NOT NULL DEFAULT 0',
    'skips_left INTEGER NOT NULL DEFAULT 2',
    'skips_day TEXT',
    'paused_until INTEGER',
  ];
  for (const col of columns) {
    try {
      await db.exec(`ALTER TABLE profiles ADD COLUMN ${col}`);
    } catch {
      // Column already exists
    }
  }

  await db.exec(
    'CREATE TABLE IF NOT EXISTS profile_messages (id TEXT PRIMARY KEY, profile_id TEXT NOT NULL, sender_name TEXT, message TEXT NOT NULL, created_at INTEGER NOT NULL, read_at INTEGER)',
  );
  try {
    await db.exec('CREATE INDEX IF NOT EXISTS idx_profile_messages_profile ON profile_messages (profile_id, created_at DESC)');
  } catch {}

  await db.exec(
    'CREATE TABLE IF NOT EXISTS profile_chats (id TEXT PRIMARY KEY, profile_id TEXT NOT NULL, visitor_id TEXT NOT NULL, sender_role TEXT NOT NULL, sender_name TEXT NOT NULL, text TEXT NOT NULL, created_at INTEGER NOT NULL, read_at INTEGER)',
  );
  try {
    await db.exec('CREATE INDEX IF NOT EXISTS idx_profile_chats_thread ON profile_chats (profile_id, visitor_id, created_at)');
    await db.exec('CREATE INDEX IF NOT EXISTS idx_profile_chats_unread ON profile_chats (profile_id, sender_role, read_at)');
  } catch {}

  await db.exec(
    'CREATE TABLE IF NOT EXISTS profile_public_orders (profile_id TEXT NOT NULL, no INTEGER NOT NULL, def TEXT NOT NULL, at INTEGER NOT NULL, visitor TEXT, status TEXT NOT NULL, delivered_at INTEGER, due_at INTEGER, done_at INTEGER, issuer_key TEXT, receipt_hash TEXT, proof TEXT, proof_expires INTEGER, review_due INTEGER, auto INTEGER, issuer_topic TEXT, PRIMARY KEY (profile_id, no))',
  );
  try {
    await db.exec('CREATE INDEX IF NOT EXISTS idx_profile_orders_status ON profile_public_orders (profile_id, status, no)');
  } catch {}

  await db.exec(
    'CREATE TABLE IF NOT EXISTS profile_blocked_visitors (profile_id TEXT NOT NULL, visitor_id TEXT NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY (profile_id, visitor_id))',
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

export function cleanBio(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const text = raw
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .trim()
    .slice(0, PROFILE_BIO_MAX)
    .trim();
  return text.length > 0 ? text : null;
}

export function cleanSocials(raw: unknown): ProfileSocial[] {
  if (!Array.isArray(raw)) return [];
  const list: ProfileSocial[] = [];
  for (const item of raw) {
    if (!item || typeof item !== 'object') continue;
    const rawPlatform = typeof item.platform === 'string' ? item.platform.toLowerCase().trim() : 'custom';
    const platform = ALLOWED_PLATFORMS.has(rawPlatform) ? rawPlatform : 'custom';
    const label = typeof item.label === 'string'
      ? item.label.replace(/[\u0000-\u001f\u007f]+/g, ' ').trim().slice(0, SOCIAL_LABEL_MAX)
      : '';
    const url = typeof item.url === 'string' ? item.url.trim() : '';
    if (!label || !url) continue;
    try {
      const parsed = new URL(url);
      if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') continue;
    } catch {
      continue;
    }
    const id = typeof item.id === 'string' && /^[A-Za-z0-9_-]{1,32}$/.test(item.id) ? item.id : randomToken(8);
    list.push({ id, platform, label, url: url.slice(0, SOCIAL_URL_MAX) });
    if (list.length >= SOCIALS_MAX) break;
  }
  return list;
}

export function cleanMessageText(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const text = raw
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]+/g, '')
    .trim()
    .slice(0, MESSAGE_BODY_MAX)
    .trim();
  return text.length > 0 ? text : null;
}

export function cleanSenderName(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const text = raw
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .trim()
    .slice(0, MESSAGE_SENDER_MAX)
    .trim();
  return text.length > 0 ? text : null;
}

export async function addProfileMessage(
  db: D1Database,
  profileId: string,
  senderName: string | null,
  message: string,
  now = Date.now(),
): Promise<string> {
  await ensureProfileTables(db);
  const id = randomToken(16);
  await db
    .prepare(
      'INSERT INTO profile_messages (id, profile_id, sender_name, message, created_at, read_at) VALUES (?, ?, ?, ?, ?, NULL)',
    )
    .bind(id, profileId, senderName, message, now)
    .run();
  await db
    .prepare(
      `DELETE FROM profile_messages WHERE profile_id = ?1 AND id NOT IN
         (SELECT id FROM profile_messages WHERE profile_id = ?1 ORDER BY created_at DESC LIMIT ?2)`,
    )
    .bind(profileId, PROFILE_MESSAGES_MAX)
    .run();
  return id;
}

export async function listProfileMessages(
  db: D1Database,
  profileId: string,
  limit = 50,
): Promise<{ messages: ProfileMessage[]; unreadCount: number }> {
  await ensureProfileTables(db);
  const { results } = await db
    .prepare('SELECT * FROM profile_messages WHERE profile_id = ? ORDER BY created_at DESC LIMIT ?')
    .bind(profileId, limit)
    .all<{ id: string; profile_id: string; sender_name: string | null; message: string; created_at: number; read_at: number | null }>();

  const unreadCount = (
    await db
      .prepare('SELECT COUNT(*) AS c FROM profile_messages WHERE profile_id = ? AND read_at IS NULL')
      .bind(profileId)
      .first<{ c: number }>()
  )?.c ?? 0;

  return {
    messages: (results ?? []).map((r) => ({
      id: r.id,
      profileId: r.profile_id,
      senderName: r.sender_name,
      message: r.message,
      createdAt: r.created_at,
      readAt: r.read_at,
    })),
    unreadCount,
  };
}

export async function markProfileMessagesRead(
  db: D1Database,
  profileId: string,
  ids: string[] | 'all',
  now = Date.now(),
): Promise<void> {
  await ensureProfileTables(db);
  if (ids === 'all') {
    await db.prepare('UPDATE profile_messages SET read_at = ? WHERE profile_id = ? AND read_at IS NULL').bind(now, profileId).run();
  } else if (ids.length > 0) {
    const placeholders = ids.map(() => '?').join(',');
    await db
      .prepare(`UPDATE profile_messages SET read_at = ? WHERE profile_id = ? AND id IN (${placeholders}) AND read_at IS NULL`)
      .bind(now, profileId, ...ids)
      .run();
  }
}

export async function deleteProfileMessages(
  db: D1Database,
  profileId: string,
  ids: string[] | 'all',
): Promise<void> {
  await ensureProfileTables(db);
  if (ids === 'all') {
    await db.prepare('DELETE FROM profile_messages WHERE profile_id = ?').bind(profileId).run();
  } else if (ids.length > 0) {
    const placeholders = ids.map(() => '?').join(',');
    await db
      .prepare(`DELETE FROM profile_messages WHERE profile_id = ? AND id IN (${placeholders})`)
      .bind(profileId, ...ids)
      .run();
  }
}

export async function addProfileChatMessage(
  db: D1Database,
  profileId: string,
  visitorId: string,
  senderRole: 'visitor' | 'player',
  senderName: string,
  text: string,
  now = Date.now(),
): Promise<string> {
  await ensureProfileTables(db);
  const id = randomToken(16);
  await db
    .prepare(
      'INSERT INTO profile_chats (id, profile_id, visitor_id, sender_role, sender_name, text, created_at, read_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
    )
    .bind(id, profileId, visitorId, senderRole, senderName, text, now, senderRole === 'player' ? now : null)
    .run();
  return id;
}

export async function getProfileChatMessages(
  db: D1Database,
  profileId: string,
  visitorId: string,
  limit = 100,
): Promise<ProfileChatMessage[]> {
  await ensureProfileTables(db);
  const { results } = await db
    .prepare(
      'SELECT * FROM profile_chats WHERE profile_id = ? AND visitor_id = ? ORDER BY created_at ASC LIMIT ?',
    )
    .bind(profileId, visitorId, limit)
    .all<{
      id: string;
      profile_id: string;
      visitor_id: string;
      sender_role: string;
      sender_name: string;
      text: string;
      created_at: number;
      read_at: number | null;
    }>();

  return (results ?? []).map((r) => ({
    id: r.id,
    profileId: r.profile_id,
    visitorId: r.visitor_id,
    senderRole: r.sender_role as 'visitor' | 'player',
    senderName: r.sender_name,
    text: r.text,
    createdAt: r.created_at,
    readAt: r.read_at,
  }));
}

export async function listProfileChatThreads(
  db: D1Database,
  profileId: string,
  limit = 50,
): Promise<ProfileChatThread[]> {
  await ensureProfileTables(db);
  const { results } = await db
    .prepare(
      `SELECT pc.visitor_id,
              (SELECT sender_name FROM profile_chats WHERE profile_id = ?1 AND visitor_id = pc.visitor_id AND sender_role = 'visitor' ORDER BY created_at DESC LIMIT 1) AS visitor_name,
              pc.text AS last_message,
              MAX(pc.created_at) AS last_message_at,
              (SELECT COUNT(*) FROM profile_chats WHERE profile_id = ?1 AND visitor_id = pc.visitor_id AND sender_role = 'visitor' AND read_at IS NULL) AS unread_count,
              (SELECT 1 FROM profile_blocked_visitors WHERE profile_id = ?1 AND visitor_id = pc.visitor_id) AS is_blocked
         FROM profile_chats pc
        WHERE pc.profile_id = ?1
        GROUP BY pc.visitor_id
        ORDER BY last_message_at DESC
        LIMIT ?2`,
    )
    .bind(profileId, limit)
    .all<{
      visitor_id: string;
      visitor_name: string | null;
      last_message: string;
      last_message_at: number;
      unread_count: number;
      is_blocked: number | null;
    }>();

  return (results ?? []).map((r) => ({
    visitorId: r.visitor_id,
    visitorName: r.visitor_name || 'Anonymous',
    lastMessage: r.last_message,
    lastMessageAt: r.last_message_at,
    unreadCount: r.unread_count ?? 0,
    isBlocked: !!r.is_blocked,
  }));
}

export async function isVisitorBlocked(
  db: D1Database,
  profileId: string,
  visitorId: string,
): Promise<boolean> {
  await ensureProfileTables(db);
  const row = await db
    .prepare('SELECT 1 FROM profile_blocked_visitors WHERE profile_id = ? AND visitor_id = ?')
    .bind(profileId, visitorId)
    .first();
  return !!row;
}

export async function blockVisitor(
  db: D1Database,
  profileId: string,
  visitorId: string,
  now = Date.now(),
): Promise<void> {
  await ensureProfileTables(db);
  await db
    .prepare('INSERT OR REPLACE INTO profile_blocked_visitors (profile_id, visitor_id, created_at) VALUES (?, ?, ?)')
    .bind(profileId, visitorId, now)
    .run();
}

export async function unblockVisitor(
  db: D1Database,
  profileId: string,
  visitorId: string,
): Promise<void> {
  await ensureProfileTables(db);
  await db
    .prepare('DELETE FROM profile_blocked_visitors WHERE profile_id = ? AND visitor_id = ?')
    .bind(profileId, visitorId)
    .run();
}

export async function markProfileChatRead(
  db: D1Database,
  profileId: string,
  visitorId: string,
  readerRole: 'visitor' | 'player',
  now = Date.now(),
): Promise<void> {
  await ensureProfileTables(db);
  const targetSender = readerRole === 'player' ? 'visitor' : 'player';
  await db
    .prepare(
      'UPDATE profile_chats SET read_at = ? WHERE profile_id = ? AND visitor_id = ? AND sender_role = ? AND read_at IS NULL',
    )
    .bind(now, profileId, visitorId, targetSender)
    .run();
}

export async function deleteProfileChatThread(
  db: D1Database,
  profileId: string,
  visitorId: string,
): Promise<void> {
  await ensureProfileTables(db);
  await db.prepare('DELETE FROM profile_chats WHERE profile_id = ? AND visitor_id = ?').bind(profileId, visitorId).run();
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
  visitor?: unknown,
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

  const now = Date.now();
  let orders = null;
  const featured = running[0] ?? null;
  if ((!featured || !featured.orders?.enabled) && row.orders_config) {
    try {
      const parsedConfig = sanitizePublicOrders(JSON.parse(row.orders_config));
      if (parsedConfig.enabled) {
        await advanceProfileOrders(db, row.id, parsedConfig, row.paused_until ?? null, now);
        orders = await profileOrdersPublic(db, row.id, parsedConfig, row.paused_until ?? null, now, visitor);
      }
    } catch {}
  }

  return {
    profile: true,
    name: row.name,
    bio: row.bio ?? null,
    socials: row.socials ? JSON.parse(row.socials) : [],
    acceptMessages: row.accept_messages === 1,
    featured,
    others: running.slice(1),
    history: row.show_history ? history.slice(0, HISTORY_SHOWN) : [],
    orders,
    now,
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

  let unreadMessages = 0;
  try {
    const unreadMsgs = await db
      .prepare('SELECT COUNT(*) AS c FROM profile_messages WHERE profile_id = ? AND read_at IS NULL')
      .bind(row.id)
      .first<{ c: number }>();
    const unreadChats = await db
      .prepare('SELECT COUNT(*) AS c FROM profile_chats WHERE profile_id = ? AND sender_role = "visitor" AND read_at IS NULL')
      .bind(row.id)
      .first<{ c: number }>();
    unreadMessages = (unreadMsgs?.c ?? 0) + (unreadChats?.c ?? 0);
  } catch {}

  return {
    profileId: row.id,
    publicId: row.public_id,
    name: row.name,
    bio: row.bio ?? null,
    socials: row.socials ? JSON.parse(row.socials) : [],
    acceptMessages: row.accept_messages === 1,
    unreadMessages,
    publicOrders: row.orders_config ? JSON.parse(row.orders_config) : null,
    showHistory: row.show_history === 1,
    timers: (results ?? []).map((r) => r.timer_id),
  };
}
