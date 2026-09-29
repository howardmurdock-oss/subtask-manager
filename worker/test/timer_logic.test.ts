// Run with: node --test worker/test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  DAY_MS,
  randomDelta,
  refuse,
  resolve,
  sanitizeConfig,
  viewFor,
  type TimerState,
} from '../src/timer_logic.ts';

const H = 3600;
const START = Date.UTC(2026, 9, 1, 12, 0, 0);
const at = (hours: number) => START + hours * H * 1000;

function timer(config: any = {}, managedBy: 'player' | 'director' = 'director'): TimerState {
  return {
    id: 'timer-abc',
    startAt: START,
    config: sanitizeConfig({ baseSeconds: 10 * H, ...config }, managedBy),
    events: [],
    releasedAt: null,
    releasedBy: null,
  };
}

test('with no changes, it ends after its base duration', () => {
  const t = timer();
  assert.equal(resolve(t, at(1)).endAt, at(10));
  assert.equal(resolve(t, at(1)).status, 'running');
  assert.equal(resolve(t, at(10)).status, 'ended');
});

test('changes add up, whatever order they arrive in', () => {
  const t = timer();
  t.events.push({ id: 'b', at: at(3), actor: 'director', delta: -1 * H });
  t.events.push({ id: 'a', at: at(2), actor: 'director', delta: 2 * H });
  assert.equal(resolve(t, at(4)).endAt, at(11));
});

test('removing more time than is left ends it at that moment, not in the past', () => {
  const t = timer();
  t.events.push({ id: 'a', at: at(2), actor: 'director', delta: -50 * H });
  const r = resolve(t, at(3));
  assert.equal(r.endAt, at(2));
  assert.equal(r.status, 'ended');
});

test('a change after the end cannot restart it', () => {
  const t = timer();
  t.events.push({ id: 'late', at: at(12), actor: 'director', delta: 5 * H });
  const r = resolve(t, at(13));
  assert.equal(r.endAt, at(10));
  assert.equal(r.history.length, 0);
});

test('the ceiling holds however much is added', () => {
  const t = timer({ maxTotalSeconds: 12 * H });
  t.events.push({ id: 'a', at: at(1), actor: 'director', delta: 100 * H });
  assert.equal(resolve(t, at(2)).endAt, at(12));
});

test('random changes are the same on every read, and land on their slots', () => {
  const t = timer({ random: { enabled: true, everyMinutes: 60, minSeconds: -H, maxSeconds: H } });
  const first = resolve(t, at(5)).history;
  const again = resolve(t, at(5)).history;
  assert.deepEqual(first, again);
  assert.equal(first.length, 5);
  assert.deepEqual(first.map((e) => e.at), [at(1), at(2), at(3), at(4), at(5)]);
  for (const e of first) {
    assert.ok(e.delta >= -H && e.delta <= H);
    assert.equal(e.delta % 60, 0, 'whole minutes');
  }
});

test('random changes differ between timers', () => {
  const a = Array.from({ length: 20 }, (_, i) => randomDelta('timer-a', i + 1, -10 * H, 10 * H));
  const b = Array.from({ length: 20 }, (_, i) => randomDelta('timer-b', i + 1, -10 * H, 10 * H));
  assert.notDeepEqual(a, b);
});

test('the player can add time but not remove it', () => {
  const t = timer({}, 'player');
  assert.equal(refuse(t, 'player', H, at(1)), null);
  assert.equal(refuse(t, 'player', -H, at(1)), 'not-allowed');
});

test('the director is held to what the setup allows', () => {
  const t = timer({ director: { canAdd: true, canRemove: false } });
  assert.equal(refuse(t, 'director', H, at(1)), null);
  assert.equal(refuse(t, 'director', -H, at(1)), 'not-allowed');
});

test("the director's daily cap counts added and removed time together, over 24 hours", () => {
  const t = timer({ baseSeconds: 100 * H, director: { dailyCapSeconds: 3 * H } });
  t.events.push({ id: 'a', at: at(1), actor: 'director', delta: 2 * H });
  t.events.push({ id: 'b', at: at(2), actor: 'director', delta: -H });
  assert.equal(refuse(t, 'director', 60, at(3)), 'daily-cap');
  // A day after the first change, it no longer counts.
  assert.equal(refuse(t, 'director', H, at(1) + DAY_MS + 1), null);
});

test('an unlimited director has no cap', () => {
  const t = timer({ baseSeconds: 1000 * H, director: { dailyCapSeconds: null } });
  for (let i = 0; i < 50; i++) t.events.push({ id: `e${i}`, at: at(1), actor: 'director', delta: 10 * H });
  assert.equal(refuse(t, 'director', 10 * H, at(2)), null);
});

test('public votes are one step each, and capped per visitor and per day', () => {
  const t = timer({
    baseSeconds: 100 * H,
    public: { enabled: true, stepSeconds: 600, perVisitorDailySeconds: 1200, dailyCapSeconds: 1800 },
  });
  assert.equal(refuse(t, 'public', 300, at(1), 'v1'), 'bad-amount');
  assert.equal(refuse(t, 'public', -600, at(1), 'v1'), 'not-allowed', 'removal off by default');
  t.events.push({ id: 'p1', at: at(1), actor: 'public', delta: 600, visitor: 'v1' });
  t.events.push({ id: 'p2', at: at(1), actor: 'public', delta: 600, visitor: 'v1' });
  assert.equal(refuse(t, 'public', 600, at(2), 'v1'), 'visitor-cap');
  assert.equal(refuse(t, 'public', 600, at(2), 'v2'), null);
  t.events.push({ id: 'p3', at: at(2), actor: 'public', delta: 600, visitor: 'v2' });
  assert.equal(refuse(t, 'public', 600, at(2), 'v3'), 'daily-cap');
});

test('at the maximum, adding is refused with a reason, removing still works', () => {
  const t = timer({
    maxTotalSeconds: 12 * H,
    director: { canAdd: true, canRemove: true },
    public: { enabled: true, allowRemove: true, stepSeconds: 600, perVisitorDailySeconds: 7200 },
  });
  t.events.push({ id: 'a', at: at(1), actor: 'director', delta: 5 * H });
  assert.equal(resolve(t, at(2)).endAt, at(12), 'held at the maximum');
  assert.equal(refuse(t, 'public', 600, at(2), 'v1'), 'at-maximum');
  assert.equal(refuse(t, 'director', H, at(2)), 'at-maximum');
  assert.equal(refuse(t, 'player', H, at(2)), 'at-maximum');
  assert.equal(refuse(t, 'public', -600, at(2), 'v1'), null);
  assert.equal(refuse(t, 'director', -H, at(2)), null);
  assert.equal((viewFor(t, 'public', at(2)) as any).atMaximum, true);
  assert.equal((viewFor(t, 'director', at(2)) as any).atMaximum, true);
});

test('below the maximum, the public page is told it is not full', () => {
  const t = timer({ maxTotalSeconds: 12 * H, public: { enabled: true } });
  assert.equal((viewFor(t, 'public', at(1)) as any).atMaximum, false);
});

test("a hidden timer's player is not told it is at the maximum", () => {
  const t = timer({ hidden: true, maxTotalSeconds: 10 * H });
  assert.equal((viewFor(t, 'player', at(1)) as any).atMaximum, null);
});

test('sharing the link with the player is off unless asked for', () => {
  assert.equal(sanitizeConfig({}, 'director').public.shareWithPlayer, false);
  assert.equal(sanitizeConfig({ public: { shareWithPlayer: true } }, 'director').public.shareWithPlayer, true);
});

test('a public link that is off takes no votes', () => {
  assert.equal(refuse(timer(), 'public', 600, at(1), 'v1'), 'public-disabled');
});

test('nothing can be changed once it is over', () => {
  const t = timer();
  assert.equal(refuse(t, 'director', H, at(11)), 'not-running');
  const released = { ...timer(), releasedAt: at(2), releasedBy: 'player' as const };
  assert.equal(refuse(released, 'director', H, at(3)), 'not-running');
  assert.equal(resolve(released, at(3)).status, 'released');
});

test('a hidden timer shows the player neither the time left nor the amounts', () => {
  const t = timer({ hidden: true });
  t.events.push({ id: 'a', at: at(1), actor: 'director', delta: H });
  const player = viewFor(t, 'player', at(2)) as any;
  assert.equal(player.endAt, null);
  assert.equal(player.history[0].delta, null);
  assert.equal(player.history[0].actor, 'director', 'who changed it is still shown');
  assert.equal(player.config.baseSeconds, null, 'the starting length would give the end away');
  assert.equal(player.config.maxTotalSeconds, null);
  const director = viewFor(t, 'director', at(2)) as any;
  assert.equal(director.endAt, at(11));
  assert.equal(director.config.baseSeconds, 10 * H);
});

test('the combination reaches the player only when it is over; the director always sees it', () => {
  const t = timer({ combination: { enabled: true, digits: '4821' } });
  assert.equal((viewFor(t, 'player', at(1)) as any).config.combination.digits, null);
  assert.equal((viewFor(t, 'player', at(1)) as any).config.combination.length, 4);
  assert.equal((viewFor(t, 'director', at(1)) as any).config.combination.digits, '4821');
  assert.equal((viewFor(t, 'player', at(11)) as any).config.combination.digits, '4821');
  const released = { ...t, releasedAt: at(1), releasedBy: 'player' as const };
  assert.equal((viewFor(released, 'player', at(1)) as any).config.combination.digits, '4821',
    'an emergency release reveals it');
});

test('strangers see only what the public link allows', () => {
  const t = timer({ combination: { enabled: true, digits: '1234' }, public: { enabled: true, showTimeLeft: false } });
  const pub = viewFor(t, 'public', at(1)) as any;
  assert.equal(pub.endAt, null);
  assert.equal(pub.history, undefined);
  assert.equal(pub.config, undefined);
  assert.equal(JSON.stringify(pub).includes('1234'), false);
});

test('a configuration from a client is bounded', () => {
  const c = sanitizeConfig({ baseSeconds: -5, public: { stepSeconds: 1e12 }, combination: { enabled: true, digits: '12ab34' } }, 'player');
  assert.equal(c.baseSeconds, 60);
  assert.equal(c.public.stepSeconds, 24 * 3600);
  assert.equal(c.combination.digits, '1234');
});
