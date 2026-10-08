/**
 * (sub)Task Manager push relay.
 *
 * Holds the Firebase service-account credential so devices never have to, and
 * turns "deliver to this topic" into one or more FCM pushes.
 *
 * Two things this deliberately does NOT do:
 *
 *  - It never sees a pairing code. The app hashes codes into topics already
 *    (SyncService.getHashedTopic); the same hash is what arrives here.
 *  - It never sees plaintext. Payloads are ciphertext produced by
 *    EncryptionHelper on the sending device, so a compromise here leaks
 *    metadata about who messaged whom, not directive contents.
 *
 * Messages are sent data-only, with no `notification` block. That matters:
 * a notification-block message is rendered by the system and the app is not
 * consulted, which would bypass the addressing, dedup and occurrence-ledger
 * logic the client already applies. Data-only high-priority messages wake the
 * app in Doze and let it decide what to show.
 */

import { ChastityTimer, randomToken, sha256Hex } from './timer.ts';
import { expiredPage, profileGonePage, publicPage } from './public_page.ts';
import { badgeSvg, embedPage, endedEmbedPage, previewText, type PublicView } from './embed.ts';
import { pngResponse } from './preview_images.ts';
import { confirmDevice, deviceOf, startDevice, verifyPage } from './device.ts';
import {
  addProfileTimer,
  cleanName,
  ensureProfileTables,
  profileByPublicId,
  profileState,
  profileSummary,
  profileWithKey,
  removeProfileTimer,
} from './profile.ts';
import { DOWNLOADS, hasStatsPassword, isBot, releaseUrl, statsPage, summarize, type CountRow } from './download_stats.ts';

export { ChastityTimer };

export interface Env {
  DB: D1Database;
  TOKEN_CACHE: KVNamespace;
  TOPIC_HUB: DurableObjectNamespace;
  FCM_PROJECT_ID: string;
  FCM_SERVICE_ACCOUNT: string; // service-account JSON, set via `wrangler secret put`
  PATREON_BUILDS: R2Bucket;
  // Comma-separated salted SHA-256 digests of the valid Patreon codes: the
  // same digests the app checks against (PatreonAccess), public in its source.
  PATREON_CODE_DIGESTS: string;
  CHASTITY_TIMER: DurableObjectNamespace;
  // Cloudflare Turnstile for public votes. Both unset: votes are not
  // challenged (the per-visitor and daily caps still apply).
  TURNSTILE_SITE_KEY?: string;
  TURNSTILE_SECRET?: string;
  // The website download stats page, subtaskmanager.com/download/stats.
  // Set with: npx wrangler secret put STATS_PASSWORD
  STATS_PASSWORD?: string;
  // Cloudflare rate limiters (wrangler.toml [[ratelimits]]). Unset, as in
  // tests, nothing is limited.
  TIMER_CREATE_LIMIT?: RateLimit;
  TIMER_OP_LIMIT?: RateLimit;
  TIMER_PUBLIC_LIMIT?: RateLimit;
}

/** Cloudflare's rate-limit binding. */
interface RateLimit {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

/** False when this key has gone over its limit. A limiter that fails lets the
 * request through: it is a guard against floods, not a lock. */
async function withinLimit(limiter: RateLimit | undefined, key: string): Promise<boolean> {
  if (!limiter) return true;
  try {
    return (await limiter.limit({ key })).success;
  } catch {
    return true;
  }
}

const slowDown = () => json({ error: 'slow-down' }, 429);

const OAUTH_TOKEN_URL = 'https://oauth2.googleapis.com/token';
const FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
const ACCESS_TOKEN_KEY = 'fcm_access_token';

/** Google issues these for an hour; refresh early so a request never races expiry. */
const ACCESS_TOKEN_TTL_SECONDS = 3300;

/** FCM caps a data message at 4KB. Anything larger is stored and pointed at. */
const MAX_PAYLOAD_BYTES = 3500;

/**
 * A proof photo compresses to about 50KB, which is roughly 120KB once it is
 * base64 and encrypted. This leaves room for that without accepting something
 * that has no business being a directive.
 */
const MAX_BLOB_BYTES = 512 * 1024;

/**
 * How long a stored payload stays fetchable. Long enough for a phone that was
 * off for a weekend, short enough that nothing accumulates: the pointer is
 * useless once the message has been applied, and the row is swept either way.
 */
const BLOB_TTL_MS = 7 * 24 * 60 * 60 * 1000;

const MAX_TOKENS_PER_TOPIC = 10;

/**
 * Occurrences a device may stage ahead. Matches the app's pre-armed alarm
 * window, so both mechanisms cover the same span of time.
 */
const MAX_SCHEDULED_PER_TOPIC = 40;

/**
 * Pushes attempted per cron tick. The free plan caps subrequests per
 * invocation, and each push is one; anything left waits for the next minute
 * rather than being dropped.
 */
const MAX_DUE_PER_TICK = 30;

/**
 * Past this, the device's own catch-up has long since handled the occurrence
 * and pushing it would deliver a directive the user already dealt with.
 */
const STALE_AFTER_MS = 24 * 60 * 60 * 1000;

/** How long delivery records are kept for /diag. */
const DELIVERY_LOG_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;

/**
 * How long a hub keeps messages for devices that were switched off, and how
 * many. A desktop reconnects with the last sequence it saw and collects what
 * it missed; beyond this it falls back to its own catch-up.
 */
const HUB_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
const HUB_MAX_MESSAGES = 500;
const HUB_MAX_BACKLOG_PER_CONNECT = 200;

/** A desktop that has not reconnected in this long is no longer listening. */
const DESKTOP_REGISTRATION_TTL_MS = 30 * 24 * 60 * 60 * 1000;

/**
 * How recently a desktop must have claimed its topic to be treated as
 * reachable. A connected client re-claims twice a day, so this only lapses for
 * a machine that has genuinely been away - at which point senders go back to
 * the relay rather than posting into a hub nobody is reading. Without it, a
 * device that stopped using the hub (an uninstall, a downgrade) would have its
 * messages delivered nowhere until the registration aged out.
 */
const DESKTOP_FRESH_MS = 7 * 24 * 60 * 60 * 1000;

/**
 * One hub per topic: live delivery for devices FCM cannot reach.
 *
 * Windows and Linux have no FCM implementation, so desktop has been receiving
 * over a shared public relay this project does not control. A hub holds a
 * WebSocket per connected device and pushes to it the moment something is
 * sent.
 *
 * It also keeps a short backlog, which is what makes this a replacement for
 * that relay rather than a live-only channel: a PC that was switched off
 * reconnects with the last sequence number it saw and collects what it missed.
 *
 * Connections are accepted through the hibernation API, so an idle desktop
 * costs nothing while connected - the object leaves memory and is revived when
 * a message actually arrives.
 *
 * Payloads are ciphertext, as everywhere else here.
 */
export class TopicHub {
  private readonly sql: SqlStorage;

  constructor(private readonly ctx: DurableObjectState, _env: Env) {
    this.sql = ctx.storage.sql;
    this.sql.exec(
      `CREATE TABLE IF NOT EXISTS messages (
         seq INTEGER PRIMARY KEY AUTOINCREMENT,
         payload TEXT NOT NULL,
         kind TEXT NOT NULL,
         created_at INTEGER NOT NULL)`,
    );
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === 'POST' && url.pathname === '/publish') {
      const body = (await request.json().catch(() => null)) as {
        payload?: string;
        kind?: string;
      } | null;
      if (!body?.payload) return json({ error: 'payload is required' }, 400);
      return json(this.publish(body.payload, body.kind ?? 'sync'));
    }

    if (request.headers.get('upgrade')?.toLowerCase() !== 'websocket') {
      return json({ error: 'expected a websocket upgrade' }, 426);
    }

    const since = Number(url.searchParams.get('since') ?? '0');
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    this.ctx.acceptWebSocket(server);

    // Whatever this device missed while it was away, oldest first.
    const backlog = this.sql
      .exec(
        `SELECT seq, payload, kind FROM messages WHERE seq > ? ORDER BY seq LIMIT ?`,
        Number.isFinite(since) ? since : 0,
        HUB_MAX_BACKLOG_PER_CONNECT,
      )
      .toArray() as Array<{ seq: number; payload: string; kind: string }>;

    for (const row of backlog) {
      server.send(JSON.stringify({ seq: row.seq, p: row.payload, k: row.kind }));
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  private publish(payload: string, kind: string): { seq: number; delivered: number } {
    const now = Date.now();
    const inserted = this.sql
      .exec(
        `INSERT INTO messages (payload, kind, created_at) VALUES (?, ?, ?) RETURNING seq`,
        payload,
        kind,
        now,
      )
      .one() as { seq: number };

    const frame = JSON.stringify({ seq: inserted.seq, p: payload, k: kind });
    let delivered = 0;
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.send(frame);
        delivered++;
      } catch {
        // Gone; the device will collect it from the backlog on reconnect.
      }
    }

    this.sql.exec(`DELETE FROM messages WHERE created_at < ?`, now - HUB_RETENTION_MS);
    this.sql.exec(
      `DELETE FROM messages WHERE seq <= (
         SELECT COALESCE(MAX(seq), 0) - ? FROM messages)`,
      HUB_MAX_MESSAGES,
    );

    return { seq: inserted.seq, delivered };
  }

  // Hibernation handlers. Without these an idle connection would keep the
  // object resident, which is what makes staying connected all day free.
  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (message === 'ping') ws.send('pong');
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    try {
      // 1006 is "abnormal closure" and may not be sent back.
      ws.close(code === 1006 ? 1000 : code, reason);
    } catch {
      // Already gone.
    }
  }

  async webSocketError(): Promise<void> {}
}

/** Hands a payload to a topic's hub for any desktop listening on it. */
async function publishToHub(
  env: Env,
  topic: string,
  payload: string,
  kind: string,
): Promise<boolean> {
  try {
    const stub = env.TOPIC_HUB.get(env.TOPIC_HUB.idFromName(topic));
    const response = await stub.fetch('https://hub.internal/publish', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ payload, kind }),
    });
    return response.ok;
  } catch {
    return false;
  }
}

/** Which kinds of device hold a topic. */
async function devicesOn(env: Env, topic: string): Promise<{ android: boolean; desktop: boolean }> {
  const { results } = await env.DB.prepare(
    `SELECT platform, updated_at FROM devices WHERE topic = ?1`,
  )
    .bind(topic)
    .all<{ platform: string; updated_at: number }>();
  const rows = results ?? [];
  const now = Date.now();
  return {
    android: rows.some((r) => r.platform === 'android'),
    desktop: rows.some((r) => r.platform !== 'android' && now - r.updated_at < DESKTOP_FRESH_MS),
  };
}

// ---------------------------------------------------------------------------
// encoding helpers
// ---------------------------------------------------------------------------

function base64UrlFromBytes(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function base64UrlFromString(value: string): string {
  return base64UrlFromBytes(new TextEncoder().encode(value));
}

/**
 * Service-account keys arrive as PKCS#8 PEM. WebCrypto wants the raw DER, so
 * strip the armour and the newlines JSON.parse has already unescaped.
 */
function pemToDer(pem: string): ArrayBuffer {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/, '')
    .replace(/-----END [^-]+-----/, '')
    .replace(/\s+/g, '');
  const raw = atob(body);
  const der = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) der[i] = raw.charCodeAt(i);
  return der.buffer;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}

// ---------------------------------------------------------------------------
// Google OAuth2
// ---------------------------------------------------------------------------

/**
 * Mints an access token by signing a JWT with the service-account key.
 *
 * Cached in KV rather than minted per request: signing is the most expensive
 * thing this Worker does, and re-minting on every push would both triple the
 * latency and risk Google's own rate limits. One write an hour keeps KV's
 * modest free-tier write allowance irrelevant.
 */
async function getAccessToken(env: Env): Promise<string> {
  const cached = await env.TOKEN_CACHE.get(ACCESS_TOKEN_KEY);
  if (cached) return cached;

  const account = JSON.parse(env.FCM_SERVICE_ACCOUNT) as {
    client_email: string;
    private_key: string;
  };

  const issuedAt = Math.floor(Date.now() / 1000);
  const header = base64UrlFromString(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = base64UrlFromString(
    JSON.stringify({
      iss: account.client_email,
      scope: FCM_SCOPE,
      aud: OAUTH_TOKEN_URL,
      iat: issuedAt,
      exp: issuedAt + 3600,
    }),
  );
  const signingInput = `${header}.${claims}`;

  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToDer(account.private_key),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    key,
    new TextEncoder().encode(signingInput),
  );

  const assertion = `${signingInput}.${base64UrlFromBytes(new Uint8Array(signature))}`;

  const response = await fetch(OAUTH_TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }),
  });

  if (!response.ok) {
    throw new Error(`token exchange failed: ${response.status} ${await response.text()}`);
  }

  const { access_token: accessToken } = (await response.json()) as { access_token: string };
  if (!accessToken) throw new Error('token exchange returned no access_token');

  await env.TOKEN_CACHE.put(ACCESS_TOKEN_KEY, accessToken, {
    expirationTtl: ACCESS_TOKEN_TTL_SECONDS,
  });
  return accessToken;
}

// ---------------------------------------------------------------------------
// routes
// ---------------------------------------------------------------------------

/**
 * A device claims a topic. Keyed by push token, not by topic, so one pairing
 * code can legitimately cover several devices (phone plus tablet) without one
 * registration silently evicting another.
 */
async function handleRegister(request: Request, env: Env): Promise<Response> {
  const body = (await request.json().catch(() => null)) as {
    topic?: string;
    token?: string;
    platform?: string;
  } | null;

  if (!body?.topic || !body.token) {
    return json({ error: 'topic and token are required' }, 400);
  }

  await env.DB.prepare(
    `INSERT INTO devices (push_token, topic, platform, updated_at)
     VALUES (?1, ?2, ?3, ?4)
     ON CONFLICT(push_token) DO UPDATE SET
       topic = excluded.topic,
       platform = excluded.platform,
       updated_at = excluded.updated_at`,
  )
    .bind(body.token, body.topic, body.platform ?? 'unknown', Date.now())
    .run();

  return json({ ok: true });
}

/**
 * Pushes one payload to every device holding a topic.
 *
 * Shared by /send and the cron so a scheduled directive is delivered by exactly
 * the same code as a dispatched one — the device cannot tell them apart, which
 * is the point: it already knows how to handle a dispatch.
 */
async function pushToTopic(
  env: Env,
  accessToken: string,
  topic: string,
  payload: string,
  kind: string,
): Promise<{ devices: number; sent: number; stale: string[]; errors: string[] }> {
  // Android only: a desktop registration is a client id, not an FCM token, and
  // sending it to FCM would fail and prune a live registration.
  const { results } = await env.DB.prepare(
    `SELECT push_token FROM devices WHERE topic = ?1 AND platform = 'android'
     ORDER BY updated_at DESC LIMIT ?2`,
  )
    .bind(topic, MAX_TOKENS_PER_TOPIC)
    .all<{ push_token: string }>();

  if (!results || results.length === 0) return { devices: 0, sent: 0, stale: [], errors: [] };

  const endpoint = `https://fcm.googleapis.com/v1/projects/${env.FCM_PROJECT_ID}/messages:send`;
  let sent = 0;
  const stale: string[] = [];
  const errors: string[] = [];

  for (const row of results) {
    const response = await fetch(endpoint, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${accessToken}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        message: {
          token: row.push_token,
          data: { p: payload, k: kind, v: '1' },
          android: { priority: 'high' },
        },
      }),
    });

    if (response.ok) {
      sent++;
      continue;
    }
    const detail = await response.text();
    errors.push(`${response.status} ${detail.slice(0, 160)}`);
    // Only prune on a verdict about the token itself. INVALID_ARGUMENT is also
    // what FCM returns for a malformed or oversized *message*, and treating
    // that as a dead token deleted a live registration - which the device then
    // never replaced, because it believed it was still registered.
    if (
      response.status === 404 ||
      detail.includes('UNREGISTERED') ||
      (detail.includes('INVALID_ARGUMENT') && /registration token/i.test(detail))
    ) {
      stale.push(row.push_token);
    }
  }

  return { devices: results.length, sent, stale, errors };
}

async function pruneTokens(env: Env, tokens: string[]): Promise<void> {
  if (tokens.length === 0) return;
  const placeholders = tokens.map((_, i) => `?${i + 1}`).join(',');
  await env.DB.prepare(`DELETE FROM devices WHERE push_token IN (${placeholders})`)
    .bind(...tokens)
    .run();
}

/**
 * Replaces everything staged for a topic.
 *
 * Wholesale replacement rather than merging: a rule the user disabled or
 * retimed must not keep firing from a row nobody remembers uploading, and the
 * device always knows its own full schedule.
 */
async function handleSchedule(request: Request, env: Env): Promise<Response> {
  const body = (await request.json().catch(() => null)) as {
    topic?: string;
    entries?: Array<{ ruleId?: string; at?: number; payload?: string }>;
  } | null;

  if (!body?.topic || !Array.isArray(body.entries)) {
    return json({ error: 'topic and entries are required' }, 400);
  }

  const valid = body.entries
    .filter(
      (e): e is { ruleId: string; at: number; payload: string } =>
        typeof e?.ruleId === 'string' &&
        typeof e?.at === 'number' &&
        typeof e?.payload === 'string' &&
        new TextEncoder().encode(e.payload).length <= MAX_PAYLOAD_BYTES,
    )
    .slice(0, MAX_SCHEDULED_PER_TOPIC);

  // Rows already due but not yet fired - the cron runs on the minute, so a
  // row can sit due for up to sixty seconds. A device only re-stages while
  // its app is alive, and a live app handles an occurrence it sees come due,
  // so these are dropped rather than sent (sending would notify twice). But
  // they are logged: silently deleting one made a morning test look like the
  // cron had never been asked.
  await ensureDeliveriesTable(env);
  const now = Date.now();
  const statements = [
    env.DB.prepare(
      `INSERT INTO deliveries (topic, rule_id, due_at, fired_at, devices, sent, detail)
       SELECT topic, rule_id, due_at, ?2, 0, 0, 'superseded: device re-staged first'
       FROM schedules WHERE topic = ?1 AND due_at <= ?2`,
    ).bind(body.topic, now),
    env.DB.prepare(`DELETE FROM schedules WHERE topic = ?1`).bind(body.topic),
    ...valid.map((e) =>
      env.DB.prepare(
        `INSERT OR REPLACE INTO schedules (topic, rule_id, due_at, payload)
         VALUES (?1, ?2, ?3, ?4)`,
      ).bind(body.topic, e.ruleId, e.at, e.payload),
    ),
  ];
  await env.DB.batch(statements);

  return json({ ok: true, staged: valid.length, rejected: body.entries.length - valid.length });
}

/** Delivers [payload] to everything listening on [topic], phones and
 * desktops. False when nothing is. For the Worker's own messages - a timer
 * announcing public additions. */
export async function deliverToTopic(env: Env, topic: string, payload: string, kind = 'sync'): Promise<boolean> {
  const { android, desktop } = await devicesOn(env, topic);
  let sent = 0;
  if (android) {
    const outcome = await pushToTopic(env, await getAccessToken(env), topic, payload, kind);
    sent = outcome.sent;
    await pruneTokens(env, outcome.stale);
  }
  const hub = desktop ? await publishToHub(env, topic, payload, kind) : false;
  return sent > 0 || hub;
}

async function handleSend(request: Request, env: Env): Promise<Response> {
  const body = (await request.json().catch(() => null)) as {
    topic?: string;
    payload?: string;
    kind?: string;
  } | null;

  if (!body?.topic || !body.payload) {
    return json({ error: 'topic and payload are required' }, 400);
  }
  if (new TextEncoder().encode(body.payload).length > MAX_PAYLOAD_BYTES) {
    // The client is expected to have offloaded this to R2 and sent a pointer.
    return json({ error: 'payload too large for a data message', limit: MAX_PAYLOAD_BYTES }, 413);
  }

  // Checked before minting a token, which is the expensive part: a topic
  // nobody has claimed should cost nothing.
  const { android, desktop } = await devicesOn(env, body.topic);
  if (!android && !desktop) {
    // Nobody registered here - an older build, or a device that has never run
    // this version. The caller should fall back to its existing transport
    // rather than treat this as a delivery failure.
    return json({ sent: 0, unregistered: true }, 404);
  }

  let sent = 0;
  let pruned = 0;
  let errors: string[] = [];
  if (android) {
    const accessToken = await getAccessToken(env);
    const outcome = await pushToTopic(
      env,
      accessToken,
      body.topic,
      body.payload,
      body.kind ?? 'sync',
    );
    sent = outcome.sent;
    errors = outcome.errors;
    await pruneTokens(env, outcome.stale);
    pruned = outcome.stale.length;
  }

  const hub = desktop
    ? await publishToHub(env, body.topic, body.payload, body.kind ?? 'sync')
    : false;

  return json({ sent, hub, pruned, errors }, sent > 0 || hub ? 200 : 502);
}

/**
 * Fires staged directives whose time has come.
 *
 * This exists because the device cannot be relied on to wake itself. On the
 * hardware this was built against, a foreground service ran for nine hours and
 * then stopped ticking for six, and an exact alarm armed via setAlarmClock was
 * confirmed armed and never delivered. A cron running outside the device is not
 * subject to any of that.
 */
let deliveriesTableReady = false;

/**
 * Creates the delivery log if it is missing.
 *
 * Done here rather than relying on schema.sql alone because applying that file
 * goes through Cloudflare's D1 query API, which has refused this account
 * (7403) even while the Worker's own binding works - so the log must not
 * depend on it. Once per isolate; both statements are no-ops after the first.
 */
let blobsTableReady = false;

/**
 * Where a payload too large for a data message waits to be collected.
 *
 * The alternative was the public relay, which a dozing Android device does not
 * hear at all - so a proof photo only arrived when its recipient next opened
 * the app, hours later, if the relay had not expired the attachment first.
 *
 * The row holds ciphertext. It is stored and served without ever being
 * readable here, exactly like the payload of a data message.
 */
async function ensureBlobsTable(env: Env): Promise<void> {
  if (blobsTableReady) return;
  await env.DB.batch([
    env.DB.prepare(
      `CREATE TABLE IF NOT EXISTS blobs (
         id TEXT PRIMARY KEY, topic TEXT NOT NULL, payload TEXT NOT NULL,
         stored_at INTEGER NOT NULL, expires_at INTEGER NOT NULL)`,
    ),
    env.DB.prepare(
      `CREATE INDEX IF NOT EXISTS idx_blobs_expiry ON blobs (expires_at)`,
    ),
  ]);
  blobsTableReady = true;
}

async function handleBlobPut(request: Request, env: Env): Promise<Response> {
  const body = (await request.json().catch(() => null)) as {
    topic?: string;
    payload?: string;
  } | null;

  if (!body?.topic || !body.payload) {
    return json({ error: 'topic and payload are required' }, 400);
  }
  if (new TextEncoder().encode(body.payload).length > MAX_BLOB_BYTES) {
    return json({ error: 'payload too large', limit: MAX_BLOB_BYTES }, 413);
  }

  await ensureBlobsTable(env);
  // Unguessable, because the id is the whole of the authority to fetch it -
  // the same bargain the topic itself makes.
  const id = crypto.randomUUID().replace(/-/g, '') + crypto.randomUUID().replace(/-/g, '');
  const now = Date.now();
  await env.DB.prepare(
    `INSERT INTO blobs (id, topic, payload, stored_at, expires_at) VALUES (?, ?, ?, ?, ?)`,
  )
    .bind(id, body.topic, body.payload, now, now + BLOB_TTL_MS)
    .run();

  return json({ id, expiresAt: now + BLOB_TTL_MS });
}

async function handleBlobGet(url: URL, env: Env): Promise<Response> {
  const id = url.searchParams.get('id') ?? '';
  if (!id) return json({ error: 'id is required' }, 400);

  await ensureBlobsTable(env);
  const row = await env.DB.prepare(
    `SELECT payload, expires_at FROM blobs WHERE id = ?`,
  )
    .bind(id)
    .first<{ payload: string; expires_at: number }>();

  // Not deleted on collection: a topic can be held by more than one device,
  // and the second one to wake up needs it as much as the first.
  if (!row || row.expires_at < Date.now()) return json({ error: 'not found' }, 404);
  return json({ payload: row.payload });
}

async function sweepExpiredBlobs(env: Env): Promise<void> {
  try {
    await ensureBlobsTable(env);
    await env.DB.prepare(`DELETE FROM blobs WHERE expires_at < ?`).bind(Date.now()).run();
  } catch {
    // A sweep that fails costs storage, not delivery.
  }
}

async function ensureDeliveriesTable(env: Env): Promise<void> {
  if (deliveriesTableReady) return;
  await env.DB.batch([
    env.DB.prepare(
      `CREATE TABLE IF NOT EXISTS deliveries (
         topic TEXT NOT NULL, rule_id TEXT NOT NULL, due_at INTEGER NOT NULL,
         fired_at INTEGER NOT NULL, devices INTEGER NOT NULL, sent INTEGER NOT NULL,
         detail TEXT)`,
    ),
    env.DB.prepare(
      `CREATE INDEX IF NOT EXISTS idx_deliveries_topic ON deliveries (topic, fired_at)`,
    ),
  ]);
  deliveriesTableReady = true;
}

async function runDueSchedules(env: Env): Promise<void> {
  const now = Date.now();

  const { results } = await env.DB.prepare(
    `SELECT topic, rule_id, due_at, payload FROM schedules
     WHERE due_at <= ?1 ORDER BY due_at ASC LIMIT ?2`,
  )
    .bind(now, MAX_DUE_PER_TICK)
    .all<{ topic: string; rule_id: string; due_at: number; payload: string }>();

  if (!results || results.length === 0) return;
  await ensureDeliveriesTable(env);

  let accessToken: string | null = null;
  const staleTokens: string[] = [];
  const statements: D1PreparedStatement[] = [];

  for (const row of results) {
    let devices = 0;
    let sent = 0;
    let detail: string | null = null;

    if (now - row.due_at > STALE_AFTER_MS) {
      // Long overdue: the device's own catch-up has dealt with this by now,
      // and pushing it would re-deliver something the user already saw.
      detail = 'skipped: stale';
    } else {
      // Per row, so one failure cannot strand the rows after it - previously a
      // throw here skipped the delete for rows already sent, and they went out
      // again the next minute.
      try {
        const holders = await devicesOn(env, row.topic);
        if (holders.android) {
          accessToken ??= await getAccessToken(env);
          const outcome = await pushToTopic(env, accessToken, row.topic, row.payload, 'scheduled');
          devices = outcome.devices;
          sent = outcome.sent;
          staleTokens.push(...outcome.stale);
          if (outcome.errors.length > 0) detail = outcome.errors.join(' | ');
        }
        // Desktop hears about scheduled directives too. Until the hub existed
        // the cron could only reach Android, so a PC got no server-side
        // scheduling at all.
        if (holders.desktop) {
          devices++;
          if (await publishToHub(env, row.topic, row.payload, 'scheduled')) sent++;
          else if (detail == null) detail = 'hub publish failed';
        }
        if (devices === 0) detail = 'no device registered for topic';
      } catch (e) {
        detail = `error: ${String(e).slice(0, 200)}`;
      }
    }

    console.log(
      `scheduled ${row.rule_id} due=${new Date(row.due_at).toISOString()} ` +
        `devices=${devices} sent=${sent}${detail ? ` detail=${detail}` : ''}`,
    );

    statements.push(
      env.DB.prepare(
        `INSERT INTO deliveries (topic, rule_id, due_at, fired_at, devices, sent, detail)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
      ).bind(row.topic, row.rule_id, row.due_at, Date.now(), devices, sent, detail),
      env.DB.prepare(
        `DELETE FROM schedules WHERE topic = ?1 AND rule_id = ?2 AND due_at = ?3`,
      ).bind(row.topic, row.rule_id, row.due_at),
    );
  }

  statements.push(
    env.DB.prepare(`DELETE FROM deliveries WHERE fired_at < ?1`).bind(
      now - DELIVERY_LOG_RETENTION_MS,
    ),
    // Desktop registrations are client ids, so FCM never reports them dead and
    // nothing else would ever remove one. A machine still in use re-claims its
    // topic whenever it reconnects.
    env.DB.prepare(`DELETE FROM devices WHERE platform != 'android' AND updated_at < ?1`).bind(
      now - DESKTOP_REGISTRATION_TTL_MS,
    ),
  );
  await env.DB.batch(statements);
  await pruneTokens(env, staleTokens);
}

/**
 * Everything the server knows about one topic, for the app's diagnostics panel.
 *
 * Answers the three questions a missed scheduled directive raises: is this
 * device registered, is anything staged, and what did the cron actually do.
 * Returns no tokens and no payloads. The topic is already a hash of the pairing
 * code, and the same hash is visible on the public relay.
 */
async function handleDiag(url: URL, env: Env): Promise<Response> {
  await ensureDeliveriesTable(env);
  const topic = url.searchParams.get('topic');
  if (!topic) return handleDiagSummary(env);

  const [devices, staged, deliveries] = await env.DB.batch([
    env.DB.prepare(
      `SELECT platform, updated_at FROM devices WHERE topic = ?1 ORDER BY updated_at DESC`,
    ).bind(topic),
    env.DB.prepare(
      `SELECT COUNT(*) AS count, MIN(due_at) AS next_due FROM schedules WHERE topic = ?1`,
    ).bind(topic),
    env.DB.prepare(
      `SELECT rule_id, due_at, fired_at, devices, sent, detail FROM deliveries
       WHERE topic = ?1 ORDER BY fired_at DESC LIMIT 15`,
    ).bind(topic),
  ]);

  const stagedRow = (staged.results?.[0] ?? {}) as { count?: number; next_due?: number | null };
  return json({
    now: Date.now(),
    devices: devices.results ?? [],
    staged: stagedRow.count ?? 0,
    nextDue: stagedRow.next_due ?? null,
    deliveries: deliveries.results ?? [],
  });
}

/**
 * Service-wide totals, with no topics, tokens or payloads - enough to answer
 * "is anything registered, is anything staged, is the cron sending" without
 * knowing anyone's pairing code.
 */
async function handleDiagSummary(env: Env): Promise<Response> {
  const since = Date.now() - 24 * 60 * 60 * 1000;
  const [devices, staged, deliveries] = await env.DB.batch([
    env.DB.prepare(
      `SELECT platform, COUNT(*) AS count, MAX(updated_at) AS last_registered
       FROM devices GROUP BY platform`,
    ),
    env.DB.prepare(`SELECT COUNT(*) AS count, MIN(due_at) AS next_due FROM schedules`),
    env.DB.prepare(
      `SELECT SUM(CASE WHEN detail LIKE 'superseded%' THEN 0 ELSE 1 END) AS attempts,
              SUM(CASE WHEN sent > 0 THEN 1 ELSE 0 END) AS delivered,
              SUM(CASE WHEN devices = 0 AND (detail IS NULL OR detail NOT LIKE 'superseded%')
                       THEN 1 ELSE 0 END) AS no_device,
              SUM(CASE WHEN detail LIKE 'superseded%' THEN 1 ELSE 0 END) AS superseded
       FROM deliveries WHERE fired_at >= ?1`,
    ).bind(since),
  ]);
  return json({
    now: Date.now(),
    devices: devices.results ?? [],
    staged: staged.results?.[0] ?? {},
    last24h: deliveries.results?.[0] ?? {},
  });
}

// ---------------------------------------------------------------------------
// Patreon early-access builds
// ---------------------------------------------------------------------------

/**
 * Serves the Patreon channel's manifest, its signature and its downloads, to
 * requests carrying a valid Patreon code in X-Patreon-Code.
 *
 * The repository is public, so these addresses are no secret; the code is
 * what keeps the builds to supporters. It is checked the way the app checks
 * it - trimmed, upper-cased, salted, hashed - so one code works in both
 * places. It arrives in a header rather than the URL because URLs are logged.
 *
 * The files live in R2 under the same names as their paths here:
 * latest.json, latest.json.sig and download/<file>.
 */
async function isPatreonCode(code: string | null, env: Env): Promise<boolean> {
  if (!code) return false;
  const salted = new TextEncoder().encode(`patreon_quest_salt_v1_${code.trim().toUpperCase()}`);
  const digest = [...new Uint8Array(await crypto.subtle.digest('SHA-256', salted))]
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
  return (env.PATREON_CODE_DIGESTS ?? '')
    .split(',')
    .map((d) => d.trim().toLowerCase())
    .includes(digest);
}

async function handlePatreonFile(request: Request, url: URL, env: Env): Promise<Response> {
  if (!(await isPatreonCode(request.headers.get('X-Patreon-Code'), env))) {
    return json({ error: 'a valid Patreon code is required' }, 403);
  }

  const key = url.pathname.slice('/patreon/'.length);
  const allowed =
    key === 'latest.json' ||
    key === 'latest.json.sig' ||
    /^download\/[A-Za-z0-9._-]+$/.test(key);
  if (!allowed) return json({ error: 'not found' }, 404);

  const object = await env.PATREON_BUILDS.get(key);
  if (!object) return json({ error: 'not found' }, 404);

  return new Response(object.body, {
    headers: {
      'content-type': key === 'latest.json' ? 'application/json; charset=utf-8' : 'application/octet-stream',
      'content-length': String(object.size),
      // Per-supporter responses; nothing between here and the app keeps them.
      'cache-control': 'private, no-store',
    },
  });
}

// ---------------------------------------------------------------------------
// Chastity timer
// ---------------------------------------------------------------------------

/** Public link id -> timer id. The link can be replaced or switched off
 * without the timer, and its keys, changing. */
async function ensureTimerLinksTable(env: Env): Promise<void> {
  await env.DB.exec(
    'CREATE TABLE IF NOT EXISTS timer_links (public_id TEXT PRIMARY KEY, timer_id TEXT NOT NULL)',
  );
}

function timerStub(env: Env, timerId: string): DurableObjectStub {
  return env.CHASTITY_TIMER.get(env.CHASTITY_TIMER.idFromName(timerId));
}

function callTimer(env: Env, timerId: string, op: string, body: unknown, key?: string | null): Promise<Response> {
  return timerStub(env, timerId).fetch(`https://timer/${op}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(key ? { 'X-Timer-Key': key } : {}) },
    body: JSON.stringify(body ?? {}),
  });
}

/** Keeps timer_links in step with whatever link id the timer now has. */
async function syncLink(env: Env, timerId: string, previous: string | null, current: string | null): Promise<void> {
  if (previous === current) return;
  await ensureTimerLinksTable(env);
  if (previous) await env.DB.prepare('DELETE FROM timer_links WHERE public_id = ?').bind(previous).run();
  if (current) {
    await env.DB.prepare('INSERT OR REPLACE INTO timer_links (public_id, timer_id) VALUES (?, ?)')
      .bind(current, timerId).run();
  }
}

async function handleTimerCreate(request: Request, env: Env): Promise<Response> {
  const body: any = await request.json().catch(() => ({}));
  const id = randomToken(16);
  const playerKey = randomToken(24);
  const directorKey = randomToken(24);
  const publicId = randomToken(9);
  const created = await callTimer(env, id, 'create', {
    id,
    managedBy: body.managedBy === 'player' ? 'player' : 'director',
    config: body.config,
    playerKeyHash: await sha256Hex(playerKey),
    directorKeyHash: await sha256Hex(directorKey),
    publicId,
  });
  if (!created.ok) return created;
  const { publicId: linked } = (await created.json()) as { publicId: string | null };
  await syncLink(env, id, null, linked);
  // Both keys go to the creator, who passes the other party theirs over the
  // partners' encrypted channel. Only their hashes are kept here.
  return json({ id, playerKey, directorKey, publicId: linked });
}

async function handleTimerOp(request: Request, env: Env, timerId: string, op: string): Promise<Response> {
  const key = request.headers.get('X-Timer-Key');
  const body: any = request.method === 'POST' ? await request.json().catch(() => ({})) : {};

  if (op === 'view') return callTimer(env, timerId, 'view', {}, key);
  if (
    op === 'adjust' || op === 'release' || op === 'reissue-key' || op === 'notify-topic' ||
    op === 'order-result' || op === 'order-skip'
  ) {
    return callTimer(env, timerId, op, body, key);
  }

  if (op === 'configure' || op === 'replace-link') {
    const before = (await (await callTimer(env, timerId, 'view', {}, key)).json()) as { publicId?: string | null };
    const response = await callTimer(env, timerId, op, { ...body, newPublicId: randomToken(9) }, key);
    if (!response.ok) return response;
    const after: any = await response.json();
    await syncLink(env, timerId, before.publicId ?? after.previous ?? null, after.publicId ?? null);
    return json(after);
  }
  return json({ error: 'not found' }, 404);
}

const PUBLIC_CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
  'access-control-allow-headers': 'content-type',
};

function withCors(response: Response): Response {
  const out = new Response(response.body, response);
  for (const [k, v] of Object.entries(PUBLIC_CORS)) out.headers.set(k, v);
  return out;
}

async function verifyTurnstile(env: Env, token: unknown, ip: string | null): Promise<boolean> {
  // Trimmed: a secret piped in from Windows PowerShell arrives with a
  // trailing carriage return, which Turnstile would reject as a wrong secret.
  const secret = env.TURNSTILE_SECRET?.trim();
  if (!secret) return true;
  if (typeof token !== 'string' || !token) return false;
  const form = new FormData();
  form.append('secret', secret);
  form.append('response', token);
  if (ip) form.append('remoteip', ip);
  const r = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', { method: 'POST', body: form });
  const result = (await r.json().catch(() => ({}))) as { success?: boolean };
  return result.success === true;
}

const PAGE_HEADERS = {
  'content-type': 'text/html; charset=utf-8',
  'cache-control': 'no-store',
  'x-robots-tag': 'noindex, nofollow',
  'referrer-policy': 'no-referrer',
  // The voting page is never framed by another site: one could otherwise lay
  // it out of sight under a disguised button and harvest votes. Embedding is
  // what /embed is for.
  'content-security-policy': "frame-ancestors 'none'",
  'x-frame-options': 'DENY',
};

/** The embeddable widget may be framed by anyone. */
const EMBED_HEADERS = {
  'content-type': 'text/html; charset=utf-8',
  'cache-control': 'no-store',
  'x-robots-tag': 'noindex, nofollow',
  'referrer-policy': 'no-referrer',
  'content-security-policy': 'frame-ancestors *',
};

/** Any /t/ address with no live timer behind it: what was there, and the app. */
function timerEndedPage(): Response {
  return new Response(expiredPage(), { status: 404, headers: PAGE_HEADERS });
}

/** The forum image. A minute's caching keeps a post that goes wide cheap. */
function badgeResponse(view: PublicView | null, whenNone: 'ended' | 'idle' = 'ended'): Response {
  return new Response(badgeSvg(view, whenNone), {
    headers: {
      'content-type': 'image/svg+xml; charset=utf-8',
      'cache-control': 'public, max-age=60',
      'x-robots-tag': 'noindex, nofollow',
      'access-control-allow-origin': '*',
    },
  });
}

/**
 * Who a vote or order is from, for the per-visitor limits - or null if they
 * have not shown they are a person. A verified app is its device; a browser
 * passes Cloudflare's check and is its address. Either way it is hashed, for
 * this link and today, so nothing identifying is stored.
 */
async function visitorOf(request: Request, env: Env, publicId: string, turnstileToken: unknown): Promise<string | null> {
  const day = new Date().toISOString().slice(0, 10);
  const device = await deviceOf(env.DB, request, sha256Hex);
  if (device) return (await sha256Hex(`device:${device}:${publicId}:${day}`)).slice(0, 16);
  const ip = request.headers.get('CF-Connecting-IP');
  if (!(await verifyTurnstile(env, turnstileToken, ip))) return null;
  return (await sha256Hex(`${ip ?? 'unknown'}:${publicId}:${day}`)).slice(0, 16);
}

async function handlePublicTimer(request: Request, env: Env, publicId: string, op: string): Promise<Response> {
  await ensureTimerLinksTable(env);
  const row = await env.DB.prepare('SELECT timer_id FROM timer_links WHERE public_id = ?')
    .bind(publicId).first<{ timer_id: string }>();

  // The widget and the image are asked for by other sites, often long after
  // the timer has gone: they show it ended rather than an error.
  if (op === 'embed' || op === 'badge.svg' || op === 'badge.png' || op === 'preview.png') {
    const live = row ? await callTimer(env, row.timer_id, 'public-view', { publicId }) : null;
    if (!live || live.status === 404) {
      if (row) await env.DB.prepare('DELETE FROM timer_links WHERE public_id = ?').bind(publicId).run();
      if (op === 'embed') return new Response(endedEmbedPage(), { headers: EMBED_HEADERS });
      if (op === 'badge.svg') return badgeResponse(null);
      return pngResponse(op === 'preview.png' ? 'preview' : 'badge', 'ended');
    }
    if (op === 'badge.svg') return badgeResponse((await live.json()) as PublicView);
    if (op === 'badge.png' || op === 'preview.png') {
      const view = (await live.json()) as PublicView;
      return pngResponse(op === 'preview.png' ? 'preview' : 'badge', view.status === 'running' ? 'locked' : 'unlocked');
    }
    const timerUrl = `https://subtaskmanager.com/t/${publicId}`;
    return new Response(embedPage(timerUrl), { headers: EMBED_HEADERS });
  }

  if (!op) {
    if (!row) return timerEndedPage();
    // A link whose timer has been deleted (30 days after it ended) leaves its
    // row behind if it was deleted before rows were cleaned up with it:
    // tidied on the first visit.
    const alive = await callTimer(env, row.timer_id, 'public-view', { publicId });
    if (alive.status === 404) {
      await env.DB.prepare('DELETE FROM timer_links WHERE public_id = ?').bind(publicId).run();
      return timerEndedPage();
    }
    const view = (await alive.json()) as PublicView;
    return new Response(publicPage(publicId, env.TURNSTILE_SITE_KEY ?? null, previewText(view)), { headers: PAGE_HEADERS });
  }

  if (!row) return withCors(json({ error: 'no such timer' }, 404));

  if (op === 'state' && request.method === 'GET') {
    return withCors(await callTimer(env, row.timer_id, 'public-view', { publicId }));
  }

  if (op === 'order' && request.method === 'POST') {
    const body: any = await request.json().catch(() => ({}));
    const visitor = await visitorOf(request, env, publicId, body.turnstileToken);
    if (!visitor) return withCors(json({ error: 'turnstile' }, 403));
    return withCors(await callTimer(env, row.timer_id, 'public-order', {
      publicId,
      visitor,
      orderId: body.orderId,
      issuerKey: body.issuerKey,
      receiptHash: body.receiptHash,
      issuerTopic: body.issuerTopic,
    }));
  }

  if (op === 'watch' && request.method === 'POST') {
    // Only a verified app: a watch list is a list of addresses to message.
    const device = await deviceOf(env.DB, request, sha256Hex);
    if (!device) return withCors(json({ error: 'not-verified' }, 403));
    const body: any = await request.json().catch(() => ({}));
    return withCors(await callTimer(env, row.timer_id, 'public-watch', { publicId, topic: body.topic, on: body.on !== false }));
  }

  if (op === 'review' && request.method === 'POST') {
    const body: any = await request.json().catch(() => ({}));
    return withCors(await callTimer(env, row.timer_id, 'public-review', {
      publicId,
      no: body.no,
      receipt: body.receipt,
      verdict: body.verdict === 'approve' ? 'approve' : 'reject',
    }));
  }

  if (op === 'proof' && request.method === 'POST') {
    // The receipt goes in the body, never the address: an address ends up
    // in logs and histories.
    const body: any = await request.json().catch(() => ({}));
    return withCors(await callTimer(env, row.timer_id, 'public-proof', { publicId, no: body.no, receipt: body.receipt }));
  }

  if (op === 'vote' && request.method === 'POST') {
    const body: any = await request.json().catch(() => ({}));
    const visitor = await visitorOf(request, env, publicId, body.turnstileToken);
    if (!visitor) return withCors(json({ error: 'turnstile' }, 403));
    return withCors(await callTimer(env, row.timer_id, 'public-vote', {
      publicId,
      visitor,
      direction: body.direction === -1 ? -1 : 1,
    }));
  }
  return withCors(json({ error: 'not found' }, 404));
}

// ---------------------------------------------------------------------------
// A player's public page (see profile.ts)
// ---------------------------------------------------------------------------

async function handleProfileCreate(request: Request, env: Env): Promise<Response> {
  const body: any = await request.json().catch(() => ({}));
  await ensureProfileTables(env.DB);
  const id = randomToken(16);
  const publicId = randomToken(9);
  const key = randomToken(24);
  const name = cleanName(body.name);
  await env.DB.prepare(
    'INSERT INTO profiles (id, public_id, key_hash, name, show_history, created_at) VALUES (?, ?, ?, ?, 0, ?)',
  )
    .bind(id, publicId, await sha256Hex(key), name, Date.now())
    .run();
  // The key goes to the player's app alone; only its hash is kept here.
  return json({ profileId: id, publicId, key, name, showHistory: false, timers: [] });
}

async function handleProfileOp(request: Request, env: Env, profileId: string, op: string): Promise<Response> {
  // The app sends it in the header its timer requests use.
  const key = request.headers.get('X-Profile-Key') ?? request.headers.get('X-Timer-Key');
  const row = await profileWithKey(env.DB, profileId, key, sha256Hex);
  if (!row) return json({ error: 'not your profile' }, 403);
  const body: any = request.method === 'POST' ? await request.json().catch(() => ({})) : {};
  const timerId = typeof body.timerId === 'string' && /^[A-Za-z0-9_-]{8,64}$/.test(body.timerId) ? body.timerId : null;

  switch (op) {
    case 'view':
      return json(await profileSummary(env.DB, row));

    case 'settings': {
      const name = 'name' in body ? cleanName(body.name) : row.name;
      const showHistory = typeof body.showHistory === 'boolean' ? (body.showHistory ? 1 : 0) : row.show_history;
      await env.DB.prepare('UPDATE profiles SET name = ?, show_history = ? WHERE id = ?').bind(name, showHistory, row.id).run();
      return json(await profileSummary(env.DB, { ...row, name, show_history: showHistory }));
    }

    case 'add': {
      // Only a timer this device is the player on: its key proves it.
      if (!timerId || typeof body.timerKey !== 'string') return json({ error: 'bad-timer' }, 400);
      const check = await callTimer(env, timerId, 'view', {}, body.timerKey);
      if (!check.ok) return json({ error: 'not your timer' }, 403);
      const view = (await check.json()) as { role?: string };
      if (view.role !== 'player') return json({ error: 'not-player' }, 403);
      await addProfileTimer(env.DB, row.id, timerId);
      return json(await profileSummary(env.DB, row));
    }

    case 'remove':
      if (!timerId) return json({ error: 'bad-timer' }, 400);
      await removeProfileTimer(env.DB, row.id, timerId);
      return json(await profileSummary(env.DB, row));

    case 'new-link': {
      // The old link stops working at once, as a timer's does.
      const publicId = randomToken(9);
      await env.DB.prepare('UPDATE profiles SET public_id = ? WHERE id = ?').bind(publicId, row.id).run();
      return json(await profileSummary(env.DB, { ...row, public_id: publicId }));
    }

    case 'rekey': {
      // Moving the profile to another device: the new device gets a fresh
      // key, and the one it was moved from can no longer change it.
      const key = randomToken(24);
      await env.DB.prepare('UPDATE profiles SET key_hash = ? WHERE id = ?').bind(await sha256Hex(key), row.id).run();
      return json({ ...(await profileSummary(env.DB, row)), key });
    }
  }
  return json({ error: 'not found' }, 404);
}

async function handlePublicProfile(env: Env, publicId: string, op: string): Promise<Response> {
  const row = await profileByPublicId(env.DB, publicId);
  if (!row) {
    if (op === 'embed') return new Response(endedEmbedPage(), { headers: EMBED_HEADERS });
    if (op === 'badge.svg') return badgeResponse(null);
    if (op === 'badge.png' || op === 'preview.png') return pngResponse(op === 'preview.png' ? 'preview' : 'badge', 'ended');
    if (op === 'state') return withCors(json({ error: 'no such profile' }, 404));
    return new Response(profileGonePage(), { status: 404, headers: PAGE_HEADERS });
  }
  await ensureTimerLinksTable(env);
  const state = await profileState(env.DB, row, async (timerId, timerPublicId) => {
    const r = await callTimer(env, timerId, 'profile-view', { publicId: timerPublicId });
    return r.ok ? ((await r.json()) as PublicView) : null;
  });
  const url = `https://subtaskmanager.com/p/${publicId}`;

  switch (op) {
    case 'state':
      return withCors(json(state));
    case 'embed':
      return new Response(embedPage(url, true), { headers: EMBED_HEADERS });
    case 'badge.svg':
      return badgeResponse(state.featured, 'idle');
    case 'badge.png':
    case 'preview.png':
      return pngResponse(op === 'preview.png' ? 'preview' : 'badge', state.featured ? 'locked' : 'unlocked');
  }
  const preview = state.featured
    ? previewText(state.featured)
    : { title: 'Chastity Timer', description: 'Not locked up right now.', state: 'unlocked' as const };
  if (state.name) preview.title = preview.title.replace('Chastity Timer', `${state.name}'s Chastity Timer`);
  return new Response(publicPage(publicId, env.TURNSTILE_SITE_KEY ?? null, preview, { profile: true }), {
    headers: PAGE_HEADERS,
  });
}

// ---------------------------------------------------------------------------
// Website downloads (see download_stats.ts)
// ---------------------------------------------------------------------------

async function ensureDownloadCountsTable(env: Env): Promise<void> {
  await env.DB.exec(
    'CREATE TABLE IF NOT EXISTS download_counts (day TEXT NOT NULL, platform TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (day, platform))',
  );
}

async function countDownload(env: Env, platform: string): Promise<void> {
  await ensureDownloadCountsTable(env);
  await env.DB.prepare(
    'INSERT INTO download_counts (day, platform, count) VALUES (?, ?, 1) ON CONFLICT (day, platform) DO UPDATE SET count = count + 1',
  ).bind(new Date().toISOString().slice(0, 10), platform).run();
}

async function handleDownload(request: Request, env: Env, ctx: ExecutionContext, platform: string): Promise<Response> {
  if (platform === 'stats') {
    // Trimmed, as for the Turnstile secret: PowerShell adds a line ending.
    if (!(await hasStatsPassword(request.headers.get('Authorization'), env.STATS_PASSWORD?.trim()))) {
      return new Response('Password required.', {
        status: 401,
        headers: { 'www-authenticate': 'Basic realm="SubTask Manager downloads", charset="UTF-8"', 'cache-control': 'no-store' },
      });
    }
    await ensureDownloadCountsTable(env);
    const rows = (await env.DB.prepare('SELECT day, platform, count FROM download_counts').all<CountRow>()).results;
    const today = new Date().toISOString().slice(0, 10);
    const summary = summarize(rows, today);
    if (new URL(request.url).searchParams.get('format') === 'json') {
      return new Response(JSON.stringify(summary), {
        headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
      });
    }
    return new Response(statsPage(summary, today), {
      headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', 'x-robots-tag': 'noindex, nofollow' },
    });
  }

  if (!DOWNLOADS[platform]) return json({ error: 'not found' }, 404);
  // Counted in the background, so the download is not held up by it - and a
  // failure to count never stops anyone downloading.
  if (request.method === 'GET' && !isBot(request.headers.get('User-Agent'))) {
    ctx.waitUntil(countDownload(env, platform).catch(() => {}));
  }
  return new Response(null, {
    status: 302,
    // Not cached anywhere, so every click reaches here and is counted.
    headers: { location: releaseUrl(platform), 'cache-control': 'no-store' },
  });
}

export default {
  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(runDueSchedules(env));
    ctx.waitUntil(sweepExpiredBlobs(env));
  },

  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    const download = url.pathname.match(/^\/download\/([a-z]+)\/?$/);
    if (download && (request.method === 'GET' || request.method === 'HEAD')) {
      return handleDownload(request, env, ctx, download[1]).catch((e) => json({ error: String(e) }, 500));
    }

    if (request.method === 'GET' && url.pathname === '/health') {
      return json({ ok: true, project: env.FCM_PROJECT_ID });
    }

    // Exercises the credential path on its own. /send deliberately answers 404
    // before minting a token when no device holds the topic, so a healthy 404
    // says nothing about whether signing, the token exchange or the secret
    // actually work. This is the only way to test them without a real device.
    if (request.method === 'GET' && url.pathname === '/selftest') {
      const startedAt = Date.now();
      try {
        const token = await getAccessToken(env);
        // Enough of the key id to tell one credential from another, which is
        // what a rotation has to prove. This endpoint is public, so no more
        // than that: not the whole id, not the account it belongs to, and
        // never the key.
        const account = JSON.parse(env.FCM_SERVICE_ACCOUNT) as { private_key_id?: string };
        return json({
          ok: true,
          // Never the token itself; its shape is enough to confirm success.
          tokenLength: token.length,
          keyIdPrefix: account.private_key_id?.slice(0, 8) ?? null,
          elapsedMs: Date.now() - startedAt,
          note: 'JWT signed, exchanged for an access token, cached in KV',
        });
      } catch (e) {
        return json({ ok: false, error: String(e) }, 500);
      }
    }

    // Desktop's live channel. The hub is addressed by topic, which is already
    // a hash of the pairing code.
    if (url.pathname === '/subscribe') {
      const topic = url.searchParams.get('topic');
      if (!topic) return json({ error: 'topic is required' }, 400);
      const stub = env.TOPIC_HUB.get(env.TOPIC_HUB.idFromName(topic));
      return stub.fetch(request);
    }

    if (request.method === 'GET' && url.pathname === '/diag') {
      return handleDiag(url, env).catch((e) => json({ error: String(e) }, 500));
    }

    if (request.method === 'POST' && url.pathname === '/register') {
      return handleRegister(request, env).catch((e) =>
        json({ error: String(e) }, 500),
      );
    }

    if (request.method === 'POST' && url.pathname === '/schedule') {
      return handleSchedule(request, env).catch((e) => json({ error: String(e) }, 500));
    }

    if (request.method === 'POST' && url.pathname === '/send') {
      return handleSend(request, env).catch((e) => json({ error: String(e) }, 500));
    }

    if (request.method === 'POST' && url.pathname === '/blob') {
      return handleBlobPut(request, env).catch((e) => json({ error: String(e) }, 500));
    }

    if (request.method === 'GET' && url.pathname === '/blob') {
      return handleBlobGet(url, env).catch((e) => json({ error: String(e) }, 500));
    }

    const ip = request.headers.get('CF-Connecting-IP') ?? 'unknown';
    if (request.method === 'POST' && url.pathname === '/timer') {
      // Starting a timer needs no key: limited per address.
      if (!(await withinLimit(env.TIMER_CREATE_LIMIT, ip))) return slowDown();
      return handleTimerCreate(request, env).catch((e) => json({ error: String(e) }, 500));
    }
    // The app's one-time human check, and the page it shows it in.
    if (request.method === 'POST' && url.pathname === '/device/start') {
      if (!(await withinLimit(env.TIMER_CREATE_LIMIT, `device:${ip}`))) return slowDown();
      const body: any = await request.json().catch(() => ({}));
      const id = await startDevice(env.DB, body.codeHash, body.secretHash, () => randomToken(16));
      return id ? json({ deviceId: id }) : json({ error: 'bad-request' }, 400);
    }
    if (request.method === 'GET' && url.pathname === '/device/status') {
      // The app, asking with its secret whether its check has passed.
      const verified = await deviceOf(env.DB, request, sha256Hex);
      const known = verified ?? (await deviceOf(env.DB, request, sha256Hex, { verifiedOnly: false }));
      return known ? json({ verified: Boolean(verified) }) : json({ error: 'unknown' }, 404);
    }
    if (request.method === 'POST' && url.pathname === '/app/verify/confirm') {
      if (!(await withinLimit(env.TIMER_CREATE_LIMIT, `device:${ip}`))) return slowDown();
      const body: any = await request.json().catch(() => ({}));
      if (!(await verifyTurnstile(env, body.turnstileToken, request.headers.get('CF-Connecting-IP')))) {
        return json({ error: 'turnstile' }, 403);
      }
      return (await confirmDevice(env.DB, body.id)) ? json({ ok: true }) : json({ error: 'not-found' }, 404);
    }
    if (request.method === 'GET' && url.pathname === '/app/verify') {
      return new Response(verifyPage(env.TURNSTILE_SITE_KEY ?? null), {
        headers: { ...PAGE_HEADERS, 'content-security-policy': "frame-ancestors 'none'" },
      });
    }
    if (request.method === 'POST' && url.pathname === '/profile') {
      if (!(await withinLimit(env.TIMER_CREATE_LIMIT, `profile:${ip}`))) return slowDown();
      return handleProfileCreate(request, env).catch((e) => json({ error: String(e) }, 500));
    }
    const profileRoute = url.pathname.match(/^\/profile\/([A-Za-z0-9_-]{8,64})\/([a-z-]+)$/);
    if (profileRoute) {
      if (!(await withinLimit(env.TIMER_OP_LIMIT, `profile:${profileRoute[1]}`))) return slowDown();
      return handleProfileOp(request, env, profileRoute[1], profileRoute[2]).catch((e) => json({ error: String(e) }, 500));
    }
    const publicProfileRoute = url.pathname.match(/^\/p\/([A-Za-z0-9_-]{6,32})(?:\/(state|embed|badge\.svg|badge\.png|preview\.png))?\/?$/);
    if (publicProfileRoute && (request.method === 'GET' || request.method === 'HEAD' || request.method === 'OPTIONS')) {
      if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: PUBLIC_CORS });
      const op = publicProfileRoute[2] ?? '';
      if (op === 'state' && !(await withinLimit(env.TIMER_PUBLIC_LIMIT, ip))) return withCors(slowDown());
      return handlePublicProfile(env, publicProfileRoute[1], op).catch((e) => withCors(json({ error: String(e) }, 500)));
    }
    if (url.pathname.startsWith('/p/') && (request.method === 'GET' || request.method === 'HEAD')) {
      return new Response(profileGonePage(), { status: 404, headers: PAGE_HEADERS });
    }
    const timerRoute = url.pathname.match(/^\/timer\/([A-Za-z0-9_-]{8,64})\/([a-z-]+)$/);
    if (timerRoute) {
      // Per timer: a script working one timer hard gets nowhere, and two
      // people sharing an address never slow each other down.
      if (!(await withinLimit(env.TIMER_OP_LIMIT, timerRoute[1]))) return slowDown();
      return handleTimerOp(request, env, timerRoute[1], timerRoute[2]).catch((e) => json({ error: String(e) }, 500));
    }
    const publicRoute = url.pathname.match(/^\/t\/([A-Za-z0-9_-]{6,32})(?:\/(state|vote|order|proof|review|watch|embed|badge\.svg|badge\.png|preview\.png))?\/?$/);
    if (publicRoute) {
      if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: PUBLIC_CORS });
      // The page's own reads and votes, per visitor. Not the page, images or
      // widget: other sites fetch those through one shared address.
      const op = publicRoute[2];
      if (
        (op === 'state' || op === 'vote' || op === 'order' || op === 'proof' || op === 'review' || op === 'watch') &&
        !(await withinLimit(env.TIMER_PUBLIC_LIMIT, ip))
      ) {
        return withCors(slowDown());
      }
      return handlePublicTimer(request, env, publicRoute[1], publicRoute[2] ?? '')
        .catch((e) => withCors(json({ error: String(e) }, 500)));
    }
    // Anything else under /t/ - mistyped, truncated, made up - gets the same
    // page as an ended timer rather than an error.
    if (url.pathname.startsWith('/t/') && (request.method === 'GET' || request.method === 'HEAD')) {
      return timerEndedPage();
    }

    if (request.method === 'GET' && url.pathname.startsWith('/patreon/')) {
      return handlePatreonFile(request, url, env).catch((e) => json({ error: String(e) }, 500));
    }

    return json({ error: 'not found' }, 404);
  },
};
