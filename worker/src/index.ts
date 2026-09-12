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

  const { results } = await env.DB.prepare(
    `SELECT push_token FROM devices WHERE topic = ?1 ORDER BY updated_at DESC LIMIT ?2`,
  )
    .bind(body.topic, MAX_TOKENS_PER_TOPIC)
    .all<{ push_token: string }>();

  if (!results || results.length === 0) {
    // No Android device has claimed this topic. The caller should fall back to
    // its existing transport rather than treat this as a delivery failure.
    return json({ sent: 0, unregistered: true }, 404);
  }

  const accessToken = await getAccessToken(env);
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
          // Data-only: the app decides what to show, so its dedup and
          // addressing rules still apply.
          data: {
            p: body.payload,
            k: body.kind ?? 'sync',
            v: '1',
          },
          android: { priority: 'high' },
        },
      }),
    });

    if (response.ok) {
      sent++;
      continue;
    }

    const detail = await response.text();
    // A token that the device has replaced or that belongs to an uninstalled
    // app stays in the table forever unless it is pruned here, and every send
    // to that topic keeps paying for it.
    if (response.status === 404 || detail.includes('UNREGISTERED') || detail.includes('INVALID_ARGUMENT')) {
      stale.push(row.push_token);
    } else {
      errors.push(`${response.status}: ${detail.slice(0, 200)}`);
    }
  }

  if (stale.length > 0) {
    const placeholders = stale.map((_, i) => `?${i + 1}`).join(',');
    await env.DB.prepare(`DELETE FROM devices WHERE push_token IN (${placeholders})`)
      .bind(...stale)
      .run();
  }

  return json({ sent, pruned: stale.length, errors }, sent > 0 ? 200 : 502);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === 'GET' && url.pathname === '/health') {
      return json({ ok: true, project: env.FCM_PROJECT_ID });
    }

    if (request.method === 'POST' && url.pathname === '/register') {
      return handleRegister(request, env).catch((e) =>
        json({ error: String(e) }, 500),
      );
    }

    if (request.method === 'POST' && url.pathname === '/send') {
      return handleSend(request, env).catch((e) => json({ error: String(e) }, 500));
    }

    return json({ error: 'not found' }, 404);
  },
};
