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
const check = async (name: string, fn: () => Promise<void>) => {
  await fn();
  passed++;
  console.log(`ok - ${name}`);
};

async function call(path: string, init: { method?: string; key?: string; body?: unknown } = {}) {
  const r = await fetch(BASE + path, {
    method: init.method ?? (init.body ? 'POST' : 'GET'),
    headers: { 'content-type': 'application/json', ...(init.key ? { 'X-Timer-Key': init.key } : {}) },
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

console.log(`\n${passed} passed`);
