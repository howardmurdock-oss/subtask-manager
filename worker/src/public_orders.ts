/**
 * Orders sent from a timer's public page: visitors pick from a list the
 * timer's manager approved - never free text - and the player carries them
 * out in the app, one at a time, in the order they arrived.
 *
 * Proof photos go to the director over the partners' channel (nothing here),
 * or, if the timer is set up that way, back to whoever sent the order: their
 * browser makes a key pair, sends the public half with the order, and the
 * player's app encrypts the photo to it. What is kept here is ciphertext only,
 * readable by that one browser, and deleted after a day.
 */

export type DurationType = 'instant' | 'actionTimer' | 'deadlineCountdown' | 'actionWithDeadline' | 'dailyWindow';
export type Verification = 'honorCheck' | 'noteProof' | 'photoProof' | 'timerOnly';

/** One order on the approved list. Public: the page shows it. */
export interface PublicOrderDef {
  id: string;
  title: string;
  description: string;
  category: string;
  tier: number;
  durationType: DurationType;
  actionSeconds: number;
  deadlineMinutes: number;
  verification: Verification;
  rewardTokens: number;
  penaltyTokens: number;
}

export interface PublicOrdersConfig {
  enabled: boolean;
  orders: PublicOrderDef[];
  /** Orders waiting or in progress at once; null for no limit. */
  maxQueued: number | null;
  /** Orders one visitor may send a day. */
  perVisitorDaily: number;
  /** Where proof photos go. */
  proofTo: 'director' | 'issuer';
  /** Skips the player has a day; each pauses deliveries a while. */
  skipsPerDay: number;
  skipPauseMinutes: number;
}

export const ORDERS_MAX = 30;
const DAY_MS = 24 * 60 * 60 * 1000;

/** Proof kept for the issuer this long, then deleted. */
export const PROOF_TTL_MS = DAY_MS;

/** Longest proof accepted: a compressed photo, encrypted and encoded. */
export const PROOF_MAX_CHARS = 900_000;

/** Slack on a deadline, for a result on its way when it passes. */
const DUE_GRACE_MS = 2 * 60 * 1000;

const DURATIONS: DurationType[] = ['instant', 'actionTimer', 'deadlineCountdown', 'actionWithDeadline', 'dailyWindow'];
const VERIFICATIONS: Verification[] = ['honorCheck', 'noteProof', 'photoProof', 'timerOnly'];

const int = (v: unknown, min: number, max: number, fallback: number): number => {
  const n = typeof v === 'number' && Number.isFinite(v) ? Math.round(v) : fallback;
  return Math.min(Math.max(n, min), max);
};

const text = (v: unknown, max: number): string =>
  typeof v === 'string'
    ? v.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]+/g, '').trim().slice(0, max).trim()
    : '';

function sanitizeOrder(raw: any): PublicOrderDef | null {
  const id = typeof raw?.id === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(raw.id) ? raw.id : null;
  const title = text(raw?.title, 80);
  if (!id || !title) return null;
  return {
    id,
    title,
    description: text(raw.description, 600),
    category: text(raw.category, 40) || 'General',
    tier: int(raw.tier, 1, 5, 1),
    durationType: DURATIONS.includes(raw.durationType) ? raw.durationType : 'instant',
    actionSeconds: int(raw.actionSeconds, 0, 24 * 3600, 0),
    deadlineMinutes: int(raw.deadlineMinutes, 0, 7 * 24 * 60, 0),
    verification: VERIFICATIONS.includes(raw.verification) ? raw.verification : 'honorCheck',
    rewardTokens: int(raw.rewardTokens, 0, 10_000, 0),
    penaltyTokens: int(raw.penaltyTokens, 0, 10_000, 0),
  };
}

export function sanitizePublicOrders(raw: any): PublicOrdersConfig {
  const seen = new Set<string>();
  const orders: PublicOrderDef[] = [];
  for (const o of Array.isArray(raw?.orders) ? raw.orders : []) {
    const def = sanitizeOrder(o);
    if (!def || seen.has(def.id)) continue;
    seen.add(def.id);
    orders.push(def);
    if (orders.length >= ORDERS_MAX) break;
  }
  return {
    enabled: raw?.enabled === true && orders.length > 0,
    orders,
    maxQueued: raw?.maxQueued == null ? null : int(raw.maxQueued, 1, 1000, 1),
    perVisitorDaily: int(raw?.perVisitorDaily, 1, 20, 1),
    proofTo: raw?.proofTo === 'issuer' ? 'issuer' : 'director',
    skipsPerDay: int(raw?.skipsPerDay, 0, 20, 2),
    skipPauseMinutes: int(raw?.skipPauseMinutes, 5, 24 * 60, 30),
  };
}

/** How long the player has, from delivery: the order's own deadline, or a
 * day for orders with none, so the queue never stalls for good. */
export function orderLimitMs(def: PublicOrderDef): number {
  if ((def.durationType === 'deadlineCountdown' || def.durationType === 'actionWithDeadline') && def.deadlineMinutes > 0) {
    return def.deadlineMinutes * 60 * 1000 + DUE_GRACE_MS;
  }
  return DAY_MS + DUE_GRACE_MS;
}

/** A browser's public key for proof: an uncompressed P-256 point, base64. */
export function validIssuerKey(v: unknown): string | null {
  if (typeof v !== 'string' || v.length > 120) return null;
  try {
    const raw = atob(v.replace(/-/g, '+').replace(/_/g, '/'));
    return raw.length === 65 && raw.charCodeAt(0) === 4 ? v : null;
  } catch {
    return null;
  }
}

export type OrderStatus = 'queued' | 'active' | 'completed' | 'failed' | 'expired' | 'skipped' | 'cancelled';

export interface OrderRow {
  no: number;
  def: PublicOrderDef;
  at: number;
  status: OrderStatus;
  deliveredAt: number | null;
  dueAt: number | null;
  doneAt: number | null;
  issuerKey: string | null;
  hasProof: boolean;
}

/** One line of the page's feed: what was ordered, and how it went. */
export interface FeedEntry {
  no: number;
  title: string;
  status: OrderStatus;
  at: number;
  doneAt: number | null;
  hasProof: boolean;
}

/** The queue, in a timer's own storage. */
export class OrderQueue {
  private readonly sql: SqlStorage;

  constructor(sql: SqlStorage) {
    this.sql = sql;
    sql.exec(
      `CREATE TABLE IF NOT EXISTS public_orders (
         no INTEGER PRIMARY KEY AUTOINCREMENT,
         def TEXT NOT NULL,
         at INTEGER NOT NULL,
         visitor TEXT,
         status TEXT NOT NULL,
         delivered_at INTEGER,
         due_at INTEGER,
         done_at INTEGER,
         issuer_key TEXT,
         receipt_hash TEXT,
         proof TEXT,
         proof_expires INTEGER)`,
    );
  }

  private row(r: Record<string, SqlStorageValue>): OrderRow {
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
    };
  }

  /** Waiting or in progress. */
  openCount(): number {
    return this.sql.exec(`SELECT COUNT(*) AS n FROM public_orders WHERE status IN ('queued', 'active')`).one().n as number;
  }

  queuedCount(): number {
    return this.sql.exec(`SELECT COUNT(*) AS n FROM public_orders WHERE status = 'queued'`).one().n as number;
  }

  sentToday(visitor: string, now: number): number {
    return this.sql
      .exec(`SELECT COUNT(*) AS n FROM public_orders WHERE visitor = ? AND at >= ?`, visitor, now - DAY_MS)
      .one().n as number;
  }

  add(def: PublicOrderDef, visitor: string, issuerKey: string | null, receiptHash: string, now: number): number {
    this.sql.exec(
      `INSERT INTO public_orders (def, at, visitor, status, issuer_key, receipt_hash) VALUES (?, ?, ?, 'queued', ?, ?)`,
      JSON.stringify(def), now, visitor, issuerKey, receiptHash,
    );
    return this.sql.exec(`SELECT last_insert_rowid() AS no`).one().no as number;
  }

  active(): OrderRow | null {
    const r = this.sql.exec(`SELECT * FROM public_orders WHERE status = 'active' LIMIT 1`).toArray()[0];
    return r ? this.row(r) : null;
  }

  /**
   * Moves the queue on: an active order past its time has expired; a timer
   * that is over takes no more; otherwise, with nothing in progress and no
   * pause, the oldest waiting order is delivered. Returns that one, if any.
   */
  advance(running: boolean, pausedUntil: number | null, now: number): OrderRow | null {
    this.sql.exec(
      `UPDATE public_orders SET status = 'expired', done_at = due_at WHERE status = 'active' AND due_at < ?`,
      now,
    );
    if (!running) {
      this.sql.exec(`UPDATE public_orders SET status = 'cancelled', done_at = ? WHERE status = 'queued'`, now);
      return null;
    }
    if (this.active() || (pausedUntil != null && pausedUntil > now)) return null;
    const next = this.sql.exec(`SELECT * FROM public_orders WHERE status = 'queued' ORDER BY no LIMIT 1`).toArray()[0];
    if (!next) return null;
    const def = JSON.parse(next.def as string) as PublicOrderDef;
    this.sql.exec(
      `UPDATE public_orders SET status = 'active', delivered_at = ?, due_at = ? WHERE no = ?`,
      now, now + orderLimitMs(def), next.no,
    );
    return this.active();
  }

  /** The player's result for the active order. */
  finish(no: number, result: 'completed' | 'failed', proof: string | null, now: number): boolean {
    const active = this.active();
    if (!active || active.no !== no) return false;
    this.sql.exec(
      `UPDATE public_orders SET status = ?, done_at = ?, proof = ?, proof_expires = ? WHERE no = ?`,
      result, now, proof, proof ? now + PROOF_TTL_MS : null, no,
    );
    return true;
  }

  skip(no: number, now: number): boolean {
    const active = this.active();
    if (!active || active.no !== no) return false;
    this.sql.exec(`UPDATE public_orders SET status = 'skipped', done_at = ? WHERE no = ?`, now, no);
    return true;
  }

  feed(limit = 20): FeedEntry[] {
    return this.sql
      .exec(`SELECT no, def, at, status, done_at, proof IS NOT NULL AS has_proof FROM public_orders ORDER BY no DESC LIMIT ?`, limit)
      .toArray()
      .map((r) => ({
        no: r.no as number,
        title: (JSON.parse(r.def as string) as PublicOrderDef).title,
        status: r.status as OrderStatus,
        at: r.at as number,
        doneAt: (r.done_at as number | null) ?? null,
        hasProof: Boolean(r.has_proof),
      }));
  }

  /** The proof for [no], for whoever holds its receipt. */
  proofFor(no: number, receiptHash: string, now: number): string | null {
    const r = this.sql
      .exec(`SELECT proof, proof_expires, receipt_hash FROM public_orders WHERE no = ?`, no)
      .toArray()[0];
    if (!r || r.receipt_hash !== receiptHash || r.proof == null || (r.proof_expires as number) < now) return null;
    return r.proof as string;
  }

  /** Proof past its day is deleted, not just hidden. */
  purgeProofs(now: number): void {
    this.sql.exec(`UPDATE public_orders SET proof = NULL, proof_expires = NULL WHERE proof_expires < ?`, now);
  }

  /** When the queue next needs looking at: an active order's deadline, or
   * proof due for deletion. */
  nextWake(): number {
    const due = this.sql.exec(`SELECT MIN(due_at) AS t FROM public_orders WHERE status = 'active'`).one().t as number | null;
    const proof = this.sql.exec(`SELECT MIN(proof_expires) AS t FROM public_orders WHERE proof_expires IS NOT NULL`).one()
      .t as number | null;
    return Math.min(due ?? Infinity, proof ?? Infinity);
  }
}
