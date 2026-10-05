/**
 * Public timers on other people's pages.
 *
 * Two forms, because sites allow different things:
 *
 *  - /t/<id>/embed: a small live widget for an <iframe> on a website or blog.
 *    It counts down and offers a Vote button that opens the full timer page
 *    in a new tab - voting is not done inside someone else's page, so the bot
 *    check works there and a host page cannot trick anyone into clicking a
 *    disguised vote button.
 *  - /t/<id>/badge.svg: an image for forums, which mostly allow images but not
 *    iframes. It cannot count down: it shows the time as of when it was
 *    fetched, linked to the timer page.
 *
 * Both show only what the public page would - a hidden time stays hidden -
 * and once the timer is gone they say so and point to the app.
 */

export interface PublicView {
  status: 'running' | 'ended' | 'released';
  endAt: number | null;
  startAt?: number;
  closedAt?: number | null;
  openEnded?: boolean;
  acceptingVotes: boolean;
  allowRemove?: boolean;
  atMaximum?: boolean;
  now: number;
}

const SITE = 'https://www.subtaskmanager.com/?from=timer-embed';

const esc = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

const STYLE = `
  :root { --bg:#171922; --line:#262a36; --text:#eef0f6; --muted:#9aa0b4; --accent:#22d3ee; --vote:#f472b6; }
  @media (prefers-color-scheme: light) { :root { --bg:#fff; --line:#e3e5ee; --text:#161823; --muted:#5d6275; } }
  * { box-sizing:border-box; }
  html, body { margin:0; height:100%; background:transparent; }
  body { font:14px/1.4 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; color:var(--text); }
  .card { height:100%; min-height:130px; display:flex; flex-direction:column; justify-content:center; gap:6px;
          background:var(--bg); border:1px solid var(--line); border-radius:14px; padding:12px 14px; }
  .label { font-size:10px; font-weight:700; letter-spacing:.12em; text-transform:uppercase; color:var(--accent); }
  .big { font-size:26px; font-weight:800; font-variant-numeric:tabular-nums; }
  .sub { color:var(--muted); font-size:12px; }
  .row { display:flex; align-items:center; justify-content:space-between; gap:10px; margin-top:4px; }
  .btn { display:inline-block; padding:8px 14px; border-radius:10px; background:var(--vote); color:#0e0f14;
         font-weight:700; text-decoration:none; white-space:nowrap; }
  .btn.app { background:var(--accent); }
  .site { font-size:11px; color:var(--muted); text-decoration:none; }
  .site:hover { text-decoration:underline; }
`;

/** The live widget, framed on someone's site. */
export function embedPage(timerUrl: string): string {
  const url = esc(timerUrl);
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Chastity Timer</title>
<style>${STYLE}</style>
</head>
<body>
<div class="card">
  <div class="label">Chastity Timer</div>
  <div class="big" id="time">&nbsp;</div>
  <div class="sub" id="sub">Loading…</div>
  <div class="row">
    <a class="btn" id="vote" href="${url}" target="_blank" rel="noopener">Vote on it</a>
    <a class="site" href="${SITE}" target="_blank" rel="noopener">subtaskmanager.com</a>
  </div>
</div>
<script>
(() => {
  const base = location.pathname.replace(/\\/embed\\/?$/, '');
  const $ = (x) => document.getElementById(x);
  let view = null, offset = 0;
  const clock = (ms) => {
    const s = Math.max(0, Math.floor(ms / 1000));
    const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60), sec = s % 60;
    const p = (n) => String(n).padStart(2, '0');
    return (d ? d + 'd ' : '') + p(h) + ':' + p(m) + ':' + p(sec);
  };
  const span = (ms) => {
    const m = Math.max(0, Math.floor(ms / 60000));
    const d = Math.floor(m / 1440), h = Math.floor(m % 1440 / 60), min = m % 60;
    return d ? d + 'd ' + h + 'h' : h ? h + 'h ' + min + 'm' : min + 'm';
  };
  function render() {
    if (!view) return;
    const running = view.status === 'running';
    const nowMs = Date.now() + offset;
    if (!running) {
      $('time').textContent = 'Unlocked';
      $('sub').textContent = view.closedAt ? 'Ran for ' + span(view.closedAt - view.startAt) : 'This timer is over';
      $('vote').textContent = 'See it';
      return;
    }
    if (view.openEnded) {
      // No end time: it counts up, from the start.
      $('time').textContent = clock(nowMs - view.startAt);
      $('sub').textContent = "locked so far · runs until it's ended";
      $('vote').textContent = 'See it';
      return;
    }
    $('time').textContent = view.endAt == null ? '??:??:??' : clock(view.endAt - nowMs);
    const sofar = ' · locked for ' + span(nowMs - view.startAt);
    $('sub').textContent = (view.endAt == null ? 'time left hidden'
      : view.atMaximum ? 'left · at its maximum' : 'left') + sofar;
    $('vote').textContent = view.acceptingVotes ? 'Vote on it' : 'See it';
  }
  async function load() {
    try {
      const r = await fetch(base + '/state', { cache: 'no-store' });
      // Gone: the server answers this address with the ended widget now.
      if (r.status === 404) { location.reload(); return; }
      if (!r.ok) return;
      view = await r.json();
      offset = view.now - Date.now();
      render();
    } catch {}
  }
  load();
  setInterval(render, 1000);
  setInterval(load, 30000);
})();
</script>
</body>
</html>`;
}

/** The widget once the timer is gone: what was there, and the app. */
export function endedEmbedPage(): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Chastity Timer</title>
<style>${STYLE}</style>
</head>
<body>
<div class="card">
  <div class="label">Chastity Timer</div>
  <div class="big">Timer ended</div>
  <div class="sub">There was a chastity timer here. Want one of your own?</div>
  <div class="row">
    <a class="btn app" href="${SITE}" target="_blank" rel="noopener">Get (sub)Task Manager</a>
  </div>
</div>
</body>
</html>`;
}

/** How long it has run, in the same words: "2d 4h". */
function soFar(view: PublicView): string {
  return roughly((view.closedAt ?? view.now) - (view.startAt ?? view.now)).replace(' left', '');
}

/** Time left in words that suit a picture which does not count down. */
export function roughly(ms: number): string {
  const m = Math.max(0, Math.floor(ms / 60000));
  const d = Math.floor(m / 1440), h = Math.floor((m % 1440) / 60), min = m % 60;
  if (d > 0) return `${d}d ${h}h left`;
  if (h > 0) return `${h}h ${min}m left`;
  return `${Math.max(1, min)}m left`;
}

/**
 * The forum image. [view] null: the timer is gone.
 */
/**
 * What a link preview (Discord, Slack, iMessage...) says about a timer. The
 * picture is one of three ready-made ones; the time left goes in the title,
 * which those apps show in bold above it.
 */
export function previewText(view: PublicView): { title: string; description: string; state: 'locked' | 'unlocked' } {
  if (view.status !== 'running') {
    const ran = view.closedAt && view.startAt ? ` It ran for ${soFar(view)}.` : '';
    return { title: 'Chastity Timer · Unlocked', description: `This timer is over.${ran}`, state: 'unlocked' };
  }
  if (view.openEnded) {
    const sofar = soFar(view);
    return {
      title: `Chastity Timer · locked ${sofar} so far`,
      description: "Someone is locked up, with no end time: it runs until it's ended.",
      state: 'locked',
    };
  }
  const left = view.endAt == null ? 'time hidden' : roughly(view.endAt - view.now);
  const description = !view.acceptingVotes
    ? 'Someone is locked up.'
    : view.atMaximum
      ? "Someone is locked up, and it's at its maximum length."
      : `Someone is locked up. Vote to add${view.allowRemove ? ' or remove' : ''} time.`;
  return { title: `Chastity Timer · ${left}`, description, state: 'locked' };
}

export function badgeSvg(view: PublicView | null): string {
  let headline: string;
  let detail: string;
  let tone: string;
  if (!view) {
    headline = 'Timer ended';
    detail = 'Get (sub)Task Manager · subtaskmanager.com';
    tone = '#22d3ee';
  } else if (view.status !== 'running') {
    headline = 'Unlocked';
    detail = view.closedAt && view.startAt
      ? `Ran for ${soFar(view)} · subtaskmanager.com`
      : 'This timer is over · subtaskmanager.com';
    tone = '#34d399';
  } else if (view.openEnded) {
    headline = `Locked · ${soFar(view)} so far`;
    detail = 'No end time · subtaskmanager.com';
    tone = '#f472b6';
  } else {
    headline = view.endAt == null ? 'Locked · time hidden' : `Locked · ${roughly(view.endAt - view.now)}`;
    detail = view.acceptingVotes ? 'Click to vote · subtaskmanager.com' : 'subtaskmanager.com';
    tone = '#f472b6';
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" width="320" height="64" viewBox="0 0 320 64" role="img" aria-label="Chastity Timer: ${esc(headline)}">
  <rect x="0.5" y="0.5" width="319" height="63" rx="12" fill="#171922" stroke="#262a36"/>
  <g transform="translate(16 16)" fill="none" stroke="${tone}" stroke-width="2.4" stroke-linecap="round">
    <rect x="2" y="13" width="24" height="18" rx="4" fill="${tone}" fill-opacity="0.18"/>
    <path d="M8 13 V9 a6 6 0 0 1 12 0 V13"/>
  </g>
  <g font-family="system-ui, -apple-system, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif">
    <text x="58" y="20" font-size="9.5" font-weight="700" letter-spacing="1.2" fill="#22d3ee">CHASTITY TIMER</text>
    <text x="58" y="39" font-size="17" font-weight="800" fill="#eef0f6">${esc(headline)}</text>
    <text x="58" y="54" font-size="10.5" fill="#9aa0b4">${esc(detail)}</text>
  </g>
</svg>`;
}
