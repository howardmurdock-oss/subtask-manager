/**
 * One Durable Object per chastity timer: the single place its state lives.
 *
 * Every change - from the director, the player, the random schedule or a
 * stranger on the public link - goes through here, one at a time, so two
 * arriving together cannot overwrite each other and every cap is checked
 * against everything already applied. The rules themselves are in
 * timer_logic.ts.
 *
 * Access is by key. Creating a timer returns a player key and a director key;
 * the creator hands the other party theirs over the partners' end-to-end
 * encrypted channel, so this Worker only ever stores hashes of them. The
 * public link uses a separate id that can be switched off or replaced without
 * touching the timer. Timer numbers are not end-to-end encrypted: the server
 * has to see them to enforce caps and to hold the combination until the end.
 */

import { OrderQueue, PROOF_MAX_CHARS, validIssuerKey } from './public_orders.ts';
import { deliverToTopic, type Env } from './index.ts';
import {
  refuse,
  resolve,
  sanitizeConfig,
  viewFor,
  type TimerConfig,
  type TimerEvent,
  type TimerState,
  type Viewer,
} from './timer_logic.ts';

/** How long a finished timer's record is kept before it is deleted. */
const RETAIN_AFTER_CLOSE_MS = 30 * 24 * 60 * 60 * 1000;

/** At most one announcement of public additions a minute, per timer. */
const NOTICE_GAP_MS = 60 * 1000;

/** Past this many stored changes a timer takes no more. Public votes are
 * capped per day, so only a director with no cap could get near it. */
const MAX_EVENTS = 20000;

/** New public links a timer may get in a day. Plenty for changing your mind. */
export const LINK_CHANGES_PER_DAY = 10;

/** Counts a new link against today's allowance; false once it is used up. */
export function countLinkChange(meta: { linkChanges?: { day: number; count: number } }, now: number): boolean {
  const day = Math.floor(now / 86_400_000);
  const used = meta.linkChanges?.day === day ? meta.linkChanges.count : 0;
  if (used >= LINK_CHANGES_PER_DAY) return false;
  meta.linkChanges = { day, count: used + 1 };
  return true;
}

interface Meta {
  id: string;
  startAt: number;
  config: TimerConfig;
  playerKeyHash: string;
  directorKeyHash: string;
  publicId: string | null;
  releasedAt: number | null;
  releasedBy: 'player' | 'director' | null;
  /** When each side first used its key. A partner whose key was never used
   * may have never received it: their key can then be issued again. */
  playerSeenAt?: number | null;
  directorSeenAt?: number | null;
  /** Set on timers created since first use was recorded. On older ones a
   * missing playerSeenAt proves nothing - the player may have connected
   * before it was tracked. */
  seenTracked?: boolean;
  /** New public links made today: switching the link on, or replacing it.
   * Capped so it can't be done endlessly; removing a link never counts. */
  linkChanges?: { day: number; count: number };
  /** Where the player's device listens: told by the player's app, so public
   * additions can be announced. A wake-up only - the app fetches what
   * happened with its own key, so a forged one announces nothing. */
  playerTopic?: string | null;
  /** Public additions not yet announced, and when the last announcement
   * went out: at most one a minute, however busy the link. */
  publicNotice?: { pending: number; lastAt: number };
  /** Skips of public orders used today (UTC day number). */
  orderSkips?: { day: number; used: number };
  /** No public orders are taken or delivered until then: after a skip. */
  ordersPausedUntil?: number | null;
  /** Apps watching this timer from its public page, told when it ends. */
  watchers?: string[];
  /** Whether they have been told. */
  watchersTold?: boolean;
}

export async function sha256Hex(text: string): Promise<string> {
  const bytes = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)));
  return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export function randomToken(bytes = 24): string {
  const raw = crypto.getRandomValues(new Uint8Array(bytes));
  return btoa(String.fromCharCode(...raw)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function reply(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  });
}

export class ChastityTimer {
  private readonly sql: SqlStorage;
  private readonly orders: OrderQueue;

  constructor(private readonly ctx: DurableObjectState, private readonly env: Env) {
    this.sql = ctx.storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS meta (k INTEGER PRIMARY KEY CHECK (k = 1), json TEXT NOT NULL)`);
    this.sql.exec(
      `CREATE TABLE IF NOT EXISTS events (
         id TEXT PRIMARY KEY,
         at INTEGER NOT NULL,
         actor TEXT NOT NULL,
         delta INTEGER NOT NULL,
         visitor TEXT)`,
    );
    this.orders = new OrderQueue(this.sql);
  }

  private running(meta: Meta, now: number): boolean {
    return resolve(this.state(meta), now).status === 'running';
  }

  /** Moves public orders on, and wakes the player for one now delivered. */
  private async advanceOrders(meta: Meta, now: number): Promise<void> {
    // Proof nobody checked in time is approved, and the player told.
    for (const no of this.orders.autoApprove(now)) {
      await this.announce(meta, 'review', no);
      await this.tellIssuer(meta, no);
    }
    const delivered = this.orders.advance(this.running(meta, now), meta.ordersPausedUntil ?? null, now);
    if (delivered) await this.announce(meta, 'order');
  }

  private skipsLeft(meta: Meta, now: number): number {
    const day = Math.floor(now / 86_400_000);
    const used = meta.orderSkips?.day === day ? meta.orderSkips.used : 0;
    return Math.max(0, (meta.config.publicOrders?.skipsPerDay ?? 0) - used);
  }

  /** What the page shows of public orders: the list, whether it is taking
   * them, and how each has gone - never who sent one, or any proof. */
  private ordersPublic(meta: Meta, now: number) {
    const cfg = meta.config.publicOrders;
    if (!cfg?.enabled || !meta.config.public.enabled) return { enabled: false };
    const paused = (meta.ordersPausedUntil ?? 0) > now;
    const full = cfg.maxQueued != null && this.orders.openCount() >= cfg.maxQueued;
    const running = this.running(meta, now);
    return {
      enabled: true,
      accepting: running && !paused && !full,
      reason: !running ? 'not-running' : paused ? 'paused' : full ? 'full' : null,
      pausedUntil: paused ? meta.ordersPausedUntil : null,
      proofTo: cfg.proofTo,
      perVisitorDaily: cfg.perVisitorDaily,
      list: cfg.orders,
      waiting: this.orders.queuedCount(),
      feed: this.orders.feed(),
    };
  }

  /** What either side's app sees: the order in progress (with the key to
   * encrypt its proof to), how many wait, and skips left. */
  private ordersPrivate(meta: Meta, now: number) {
    const cfg = meta.config.publicOrders;
    if (!cfg?.enabled) return { enabled: false };
    return {
      enabled: true,
      proofTo: cfg.proofTo,
      active: this.orders.active(),
      waiting: this.orders.queuedCount(),
      skipsLeft: this.skipsLeft(meta, now),
      pausedUntil: (meta.ordersPausedUntil ?? 0) > now ? meta.ordersPausedUntil : null,
      feed: this.orders.feed(),
    };
  }

  private publicView(meta: Meta, now: number) {
    return { ...viewFor(this.state(meta), 'public', now), orders: this.ordersPublic(meta, now) };
  }

  private meta(): Meta | null {
    const row = this.sql.exec(`SELECT json FROM meta WHERE k = 1`).toArray()[0];
    return row ? (JSON.parse(row.json as string) as Meta) : null;
  }

  private saveMeta(meta: Meta): void {
    this.sql.exec(`INSERT OR REPLACE INTO meta (k, json) VALUES (1, ?)`, JSON.stringify(meta));
  }

  private state(meta: Meta): TimerState {
    const events = this.sql
      .exec(`SELECT id, at, actor, delta, visitor FROM events`)
      .toArray()
      .map((r) => ({
        id: r.id as string,
        at: r.at as number,
        actor: r.actor as TimerEvent['actor'],
        delta: r.delta as number,
        ...(r.visitor ? { visitor: r.visitor as string } : {}),
      }));
    return {
      id: meta.id,
      startAt: meta.startAt,
      config: meta.config,
      events,
      releasedAt: meta.releasedAt,
      releasedBy: meta.releasedBy,
    };
  }

  /** Which party [key] belongs to, or null. */
  private async roleOf(meta: Meta, key: string | null): Promise<'player' | 'director' | null> {
    if (!key) return null;
    const hash = await sha256Hex(key);
    if (hash === meta.playerKeyHash) return 'player';
    if (hash === meta.directorKeyHash) return 'director';
    return null;
  }

  /** Once the timer is over, schedules its record's deletion. */
  private async scheduleCleanup(meta: Meta): Promise<void> {
    const { status, endAt } = resolve(this.state(meta), Date.now());
    const closedAt = status === 'released' ? meta.releasedAt! : endAt;
    // Re-armed on every change: the end moves, and a running timer's alarm
    // sits past its current end. With no end time there is nothing to sit
    // past: it is checked again later, and re-armed while still running.
    const from = Number.isFinite(closedAt) ? Math.max(closedAt, Date.now()) : Date.now();
    // An announcement held back is sent when its minute is up.
    const notice = meta.publicNotice?.pending ? meta.publicNotice.lastAt + NOTICE_GAP_MS : Infinity;
    // Public orders: a deadline, proof due for deletion, or a pause ending
    // with orders waiting.
    const pause = meta.ordersPausedUntil && this.orders.queuedCount() > 0 ? meta.ordersPausedUntil : Infinity;
    const orders = Math.min(this.orders.nextWake(), pause);
    // Watchers are told when it ends: woken then, if it has an end.
    const watched = meta.watchers?.length && !meta.watchersTold && status === 'running' && Number.isFinite(endAt) ? endAt : Infinity;
    await this.ctx.storage.setAlarm(
      Math.min(
        from + RETAIN_AFTER_CLOSE_MS,
        Math.max(notice, Date.now()),
        Math.max(orders, Date.now()),
        Math.max(watched, Date.now()),
      ),
    );
  }

  /** Public time added: announced to the player now, or held for the rest
   * of the minute and sent with whatever else comes in. */
  private async notePublicAdd(meta: Meta, seconds: number, now: number): Promise<void> {
    if (!meta.config.notify?.onAdd || !meta.playerTopic) return;
    const last = meta.publicNotice?.lastAt ?? 0;
    const pending = (meta.publicNotice?.pending ?? 0) + seconds;
    if (now - last >= NOTICE_GAP_MS) {
      meta.publicNotice = { pending: 0, lastAt: now };
      this.saveMeta(meta);
      await this.announce(meta);
    } else {
      meta.publicNotice = { pending, lastAt: last };
      this.saveMeta(meta);
    }
  }

  /** Wakes the player's app to look at the timer. It carries nothing but the
   * timer's id: what was added, and by whom, the app fetches itself. */
  /** Tells an app that sent an order or watches this timer - it has no key,
   * so the message names the public link, for it to look itself. */
  private async tellApp(meta: Meta, topic: string, check: 'issued' | 'ended', no?: number): Promise<void> {
    if (!meta.publicId) return;
    const message = {
      id: `timer-${crypto.randomUUID()}`,
      type: 'timerChanged',
      senderId: 'timer-service',
      timestamp: new Date().toISOString(),
      payload: { publicId: meta.publicId, check, ...(no != null ? { no } : {}) },
    };
    try {
      await deliverToTopic(this.env, topic, JSON.stringify(message));
    } catch {
      // Best effort.
    }
  }

  private async tellIssuer(meta: Meta, no: number): Promise<void> {
    const topic = this.orders.issuerTopicOf(no);
    if (topic) await this.tellApp(meta, topic, 'issued', no);
  }

  /** Once it is over, its watchers are told - once. */
  private async tellWatchers(meta: Meta, now: number): Promise<void> {
    if (!meta.watchers?.length || meta.watchersTold || this.running(meta, now)) return;
    meta.watchersTold = true;
    this.saveMeta(meta);
    for (const topic of meta.watchers) await this.tellApp(meta, topic, 'ended');
  }

  private async announce(meta: Meta, check: 'public' | 'order' | 'review' = 'public', no?: number): Promise<void> {
    if (!meta.playerTopic) return;
    const message = {
      id: `timer-${crypto.randomUUID()}`,
      type: 'timerChanged',
      senderId: 'timer-service',
      timestamp: new Date().toISOString(),
      payload: { timerId: meta.id, check, ...(no != null ? { no } : {}) },
    };
    try {
      await deliverToTopic(this.env, meta.playerTopic, JSON.stringify(message));
    } catch {
      // Best effort: the change itself has happened either way.
    }
  }

  async alarm(): Promise<void> {
    const meta = this.meta();
    if (!meta) return;
    if (meta.publicNotice?.pending && Date.now() >= meta.publicNotice.lastAt + NOTICE_GAP_MS) {
      meta.publicNotice = { pending: 0, lastAt: Date.now() };
      this.saveMeta(meta);
      if (meta.config.notify?.onAdd) await this.announce(meta);
    }
    this.orders.purgeProofs(Date.now());
    await this.advanceOrders(meta, Date.now());
    await this.tellWatchers(meta, Date.now());
    const { status, endAt } = resolve(this.state(meta), Date.now());
    const closedAt = status === 'released' ? meta.releasedAt! : endAt;
    if (status === 'running' || Date.now() < closedAt + RETAIN_AFTER_CLOSE_MS) {
      await this.scheduleCleanup(meta);
      return;
    }
    // The public link goes with it: its row in timer_links would otherwise
    // be left behind for every timer ever made.
    try {
      await this.env.DB.prepare('DELETE FROM timer_links WHERE timer_id = ?').bind(meta.id).run();
    } catch {
      // The table may not exist yet; nothing to remove then.
    }
    await this.ctx.storage.deleteAll();
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const op = url.pathname.split('/').pop();
    const body: any = request.method === 'POST' ? await request.json().catch(() => ({})) : {};
    const now = Date.now();

    if (op === 'create') {
      if (this.meta()) return reply({ error: 'exists' }, 409);
      const meta: Meta = {
        id: body.id,
        startAt: now,
        config: sanitizeConfig(body.config, body.managedBy === 'player' ? 'player' : 'director'),
        playerKeyHash: body.playerKeyHash,
        directorKeyHash: body.directorKeyHash,
        publicId: body.publicId ?? null,
        releasedAt: null,
        releasedBy: null,
        seenTracked: true,
      };
      if (!meta.config.public.enabled) meta.publicId = null;
      this.saveMeta(meta);
      await this.scheduleCleanup(meta);
      return reply({ ok: true, publicId: meta.publicId });
    }

    const meta = this.meta();
    if (!meta) return reply({ error: 'no such timer' }, 404);

    // The public side: no key, a narrower view, one step per vote.
    if (op === 'public-view') {
      if (!meta.publicId || meta.publicId !== body.publicId) return reply({ error: 'no such timer' }, 404);
      await this.advanceOrders(meta, now);
      return reply(this.publicView(meta, now));
    }
    // For a player's profile page (never routed from outside): the public
    // view, only if this timer may be shown there - its link is on, and a
    // director's timer only if the director gave the player the link.
    if (op === 'profile-view') {
      if (!meta.publicId || meta.publicId !== body.publicId) return reply({ error: 'no such timer' }, 404);
      if (meta.config.managedBy === 'director' && !meta.config.public.shareWithPlayer) {
        return reply({ error: 'not shown' }, 404);
      }
      await this.advanceOrders(meta, now);
      return reply(this.publicView(meta, now));
    }

    // A visitor's order, from the approved list.
    if (op === 'public-order') {
      if (!meta.publicId || meta.publicId !== body.publicId) return reply({ error: 'no such timer' }, 404);
      await this.advanceOrders(meta, now);
      const cfg = meta.config.publicOrders;
      const refuseOrder = (error: string) => reply({ error, view: this.publicView(meta, now) }, 409);
      if (!cfg?.enabled || !meta.config.public.enabled) return refuseOrder('orders-off');
      if (!this.running(meta, now)) return refuseOrder('not-running');
      if ((meta.ordersPausedUntil ?? 0) > now) return refuseOrder('paused');
      const def = cfg.orders.find((o) => o.id === body.orderId);
      if (!def) return refuseOrder('unknown-order');
      const visitor = typeof body.visitor === 'string' ? body.visitor : 'unknown';
      if (this.orders.sentToday(visitor, now) >= cfg.perVisitorDaily) return refuseOrder('visitor-cap');
      if (cfg.maxQueued != null && this.orders.openCount() >= cfg.maxQueued) return refuseOrder('full');
      const receiptHash = typeof body.receiptHash === 'string' && /^[0-9a-f]{64}$/.test(body.receiptHash) ? body.receiptHash : null;
      if (!receiptHash) return reply({ error: 'bad-receipt' }, 400);
      // Proof for the sender needs their key; without one it goes nowhere.
      const issuerKey = cfg.proofTo === 'issuer' ? validIssuerKey(body.issuerKey) : null;
      if (cfg.proofTo === 'issuer' && def.verification === 'photoProof' && !issuerKey) return reply({ error: 'bad-key' }, 400);
      const issuerTopic =
        typeof body.issuerTopic === 'string' && /^orders_relay_[0-9a-f]{24}$/.test(body.issuerTopic) ? body.issuerTopic : null;
      const no = this.orders.add(def, visitor, issuerKey, receiptHash, now, issuerTopic);
      await this.advanceOrders(meta, now);
      await this.scheduleCleanup(meta);
      return reply({ no, view: this.publicView(meta, now) });
    }

    // The sender's verdict on the proof: only with their order's receipt.
    if (op === 'public-review') {
      if (!meta.publicId || meta.publicId !== body.publicId) return reply({ error: 'no such timer' }, 404);
      await this.advanceOrders(meta, now);
      const receiptHash = typeof body.receipt === 'string' && body.receipt.length <= 200 ? await sha256Hex(body.receipt) : '';
      const no = Number(body.no);
      if (!this.orders.review(no, receiptHash, body.verdict === 'approve', now)) {
        return reply({ error: 'not-reviewing', view: this.publicView(meta, now) }, 409);
      }
      await this.announce(meta, 'review', no);
      await this.scheduleCleanup(meta);
      return reply(this.publicView(meta, now));
    }

    // An app watching the timer from its public page: told when it ends.
    if (op === 'public-watch') {
      if (!meta.publicId || meta.publicId !== body.publicId) return reply({ error: 'no such timer' }, 404);
      const topic = typeof body.topic === 'string' && /^orders_relay_[0-9a-f]{24}$/.test(body.topic) ? body.topic : null;
      if (!topic) return reply({ error: 'bad-topic' }, 400);
      const watchers = new Set(meta.watchers ?? []);
      if (body.on === false) watchers.delete(topic);
      else if (watchers.size < 500) watchers.add(topic);
      meta.watchers = [...watchers];
      this.saveMeta(meta);
      await this.scheduleCleanup(meta);
      return reply({ watching: watchers.has(topic) });
    }

    // The sender collecting their proof: only with their order's receipt.
    if (op === 'public-proof') {
      if (!meta.publicId || meta.publicId !== body.publicId) return reply({ error: 'no such timer' }, 404);
      const receiptHash = typeof body.receipt === 'string' && body.receipt.length <= 200 ? await sha256Hex(body.receipt) : '';
      const proof = this.orders.proofFor(Number(body.no), receiptHash, now);
      return proof ? reply({ proof }) : reply({ error: 'no proof' }, 404);
    }
    if (op === 'public-vote') {
      if (!meta.publicId || meta.publicId !== body.publicId) return reply({ error: 'no such timer' }, 404);
      const delta = (body.direction === -1 ? -1 : 1) * meta.config.public.stepSeconds;
      const state = this.state(meta);
      const why = refuse(state, 'public', delta, now, body.visitor);
      if (why) return reply({ error: why, view: viewFor(state, 'public', now) }, 409);
      this.sql.exec(
        `INSERT INTO events (id, at, actor, delta, visitor) VALUES (?, ?, 'public', ?, ?)`,
        `public-${crypto.randomUUID()}`, now, delta, body.visitor ?? null,
      );
      if (delta > 0) await this.notePublicAdd(meta, delta, now);
      await this.scheduleCleanup(meta);
      return reply(this.publicView(meta, now));
    }

    const role = await this.roleOf(meta, request.headers.get('X-Timer-Key'));
    if (!role) return reply({ error: 'not your timer' }, 403);
    const manager = role === meta.config.managedBy;
    // The link, for whoever may see it: the manager, and the player when it
    // is shared with them. In every reply - a change's reply used to leave it
    // out, and the app showed the link as switched off until the next fetch.
    const linkFor = () =>
      manager || (role === 'player' && meta.config.public.shareWithPlayer) ? meta.publicId : null;

    // First use of a key: the side holding it has the timer.
    const seenField = role === 'player' ? 'playerSeenAt' : 'directorSeenAt';
    if (!meta[seenField]) {
      meta[seenField] = now;
      this.saveMeta(meta);
    }
    // Whether the partner has ever connected; null when it cannot be known
    // (a player on a timer from before first use was recorded).
    const partnerSeen = (): boolean | null => {
      if (role === 'player') return Boolean(meta.directorSeenAt);
      if (meta.playerSeenAt) return true;
      return meta.seenTracked ? false : null;
    };
    // Shared by every reply: who is asking, the link if they may see it, and
    // for the manager, whether the partner has ever connected.
    const about = () => ({
      role,
      manager,
      publicId: linkFor(),
      ...(manager ? { partnerConnected: partnerSeen() } : {}),
      orders: this.ordersPrivate(meta, now),
    });

    switch (op) {
      case 'view':
        await this.advanceOrders(meta, now);
        return reply({ ...about(), ...viewFor(this.state(meta), role as Viewer, now) });

      case 'order-result': {
        // The player's own report: done, with any proof, or failed.
        if (role !== 'player') return reply({ error: 'not-allowed' }, 403);
        await this.advanceOrders(meta, now);
        const result =
          body.result === 'completed' || body.result === 'failed' || body.result === 'submitted' ? body.result : null;
        if (!result) return reply({ error: 'bad-result' }, 400);
        const no = Number(body.no);
        const active = this.orders.active();
        // Proof is kept only for a sender who can open it, already encrypted.
        const proof =
          result !== 'failed' && active?.no === no && active.issuerKey && typeof body.proof === 'string' && body.proof.length <= PROOF_MAX_CHARS
            ? body.proof
            : null;
        if (result === 'submitted') {
          // Done, with proof to be checked: approved or rejected by whoever
          // receives it - or approved for them, if they take too long.
          if (!this.orders.submit(no, proof, now)) return reply({ error: 'not-active' }, 409);
          await this.tellIssuer(meta, no);
        } else {
          // Proof waiting on its sender is theirs to decide, not the player's.
          if (this.orders.awaitsSender(no)) return reply({ error: 'awaiting-sender' }, 409);
          if (!this.orders.finish(no, result, proof, now)) return reply({ error: 'not-active' }, 409);
          await this.tellIssuer(meta, no);
        }
        await this.advanceOrders(meta, now);
        await this.scheduleCleanup(meta);
        return reply({ ...about(), ...viewFor(this.state(meta), role, now) });
      }

      case 'order-skip': {
        if (role !== 'player') return reply({ error: 'not-allowed' }, 403);
        await this.advanceOrders(meta, now);
        if (this.skipsLeft(meta, now) <= 0) return reply({ error: 'no-skips' }, 409);
        if (!this.orders.skip(Number(body.no), now)) return reply({ error: 'not-active' }, 409);
        await this.tellIssuer(meta, Number(body.no));
        const day = Math.floor(now / 86_400_000);
        meta.orderSkips = { day, used: (meta.orderSkips?.day === day ? meta.orderSkips.used : 0) + 1 };
        // A breather: nothing new is taken or delivered for a while.
        meta.ordersPausedUntil = now + (meta.config.publicOrders?.skipPauseMinutes ?? 30) * 60 * 1000;
        this.saveMeta(meta);
        await this.scheduleCleanup(meta);
        return reply({ ...about(), ...viewFor(this.state(meta), role, now) });
      }

      case 'adjust': {
        const delta = Number(body.delta);
        const eventId = `${role}-${String(body.eventId ?? crypto.randomUUID()).slice(0, 64)}`;
        const state = this.state(meta);
        // A retried request is not applied twice.
        if (state.events.some((e) => e.id === eventId)) {
          return reply({ ...about(), ...viewFor(state, role, now) });
        }
        if (state.events.length >= MAX_EVENTS) return reply({ error: 'too-many-changes' }, 409);
        const why = refuse(state, role, delta, now);
        if (why) return reply({ error: why, ...about(), ...viewFor(state, role, now) }, 409);
        this.sql.exec(`INSERT INTO events (id, at, actor, delta) VALUES (?, ?, ?, ?)`, eventId, now, role, delta);
        await this.scheduleCleanup(meta);
        return reply({ ...about(), ...viewFor(this.state(meta), role, now) });
      }

      case 'configure': {
        // Only whoever set the timer up changes its settings, and not the
        // ones already in play: the base, the random schedule (changing it
        // would rewrite past random changes) or the combination.
        if (!manager) return reply({ error: 'not-allowed' }, 403);
        if (resolve(this.state(meta), now).status !== 'running') return reply({ error: 'not-running' }, 409);
        const next = sanitizeConfig({ ...meta.config, ...body.config }, meta.config.managedBy);
        meta.config = {
          ...next,
          baseSeconds: meta.config.baseSeconds,
          // Switching it would wipe out, or invent, an end time.
          openEnded: meta.config.openEnded ?? false,
          random: meta.config.random,
          combination: meta.config.combination,
        };
        if (meta.config.public.enabled && !meta.publicId) {
          if (!countLinkChange(meta, now)) return reply({ error: 'link-changes' }, 429);
          meta.publicId = body.newPublicId ?? null;
        }
        if (!meta.config.public.enabled) meta.publicId = null;
        this.saveMeta(meta);
        await this.scheduleCleanup(meta);
        return reply({ ...about(), ...viewFor(this.state(meta), role, now) });
      }

      case 'replace-link': {
        if (!manager) return reply({ error: 'not-allowed' }, 403);
        if (!meta.config.public.enabled) return reply({ error: 'public-disabled' }, 409);
        if (!countLinkChange(meta, now)) return reply({ error: 'link-changes' }, 429);
        const previous = meta.publicId;
        meta.publicId = body.newPublicId;
        this.saveMeta(meta);
        return reply({ ok: true, previous, publicId: meta.publicId });
      }

      case 'notify-topic': {
        // The player's own device saying where it listens. Nobody else's.
        if (role !== 'player') return reply({ error: 'not-allowed' }, 403);
        const topic =
          typeof body.topic === 'string' && /^orders_relay_[0-9a-f]{24}$/.test(body.topic) ? body.topic : null;
        if (!topic) return reply({ error: 'bad-topic' }, 400);
        meta.playerTopic = topic;
        this.saveMeta(meta);
        return reply({ ok: true });
      }

      case 'reissue-key': {
        // The partner's key never arrived (their device was asleep, say): the
        // manager may have a fresh one made, to send again. Only while the
        // partner has never connected - once they have, nobody can replace
        // their key, so a player's emergency release cannot be taken away.
        if (!manager) return reply({ error: 'not-allowed' }, 403);
        // Unknown counts as connected: a player's key is never replaced
        // unless they certainly never had it.
        if (partnerSeen() !== false) return reply({ error: 'partner-connected' }, 409);
        const key = randomToken(24);
        const hash = await sha256Hex(key);
        if (role === 'player') meta.directorKeyHash = hash;
        else meta.playerKeyHash = hash;
        this.saveMeta(meta);
        return reply({ key });
      }

      case 'release': {
        // The player's emergency release is always available and cannot be
        // taken away. The director may end it early too.
        const state = this.state(meta);
        if (resolve(state, now).status !== 'running') {
          return reply({ ...about(), ...viewFor(state, role, now) });
        }
        meta.releasedAt = now;
        meta.releasedBy = role;
        this.saveMeta(meta);
        await this.tellWatchers(meta, now);
        await this.scheduleCleanup(meta);
        return reply({ ...about(), ...viewFor(this.state(meta), role, now) });
      }
    }
    return reply({ error: 'not found' }, 404);
  }
}
