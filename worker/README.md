# subtask-push

Cloudflare Worker that fronts Firebase Cloud Messaging for (sub)Task Manager.

It exists so the FCM service-account credential never ships inside an APK.
Devices POST here; this Worker resolves the topic to one or more push tokens
and calls FCM.

It never sees a pairing code (the app hashes those into topics before they
leave the device) and never sees plaintext (payloads are ciphertext from
`EncryptionHelper`). A compromise here leaks who messaged whom and when, not
what was said.

## Setup

Everything below is one-time. `cloudflare_env.ps1` already exports
`CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN`, so wrangler is authenticated
from the repo root.

### 1. Firebase (console, free Spark plan)

Do **not** enable Cloud Functions — those require the Blaze plan and a card on
file, which is the whole reason this Worker exists.

1. Create a project. Note its **project id**.
2. Add an Android app with package name `com.example.orders_app`, download
   `google-services.json` (needed in phase 02, not here).
3. Project settings → Service accounts → **Generate new private key**. This
   downloads a JSON file. Treat it like a password.

### 2. Cloudflare resources

```bash
cd worker
npx wrangler d1 create subtask-push-registry
npx wrangler kv namespace create TOKEN_CACHE
```

Each command prints an id. Put them in `wrangler.toml` where the
`REPLACE_WITH_*` placeholders are, along with your Firebase project id.

### 3. Schema and secret

```bash
npm run schema
npx wrangler secret put FCM_SERVICE_ACCOUNT
```

For the secret, paste the **entire contents** of the service-account JSON file
when prompted — not a path to it, and not just the private key.

### 4. Deploy

```bash
npm run deploy
```

## Verifying before any app changes

This is the phase 01 gate. If these three steps don't work, nothing downstream
will, and debugging is far cheaper here than on a phone.

```bash
# 1. Worker is up and knows its project
curl https://subtask-push.<your-subdomain>.workers.dev/health

# 2. Register a fake device
curl -X POST https://subtask-push.<your-subdomain>.workers.dev/register \
  -H 'content-type: application/json' \
  -d '{"topic":"orders_relay_testtopic","token":"<a real FCM token>","platform":"android"}'

# 3. Send to it
curl -X POST https://subtask-push.<your-subdomain>.workers.dev/send \
  -H 'content-type: application/json' \
  -d '{"topic":"orders_relay_testtopic","payload":"hello","kind":"test"}'
```

A real FCM token for step 2 comes from the app once phase 02 lands. Until then
step 3 will answer `404 {"unregistered":true}`, which still proves routing,
D1 and the token-minting path all work — the JWT signing runs before the
registry lookup fails.

`npm run tail` streams live logs while you test.

## Endpoints

| Method | Path | Body | Notes |
|---|---|---|---|
| `GET` | `/health` | — | Liveness plus configured project id |
| `POST` | `/register` | `{topic, token, platform}` | Upsert, keyed by push token |
| `POST` | `/send` | `{topic, payload, kind?}` | `404` with `unregistered:true` if no Android device holds that topic |

`/send` returning `404 unregistered` is **not** a failure. It means the target
is a desktop device, or hasn't upgraded yet, and the caller should fall back to
the existing ntfy path.

## Design notes

**Data-only messages.** No `notification` block is ever sent. A notification
block is rendered by the system without consulting the app, which would bypass
the addressing, dedup and occurrence-ledger logic the client already applies —
and that logic was hard won. Data-only high-priority messages wake the app in
Doze and let it decide what to show.

**Access-token caching.** Signing the RS256 JWT is the most expensive operation
here. The resulting token is cached in KV for 55 minutes, so signing happens
roughly once an hour rather than once per push. That is also what keeps KV's
modest free-tier write allowance irrelevant — about 24 writes a day.

**Stale token pruning.** FCM answers `UNREGISTERED` for tokens belonging to
reinstalled or removed apps. Those rows are deleted on the spot; left alone
they accumulate and every later send to that topic keeps paying for them.

**Rate limiting is not implemented in code.** Anyone who knows a topic hash can
send to it — the same trust model the ntfy topics already have, so this is not
a regression. Add a Cloudflare rate-limiting rule on `/send` in the dashboard
rather than burning D1 or KV writes on a counter.

## Budget

Free tier is 100,000 Worker requests/day. Only sends cost anything; FCM pushes
reach devices directly and never touch this Worker.

At 3,000 daily users that is 33 requests per user per day, which holds only if
**state broadcasts never come through here**. They are ambient, they matter
only when the peer's app is already open, and at one per minute of app-open
time a single user would otherwise burn their whole share in half an hour.

Workers Paid is $5/month for 10 million requests/day if that ever binds.
