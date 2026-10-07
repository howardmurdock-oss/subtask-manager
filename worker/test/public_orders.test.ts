// Public orders: what the approved list may hold, and how long each has.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { orderLimitMs, sanitizePublicOrders, validIssuerKey } from '../src/public_orders.ts';

const order = (over: Record<string, unknown> = {}) => ({
  id: 'pushups',
  title: '20 push-ups',
  description: 'Now.',
  verification: 'photoProof',
  durationType: 'deadlineCountdown',
  deadlineMinutes: 30,
  rewardTokens: 5,
  penaltyTokens: 3,
  ...over,
});

test('off unless switched on, and never on with nothing to order', () => {
  assert.equal(sanitizePublicOrders(undefined).enabled, false);
  assert.equal(sanitizePublicOrders({ enabled: true, orders: [] }).enabled, false);
  assert.equal(sanitizePublicOrders({ enabled: true, orders: [order()] }).enabled, true);
});

test('each order is checked: plain text, bounded numbers, known kinds', () => {
  const [o] = sanitizePublicOrders({
    enabled: true,
    orders: [order({ title: '  20 push-ups\u0000 ', rewardTokens: 1e9, penaltyTokens: -4, tier: 9, verification: 'telepathy' })],
  }).orders;
  assert.equal(o.title, '20 push-ups');
  assert.equal(o.rewardTokens, 10_000);
  assert.equal(o.penaltyTokens, 0);
  assert.equal(o.tier, 5);
  assert.equal(o.verification, 'honorCheck');
});

test('orders without an id or title, and repeats, are dropped; the list is capped', () => {
  const cfg = sanitizePublicOrders({
    enabled: true,
    orders: [order({ id: '' }), order({ title: '' }), order(), order(), ...Array.from({ length: 40 }, (_, i) => order({ id: `o${i}` }))],
  });
  assert.equal(cfg.orders[0].id, 'pushups');
  assert.equal(cfg.orders.filter((o) => o.id === 'pushups').length, 1);
  assert.equal(cfg.orders.length, 30);
});

test('the defaults: one order per visitor a day, two skips, proof to the director, no queue limit', () => {
  const cfg = sanitizePublicOrders({ enabled: true, orders: [order()] });
  assert.equal(cfg.perVisitorDaily, 1);
  assert.equal(cfg.skipsPerDay, 2);
  assert.equal(cfg.skipPauseMinutes, 30);
  assert.equal(cfg.proofTo, 'director');
  assert.equal(cfg.maxQueued, null);
  assert.equal(sanitizePublicOrders({ proofTo: 'issuer' }).proofTo, 'issuer');
  assert.equal(sanitizePublicOrders({ maxQueued: 0 }).maxQueued, 1);
});

test("each order runs on its own time limit; one with none still can't stall the queue", () => {
  const [timed] = sanitizePublicOrders({ orders: [order()] }).orders;
  assert.equal(orderLimitMs(timed), 32 * 60 * 1000, 'its 30 minutes, and a moment for the result to arrive');
  const [untimed] = sanitizePublicOrders({ orders: [order({ durationType: 'instant' })] }).orders;
  assert.equal(orderLimitMs(untimed), 24 * 60 * 60 * 1000 + 2 * 60 * 1000);
});

test("a sender's key must be a real public key", () => {
  const point = btoa(String.fromCharCode(4, ...new Array(64).fill(7)));
  assert.equal(validIssuerKey(point), point);
  assert.equal(validIssuerKey(btoa('short')), null);
  assert.equal(validIssuerKey(btoa(String.fromCharCode(2, ...new Array(64).fill(7)))), null, 'compressed points are not used');
  assert.equal(validIssuerKey(42), null);
});

test('proof is checked within twice the order\'s own time - an hour for orders with none', async () => {
  const { reviewWindowMs } = await import('../src/public_orders.ts');
  const [timed] = sanitizePublicOrders({ orders: [order()] }).orders;
  assert.equal(reviewWindowMs(timed), 60 * 60 * 1000, 'twice its 30 minutes');
  const [untimed] = sanitizePublicOrders({ orders: [order({ durationType: 'instant' })] }).orders;
  assert.equal(reviewWindowMs(untimed), 60 * 60 * 1000);
  const [quick] = sanitizePublicOrders({ orders: [order({ deadlineMinutes: 2 })] }).orders;
  assert.equal(reviewWindowMs(quick), 4 * 60 * 1000);
});

// The queue against a real SQLite database (Node's own), standing in for a
// timer's storage, with the clock in the test's hands.
test('proof nobody checks in time is approved; a decision before then stands', async () => {
  const { DatabaseSync } = await import('node:sqlite');
  const { OrderQueue, reviewWindowMs } = await import('../src/public_orders.ts');
  const db = new DatabaseSync(':memory:');
  const sql = {
    exec(query: string, ...args: unknown[]) {
      const stmt = db.prepare(query);
      const rows = /^\s*SELECT/i.test(query) ? stmt.all(...(args as any[])) : (stmt.run(...(args as any[])), []);
      return { toArray: () => rows, one: () => rows[0] };
    },
  } as unknown as SqlStorage;
  const q = new OrderQueue(sql);
  const [def] = sanitizePublicOrders({ orders: [order({ deadlineMinutes: 10 })] }).orders;
  const t0 = 1_000_000;

  const a = q.add(def, 'v1', null, 'h'.repeat(64), t0);
  q.advance(true, null, t0);
  assert.equal(q.submit(a, null, t0 + 60_000), true);
  const b = q.add(def, 'v2', null, 'x'.repeat(64), t0);
  assert.equal(q.advance(true, null, t0 + 60_000)?.no, b, 'the next is delivered while the first is checked');
  assert.equal(q.submit(b, null, t0 + 120_000), true);
  assert.equal(q.review(b, 'x'.repeat(64), false, t0 + 180_000), true, 'b rejected in time');

  const window = reviewWindowMs(def);
  assert.deepEqual(q.autoApprove(t0 + 60_000 + window - 1), [], 'not yet');
  assert.deepEqual(q.autoApprove(t0 + 60_000 + window + 1), [a]);
  const feed = q.feed();
  assert.equal(feed.find((f) => f.no === a)?.status, 'completed');
  assert.equal(feed.find((f) => f.no === a)?.auto, true);
  assert.equal(feed.find((f) => f.no === b)?.status, 'failed', 'a decision is never overruled');
  assert.equal(q.review(a, 'h'.repeat(64), false, t0 + 60_000 + window + 2), false, 'too late to reject');
});
