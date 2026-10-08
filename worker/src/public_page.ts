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

/**
 * Tags that Discord, Slack, iMessage, X and the rest read to draw a preview
 * card when the link is pasted. Without them a pasted link was a bare URL.
 */
export function previewTags(p: { url: string; title: string; description: string; image: string; tone: string }): string {
  const e = (s: string) => escapeHtml(s);
  return `<meta name="description" content="${e(p.description)}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="(sub)Task Manager">
<meta property="og:url" content="${e(p.url)}">
<meta property="og:title" content="${e(p.title)}">
<meta property="og:description" content="${e(p.description)}">
<meta property="og:image" content="${e(p.image)}">
<meta property="og:image:width" content="800">
<meta property="og:image:height" content="418">
<meta property="og:image:alt" content="${e(p.title)}">
<meta name="twitter:card" content="summary_large_image">
<meta name="theme-color" content="${e(p.tone)}">`;
}

/**
 * A timer's page - or, with [opts.profile], a player's page (/p/<id>): the
 * same page, showing whichever of their timers is running, with their name,
 * any others running, and past ones if they show them.
 */
export function publicPage(
  publicId: string,
  turnstileSiteKey: string | null,
  preview?: { title: string; description: string; state: 'locked' | 'unlocked' },
  opts: { profile?: boolean } = {},
): string {
  const id = escapeHtml(publicId);
  const siteKey = turnstileSiteKey ? escapeHtml(turnstileSiteKey) : '';
  const profile = opts.profile === true;
  const url = `https://subtaskmanager.com/${profile ? 'p' : 't'}/${publicId}`;
  const tags = preview
    ? previewTags({
        url,
        title: preview.title,
        description: preview.description,
        image: `${url}/preview.png?s=${preview.state}`,
        tone: preview.state === 'locked' ? '#f472b6' : '#34d399',
      })
    : '';
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="referrer" content="no-referrer">
${tags}
<title>Chastity Timer</title>
${siteKey ? '<script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>' : ''}
<style>
  :root { --bg:#0e0f14; --card:#171922; --line:#262a36; --text:#eef0f6; --muted:#9aa0b4; --accent:#22d3ee; --add:#f472b6; --remove:#34d399; }
  @media (prefers-color-scheme: light) { :root { --bg:#f5f6fa; --card:#fff; --line:#e3e5ee; --text:#161823; --muted:#5d6275; } }
  * { box-sizing: border-box; }
  body { margin:0; min-height:100vh; display:flex; padding:16px; box-sizing:border-box;
         background:var(--bg); color:var(--text); font:16px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  /* Centred, but never cut off at the top when taller than the window. */
  main { margin:auto; width:100%; max-width:420px; background:var(--card); border:1px solid var(--line); border-radius:20px; padding:28px 22px; text-align:center; }
  .left { margin-top:10px; font-size:13px; color:var(--muted); min-height:18px; }
  .cols { display:block; }
  /* A wide screen, with orders to show: the timer on the left, the orders on
     the right, as a grid of cards. */
  @media (min-width: 980px) {
    main.wide { max-width:1120px; padding:28px; }
    main.wide .cols { display:grid; grid-template-columns:400px 1fr; grid-template-rows:auto 1fr; column-gap:32px; align-items:start; }
    main.wide .col-timer { grid-column:1; grid-row:1; }
    main.wide .col-lists { grid-column:1; grid-row:2; }
    main.wide .orders { grid-column:2; grid-row:1 / span 2; margin-top:0; padding-top:0; border-top:0; padding-left:32px; border-left:1px solid var(--line); }
    main.wide #orderList { display:grid; grid-template-columns:repeat(auto-fill, minmax(250px, 1fr)); gap:12px; }
    main.wide #orderList .order { margin-top:0; display:flex; flex-direction:column; }
    main.wide #orderList .order button { margin-top:auto; flex:none; }
    main.wide #orderList .order .meta { margin-bottom:10px; }
  }
  .label { font-size:12px; font-weight:700; letter-spacing:.12em; text-transform:uppercase; color:var(--accent); }
  h1 { font-size:20px; margin:6px 0 18px; }
  .time { font-variant-numeric: tabular-nums; font-size:clamp(34px, 11vw, 52px); font-weight:800; letter-spacing:.02em; margin:4px 0; }
  .sub { color:var(--muted); font-size:14px; min-height:21px; }
  [hidden] { display:none !important; }
  .ran { color:var(--muted); font-size:13px; margin-top:6px; min-height:20px; font-variant-numeric:tabular-nums; }
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
  .openapp { display:flex; align-items:center; justify-content:center; gap:10px; flex-wrap:wrap; margin:-6px 0 20px;
             padding:10px 12px; border-radius:14px; border:1px solid var(--accent); color:var(--accent);
             font-weight:700; text-decoration:none; font-size:15px; }
  .openapp:hover { background:rgba(34,211,238,.1); }
  .openapp small { font-weight:400; color:var(--muted); font-size:12px; }
  .list { margin-top:20px; padding-top:14px; border-top:1px solid var(--line); text-align:left; }
  .list .label { font-size:11px; margin-bottom:6px; }
  .list ul { list-style:none; margin:0; padding:0; }
  .list li { display:flex; justify-content:space-between; gap:10px; padding:6px 0; font-size:14px; font-variant-numeric:tabular-nums; }
  .list li span:last-child { color:var(--muted); }
  .list a { color:var(--text); text-decoration:none; }
  .list a:hover { text-decoration:underline; }
  .orders { margin-top:22px; padding-top:16px; border-top:1px solid var(--line); text-align:left; }
  .orders > .label { font-size:11px; }
  .note { color:var(--muted); font-size:13px; margin:4px 0 10px; }
  .order { border:1px solid var(--line); border-radius:14px; padding:12px; margin-top:10px; }
  .order h3 { margin:0; font-size:15px; }
  .order p { margin:4px 0 0; color:var(--muted); font-size:13px; white-space:pre-line; }
  .order .meta { font-size:12px; color:var(--muted); margin-top:6px; }
  .order button { margin-top:10px; width:100%; padding:11px; background:var(--accent); }
  .feed { list-style:none; margin:8px 0 0; padding:0; }
  .feed li { display:flex; justify-content:space-between; align-items:center; gap:8px; padding:7px 0; font-size:14px; border-bottom:1px solid var(--line); }
  .feed li:last-child { border-bottom:0; }
  .feed .st { color:var(--muted); font-size:13px; white-space:nowrap; }
  .feed .st.ok { color:var(--remove); } .feed .st.bad { color:var(--add); }
  .feed button { flex:none; padding:6px 10px; font-size:12px; background:var(--accent); border-radius:10px; }
  .mine { font-size:11px; font-weight:700; color:var(--accent); margin-left:6px; }
  .overlay { position:fixed; inset:0; background:rgba(0,0,0,.75); display:flex; align-items:center; justify-content:center; padding:16px; z-index:10; }
  .sheet { width:100%; max-width:420px; max-height:90vh; overflow:auto; background:var(--card); border:1px solid var(--line); border-radius:20px; padding:22px; text-align:center; }
  .sheet h2 { margin:0 0 8px; font-size:20px; }
  .sheet p { color:var(--muted); margin:0 0 16px; }
  .sheet img { max-width:100%; border-radius:12px; }
  .sheet .row { display:flex; gap:10px; }
  .sheet button { background:var(--accent); }
  .sheet button.plain { background:var(--line); color:var(--text); }
</style>
</head>
<body>
<main id="page">
  <!-- The same timer in the app: vote and order there, get proof there, and
       be told when it ends. Without the app, this goes to the download. -->
  <a class="openapp" id="openApp" href="https://www.subtaskmanager.com/?from=open-in-app#downloads">Open in the app
    <small>vote, send orders and get told when it ends</small></a>
  <div class="cols">
  <section class="col-timer">
  <div class="label">Chastity Timer</div>
  <h1 id="headline">Someone is locked up</h1>
  <div class="time" id="time">&nbsp;</div>
  <div class="sub" id="sub">Loading…</div>
  <div class="ran" id="ran"></div>
  <div class="buttons" id="buttons">
    <button class="add" id="add" disabled>Add time</button>
    <button class="remove" id="remove" disabled hidden>Remove time</button>
  </div>
  <div class="left" id="votesLeft"></div>
  <div id="cf"></div>
  <div class="msg" id="msg" role="status"></div>
  <div class="foot" id="votefoot">Each vote counts once toward a daily limit set by the person who's locked.</div>
  </section>
  <section class="orders" id="orders" hidden>
    <div class="label">Send an order</div>
    <div class="note" id="ordersNote"></div>
    <div id="orderList"></div>
    <div class="label" style="margin-top:18px">Orders so far</div>
    <ul class="feed" id="feedList"></ul>
    <div class="note" id="feedEmpty">None yet.</div>
  </section>
  <!-- After the orders on a phone; under the timer on a wide screen. -->
  <section class="col-lists">
  <div class="list" id="also" hidden><div class="label">Also running</div><ul id="alsoList"></ul></div>
  <div class="list" id="past" hidden><div class="label">Past timers</div><ul id="pastList"></ul></div>
  </section>
  </div>
  <!-- Back to the website: a link that goes wide brings people to the app.
       Tagged so those visits can be told apart from others. -->
  <div class="made">Made with <a href="https://subtaskmanager.com/?from=timer">(sub)Task Manager</a> · <a href="https://subtaskmanager.com/?from=timer">Get the app</a></div>
</main>
<div class="overlay" id="age" hidden>
  <div class="sheet">
    <h2>Adults only</h2>
    <p>This page takes orders for an adult's chastity play, and can show explicit photos. Are you of legal age where you live?</p>
    <div class="row"><button class="plain" id="ageNo">No</button><button id="ageYes">Yes, I am</button></div>
  </div>
</div>
<div class="overlay" id="shown" hidden>
  <div class="sheet"><div id="shownBody"></div><button class="plain" id="shownClose" style="margin-top:14px;width:100%">Close</button></div>
</div>
<script>
(() => {
  const id = ${JSON.stringify(id)};
  const siteKey = ${JSON.stringify(siteKey)};
  const isProfile = ${profile ? 'true' : 'false'};
  const base = location.pathname.replace(/\\/$/, '');
  const $ = (x) => document.getElementById(x);
  // On a player's page, votes go to whichever timer is showing.
  let view = null, profile = null, voteBase = base, token = null, offset = 0;

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
    'slow-down': 'Too many tries just now. Wait a minute, then try again.',
  };

  // "2d 4h", "35m": how long it has run.
  const span = (ms) => {
    const m = Math.max(0, Math.floor(ms / 60000));
    const d = Math.floor(m / 1440), h = Math.floor(m % 1440 / 60), min = m % 60;
    return d ? d + 'd ' + h + 'h' : h ? h + 'h ' + min + 'm' : min + 'm';
  };

  // A player's page: their other running timers, and past ones.
  function renderLists() {
    if (!profile) return;
    const nowMs = Date.now() + offset;
    const also = $('alsoList');
    also.replaceChildren(...profile.others.map((t) => {
      const li = document.createElement('li');
      const a = document.createElement('a');
      a.href = '/t/' + t.publicId;
      a.textContent = 'Another timer';
      const right = document.createElement('span');
      right.textContent = t.openEnded ? span(nowMs - t.startAt) + ' so far'
        : t.endAt == null ? 'time hidden' : clock(t.endAt - nowMs) + ' left';
      li.append(a, right);
      return li;
    }));
    $('also').hidden = profile.others.length === 0;
    const past = $('pastList');
    past.replaceChildren(...profile.history.map((h) => {
      const li = document.createElement('li');
      const when = document.createElement('span');
      when.textContent = new Date(h.closedAt).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
      const ran = document.createElement('span');
      ran.textContent = 'ran for ' + span(h.closedAt - h.startAt);
      li.append(when, ran);
      return li;
    }));
    $('past').hidden = profile.history.length === 0;
  }

  function render() {
    renderLists();
    renderOrders();
    const who = profile && profile.name ? profile.name : null;
    if (!view) {
      if (!profile) return;
      // Between timers: the page stays, and says so.
      $('headline').textContent = (who || 'They') + " isn't locked up right now";
      $('time').textContent = 'Unlocked';
      $('sub').textContent = 'Check back later.';
      $('ran').textContent = '';
      $('buttons').hidden = $('votefoot').hidden = true;
      $('msg').textContent = '';
      return;
    }
    const running = view.status === 'running';
    const nowMs = Date.now() + offset;
    $('headline').textContent = running ? (who ? who + ' is locked up' : 'Someone is locked up') : 'This timer is over';
    $('ran').textContent = '';
    if (running && view.openEnded) {
      // No end time: it counts up, from the start.
      $('time').textContent = clock(nowMs - view.startAt);
      $('sub').textContent = "locked so far · it runs until it's ended";
    } else if (running && view.endAt != null) {
      $('time').textContent = clock(view.endAt - nowMs);
      $('sub').textContent = 'left on the timer';
      $('ran').textContent = 'Locked for ' + span(nowMs - view.startAt) + ' so far';
    } else if (running) {
      $('time').textContent = '??:??:??';
      $('sub').textContent = 'The time left is hidden';
      $('ran').textContent = 'Locked for ' + span(nowMs - view.startAt) + ' so far';
    } else {
      $('time').textContent = 'Unlocked';
      $('sub').textContent = view.closedAt ? 'Ran for ' + span(view.closedAt - view.startAt) : '';
    }
    // Nothing to vote on without an end to move.
    $('buttons').hidden = !!view.openEnded;
    $('votefoot').hidden = !!view.openEnded;
    const step = human(view.stepSeconds);
    $('add').textContent = 'Add ' + step;
    $('remove').textContent = 'Remove ' + step;
    $('remove').hidden = !view.allowRemove;
    // What this visitor has left today.
    const you = view.you || null;
    const votes = you && view.acceptingVotes && !view.openEnded ? you.votesLeft : null;
    $('votesLeft').textContent = votes == null ? ''
      : votes === 0 ? 'No votes left for you today. Come back tomorrow.'
      : 'You have ' + votes + ' vote' + (votes === 1 ? '' : 's') + ' left today.';
    const canVote = view.acceptingVotes && (!siteKey || token) && votes !== 0;
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
      // Gone while the page was open: the server now answers this address
      // with the "this timer has ended" page, so load that.
      if (r.status === 404) { location.reload(); return; }
      if (!r.ok) { $('sub').textContent = "Couldn't reach the timer. Try again in a moment."; return; }
      const s = await r.json();
      if (isProfile) {
        profile = s;
        // A different timer now showing: its own messages go with it.
        if (s.featured && (!view || view.publicId !== s.featured.publicId)) $('msg').textContent = '';
        view = s.featured;
        voteBase = view ? '/t/' + view.publicId : null;
      } else {
        view = s;
      }
      offset = s.now - Date.now();
      render();
      if (view && view.orders && view.orders.enabled) adultCheck();
    } catch { $('sub').textContent = "Couldn't reach the timer. Check your connection."; }
  }

  async function vote(direction) {
    $('add').disabled = $('remove').disabled = true;
    $('msg').textContent = '';
    try {
      if (!voteBase) return;
      const r = await fetch(voteBase + '/vote', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ direction, turnstileToken: token }),
      });
      const body = await r.json();
      if (r.ok) {
        view = isProfile ? { ...body, publicId: view.publicId } : body;
        offset = body.now - Date.now();
        $('msg').textContent = direction > 0 ? 'Time added. Thanks for voting.' : 'Time removed. Thanks for voting.';
      } else {
        if (body.view) {
          view = isProfile ? { ...body.view, publicId: view.publicId } : body.view;
          offset = body.view.now - Date.now();
        }
        $('msg').textContent = reasons[body.error] || "That vote didn't go through.";
      }
    } catch { $('msg').textContent = "That vote didn't go through. Check your connection."; }
    if (siteKey && window.turnstile) { token = null; window.turnstile.reset('#cf'); }
    render();
  }

  // ---- Public orders --------------------------------------------------------
  // A visitor picks from the list the person approved. Proof for them comes
  // encrypted to a key made here, in this browser: only this browser can
  // open it, and only for a day.
  const store = {
    get(k, d) { try { const v = localStorage.getItem(k); return v ? JSON.parse(v) : d; } catch { return d; } },
    set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} },
  };
  const MINE = 'stm-orders-v1', KEY = 'stm-proof-key-v1', ADULT = 'stm-adult-v1';
  const timerId = () => (isProfile ? (view && view.publicId) : id);
  const ordersBase = () => (isProfile ? voteBase : base);
  const mine = () => store.get(MINE, []).filter((m) => Date.now() - m.at < 3 * 86400000);
  const b64 = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf)));
  const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
  const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
  const statusText = { queued: ['waiting', ''], active: ['in progress', ''], reviewing: ['being checked', ''],
    completed: ['done \u2713', 'ok'], failed: ['failed', 'bad'],
    expired: ['ran out of time', 'bad'], skipped: ['skipped', ''], cancelled: ['cancelled', ''] };
  const orderReasons = {
    'visitor-cap': "You've sent all the orders you can today. Come back tomorrow.",
    'paused': "They've just skipped one, so orders are paused for a little while.",
    'full': 'Their order queue is full right now. Try again later.',
    'not-running': 'This timer has finished.',
    'orders-off': "This timer isn't taking orders.",
    'unknown-order': "That order isn't on the list any more.",
    'turnstile': 'Please complete the check first.',
    'bad-key': "Your browser couldn't make a key to receive proof.",
    'slow-down': 'Too many tries just now. Wait a minute, then try again.',
  };
  let ordersShown = '';

  function adultCheck() {
    if (store.get(ADULT, false)) return Promise.resolve(true);
    return new Promise((done) => {
      $('age').hidden = false;
      $('ageYes').onclick = () => { store.set(ADULT, true); $('age').hidden = true; done(true); };
      $('ageNo').onclick = () => {
        document.body.replaceChildren(Object.assign(document.createElement('main'), { textContent: "This page isn't for you." }));
        done(false);
      };
    });
  }

  function describe(o) {
    const bits = [];
    if ((o.durationType === 'deadlineCountdown' || o.durationType === 'actionWithDeadline') && o.deadlineMinutes) bits.push(o.deadlineMinutes + ' min to do it');
    if (o.actionSeconds && (o.durationType === 'actionTimer' || o.durationType === 'actionWithDeadline')) bits.push('for ' + human(o.actionSeconds));
    if (o.verification === 'photoProof') bits.push('photo proof');
    if (o.verification === 'noteProof') bits.push('written proof');
    if (o.rewardTokens) bits.push('+' + o.rewardTokens + ' tokens');
    if (o.penaltyTokens) bits.push('\u2212' + o.penaltyTokens + ' if failed');
    return bits.join(' \u00b7 ');
  }

  function renderOrders() {
    const o = view && view.orders;
    $('orders').hidden = !(o && o.enabled);
    // Two columns on a wide screen - only when there are orders for one.
    $('page').classList.toggle('wide', !!(o && o.enabled));
    if (!o || !o.enabled) return;
    const ordersLeft = view.you ? view.you.ordersLeft : null;
    const key = JSON.stringify(o) + (token ? 1 : 0) + mine().length;
    if (key === ordersShown) return;
    ordersShown = key;
    const notes = { 'paused': orderReasons.paused, 'full': orderReasons.full, 'not-running': orderReasons['not-running'] };
    $('ordersNote').textContent = o.accepting && ordersLeft === 0
      ? "You've sent all the orders you can today. Come back tomorrow."
      : o.accepting
      ? 'Pick one to send. They carry it out in the app, and how it went shows here.' +
        (ordersLeft != null ? ' You can send ' + ordersLeft + ' more today.' : '') +
        (o.proofTo === 'issuer'
          ? ' If it needs a photo, the photo comes to you - in this browser only, for a day.'
          : " Photo proof goes to the person who manages this timer, not to you.") +
        (o.waiting ? ' ' + o.waiting + ' waiting ahead of yours.' : '')
      : notes[o.reason] || '';
    $('orderList').replaceChildren(...(o.accepting && ordersLeft !== 0 ? o.list : []).map((def) => {
      const card = document.createElement('div');
      card.className = 'order';
      const h = document.createElement('h3'); h.textContent = def.title;
      const p = document.createElement('p'); p.textContent = def.description;
      const meta = document.createElement('div'); meta.className = 'meta'; meta.textContent = describe(def);
      const b = document.createElement('button');
      b.textContent = 'Send this order';
      b.disabled = !!siteKey && !token;
      b.onclick = () => sendOrder(def, b);
      card.append(h);
      if (def.description) card.append(p);
      if (meta.textContent) card.append(meta);
      card.append(b);
      return card;
    }));
    const ours = new Map(mine().filter((m) => m.pid === timerId()).map((m) => [m.no, m]));
    $('feedList').replaceChildren(...o.feed.map((f) => {
      const li = document.createElement('li');
      const left = document.createElement('span');
      left.textContent = f.title;
      if (ours.has(f.no)) { const tag = document.createElement('span'); tag.className = 'mine'; tag.textContent = 'YOURS'; left.append(tag); }
      const [label, tone] = statusText[f.status] || [f.status, ''];
      const right = document.createElement('span');
      right.className = 'st ' + tone;
      // Approved because nobody checked it in time.
      right.textContent = f.status === 'completed' && f.auto ? 'done \u2713 (not checked)' : label;
      li.append(left);
      if (f.hasProof && ours.has(f.no)) {
        const see = document.createElement('button');
        see.textContent = f.status === 'reviewing' ? 'Check proof' : 'See proof';
        see.onclick = () => showProof(ours.get(f.no), f);
        li.append(see);
      } else {
        li.append(right);
      }
      return li;
    }));
    $('feedEmpty').hidden = o.feed.length > 0;
  }

  async function issuerKey() {
    const saved = store.get(KEY, null);
    if (saved) return saved.pub;
    const pair = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
    const pub = b64(await crypto.subtle.exportKey('raw', pair.publicKey));
    store.set(KEY, { pub, priv: await crypto.subtle.exportKey('jwk', pair.privateKey) });
    return pub;
  }

  async function sendOrder(def, button) {
    if (!(await adultCheck())) return;
    button.disabled = true;
    $('msg').textContent = '';
    try {
      const receipt = hex(crypto.getRandomValues(new Uint8Array(32)));
      const receiptHash = hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(receipt)));
      const body = { orderId: def.id, turnstileToken: token, receiptHash };
      if (view.orders.proofTo === 'issuer') body.issuerKey = await issuerKey();
      const r = await fetch(ordersBase() + '/order', {
        method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
      });
      const res = await r.json();
      if (res.view) { view = isProfile ? { ...res.view, publicId: view.publicId } : res.view; offset = res.view.now - Date.now(); }
      if (r.ok) {
        store.set(MINE, [...mine(), { pid: timerId(), no: res.no, receipt, title: def.title, at: Date.now() }]);
        $('msg').textContent = 'Order sent. Watch for it under "Orders so far".';
      } else {
        $('msg').textContent = orderReasons[res.error] || "That order didn't go through.";
      }
    } catch { $('msg').textContent = "That order didn't go through. Check your connection."; }
    if (siteKey && window.turnstile) { token = null; window.turnstile.reset('#cf'); }
    ordersShown = '';
    render();
  }

  // Approve and Reject, while the proof waits to be checked.
  function verdict(m, f) {
    if (!f || f.status !== 'reviewing') return [];
    const row = document.createElement('div');
    row.className = 'row';
    row.style.marginTop = '14px';
    const no = Object.assign(document.createElement('button'), { className: 'plain', textContent: 'Reject' });
    const yes = Object.assign(document.createElement('button'), { textContent: 'Approve' });
    no.onclick = () => decide(m, false);
    yes.onclick = () => decide(m, true);
    row.append(no, yes);
    const left = f.reviewDue ? Math.max(0, Math.round((f.reviewDue - (Date.now() + offset)) / 60000)) : null;
    const note = Object.assign(document.createElement('p'), {
      textContent: 'Does it show the order was done?' + (left != null ? ' If you do not decide within ' + left + ' min, it is approved.' : ''),
    });
    note.style.margin = '14px 0 0';
    return [note, row];
  }

  function showSheet(...nodes) {
    $('shownBody').replaceChildren(...nodes);
    $('shown').hidden = false;
  }
  $('shownClose').onclick = () => { $('shown').hidden = true; $('shownBody').replaceChildren(); };

  // The sender's verdict on their order's proof.
  async function decide(m, approve) {
    try {
      const r = await fetch(ordersBase() + '/review', {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ no: m.no, receipt: m.receipt, verdict: approve ? 'approve' : 'reject' }),
      });
      const res = await r.json();
      const v = r.ok ? res : res.view;
      if (v) { view = isProfile ? { ...v, publicId: view.publicId } : v; offset = v.now - Date.now(); }
      $('msg').textContent = r.ok
        ? (approve ? 'Approved. They get the tokens for it.' : "Rejected. It counts as failed.")
        : 'Too late to decide - it has already been settled.';
    } catch { $('msg').textContent = "That didn't go through. Check your connection."; }
    $('shown').hidden = true;
    ordersShown = '';
    render();
  }

  async function showProof(m, f) {
    if (!(await adultCheck())) return;
    const text = (t) => Object.assign(document.createElement('p'), { textContent: t });
    try {
      const r = await fetch(ordersBase() + '/proof', {
        method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ no: m.no, receipt: m.receipt }),
      });
      if (!r.ok) { showSheet(text('This proof is no longer available. Proof is kept for a day.')); return; }
      const env = JSON.parse((await r.json()).proof);
      const saved = store.get(KEY, null);
      if (!saved) { showSheet(text("This browser no longer has the key to open it.")); return; }
      const priv = await crypto.subtle.importKey('jwk', saved.priv, { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']);
      const epk = await crypto.subtle.importKey('raw', unb64(env.epk), { name: 'ECDH', namedCurve: 'P-256' }, false, []);
      const bits = await crypto.subtle.deriveBits({ name: 'ECDH', public: epk }, priv, 256);
      const hk = await crypto.subtle.importKey('raw', bits, 'HKDF', false, ['deriveKey']);
      const aes = await crypto.subtle.deriveKey(
        { name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(32), info: new TextEncoder().encode('stm-proof-v1') },
        hk, { name: 'AES-GCM', length: 256 }, false, ['decrypt']);
      const plain = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: unb64(env.iv) }, aes, unb64(env.ct));
      const title = Object.assign(document.createElement('h2'), { textContent: m.title });
      if (['image/jpeg', 'image/png', 'image/webp', 'image/gif'].includes(env.mime)) {
        const img = document.createElement('img');
        img.alt = 'Proof';
        img.src = URL.createObjectURL(new Blob([plain], { type: env.mime }));
        showSheet(title, img, ...verdict(m, f), text('Only this browser can open it, and only until a day after it was sent.'));
      } else {
        showSheet(title, text(new TextDecoder().decode(plain)), ...verdict(m, f));
      }
    } catch { showSheet(text("Couldn't open this proof.")); }
  }

  // Open in the app: its link opens it if it is installed. If the page is
  // still in front a moment later, it is not - so on to the download.
  (() => {
    const link = $('openApp');
    if (/iPhone|iPad|iPod/.test(navigator.userAgent)) { link.hidden = true; return; }
    const download = link.href;
    const path = location.pathname.endsWith('/') ? location.pathname.slice(0, -1) : location.pathname;
    link.href = 'subtaskmanager:/' + path;
    link.onclick = (e) => {
      e.preventDefault();
      let left = false;
      const away = () => { left = true; };
      window.addEventListener('blur', away, { once: true });
      document.addEventListener('visibilitychange', away, { once: true });
      location.href = link.href;
      setTimeout(() => { if (!left && !document.hidden) location.href = download; }, 1500);
    };
  })();

  $('add').onclick = () => vote(1);
  $('remove').onclick = () => vote(-1);

  if (siteKey) {
    window.onTurnstile = (t) => { token = t; ordersShown = ''; render(); };
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

/**
 * What any /t/ address shows when there is no live timer behind it: it ended
 * and was deleted (30 days after the end), its link was switched off or
 * replaced, or the address was never real. Links get shared around and found
 * late, so it says what was there and points to the app rather than leaving
 * a dead end.
 */
export function expiredPage(): string {
  const site = 'https://www.subtaskmanager.com/?from=timer-ended';
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="referrer" content="no-referrer">
${previewTags({
  url: 'https://www.subtaskmanager.com/',
  title: 'Chastity Timer · Timer ended',
  description: 'There was a chastity timer here. Get (sub)Task Manager to run your own.',
  // A path no real link can have (they are 12 characters), so it always
  // answers with the "ended" picture.
  image: 'https://subtaskmanager.com/t/timer-ended/preview.png',
  tone: '#22d3ee',
})}
<title>Chastity Timer</title>
<style>
  :root { --bg:#0e0f14; --card:#171922; --line:#262a36; --text:#eef0f6; --muted:#9aa0b4; --accent:#22d3ee; }
  @media (prefers-color-scheme: light) { :root { --bg:#f5f6fa; --card:#fff; --line:#e3e5ee; --text:#161823; --muted:#5d6275; } }
  * { box-sizing: border-box; }
  body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center; padding:16px;
         background:var(--bg); color:var(--text); font:16px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  main { width:100%; max-width:420px; background:var(--card); border:1px solid var(--line); border-radius:20px; padding:28px 22px; text-align:center; }
  .label { font-size:12px; font-weight:700; letter-spacing:.12em; text-transform:uppercase; color:var(--accent); }
  h1 { font-size:22px; margin:8px 0 10px; }
  p { color:var(--muted); margin:0 0 14px; }
  .icon { font-size:40px; line-height:1; margin:6px 0 4px; }
  .cta { display:block; margin-top:20px; padding:15px 10px; border-radius:14px; background:var(--accent); color:#0e0f14;
         font-weight:700; text-decoration:none; }
  .cta:hover { filter:brightness(1.08); }
  .site { margin-top:12px; font-size:13px; }
  .site a { color:var(--accent); text-decoration:none; }
</style>
</head>
<body>
<main>
  <div class="label">Chastity Timer</div>
  <div class="icon" aria-hidden="true">&#128275;</div>
  <h1>This timer has ended</h1>
  <p>There was a chastity timer here, but it has expired, or its link has been switched off.</p>
  <p>Want to run one of your own? Set up a timer, share a link, and let people add or take away time.</p>
  <a class="cta" href="${site}">Get (sub)Task Manager</a>
  <div class="site"><a href="${site}">www.subtaskmanager.com</a></div>
</main>
</body>
</html>`;
}

/** A player's page address that no longer works: replaced, or never real. */
export function profileGonePage(): string {
  return expiredPage()
    .replace('<h1>This timer has ended</h1>', '<h1>This link no longer works</h1>')
    .replace(
      '<p>There was a chastity timer here, but it has expired, or its link has been switched off.</p>',
      '<p>This page has moved to a new link, or been taken down.</p>',
    );
}
