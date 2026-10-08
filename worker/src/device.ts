/**
 * Verified app installs: one human check, then votes and orders from the
 * app go through without one.
 *
 * A friend code proves nothing on its own - the app makes it, and partners
 * know it. So the first time an install votes or orders, it registers a hash
 * of its friend code and of a secret it made and keeps, then opens the check
 * page in the browser. Passing Cloudflare's check there confirms the
 * registration, and the page hands back to the app with a link. From then on
 * the app proves itself with its secret, and the per-visitor limits count
 * against the device rather than an address.
 */

export interface DeviceRow {
  id: string;
  code_hash: string;
  secret_hash: string;
  created_at: number;
  verified: number | null;
}

/** How long a registration waits for its check. */
const CONFIRM_WITHIN_MS = 60 * 60 * 1000;

let ready = false;

export async function ensureDevicesTable(db: D1Database): Promise<void> {
  if (ready) return;
  await db.exec(
    'CREATE TABLE IF NOT EXISTS verified_devices (id TEXT PRIMARY KEY, code_hash TEXT NOT NULL, secret_hash TEXT NOT NULL, created_at INTEGER NOT NULL, last_used INTEGER, verified INTEGER)',
  );
  ready = true;
}

const HEX64 = /^[0-9a-f]{64}$/;

/** An install asking to be verified. Not usable until its check passes. */
export async function startDevice(
  db: D1Database,
  codeHash: unknown,
  secretHash: unknown,
  newId: () => string,
): Promise<string | null> {
  if (typeof codeHash !== 'string' || !HEX64.test(codeHash)) return null;
  if (typeof secretHash !== 'string' || !HEX64.test(secretHash)) return null;
  await ensureDevicesTable(db);
  // Requests never confirmed are not kept.
  await db.prepare('DELETE FROM verified_devices WHERE verified IS NULL AND created_at < ?')
    .bind(Date.now() - CONFIRM_WITHIN_MS)
    .run();
  const id = newId();
  await db
    .prepare('INSERT INTO verified_devices (id, code_hash, secret_hash, created_at) VALUES (?, ?, ?, ?)')
    .bind(id, codeHash, secretHash, Date.now())
    .run();
  return id;
}

/** The check passed, on the page: the request is confirmed. */
export async function confirmDevice(db: D1Database, id: unknown): Promise<boolean> {
  if (typeof id !== 'string' || id.length > 64) return false;
  await ensureDevicesTable(db);
  const result = await db
    .prepare('UPDATE verified_devices SET verified = ? WHERE id = ? AND verified IS NULL AND created_at >= ?')
    .bind(Date.now(), id, Date.now() - CONFIRM_WITHIN_MS)
    .run();
  return (result.meta?.changes ?? 0) > 0;
}

/** The verified device a request comes from, or null. */
export async function deviceOf(
  db: D1Database,
  request: Request,
  hash: (s: string) => Promise<string>,
  { verifiedOnly = true } = {},
): Promise<string | null> {
  const id = request.headers.get('X-Device-Id');
  const secret = request.headers.get('X-Device-Secret');
  if (!id || !secret || id.length > 64 || secret.length > 200) return null;
  await ensureDevicesTable(db);
  const row = await db.prepare('SELECT * FROM verified_devices WHERE id = ?').bind(id).first<DeviceRow>();
  if (!row || row.secret_hash !== (await hash(secret))) return null;
  if (verifiedOnly && !row.verified) return null;
  await db.prepare('UPDATE verified_devices SET last_used = ? WHERE id = ?').bind(Date.now(), id).run();
  return id;
}

/** The check page the app opens in the browser. Its request id comes in the
 * address's #fragment, which is never sent to the server in a request. */
export function verifyPage(siteKey: string | null): string {
  const key = JSON.stringify(siteKey ?? '');
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="referrer" content="no-referrer">
<title>Quick check</title>
<script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>
<style>
  :root { --bg:#0e0f14; --card:#171922; --line:#262a36; --text:#eef0f6; --muted:#9aa0b4; --accent:#22d3ee; }
  @media (prefers-color-scheme: light) { :root { --bg:#f5f6fa; --card:#fff; --line:#e3e5ee; --text:#161823; --muted:#5d6275; } }
  body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center; padding:16px;
         background:var(--bg); color:var(--text); font:16px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  main { width:100%; max-width:420px; background:var(--card); border:1px solid var(--line); border-radius:20px; padding:26px 22px; text-align:center; }
  h1 { font-size:20px; margin:0 0 8px; }
  p { color:var(--muted); margin:0 0 16px; }
  #cf { display:flex; justify-content:center; min-height:70px; }
  a { display:none; margin-top:14px; padding:13px; border-radius:14px; background:var(--accent); color:#0e0f14; font-weight:700; text-decoration:none; }
</style>
</head>
<body>
<main>
  <h1>Quick check</h1>
  <p id="note">A one-time check that you're a person. After this, the app won't ask again.</p>
  <div id="cf"></div>
  <a id="back" href="subtaskmanager://verified">Back to the app</a>
</main>
<script>
(() => {
  const siteKey = ${key};
  const id = location.hash.slice(1);
  const note = document.getElementById('note');
  if (!/^[A-Za-z0-9_-]{8,64}$/.test(id)) { note.textContent = 'Open this from (sub)Task Manager.'; return; }
  const confirm = async (token) => {
    note.textContent = 'Checking...';
    try {
      const r = await fetch('/app/verify/confirm', {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ id, turnstileToken: token }),
      });
      if (!r.ok) { note.textContent = 'That did not go through. Go back to the app and try again.'; return; }
      note.textContent = "Done - you're verified. Heading back to the app.";
      document.getElementById('cf').remove();
      const back = document.getElementById('back');
      back.style.display = 'block';
      location.href = back.href;
    } catch { note.textContent = "Couldn't reach the server. Check your connection."; }
  };
  if (!siteKey) { confirm(''); return; }
  const wait = setInterval(() => {
    if (!window.turnstile) return;
    clearInterval(wait);
    window.turnstile.render('#cf', { sitekey: siteKey, callback: confirm });
  }, 200);
})();
</script>
</body>
</html>`;
}
