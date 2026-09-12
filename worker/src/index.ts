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

export interface Env {
  DB: D1Database;
  TOKEN_CACHE: KVNamespace;
  FCM_PROJECT_ID: string;
  FCM_SERVICE_ACCOUNT: string; // service-account JSON, set via `wrangler secret put`
}

const OAUTH_TOKEN_URL = 'https://oauth2.googleapis.com/token';
const FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
const ACCESS_TOKEN_KEY = 'fcm_access_token';

/** Google issues these for an hour; refresh early so a request never races expiry. */
const ACCESS_TOKEN_TTL_SECONDS = 3300;

/** FCM caps a data message at 4KB. Anything larger travels via R2 (phase 04). */
const MAX_PAYLOAD_BYTES = 3500;

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
): Promise<{ sent: number; stale: string[] }> {
  const { results } = await env.DB.prepare(
    `SELECT push_token FROM devices WHERE topic = ?1 ORDER BY updated_at DESC LIMIT ?2`,
  )
    .bind(topic, MAX_TOKENS_PER_TOPIC)
    .all<{ push_token: string }>();

  if (!results || results.length === 0) return { sent: 0, stale: [] };

  const endpoint = `https://fcm.googleapis.com/v1/projects/${env.FCM_PROJECT_ID}/messages:send`;
  let sent = 0;
  const stale: string[] = [];

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
    if (
      response.status === 404 ||
      detail.includes('UNREGISTERED') ||
      detail.includes('INVALID_ARGUMENT')
    ) {
      stale.push(row.push_token);
    }
  }

  return { sent, stale };
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

  const statements = [
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

  // Checked before minting a token: a desktop target should cost nothing.
  const { results } = await env.DB.prepare(
    `SELECT 1 FROM devices WHERE topic = ?1 LIMIT 1`,
  )
    .bind(body.topic)
    .all();

  if (!results || results.length === 0) {
    // No Android device has claimed this topic. The caller should fall back to
    // its existing transport rather than treat this as a delivery failure.
    return json({ sent: 0, unregistered: true }, 404);
  }

  const accessToken = await getAccessToken(env);
  const { sent, stale } = await pushToTopic(
    env,
    accessToken,
    body.topic,
    body.payload,
    body.kind ?? 'sync',
  );
  await pruneTokens(env, stale);

  return json({ sent, pruned: stale.length }, sent > 0 ? 200 : 502);
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
async function runDueSchedules(env: Env): Promise<void> {
  const now = Date.now();

  const { results } = await env.DB.prepare(
    `SELECT topic, rule_id, due_at, payload FROM schedules
     WHERE due_at <= ?1 ORDER BY due_at ASC LIMIT ?2`,
  )
    .bind(now, MAX_DUE_PER_TICK)
    .all<{ topic: string; rule_id: string; due_at: number; payload: string }>();

  if (!results || results.length === 0) return;

  let accessToken: string | null = null;
  const staleTokens: string[] = [];
  const done: Array<{ topic: string; ruleId: string; dueAt: number }> = [];

  for (const row of results) {
    done.push({ topic: row.topic, ruleId: row.rule_id, dueAt: row.due_at });

    // Long overdue: the device's own catch-up has dealt with this by now, and
    // pushing it would re-deliver something the user already saw.
    if (now - row.due_at > STALE_AFTER_MS) continue;

    accessToken ??= await getAccessToken(env);
    const { stale } = await pushToTopic(env, accessToken, row.topic, row.payload, 'scheduled');
    staleTokens.push(...stale);
  }

  // Delete after attempting, not before: a row that fails to send is one the
  // device will still catch up on, and retrying it every minute for a day
  // would be worse than dropping it.
  if (done.length > 0) {
    await env.DB.batch(
      done.map((d) =>
        env.DB.prepare(
          `DELETE FROM schedules WHERE topic = ?1 AND rule_id = ?2 AND due_at = ?3`,
        ).bind(d.topic, d.ruleId, d.dueAt),
      ),
    );
  }

  await pruneTokens(env, staleTokens);
}

export default {
  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(runDueSchedules(env));
  },

  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

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
        return json({
          ok: true,
          // Never the token itself; its shape is enough to confirm success.
          tokenLength: token.length,
          elapsedMs: Date.now() - startedAt,
          note: 'JWT signed, exchanged for an access token, cached in KV',
        });
      } catch (e) {
        return json({ ok: false, error: String(e) }, 500);
      }
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

    return json({ error: 'not found' }, 404);
  },
};
