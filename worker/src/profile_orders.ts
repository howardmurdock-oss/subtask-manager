/**
 * Standalone orders for a player's public profile page (/p/<id>): visitors
 * can send orders from the approved list on the player's profile even when
 * no chastity timer is currently active.
 */
import {
  type PublicOrderDef,
  type PublicOrdersConfig,
  type OrderRow,
  type OrderStatus,
  type FeedEntry,
  orderLimitMs,
  reviewWindowMs,
  PROOF_TTL_MS,
} from './public_orders.ts';
import type { ProfileRow } from './profile.ts';

const DAY_MS = 24 * 60 * 60 * 1000;

export function profileOrderRow(r: any): OrderRow {
  return {
    no: r.no as number,
    def: JSON.parse(r.def as string) as PublicOrderDef,
    at: r.at as number,
    status: r.status as OrderStatus,
    deliveredAt: (r.delivered_at as number | null) ?? null,
    dueAt: (r.due_at as number | null) ?? null,
    doneAt: (r.done_at as number | null) ?? null,
    issuerKey: (r.issuer_key as string | null) ?? null,
    hasProof: r.proof != null,
    reviewDue: (r.review_due as number | null) ?? null,
  };
}

export async function advanceProfileOrders(
  db: D1Database,
  profileId: string,
  cfg: PublicOrdersConfig | null,
  pausedUntil: number | null,
  now: number,
): Promise<OrderRow | null> {
  // Expire overdue active orders
  await db
    .prepare(
      `UPDATE profile_public_orders SET status = 'expired', done_at = due_at
        WHERE profile_id = ? AND status = 'active' AND due_at < ?`,
    )
    .bind(profileId, now)
    .run();

  // Auto-approve unreviewed proofs
  await db
    .prepare(
      `UPDATE profile_public_orders SET status = 'completed', auto = 1, done_at = review_due, review_due = NULL
        WHERE profile_id = ? AND status = 'reviewing' AND review_due < ?`,
    )
    .bind(profileId, now)
    .run();

  if (!cfg?.enabled) {
    await db
      .prepare(`UPDATE profile_public_orders SET status = 'cancelled', done_at = ? WHERE profile_id = ? AND status = 'queued'`)
      .bind(now, profileId)
      .run();
    return null;
  }

  // If currently active, return active order
  const active = await db
    .prepare(`SELECT * FROM profile_public_orders WHERE profile_id = ? AND status = 'active' LIMIT 1`)
    .bind(profileId)
    .first();
  if (active) return profileOrderRow(active);

  // If paused, don't advance next queued order
  if (pausedUntil != null && pausedUntil > now) return null;

  // Fetch next queued order
  const next = await db
    .prepare(`SELECT * FROM profile_public_orders WHERE profile_id = ? AND status = 'queued' ORDER BY no ASC LIMIT 1`)
    .bind(profileId)
    .first();
  if (!next) return null;

  const def = JSON.parse(next.def as string) as PublicOrderDef;
  const dueAt = now + orderLimitMs(def);
  await db
    .prepare(
      `UPDATE profile_public_orders SET status = 'active', delivered_at = ?, due_at = ? WHERE profile_id = ? AND no = ?`,
    )
    .bind(now, dueAt, profileId, next.no)
    .run();

  const updated = await db
    .prepare(`SELECT * FROM profile_public_orders WHERE profile_id = ? AND no = ?`)
    .bind(profileId, next.no)
    .first();
  return updated ? profileOrderRow(updated) : null;
}

export async function addProfileOrder(
  db: D1Database,
  profileId: string,
  def: PublicOrderDef,
  visitor: string,
  issuerKey: string | null,
  receiptHash: string,
  now: number,
  issuerTopic: string | null = null,
): Promise<number> {
  const maxRow = await db
    .prepare(`SELECT COALESCE(MAX(no), 0) AS max_no FROM profile_public_orders WHERE profile_id = ?`)
    .bind(profileId)
    .first<{ max_no: number }>();
  const no = (maxRow?.max_no ?? 0) + 1;

  await db
    .prepare(
      `INSERT INTO profile_public_orders (profile_id, no, def, at, visitor, status, issuer_key, receipt_hash, issuer_topic)
       VALUES (?, ?, ?, ?, ?, 'queued', ?, ?, ?)`,
    )
    .bind(profileId, no, JSON.stringify(def), now, visitor, issuerKey, receiptHash, issuerTopic)
    .run();

  return no;
}

export async function profileOpenOrderCount(db: D1Database, profileId: string): Promise<number> {
  const row = await db
    .prepare(`SELECT COUNT(*) AS n FROM profile_public_orders WHERE profile_id = ? AND status IN ('queued', 'active')`)
    .bind(profileId)
    .first<{ n: number }>();
  return row?.n ?? 0;
}

export async function profileQueuedOrderCount(db: D1Database, profileId: string): Promise<number> {
  const row = await db
    .prepare(`SELECT COUNT(*) AS n FROM profile_public_orders WHERE profile_id = ? AND status = 'queued'`)
    .bind(profileId)
    .first<{ n: number }>();
  return row?.n ?? 0;
}

export async function profileSentOrdersToday(
  db: D1Database,
  profileId: string,
  visitor: string,
  now: number,
): Promise<number> {
  const row = await db
    .prepare(`SELECT COUNT(*) AS n FROM profile_public_orders WHERE profile_id = ? AND visitor = ? AND at >= ?`)
    .bind(profileId, visitor, now - DAY_MS)
    .first<{ n: number }>();
  return row?.n ?? 0;
}

export async function profileOrderFeed(db: D1Database, profileId: string, limit = 20): Promise<FeedEntry[]> {
  const { results } = await db
    .prepare(
      `SELECT no, def, at, status, done_at, review_due, auto, proof IS NOT NULL AS has_proof
         FROM profile_public_orders WHERE profile_id = ? ORDER BY no DESC LIMIT ?`,
    )
    .bind(profileId, limit)
    .all<{
      no: number;
      def: string;
      at: number;
      status: OrderStatus;
      done_at: number | null;
      review_due: number | null;
      auto: number | null;
      has_proof: number;
    }>();

  return (results ?? []).map((r) => ({
    no: r.no,
    title: (JSON.parse(r.def) as PublicOrderDef).title,
    status: r.status,
    at: r.at,
    doneAt: r.done_at,
    hasProof: Boolean(r.has_proof),
    reviewDue: r.review_due,
    auto: Boolean(r.auto),
  }));
}

export function profileSkipsLeft(row: ProfileRow, cfg: PublicOrdersConfig, now: number): number {
  const today = new Date(now).toISOString().slice(0, 10);
  if (row.skips_day !== today) return cfg.skipsPerDay;
  return Math.max(0, row.skips_left ?? cfg.skipsPerDay);
}

export async function skipProfileOrder(
  db: D1Database,
  row: ProfileRow,
  cfg: PublicOrdersConfig,
  no: number,
  now: number,
): Promise<boolean> {
  const active = await db
    .prepare(`SELECT * FROM profile_public_orders WHERE profile_id = ? AND no = ? AND status = 'active'`)
    .bind(row.id, no)
    .first();
  if (!active) return false;

  const skipsLeft = profileSkipsLeft(row, cfg, now);
  if (skipsLeft <= 0) return false;

  const today = new Date(now).toISOString().slice(0, 10);
  const remaining = skipsLeft - 1;
  const pausedUntil = now + (cfg.skipPauseMinutes ?? 30) * 60 * 1000;

  await db
    .prepare(`UPDATE profile_public_orders SET status = 'skipped', done_at = ? WHERE profile_id = ? AND no = ?`)
    .bind(now, row.id, no)
    .run();

  await db
    .prepare(`UPDATE profiles SET skips_left = ?, skips_day = ?, paused_until = ? WHERE id = ?`)
    .bind(remaining, today, pausedUntil, row.id)
    .run();

  return true;
}

export async function submitProfileOrder(
  db: D1Database,
  profileId: string,
  no: number,
  proof: string | null,
  now: number,
): Promise<boolean> {
  const active = await db
    .prepare(`SELECT * FROM profile_public_orders WHERE profile_id = ? AND no = ? AND status = 'active'`)
    .bind(profileId, no)
    .first();
  if (!active) return false;

  const def = JSON.parse(active.def as string) as PublicOrderDef;
  const reviewDue = now + reviewWindowMs(def);
  const proofExpires = proof ? Math.max(reviewDue, now + PROOF_TTL_MS) : null;

  await db
    .prepare(
      `UPDATE profile_public_orders SET status = 'reviewing', review_due = ?, proof = ?, proof_expires = ?
        WHERE profile_id = ? AND no = ?`,
    )
    .bind(reviewDue, proof, proofExpires, profileId, no)
    .run();

  return true;
}

export async function finishProfileOrder(
  db: D1Database,
  profileId: string,
  no: number,
  result: 'completed' | 'failed',
  proof: string | null,
  now: number,
): Promise<boolean> {
  const row = await db
    .prepare(`SELECT * FROM profile_public_orders WHERE profile_id = ? AND no = ? AND status IN ('active', 'reviewing')`)
    .bind(profileId, no)
    .first<{ proof_expires: number | null }>();
  if (!row) return false;

  const proofExpires = proof ? Math.max(row.proof_expires ?? 0, now + PROOF_TTL_MS) : row.proof_expires;
  await db
    .prepare(
      `UPDATE profile_public_orders SET status = ?, done_at = ?, review_due = NULL,
         proof = COALESCE(?, proof),
         proof_expires = ?
       WHERE profile_id = ? AND no = ?`,
    )
    .bind(result, now, proof, proofExpires, profileId, no)
    .run();

  return true;
}

export async function reviewProfileOrder(
  db: D1Database,
  profileId: string,
  no: number,
  receiptHash: string,
  approve: boolean,
  now: number,
): Promise<boolean> {
  const row = await db
    .prepare(`SELECT status, receipt_hash FROM profile_public_orders WHERE profile_id = ? AND no = ?`)
    .bind(profileId, no)
    .first<{ status: string; receipt_hash: string }>();
  if (!row || row.status !== 'reviewing' || row.receipt_hash !== receiptHash) return false;

  await db
    .prepare(`UPDATE profile_public_orders SET status = ?, done_at = ?, review_due = NULL WHERE profile_id = ? AND no = ?`)
    .bind(approve ? 'completed' : 'failed', now, profileId, no)
    .run();

  return true;
}

export async function profileOrderProof(
  db: D1Database,
  profileId: string,
  no: number,
  receiptHash: string,
  now: number,
): Promise<string | null> {
  const row = await db
    .prepare(`SELECT proof, proof_expires, receipt_hash FROM profile_public_orders WHERE profile_id = ? AND no = ?`)
    .bind(profileId, no)
    .first<{ proof: string | null; proof_expires: number | null; receipt_hash: string }>();
  if (!row || row.receipt_hash !== receiptHash || row.proof == null || (row.proof_expires ?? 0) < now) return null;
  return row.proof;
}

export async function purgeProfileProofs(db: D1Database, now: number): Promise<void> {
  await db
    .prepare(`UPDATE profile_public_orders SET proof = NULL, proof_expires = NULL WHERE proof_expires < ?`)
    .bind(now)
    .run();
}

export async function profileOrdersPublic(
  db: D1Database,
  profileId: string,
  cfg: PublicOrdersConfig,
  pausedUntil: number | null,
  now: number,
  visitor?: unknown,
) {
  if (!cfg?.enabled) return { enabled: false };
  const open = await profileOpenOrderCount(db, profileId);
  const queued = await profileQueuedOrderCount(db, profileId);
  const paused = (pausedUntil ?? 0) > now;
  const full = cfg.maxQueued != null && open >= cfg.maxQueued;
  const feed = await profileOrderFeed(db, profileId);

  const base = {
    enabled: true,
    accepting: !paused && !full,
    reason: paused ? 'paused' : full ? 'full' : null,
    pausedUntil: paused ? pausedUntil : null,
    proofTo: cfg.proofTo,
    perVisitorDaily: cfg.perVisitorDaily,
    list: cfg.orders,
    waiting: queued,
    feed,
  };

  if (typeof visitor !== 'string' || !visitor) return base;
  const sent = await profileSentOrdersToday(db, profileId, visitor, now);
  return {
    ...base,
    you: {
      ordersLeft: Math.max(0, cfg.perVisitorDaily - sent),
    },
  };
}

export async function profileOrdersPrivate(
  db: D1Database,
  row: ProfileRow,
  cfg: PublicOrdersConfig,
  now: number,
) {
  if (!cfg?.enabled) return { enabled: false };
  const activeRow = await db
    .prepare(`SELECT * FROM profile_public_orders WHERE profile_id = ? AND status = 'active' LIMIT 1`)
    .bind(row.id)
    .first();
  const active = activeRow ? profileOrderRow(activeRow) : null;
  const queued = await profileQueuedOrderCount(db, row.id);
  const skipsLeft = profileSkipsLeft(row, cfg, now);
  const pausedUntil = (row.paused_until ?? 0) > now ? row.paused_until : null;
  const feed = await profileOrderFeed(db, row.id);

  return {
    enabled: true,
    proofTo: cfg.proofTo,
    active,
    waiting: queued,
    skipsLeft,
    pausedUntil,
    feed,
  };
}
