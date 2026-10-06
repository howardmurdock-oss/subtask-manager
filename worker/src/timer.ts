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

/** Past this many stored changes a timer takes no more. Public votes are
 * capped per day, so only a director with no cap could get near it. */
const MAX_EVENTS = 20000;

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

  constructor(private readonly ctx: DurableObjectState, private readonly env: { DB: D1Database }) {
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
    await this.ctx.storage.setAlarm(from + RETAIN_AFTER_CLOSE_MS);
  }

  async alarm(): Promise<void> {
    const meta = this.meta();
    if (!meta) return;
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
      return reply(viewFor(this.state(meta), 'public', now));
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
      await this.scheduleCleanup(meta);
      return reply(viewFor(this.state(meta), 'public', now));
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
    });

    switch (op) {
      case 'view':
        return reply({ ...about(), ...viewFor(this.state(meta), role as Viewer, now) });

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
        if (meta.config.public.enabled && !meta.publicId) meta.publicId = body.newPublicId ?? null;
        if (!meta.config.public.enabled) meta.publicId = null;
        this.saveMeta(meta);
        await this.scheduleCleanup(meta);
        return reply({ ...about(), ...viewFor(this.state(meta), role, now) });
      }

      case 'replace-link': {
        if (!manager) return reply({ error: 'not-allowed' }, 403);
        if (!meta.config.public.enabled) return reply({ error: 'public-disabled' }, 409);
        const previous = meta.publicId;
        meta.publicId = body.newPublicId;
        this.saveMeta(meta);
        return reply({ ok: true, previous, publicId: meta.publicId });
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
        await this.scheduleCleanup(meta);
        return reply({ ...about(), ...viewFor(this.state(meta), role, now) });
      }
    }
    return reply({ error: 'not found' }, 404);
  }
}
