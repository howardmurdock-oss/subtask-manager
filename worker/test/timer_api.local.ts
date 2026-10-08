// End-to-end check of the timer routes against a running Worker.
//
//   npx wrangler dev --local --port 8799      (in one terminal)
//   node test/timer_api.local.ts              (in another)
//
// Not part of `npm test`: it needs the Worker running. Uses only local
// simulated storage - never point it at the live Worker.
import assert from 'node:assert/strict';

const BASE = process.env.TIMER_BASE ?? 'http://127.0.0.1:8799';
if (!/^http:\/\/(127\.0\.0\.1|localhost)/.test(BASE)) throw new Error('local Worker only');

const H = 3600;
let passed = 0;
// Each check from its own address, so the per-visitor limits are about it
// alone, not the whole run.
let visitorIp = '10.0.0.1';
const check = async (name: string, fn: () => Promise<void>) => {
  visitorIp = `10.1.${Math.floor(Math.random() * 250)}.${Math.floor(Math.random() * 250)}`;
  await fn();
  passed++;
  console.log(`ok - ${name}`);
};

// Each timer started from its own made-up address, so the limit on starting
// them only comes into it where a check is about it. Everything else from one.
async function call(path: string, init: { method?: string; key?: string; body?: unknown; ip?: string } = {}) {
  const r = await fetch(BASE + path, {
    method: init.method ?? (init.body ? 'POST' : 'GET'),
    headers: {
      'content-type': 'application/json',
      'CF-Connecting-IP': init.ip ?? (path !== '/timer' ? visitorIp : `10.${Math.floor(Math.random() * 250)}.${Math.floor(Math.random() * 250)}.${Math.floor(Math.random() * 250)}`),
      ...(init.key ? { 'X-Timer-Key': init.key } : {}),
    },
    body: init.body ? JSON.stringify(init.body) : undefined,
  });
  const text = await r.text();
  let body: any = text;
  try { body = JSON.parse(text); } catch {}
  return { status: r.status, body, headers: r.headers };
}

const created = await call('/timer', {
  body: {
    managedBy: 'director',
    config: {
      baseSeconds: 10 * H,
      hidden: true,
      director: { canAdd: true, canRemove: true, dailyCapSeconds: 3 * H },
      public: { enabled: true, allowRemove: false, stepSeconds: 600, perVisitorDailySeconds: 1200, dailyCapSeconds: 3000 },
      combination: { enabled: true, digits: '4821' },
    },
  },
});
const { id, playerKey, directorKey, publicId } = created.body;

await check('creating a timer returns its id, both keys and a public link', async () => {
  assert.equal(created.status, 200);
  assert.ok(id && playerKey && directorKey && publicId);
  assert.notEqual(playerKey, directorKey);
});

await check('without a key, or with the wrong one, nothing is shown', async () => {
  assert.equal((await call(`/timer/${id}/view`)).status, 403);
  assert.equal((await call(`/timer/${id}/view`, { key: 'nope' })).status, 403);
});

await check('the director sees everything, including the combination', async () => {
  const v = (await call(`/timer/${id}/view`, { key: directorKey })).body;
  assert.equal(v.role, 'director');
  assert.equal(v.manager, true);
  assert.equal(typeof v.endAt, 'number');
  assert.equal(v.config.combination.digits, '4821');
  assert.equal(v.publicId, publicId);
});

await check('the player of a hidden timer sees neither time left nor combination', async () => {
  const v = (await call(`/timer/${id}/view`, { key: playerKey })).body;
  assert.equal(v.role, 'player');
  assert.equal(v.manager, false);
  assert.equal(v.endAt, null);
  assert.equal(v.config.combination.digits, null);
  assert.equal(v.config.combination.length, 4);
  assert.equal(v.publicId, null, 'the link is for whoever manages the timer');
});

await check('the director can add and remove, up to the daily cap', async () => {
  const before = (await call(`/timer/${id}/view`, { key: directorKey })).body.endAt;
  const add = await call(`/timer/${id}/adjust`, { key: directorKey, body: { delta: 2 * H, eventId: 'e1' } });
  assert.equal(add.status, 200);
  assert.equal(add.body.endAt, before + 2 * H * 1000);
  const retry = await call(`/timer/${id}/adjust`, { key: directorKey, body: { delta: 2 * H, eventId: 'e1' } });
  assert.equal(retry.body.endAt, add.body.endAt, 'a retried change is not applied twice');
  const over = await call(`/timer/${id}/adjust`, { key: directorKey, body: { delta: -2 * H, eventId: 'e2' } });
  assert.equal(over.status, 409);
  assert.equal(over.body.error, 'daily-cap');
});

await check('the player can add but not remove, and a hidden timer hides the amounts', async () => {
  const add = await call(`/timer/${id}/adjust`, { key: playerKey, body: { delta: H, eventId: 'p1' } });
  assert.equal(add.status, 200);
  assert.ok(add.body.history.every((e: any) => e.delta === null));
  const remove = await call(`/timer/${id}/adjust`, { key: playerKey, body: { delta: -H, eventId: 'p2' } });
  assert.equal(remove.body.error, 'not-allowed');
});

await check('only the manager can change the settings', async () => {
  const byPlayer = await call(`/timer/${id}/configure`, { key: playerKey, body: { config: { hidden: false } } });
  assert.equal(byPlayer.status, 403);
  const byDirector = await call(`/timer/${id}/configure`, { key: directorKey, body: { config: { public: { enabled: true, showTimeLeft: false, stepSeconds: 600, perVisitorDailySeconds: 1200, dailyCapSeconds: 3000 } } } });
  assert.equal(byDirector.status, 200);
  assert.equal(byDirector.body.config.public.showTimeLeft, false);
});

await check('the public page is served, kept out of search, and free of anything private', async () => {
  const page = await call(`/t/${publicId}`);
  assert.equal(page.status, 200);
  assert.match(page.headers.get('content-type') ?? '', /text\/html/);
  assert.match(page.headers.get('x-robots-tag') ?? '', /noindex/);
  assert.ok(!String(page.body).includes('4821'));
  assert.ok(!String(page.body).includes(id));
});

await check('the public state shows only what is allowed', async () => {
  const s = await call(`/t/${publicId}/state`);
  assert.equal(s.status, 200);
  assert.equal(s.headers.get('access-control-allow-origin'), '*');
  assert.equal(s.body.endAt, null, 'time left was switched off for strangers');
  assert.equal(s.body.history, undefined);
  assert.ok(!JSON.stringify(s.body).includes('4821'));
});

await check('votes count one step each, up to the per-visitor cap', async () => {
  const before = (await call(`/timer/${id}/view`, { key: directorKey })).body.endAt;
  assert.equal((await call(`/t/${publicId}/vote`, { body: { direction: 1 } })).status, 200);
  assert.equal((await call(`/t/${publicId}/vote`, { body: { direction: 1 } })).status, 200);
  const third = await call(`/t/${publicId}/vote`, { body: { direction: 1 } });
  assert.equal(third.status, 409);
  assert.equal(third.body.error, 'visitor-cap');
  const after = (await call(`/timer/${id}/view`, { key: directorKey })).body.endAt;
  assert.equal(after, before + 1200 * 1000);
  const remove = await call(`/t/${publicId}/vote`, { body: { direction: -1 } });
  assert.equal(remove.body.error, 'not-allowed', 'removal is off for this link');
});

await check('replacing the link retires the old one', async () => {
  const replaced = await call(`/timer/${id}/replace-link`, { key: directorKey, body: {} });
  assert.equal(replaced.status, 200);
  const fresh = replaced.body.publicId;
  assert.ok(fresh && fresh !== publicId);
  assert.equal((await call(`/t/${publicId}/state`)).status, 404);
  assert.equal((await call(`/t/${fresh}/state`)).status, 200);

  const off = await call(`/timer/${id}/configure`, { key: directorKey, body: { config: { public: { enabled: false } } } });
  assert.equal(off.status, 200);
  assert.equal((await call(`/t/${fresh}/state`)).status, 404, 'switching the link off retires it');
});

await check('an unknown or mistyped link gets the "this timer has ended" page, not an error', async () => {
  for (const path of ['/t/doesNotExist123', '/t/x', '/t/', '/t/some/deeper/path']) {
    const page = await call(path);
    assert.equal(page.status, 404, path);
    assert.match(page.headers.get('content-type') ?? '', /text\/html/, path);
    assert.match(String(page.body), /This timer has ended/, path);
    assert.match(page.headers.get('x-robots-tag') ?? '', /noindex/, path);
  }
});

await check('a live link still gets the timer, and a retired one gets the ended page', async () => {
  const t = (await call('/timer', { body: { managedBy: 'director', config: { baseSeconds: 5 * H, public: { enabled: true } } } })).body;
  const live = await call(`/t/${t.publicId}`);
  assert.equal(live.status, 200);
  assert.doesNotMatch(String(live.body), /This timer has ended/);
  const replaced = await call(`/timer/${t.id}/replace-link`, { key: t.directorKey, body: {} });
  const old = await call(`/t/${t.publicId}`);
  assert.match(String(old.body), /This timer has ended/);
  assert.equal((await call(`/t/${replaced.body.publicId}`)).status, 200);
});

await check('the widget and the image work for a live timer, and fall back once it is gone', async () => {
  const t = (await call('/timer', { body: { managedBy: 'director', config: { baseSeconds: 5 * H, public: { enabled: true } } } })).body;
  const widget = await call(`/t/${t.publicId}/embed`);
  assert.equal(widget.status, 200);
  assert.equal(widget.headers.get('content-security-policy'), 'frame-ancestors *', 'anyone may frame the widget');
  assert.match(String(widget.body), /Vote on it/);
  const image = await call(`/t/${t.publicId}/badge.svg`);
  assert.match(image.headers.get('content-type') ?? '', /image\/svg\+xml/);
  assert.match(String(image.body), /Locked · 5h 0m left|Locked · 4h 59m left/);

  const page = await call(`/t/${t.publicId}`);
  assert.equal(page.headers.get('content-security-policy'), "frame-ancestors 'none'", 'the voting page is never framed');

  await call(`/timer/${t.id}/replace-link`, { key: t.directorKey, body: {} });
  assert.match(String((await call(`/t/${t.publicId}/embed`)).body), /Timer ended/);
  assert.match(String((await call(`/t/${t.publicId}/badge.svg`)).body), /Timer ended/);
  assert.match(String((await call('/t/neverExisted99/badge.svg')).body), /Timer ended/);
});

await check('link previews: tags on the page, and the right picture for the state', async () => {
  const t = (await call('/timer', { body: { managedBy: 'player', config: { baseSeconds: 3 * H, public: { enabled: true } } } })).body;
  const page = String((await call(`/t/${t.publicId}`)).body);
  assert.match(page, /og:title" content="Chastity Timer · (3h 0m|2h 59m) left"/);
  const png = async (path: string) => {
    const r = await fetch(BASE + path);
    return { type: r.headers.get('content-type'), size: (await r.arrayBuffer()).byteLength };
  };
  const locked = await png(`/t/${t.publicId}/preview.png`);
  assert.equal(locked.type, 'image/png');
  assert.ok(locked.size > 10000);
  await call(`/timer/${t.id}/release`, { key: t.playerKey, body: {} });
  const unlocked = await png(`/t/${t.publicId}/preview.png`);
  assert.notEqual(unlocked.size, locked.size, 'a different picture once it is over');
  const ended = await png('/t/timer-ended/preview.png');
  assert.equal(ended.type, 'image/png');
  assert.notEqual(ended.size, locked.size);
  assert.equal((await png(`/t/${t.publicId}/badge.png`)).type, 'image/png');
});

await check("a partner's key that never arrived can be issued again, until they connect", async () => {
  const t = (await call('/timer', { body: { managedBy: 'player', config: { baseSeconds: 3 * H } } })).body;
  const mine = await call(`/timer/${t.id}/view`, { key: t.playerKey });
  assert.equal(mine.body.partnerConnected, false, 'the director has not connected yet');

  const fresh = await call(`/timer/${t.id}/reissue-key`, { key: t.playerKey, body: {} });
  assert.equal(fresh.status, 200);
  assert.ok(fresh.body.key && fresh.body.key !== t.directorKey);
  assert.equal((await call(`/timer/${t.id}/view`, { key: t.directorKey })).status, 403, 'the lost key no longer works');

  const theirs = await call(`/timer/${t.id}/view`, { key: fresh.body.key });
  assert.equal(theirs.status, 200);
  assert.equal(theirs.body.role, 'director');
  assert.equal((await call(`/timer/${t.id}/view`, { key: t.playerKey })).body.partnerConnected, true);
  const again = await call(`/timer/${t.id}/reissue-key`, { key: t.playerKey, body: {} });
  assert.equal(again.status, 409);
  assert.equal(again.body.error, 'partner-connected');
});

await check('only whoever manages the timer can have a key issued again', async () => {
  const t = (await call('/timer', { body: { managedBy: 'player', config: { baseSeconds: 3 * H } } })).body;
  const r = await call(`/timer/${t.id}/reissue-key`, { key: t.directorKey, body: {} });
  assert.equal(r.status, 403);
  assert.equal((await call(`/timer/${t.id}/view`, { key: t.playerKey })).body.partnerConnected, true,
    'using a key at all is connecting');
});

await check("a director cannot replace a player's key once the player has it", async () => {
  const t = (await call('/timer', { body: { managedBy: 'director', config: { baseSeconds: 3 * H } } })).body;
  await call(`/timer/${t.id}/view`, { key: t.directorKey });
  await call(`/timer/${t.id}/view`, { key: t.playerKey });
  const r = await call(`/timer/${t.id}/reissue-key`, { key: t.directorKey, body: {} });
  assert.equal(r.status, 409, "the player's emergency release can never be taken away");
  assert.equal((await call(`/timer/${t.id}/view`, { key: t.playerKey })).status, 200);
});

await check('a change keeps the link in its reply, for whoever may see it', async () => {
  const t = (await call('/timer', { body: { managedBy: 'director', config: { baseSeconds: 5 * H, public: { enabled: true } } } })).body;
  const add = await call(`/timer/${t.id}/adjust`, { key: t.directorKey, body: { delta: 60, eventId: 'x1' } });
  assert.equal(add.body.publicId, t.publicId);
  const player = await call(`/timer/${t.id}/view`, { key: t.playerKey });
  assert.equal(player.body.publicId, null, 'not shared with the player by default');

  const shared = await call(`/timer/${t.id}/configure`, { key: t.directorKey, body: { config: { public: { enabled: true, shareWithPlayer: true } } } });
  assert.equal(shared.status, 200);
  const nowPlayer = await call(`/timer/${t.id}/view`, { key: t.playerKey });
  assert.equal(nowPlayer.body.publicId, t.publicId, 'shared: the player gets it');
  const replace = await call(`/timer/${t.id}/replace-link`, { key: t.playerKey, body: {} });
  assert.equal(replace.status, 403, 'but replacing it stays with the director');
});

await check('at the maximum, a public vote is refused with a reason', async () => {
  const t = (await call('/timer', { body: { managedBy: 'director', config: { baseSeconds: 2 * H, maxTotalSeconds: 2 * H, public: { enabled: true, stepSeconds: 600 } } } })).body;
  const state = await call(`/t/${t.publicId}/state`);
  assert.equal(state.body.atMaximum, true);
  const vote = await call(`/t/${t.publicId}/vote`, { body: { direction: 1 } });
  assert.equal(vote.status, 409);
  assert.equal(vote.body.error, 'at-maximum');
});

await check("the player's emergency release ends it and reveals the combination", async () => {
  const released = await call(`/timer/${id}/release`, { key: playerKey, body: {} });
  assert.equal(released.status, 200);
  assert.equal(released.body.status, 'released');
  assert.equal(released.body.releasedBy, 'player');
  assert.equal(released.body.config.combination.digits, '4821');
  const after = await call(`/timer/${id}/adjust`, { key: directorKey, body: { delta: H, eventId: 'late' } });
  assert.equal(after.body.error, 'not-running');
});

await check('a player-managed timer is the player\'s to configure', async () => {
  const own = (await call('/timer', { body: { managedBy: 'player', config: { baseSeconds: 2 * H } } })).body;
  assert.equal(own.publicId, null, 'no link unless asked for');
  const v = (await call(`/timer/${own.id}/view`, { key: own.playerKey })).body;
  assert.equal(v.manager, true);
  const byDirector = await call(`/timer/${own.id}/configure`, { key: own.directorKey, body: { config: { hidden: true } } });
  assert.equal(byDirector.status, 403);
  const linked = await call(`/timer/${own.id}/configure`, { key: own.playerKey, body: { config: { public: { enabled: true } } } });
  assert.ok(linked.body.publicId);
  assert.equal((await call(`/t/${linked.body.publicId}/state`)).status, 200);
});

await check('a timer with no end time can be created, viewed, shared and ended', async () => {
  const made = await call('/timer', {
    body: { managedBy: 'player', config: { baseSeconds: H, openEnded: true, maxTotalSeconds: 48 * H, public: { enabled: true } } },
  });
  assert.equal(made.status, 200, JSON.stringify(made.body));
  const t = made.body;
  const v = (await call(`/timer/${t.id}/view`, { key: t.playerKey })).body;
  assert.equal(v.status, 'running');
  assert.equal(v.endAt, null);
  assert.equal(v.config.openEnded, true);
  assert.equal(v.config.maxTotalSeconds, null, "a player's own: no limit");
  const add = await call(`/timer/${t.id}/adjust`, { key: t.playerKey, body: { delta: 600, eventId: 'o1' } });
  assert.equal(add.status, 409);
  const pub = await call(`/t/${t.publicId}/state`);
  assert.equal(pub.status, 200);
  assert.equal(pub.body.openEnded, true);
  assert.equal(pub.body.acceptingVotes, false);
  assert.equal((await call(`/t/${t.publicId}`)).status, 200, 'the public page renders');
  const ended = await call(`/timer/${t.id}/release`, { key: t.playerKey, body: {} });
  assert.equal(ended.status, 200);
  const after = (await call(`/timer/${t.id}/view`, { key: t.playerKey })).body;
  assert.equal(after.status, 'released');
  assert.ok(after.closedAt);
});

await check('a timer gets a limited number of new links a day, and can always remove one', async () => {
  const t = (await call('/timer', { body: { managedBy: 'player', config: { baseSeconds: H } } })).body;
  const set = (enabled: boolean) =>
    call(`/timer/${t.id}/configure`, { key: t.playerKey, body: { config: { public: { enabled } } } });
  for (let i = 0; i < 10; i++) {
    assert.equal((await set(true)).status, 200, `link ${i + 1}`);
    assert.equal((await set(false)).status, 200);
  }
  const refused = await set(true);
  assert.equal(refused.status, 429);
  assert.equal(refused.body.error, 'link-changes');
  const v = (await call(`/timer/${t.id}/view`, { key: t.playerKey })).body;
  assert.equal(v.config.public.enabled, false, 'the refused change was not kept');
});

await check('starting timers over and over from one address is slowed down', async () => {
  let limited = 0;
  for (let i = 0; i < 12; i++) {
    const r = await call('/timer', { body: { managedBy: 'player', config: { baseSeconds: H } }, ip: '10.255.0.1' });
    if (r.status === 429) {
      assert.equal(r.body.error, 'slow-down');
      limited++;
    }
  }
  assert.ok(limited > 0, 'some were refused');
});

await check("the player's device says where it listens; votes still go through when told", async () => {
  const t = (await call('/timer', {
    body: { managedBy: 'director', config: { baseSeconds: H, public: { enabled: true }, notify: { message: '  {time} more, Toy\n' } } },
  })).body;
  const d = (await call(`/timer/${t.id}/view`, { key: t.directorKey })).body;
  assert.deepEqual(d.config.notify, { onAdd: true, message: '{time} more, Toy' });
  const topic = 'orders_relay_0123456789abcdef01234567';
  assert.equal((await call(`/timer/${t.id}/notify-topic`, { key: t.directorKey, body: { topic } })).status, 403, 'not the director');
  assert.equal((await call(`/timer/${t.id}/notify-topic`, { key: t.playerKey, body: { topic: 'somewhere-else' } })).status, 400);
  assert.equal((await call(`/timer/${t.id}/notify-topic`, { key: t.playerKey, body: { topic } })).status, 200);
  // Nothing listens on that topic here: the vote must still count.
  assert.equal((await call(`/t/${t.publicId}/vote`, { body: { direction: 1 }, ip: '10.7.7.7' })).status, 200);
  assert.equal((await call(`/t/${t.publicId}/vote`, { body: { direction: 1 }, ip: '10.7.7.8' })).status, 200, 'held for the minute');
  const off = await call(`/timer/${t.id}/configure`, { key: t.directorKey, body: { config: { notify: { onAdd: false } } } });
  assert.equal(off.body.config.notify.onAdd, false);
  const pub = (await call(`/t/${t.publicId}/state`)).body;
  assert.equal(JSON.stringify(pub).includes('notify'), false);
});

await check("a player's page: one link, showing whichever of their timers may be shown", async () => {
  const made = await call('/profile', { body: { name: '  Toy\n ' } });
  assert.equal(made.status, 200);
  const p = made.body;
  assert.equal(p.name, 'Toy');
  const as = (op: string, body?: unknown, key = p.key) =>
    fetch(`${BASE}/profile/${p.profileId}/${op}`, {
      method: body ? 'POST' : 'GET',
      headers: { 'content-type': 'application/json', 'X-Profile-Key': key, 'CF-Connecting-IP': '10.0.0.1' },
      body: body ? JSON.stringify(body) : undefined,
    }).then(async (r) => ({ status: r.status, body: await r.json() as any }));
  const state = async (pid = p.publicId) => (await call(`/p/${pid}/state`)).body;

  assert.equal((await as('view', undefined, 'wrong')).status, 403, 'not without its key');
  assert.equal((await state()).featured, null, 'nothing yet');

  // The player's own timer, link on.
  const own = (await call('/timer', { body: { managedBy: 'player', config: { baseSeconds: H, public: { enabled: true } } } })).body;
  assert.equal((await as('add', { timerId: own.id, timerKey: own.directorKey })).status, 403, "only as the timer's player");
  assert.equal((await as('add', { timerId: own.id, timerKey: own.playerKey })).status, 200);
  let s = await state();
  assert.equal(s.name, 'Toy');
  assert.equal(s.featured.publicId, own.publicId);
  assert.equal(JSON.stringify(s).includes(own.id), false, 'the timer id stays private');

  // A director's timer shows only once the player is given the link.
  const dir = (await call('/timer', { body: { managedBy: 'director', config: { baseSeconds: 2 * H, public: { enabled: true } } } })).body;
  await as('add', { timerId: dir.id, timerKey: dir.playerKey });
  assert.equal((await state()).others.length, 0);
  await call(`/timer/${dir.id}/configure`, { key: dir.directorKey, body: { config: { public: { enabled: true, shareWithPlayer: true } } } });
  s = await state();
  assert.equal(s.featured.publicId, dir.publicId, 'the most recently added comes first');
  assert.equal(s.others[0].publicId, own.publicId);

  // Link off: it leaves the page.
  await call(`/timer/${dir.id}/configure`, { key: dir.directorKey, body: { config: { public: { enabled: false } } } });
  assert.equal((await state()).featured.publicId, own.publicId);

  // Ended: in the past list only if the player shows it.
  await call(`/timer/${own.id}/release`, { key: own.playerKey, body: {} });
  s = await state();
  assert.equal(s.featured, null);
  assert.equal(s.history.length, 0, 'history is off unless switched on');
  assert.equal((await as('settings', { showHistory: true })).body.showHistory, true);
  s = await state();
  assert.equal(s.history.length, 1);
  assert.equal(s.history[0].status, 'released');

  // Deleted from the device: gone from the page.
  await as('remove', { timerId: own.id });
  assert.equal((await state()).history.length, 0);

  // The page, widget and badge.
  const page = await call(`/p/${p.publicId}`);
  assert.equal(page.status, 200);
  assert.ok(String(page.body).includes('Toy&#39;s Chastity Timer'), 'the name, escaped, in the preview');
  assert.ok(String((await call(`/p/${p.publicId}/badge.svg`)).body).includes('Not locked up'));
  assert.equal((await call(`/p/${p.publicId}/embed`)).status, 200);

  // A new link: the old one stops working.
  const moved = (await as('new-link', {})).body;
  assert.notEqual(moved.publicId, p.publicId);
  assert.equal((await call(`/p/${p.publicId}`)).status, 404);
  assert.equal((await call(`/p/${moved.publicId}/state`)).status, 200);

  // Moved to another device: the old key no longer works.
  const rekeyed = (await as('rekey', {})).body;
  assert.ok(rekeyed.key && rekeyed.key !== p.key);
  assert.equal((await as('view')).status, 403);
  assert.equal((await as('view', undefined, rekeyed.key)).status, 200);
});

await check('public orders: sent from the list, delivered one at a time, proof only to its sender', async () => {
  const sha = async (t: string) =>
    [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(t)))].map((b) => b.toString(16).padStart(2, '0')).join('');
  const keyPair = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const issuerKey = btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.exportKey('raw', keyPair.publicKey))));
  const t = (await call('/timer', {
    body: {
      managedBy: 'player',
      config: {
        baseSeconds: 10 * H,
        public: { enabled: true },
        publicOrders: {
          enabled: true,
          proofTo: 'issuer',
          perVisitorDaily: 2,
          maxQueued: 3,
          skipsPerDay: 1,
          skipPauseMinutes: 5,
          orders: [
            { id: 'plank', title: 'Plank, 2 minutes', durationType: 'deadlineCountdown', deadlineMinutes: 30, rewardTokens: 5, penaltyTokens: 2 },
            { id: 'check', title: 'Cage check', verification: 'photoProof', rewardTokens: 3 },
          ],
        },
      },
    },
  })).body;
  const order = (orderId: string, ip: string, receipt: string) =>
    sha(receipt).then((receiptHash) =>
      call(`/t/${t.publicId}/order`, { body: { orderId, issuerKey, receiptHash }, ip }));

  const page = (await call(`/t/${t.publicId}/state`)).body;
  assert.equal(page.orders.enabled, true);
  assert.equal(page.orders.accepting, true);
  assert.deepEqual(page.orders.list.map((o: any) => o.id), ['plank', 'check']);

  const first = await order('plank', '10.8.0.1', 'receipt-1');
  assert.equal(first.status, 200, JSON.stringify(first.body));
  assert.equal((await order('check', '10.8.0.1', 'receipt-2')).status, 200);
  assert.equal((await order('plank', '10.8.0.1', 'receipt-3')).body.error, 'visitor-cap');
  assert.equal((await order('nope', '10.8.0.2', 'receipt-4')).body.error, 'unknown-order');

  // The player sees the one in progress, with the key to encrypt proof to.
  let mine = (await call(`/timer/${t.id}/view`, { key: t.playerKey })).body.orders;
  assert.equal(mine.active.def.id, 'plank');
  assert.equal(mine.waiting, 1);
  const result = (no: number, body: object, key = t.playerKey) =>
    call(`/timer/${t.id}/order-result`, { key, body: { no, ...body } });
  assert.equal((await result(mine.active.no, { result: 'completed' }, t.directorKey)).status, 403, 'only the player');
  assert.equal((await result(mine.active.no, { result: 'completed' })).status, 200);

  // The next one is delivered, and its proof kept for its sender alone.
  mine = (await call(`/timer/${t.id}/view`, { key: t.playerKey })).body.orders;
  assert.equal(mine.active.def.id, 'check');
  assert.equal(mine.active.issuerKey, issuerKey);
  await result(mine.active.no, { result: 'completed', proof: 'CIPHERTEXT' });
  const proof = (receipt: string) => call(`/t/${t.publicId}/proof`, { body: { no: mine.active.no, receipt } });
  assert.equal((await proof('receipt-1')).status, 404, "another order's receipt");
  assert.equal((await proof('receipt-2')).body.proof, 'CIPHERTEXT');

  // The feed: what, and how it went - not who, nor the proof.
  const feed = (await call(`/t/${t.publicId}/state`)).body.orders.feed;
  assert.deepEqual(feed.map((f: any) => f.status), ['completed', 'completed']);
  assert.equal(feed[0].hasProof, true);
  assert.equal(JSON.stringify(feed).includes('CIPHERTEXT') || JSON.stringify(feed).includes('10.8.0.1'), false);

  // A skip: no penalty here, and a pause - nothing new taken meanwhile.
  await order('plank', '10.8.0.3', 'receipt-5');
  mine = (await call(`/timer/${t.id}/view`, { key: t.playerKey })).body.orders;
  const skipped = await call(`/timer/${t.id}/order-skip`, { key: t.playerKey, body: { no: mine.active.no } });
  assert.equal(skipped.status, 200);
  assert.equal(skipped.body.orders.skipsLeft, 0);
  assert.ok(skipped.body.orders.pausedUntil > Date.now());
  assert.equal((await order('plank', '10.8.0.4', 'receipt-6')).body.error, 'paused');
  const pausedPage = (await call(`/t/${t.publicId}/state`)).body.orders;
  assert.equal(pausedPage.accepting, false);
  assert.equal(pausedPage.reason, 'paused');

  // Over: nothing more is taken.
  await call(`/timer/${t.id}/release`, { key: t.playerKey, body: {} });
  assert.equal((await order('plank', '10.8.0.5', 'receipt-7')).body.error, 'not-running');
});

await check('a timer without public orders takes none, and the page says so', async () => {
  const plain = (await call('/timer', { body: { managedBy: 'player', config: { baseSeconds: H, public: { enabled: true } } } })).body;
  assert.equal((await call(`/t/${plain.publicId}/state`)).body.orders.enabled, false);
  const r = await call(`/t/${plain.publicId}/order`, { body: { orderId: 'x', receiptHash: 'a'.repeat(64) }, ip: '10.8.1.1' });
  assert.equal(r.body.error, 'orders-off');
});

await check('photo proof is approved or rejected by whoever receives it', async () => {
  const sha = async (t: string) =>
    [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(t)))].map((b) => b.toString(16).padStart(2, '0')).join('');
  const keyPair = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const issuerKey = btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.exportKey('raw', keyPair.publicKey))));
  const make = async (proofTo: string) => (await call('/timer', {
    body: { managedBy: 'player', config: { baseSeconds: 10 * H, public: { enabled: true }, publicOrders: {
      enabled: true, proofTo, perVisitorDaily: 5,
      orders: [{ id: 'check', title: 'Cage check', verification: 'photoProof', durationType: 'deadlineCountdown', deadlineMinutes: 5 }],
    } } },
  })).body;
  const send = async (t: any, ip: string, receipt: string) =>
    (await call(`/t/${t.publicId}/order`, { body: { orderId: 'check', issuerKey, receiptHash: await sha(receipt) }, ip })).body.no as number;
  const mine = async (t: any) => (await call(`/timer/${t.id}/view`, { key: t.playerKey })).body.orders;
  const result = (t: any, no: number, body: object) => call(`/timer/${t.id}/order-result`, { key: t.playerKey, body: { no, ...body } });
  const feed = async (t: any) => (await call(`/t/${t.publicId}/state`)).body.orders.feed;
  const review = (t: any, no: number, receipt: string, verdict: string) =>
    call(`/t/${t.publicId}/review`, { body: { no, receipt, verdict } });

  // To the sender: they decide.
  const t = await make('issuer');
  const a = await send(t, '10.9.0.1', 'r-a');
  assert.equal((await result(t, a, { result: 'submitted', proof: 'PHOTO' })).status, 200);
  assert.equal((await feed(t))[0].status, 'reviewing');
  assert.ok((await feed(t))[0].reviewDue > Date.now());
  assert.equal((await result(t, a, { result: 'completed' })).body.error, 'awaiting-sender', 'not the player\'s to decide');
  assert.equal((await review(t, a, 'wrong', 'approve')).status, 409, 'only with its receipt');
  assert.equal((await call(`/t/${t.publicId}/proof`, { body: { no: a, receipt: 'r-a' } })).body.proof, 'PHOTO', 'viewable while being checked');
  assert.equal((await review(t, a, 'r-a', 'approve')).status, 200);
  assert.equal((await feed(t))[0].status, 'completed');
  assert.equal((await review(t, a, 'r-a', 'reject')).status, 409, 'decided once');

  // Rejected: failed. And the queue moves on meanwhile.
  const b = await send(t, '10.9.0.2', 'r-b');
  await result(t, b, { result: 'submitted', proof: 'PHOTO2' });
  const c = await send(t, '10.9.0.3', 'r-c');
  assert.equal((await mine(t)).active.no, c, 'delivered while the last one is checked');
  await review(t, b, 'r-b', 'reject');
  assert.equal((await feed(t)).find((f: any) => f.no === b).status, 'failed');

  // To the director: the player reports their verdict, after any delay.
  const d = await make('director');
  const n = await send(d, '10.9.0.4', 'r-d');
  await result(d, n, { result: 'submitted' });
  assert.equal((await feed(d))[0].status, 'reviewing');
  assert.equal((await result(d, n, { result: 'completed' })).status, 200);
  assert.equal((await feed(d))[0].status, 'completed');
});

await check('an app install is verified once, then votes as itself and may watch', async () => {
  const sha = async (t: string) =>
    [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(t)))].map((b) => b.toString(16).padStart(2, '0')).join('');
  const secret = 'device-secret-1';
  const started = await call('/device/start', { body: { codeHash: await sha('my-topic'), secretHash: await sha(secret) } });
  assert.equal(started.status, 200);
  const id = started.body.deviceId;
  const as = (path: string, init: { method?: string; body?: unknown; secret?: string } = {}) =>
    fetch(BASE + path, {
      method: init.method ?? (init.body ? 'POST' : 'GET'),
      headers: { 'content-type': 'application/json', 'CF-Connecting-IP': '10.77.0.1', 'X-Device-Id': id, 'X-Device-Secret': init.secret ?? secret },
      body: init.body ? JSON.stringify(init.body) : undefined,
    }).then(async (r) => ({ status: r.status, body: await r.json() as any }));

  assert.equal((await as('/device/status')).body.verified, false, 'not until the check passes');
  assert.equal((await as('/device/status', { secret: 'wrong' })).status, 404);
  const t = (await call('/timer', { body: { managedBy: 'player', config: { baseSeconds: H, public: { enabled: true } } } })).body;
  assert.equal((await as(`/t/${t.publicId}/watch`, { body: { topic: 'orders_relay_0123456789abcdef01234567' } })).status, 403, 'unverified');

  // The check page confirms it.
  assert.equal((await call('/app/verify/confirm', { body: { id } })).status, 200);
  assert.equal((await call('/app/verify/confirm', { body: { id } })).status, 404, 'once');
  assert.equal((await as('/device/status')).body.verified, true);
  assert.equal((await call('/app/verify')).status, 200, 'the check page is served');

  assert.equal((await as(`/t/${t.publicId}/vote`, { body: { direction: 1 } })).status, 200);
  const watched = await as(`/t/${t.publicId}/watch`, { body: { topic: 'orders_relay_0123456789abcdef01234567' } });
  assert.equal(watched.body.watching, true);
  // Told when it ends - nothing listens here, but ending must still work.
  assert.equal((await call(`/timer/${t.id}/release`, { key: t.playerKey, body: {} })).status, 200);
});

console.log(`\n${passed} passed`);
