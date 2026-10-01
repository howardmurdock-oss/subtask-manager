/**
 * The page behind a public timer link: what a stranger sees and votes on.
 *
 * Served by the Worker rather than the website, which is deployed from the
 * public repository on every release. Self-contained - no scripts or styles
 * from anywhere else, except Cloudflare Turnstile's once it is configured -
 * and kept out of search results.
 */

const escapeHtml = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

export function publicPage(publicId: string, turnstileSiteKey: string | null): string {
  const id = escapeHtml(publicId);
  const siteKey = turnstileSiteKey ? escapeHtml(turnstileSiteKey) : '';
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="referrer" content="no-referrer">
<title>Chastity Timer</title>
${siteKey ? '<script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>' : ''}
<style>
  :root { --bg:#0e0f14; --card:#171922; --line:#262a36; --text:#eef0f6; --muted:#9aa0b4; --accent:#22d3ee; --add:#f472b6; --remove:#34d399; }
  @media (prefers-color-scheme: light) { :root { --bg:#f5f6fa; --card:#fff; --line:#e3e5ee; --text:#161823; --muted:#5d6275; } }
  * { box-sizing: border-box; }
  body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center; padding:16px;
         background:var(--bg); color:var(--text); font:16px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  main { width:100%; max-width:420px; background:var(--card); border:1px solid var(--line); border-radius:20px; padding:28px 22px; text-align:center; }
  .label { font-size:12px; font-weight:700; letter-spacing:.12em; text-transform:uppercase; color:var(--accent); }
  h1 { font-size:20px; margin:6px 0 18px; }
  .time { font-variant-numeric: tabular-nums; font-size:clamp(34px, 11vw, 52px); font-weight:800; letter-spacing:.02em; margin:4px 0; }
  .sub { color:var(--muted); font-size:14px; min-height:21px; }
  .buttons { display:flex; gap:12px; margin-top:22px; }
  button { flex:1; border:0; border-radius:14px; padding:16px 10px; font:inherit; font-weight:700; cursor:pointer; color:#0e0f14; }
  button:disabled { opacity:.45; cursor:not-allowed; }
  .add { background:var(--add); } .remove { background:var(--remove); }
  #cf { margin-top:16px; display:flex; justify-content:center; min-height:0; }
  .msg { margin-top:16px; font-size:14px; min-height:21px; }
  .foot { margin-top:22px; font-size:12px; color:var(--muted); }
  .made { margin-top:14px; padding-top:14px; border-top:1px solid var(--line); font-size:13px; color:var(--muted); }
  .made a { color:var(--accent); font-weight:700; text-decoration:none; }
  .made a:hover { text-decoration:underline; }
</style>
</head>
<body>
<main>
  <div class="label">Chastity Timer</div>
  <h1 id="headline">Someone is locked up</h1>
  <div class="time" id="time">&nbsp;</div>
  <div class="sub" id="sub">Loading…</div>
  <div class="buttons">
    <button class="add" id="add" disabled>Add time</button>
    <button class="remove" id="remove" disabled hidden>Remove time</button>
  </div>
  <div id="cf"></div>
  <div class="msg" id="msg" role="status"></div>
  <div class="foot">Each vote counts once toward a daily limit set by the person who's locked.</div>
  <!-- Back to the website: a link that goes wide brings people to the app.
       Tagged so those visits can be told apart from others. -->
  <div class="made">Made with <a href="https://subtaskmanager.com/?from=timer">(sub)Task Manager</a> · <a href="https://subtaskmanager.com/?from=timer">Get the app</a></div>
</main>
<script>
(() => {
  const id = ${JSON.stringify(id)};
  const siteKey = ${JSON.stringify(siteKey)};
  const base = location.pathname.replace(/\\/$/, '');
  const $ = (x) => document.getElementById(x);
  let view = null, token = null, offset = 0;

  const human = (s) => {
    const m = Math.round(s / 60);
    if (m < 60) return m + ' min';
    const h = m / 60;
    return (Number.isInteger(h) ? h : h.toFixed(1)) + (h === 1 ? ' hour' : ' hours');
  };
  const clock = (ms) => {
    const s = Math.max(0, Math.floor(ms / 1000));
    const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60), sec = s % 60;
    const pad = (n) => String(n).padStart(2, '0');
    return (d ? d + 'd ' : '') + pad(h) + ':' + pad(m) + ':' + pad(sec);
  };
  const reasons = {
    'visitor-cap': "You've used your votes for today. Come back tomorrow.",
    'daily-cap': "Today's limit for this timer has been reached.",
    'not-running': 'This timer has finished.',
    'not-allowed': "Removing time isn't allowed on this timer.",
    'public-disabled': "This timer isn't taking votes.",
    'turnstile': 'Please complete the check below first.',
    'at-maximum': 'This timer is already at its maximum length.',
  };

  function render() {
    if (!view) return;
    const running = view.status === 'running';
    $('headline').textContent = running ? 'Someone is locked up' : 'This timer is over';
    if (running && view.endAt != null) {
      $('time').textContent = clock(view.endAt - (Date.now() + offset));
      $('sub').textContent = 'left on the timer';
    } else {
      $('time').textContent = running ? '??:??:??' : 'Unlocked';
      $('sub').textContent = running ? 'The time left is hidden' : '';
    }
    const step = human(view.stepSeconds);
    $('add').textContent = 'Add ' + step;
    $('remove').textContent = 'Remove ' + step;
    $('remove').hidden = !view.allowRemove;
    const canVote = view.acceptingVotes && (!siteKey || token);
    $('add').disabled = !canVote || view.atMaximum;
    $('remove').disabled = !canVote;
    // Said outright: a greyed-out button alone looks broken.
    if (running && view.atMaximum && !$('msg').textContent) {
      $('msg').textContent = view.allowRemove
        ? 'This timer is at its maximum length. Time can only be removed.'
        : 'This timer is at its maximum length. No more time can be added.';
    }
  }

  async function load() {
    try {
      const r = await fetch(base + '/state', { cache: 'no-store' });
      if (!r.ok) { $('sub').textContent = 'This link has been switched off.'; $('time').textContent = ''; return; }
      view = await r.json();
      offset = view.now - Date.now();
      render();
    } catch { $('sub').textContent = "Couldn't reach the timer. Check your connection."; }
  }

  async function vote(direction) {
    $('add').disabled = $('remove').disabled = true;
    $('msg').textContent = '';
    try {
      const r = await fetch(base + '/vote', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ direction, turnstileToken: token }),
      });
      const body = await r.json();
      if (r.ok) {
        view = body; offset = view.now - Date.now();
        $('msg').textContent = direction > 0 ? 'Time added. Thanks for voting.' : 'Time removed. Thanks for voting.';
      } else {
        if (body.view) { view = body.view; offset = view.now - Date.now(); }
        $('msg').textContent = reasons[body.error] || "That vote didn't go through.";
      }
    } catch { $('msg').textContent = "That vote didn't go through. Check your connection."; }
    if (siteKey && window.turnstile) { token = null; window.turnstile.reset('#cf'); }
    render();
  }

  $('add').onclick = () => vote(1);
  $('remove').onclick = () => vote(-1);

  if (siteKey) {
    window.onTurnstile = (t) => { token = t; render(); };
    const wait = setInterval(() => {
      if (!window.turnstile) return;
      clearInterval(wait);
      window.turnstile.render('#cf', { sitekey: siteKey, callback: window.onTurnstile, 'expired-callback': () => { token = null; render(); } });
    }, 200);
  }

  load();
  setInterval(render, 1000);
  setInterval(load, 30000);
})();
</script>
</body>
</html>`;
}
