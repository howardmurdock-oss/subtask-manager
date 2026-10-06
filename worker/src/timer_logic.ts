/**
 * The chastity timer's rules, kept free of Cloudflare so they can be tested
 * on their own (node --test). The Durable Object in timer.ts stores state and
 * calls these.
 *
 * A timer is a start time, a configuration and a log of changes. The end is
 * never stored: it is the start plus the base duration plus every change,
 * worked out when asked. That is what lets changes arrive from the director,
 * the player, strangers on a public link and the random schedule without any
 * of them overwriting another.
 *
 * Random changes are not stored at all. Each one is derived from the timer id
 * and its slot number, so every read produces the same history, no device has
 * to be awake for one to happen, and nobody can re-roll one.
 */

export type Actor = 'player' | 'director' | 'random' | 'public';

export interface TimerConfig {
  /** Seconds the timer starts with. */
  baseSeconds: number;
  /** Who set it up. A director-managed timer's settings are the director's. */
  managedBy: 'player' | 'director';
  /** No end time: it runs until someone ends it (or reaches its maximum,
   * if it has one). Nothing can add or remove time - there is no end to
   * move - so changes, random changes, hiding and public voting are off. */
  openEnded: boolean;
  /** Telling the player when time is added. The message is the manager's
   * own wording; the app always adds who added it. */
  notify: { onAdd: boolean; message: string | null };
  /** The player does not see the time left, or how much each change was. */
  hidden: boolean;
  /** No change may push the end past start + this. Null: no ceiling. */
  maxTotalSeconds: number | null;
  director: {
    canAdd: boolean;
    canRemove: boolean;
    /** Seconds of change allowed per rolling 24h, added and removed counted
     * together. Null: unlimited. */
    dailyCapSeconds: number | null;
  };
  random: {
    enabled: boolean;
    everyMinutes: number;
    /** Each slot changes the timer by a whole number of minutes in this
     * range, in seconds. Negative removes time. */
    minSeconds: number;
    maxSeconds: number;
  };
  public: {
    enabled: boolean;
    allowRemove: boolean;
    /** What one vote adds or removes. */
    stepSeconds: number;
    /** Per visitor, per rolling 24h, counted as absolute change. */
    perVisitorDailySeconds: number;
    /** Across all visitors, per rolling 24h. Null: unlimited. */
    dailyCapSeconds: number | null;
    showTimeLeft: boolean;
    /** The player gets the link too, to hand out. Replacing it or switching
     * it off stays with whoever manages the timer. */
    shareWithPlayer: boolean;
  };
  combination: {
    enabled: boolean;
    /** Held here and shown to the player only once the timer is over. */
    digits: string | null;
  };
}

export interface TimerEvent {
  id: string;
  at: number;
  actor: Actor;
  delta: number;
  /** Public votes only: an opaque per-day visitor tag, for the per-visitor cap. */
  visitor?: string;
}

export type TimerStatus = 'running' | 'ended' | 'released';

export interface TimerState {
  id: string;
  startAt: number;
  config: TimerConfig;
  /** Stored changes. Random ones are derived, never stored. */
  events: TimerEvent[];
  /** Set by an emergency release, or the director ending it early. */
  releasedAt: number | null;
  releasedBy: 'player' | 'director' | null;
}

export const DAY_MS = 24 * 60 * 60 * 1000;

// ---------------------------------------------------------------------------
// Random changes
// ---------------------------------------------------------------------------

/** A 32-bit FNV-1a hash: small, stable, and the same everywhere it runs. */
function fnv1a(text: string): number {
  let hash = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash >>> 0;
}

/** The change random slot [slot] makes: whole minutes within the range. */
export function randomDelta(timerId: string, slot: number, minSeconds: number, maxSeconds: number): number {
  const lo = Math.ceil(Math.min(minSeconds, maxSeconds) / 60);
  const hi = Math.floor(Math.max(minSeconds, maxSeconds) / 60);
  if (hi < lo) return 0;
  const span = hi - lo + 1;
  return (lo + (fnv1a(`${timerId}:${slot}`) % span)) * 60;
}

// ---------------------------------------------------------------------------
// Working the timer out
// ---------------------------------------------------------------------------

export interface Resolved {
  endAt: number;
  status: TimerStatus;
  /** Stored and random changes, oldest first, as they actually applied. */
  history: TimerEvent[];
}

/**
 * Replays every change in time order. A change only counts while the timer is
 * still running at its moment: time added after the end cannot restart it,
 * and removing time can end it on the spot.
 */
export function resolve(state: TimerState, now: number): Resolved {
  const { config, startAt } = state;
  const ceiling = config.maxTotalSeconds == null ? Infinity : startAt + config.maxTotalSeconds * 1000;
  const until = state.releasedAt ?? now;

  const stored = [...state.events].sort((a, b) => a.at - b.at || a.id.localeCompare(b.id));
  // An open-ended timer ends only at its maximum, if it has one.
  let endAt = config.openEnded ? ceiling : Math.min(startAt + config.baseSeconds * 1000, ceiling);
  const history: TimerEvent[] = [];

  const everyMs = config.random.enabled && config.random.everyMinutes > 0
    ? config.random.everyMinutes * 60 * 1000
    : 0;
  let slot = 1;
  let i = 0;

  for (;;) {
    const nextStored = i < stored.length ? stored[i] : null;
    const nextRandomAt = everyMs ? startAt + slot * everyMs : Infinity;
    const nextAt = Math.min(nextStored?.at ?? Infinity, nextRandomAt);
    // Nothing more happened while the timer ran.
    if (nextAt > until || nextAt >= endAt) break;

    let event: TimerEvent;
    if (nextStored && nextStored.at <= nextRandomAt) {
      event = nextStored;
      i++;
    } else {
      const delta = randomDelta(state.id, slot, config.random.minSeconds, config.random.maxSeconds);
      event = { id: `random-${slot}`, at: nextRandomAt, actor: 'random', delta };
      slot++;
    }

    // Removing time never ends it earlier than the moment of the change.
    endAt = Math.min(Math.max(endAt + event.delta * 1000, event.at), ceiling);
    history.push(event);
  }

  const status: TimerStatus = state.releasedAt != null ? 'released' : now >= endAt ? 'ended' : 'running';
  return { endAt, status, history };
}

// ---------------------------------------------------------------------------
// Checking a change before it is stored
// ---------------------------------------------------------------------------

/** Seconds of change [matches] made in the 24h before [now]. */
function usedInDay(history: TimerEvent[], now: number, matches: (e: TimerEvent) => boolean): number {
  return history
    .filter((e) => e.at > now - DAY_MS && matches(e))
    .reduce((sum, e) => sum + Math.abs(e.delta), 0);
}

export type Refusal =
  | 'not-running'
  | 'not-allowed'
  | 'daily-cap'
  | 'visitor-cap'
  | 'public-disabled'
  | 'at-maximum'
  | 'open-ended'
  | 'bad-amount';

/** Whether no more time can be added: the end is at the maximum length. */
function isAtMaximum(state: TimerState, endAt: number): boolean {
  const max = state.config.maxTotalSeconds;
  return max != null && endAt >= state.startAt + max * 1000;
}

/** Why a change by [actor] cannot be made, or null when it can. */
export function refuse(
  state: TimerState,
  actor: 'player' | 'director' | 'public',
  delta: number,
  now: number,
  visitor?: string,
): Refusal | null {
  if (!Number.isFinite(delta) || delta === 0 || !Number.isInteger(delta)) return 'bad-amount';
  const { status, history, endAt } = resolve(state, now);
  if (status !== 'running') return 'not-running';
  const { config } = state;
  // No end time to move.
  if (config.openEnded) return 'open-ended';
  // At the maximum, added time would do nothing - and a vote would still be
  // spent. Refused, so whoever tried is told why rather than left guessing.
  const full = delta > 0 && isAtMaximum(state, endAt);

  switch (actor) {
    case 'player':
      // The player can make it longer, never shorter. The way out is the
      // emergency release, which is logged and tells the director.
      if (delta < 0) return 'not-allowed';
      return full ? 'at-maximum' : null;

    case 'director': {
      if (delta > 0 && !config.director.canAdd) return 'not-allowed';
      if (delta < 0 && !config.director.canRemove) return 'not-allowed';
      if (full) return 'at-maximum';
      const cap = config.director.dailyCapSeconds;
      if (cap != null && usedInDay(history, now, (e) => e.actor === 'director') + Math.abs(delta) > cap) {
        return 'daily-cap';
      }
      return null;
    }

    case 'public': {
      if (!config.public.enabled) return 'public-disabled';
      if (Math.abs(delta) !== config.public.stepSeconds) return 'bad-amount';
      if (delta < 0 && !config.public.allowRemove) return 'not-allowed';
      if (full) return 'at-maximum';
      const perVisitor = usedInDay(history, now, (e) => e.actor === 'public' && e.visitor === visitor);
      if (perVisitor + Math.abs(delta) > config.public.perVisitorDailySeconds) return 'visitor-cap';
      const cap = config.public.dailyCapSeconds;
      if (cap != null && usedInDay(history, now, (e) => e.actor === 'public') + Math.abs(delta) > cap) {
        return 'daily-cap';
      }
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// What each party gets to see
// ---------------------------------------------------------------------------

export type Viewer = 'player' | 'director' | 'public';

/**
 * The timer as [viewer] may see it. A hidden timer tells the player that it
 * is running and who changed it, not the time left or by how much. The
 * combination reaches the player only once it is over; the director, who set
 * it, always sees it. Strangers see the time left only if allowed, and never
 * the history, the combination or the settings.
 */
export function viewFor(state: TimerState, viewer: Viewer, now: number): Record<string, unknown> {
  const { endAt: end, status, history } = resolve(state, now);
  const { config } = state;
  const over = status !== 'running';
  const hideTime = !over && ((viewer === 'player' && config.hidden) || (viewer === 'public' && !config.public.showTimeLeft));
  // An open-ended timer with no maximum has no end at all.
  const endAt = Number.isFinite(end) ? end : null;
  // When it stopped, for "ran for": released early, or reached its end.
  const closedAt = !over ? null : state.releasedAt ?? endAt;

  if (viewer === 'public') {
    return {
      status,
      // The start, for "locked for ... so far": it says nothing about the
      // end, so it is shown even where the time left is not.
      startAt: state.startAt,
      closedAt,
      openEnded: config.openEnded,
      endAt: hideTime ? null : endAt,
      stepSeconds: config.public.stepSeconds,
      allowRemove: config.public.allowRemove,
      acceptingVotes: config.public.enabled && !over && !config.openEnded,
      // Adding is refused at the maximum; the page says so instead of
      // leaving a button that seems to do nothing.
      atMaximum: !over && isAtMaximum(state, end),
      now,
    };
  }

  const hideAmounts = viewer === 'player' && config.hidden && !over;
  return {
    id: state.id,
    status,
    startAt: state.startAt,
    endAt: hideTime ? null : endAt,
    closedAt,
    releasedAt: state.releasedAt,
    releasedBy: state.releasedBy,
    // Not for a hidden timer's player: it would hint at the end.
    atMaximum: hideAmounts ? null : !over && isAtMaximum(state, end),
    config: {
      ...config,
      // The starting length and the ceiling, with the start time, would give
      // away the end of a hidden timer.
      baseSeconds: hideAmounts ? null : config.baseSeconds,
      maxTotalSeconds: hideAmounts ? null : config.maxTotalSeconds,
      combination: {
        enabled: config.combination.enabled,
        length: config.combination.digits?.length ?? null,
        digits: config.combination.enabled && (viewer === 'director' || over) ? config.combination.digits : null,
      },
    },
    history: history.map((e) => ({
      id: e.id,
      at: e.at,
      actor: e.actor,
      delta: hideAmounts ? null : e.delta,
    })),
    now,
  };
}

// ---------------------------------------------------------------------------
// Checking a configuration
// ---------------------------------------------------------------------------

/** Longest custom notification message. */
export const NOTIFY_MESSAGE_MAX = 120;

/** A custom notification message: one line of plain text, or none. */
function cleanMessage(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const text = raw
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, NOTIFY_MESSAGE_MAX)
    .trim();
  return text.length > 0 ? text : null;
}

const clampInt = (value: unknown, min: number, max: number, fallback: number): number => {
  const n = typeof value === 'number' && Number.isFinite(value) ? Math.round(value) : fallback;
  return Math.min(Math.max(n, min), max);
};

const YEAR = 365 * 24 * 60 * 60;

/** A configuration from a client, with every value checked and bounded. */
export function sanitizeConfig(raw: any, managedBy: 'player' | 'director'): TimerConfig {
  const r = raw ?? {};
  const digits = typeof r.combination?.digits === 'string' ? r.combination.digits.replace(/\D/g, '').slice(0, 12) : '';
  const nullableCap = (v: unknown) => (v == null ? null : clampInt(v, 60, YEAR, 60));
  const openEnded = r.openEnded === true;
  return {
    baseSeconds: clampInt(r.baseSeconds, 60, YEAR, 3600),
    managedBy,
    openEnded,
    // Nothing to hide, change or roll without an end time.
    hidden: !openEnded && r.hidden === true,
    notify: {
      // On unless switched off: before this setting, a director's additions
      // were always announced.
      onAdd: !openEnded && r.notify?.onAdd !== false,
      message: cleanMessage(r.notify?.message),
    },
    // A player's own timer with no end time has no limit either: they end
    // it when they like, and a limit would only make it a timed lock.
    maxTotalSeconds:
      r.maxTotalSeconds == null || (openEnded && managedBy === 'player')
        ? null
        : clampInt(r.maxTotalSeconds, 60, 5 * YEAR, YEAR),
    director: {
      canAdd: r.director?.canAdd !== false,
      canRemove: r.director?.canRemove !== false,
      dailyCapSeconds: nullableCap(r.director?.dailyCapSeconds),
    },
    random: {
      enabled: !openEnded && r.random?.enabled === true,
      everyMinutes: clampInt(r.random?.everyMinutes, 15, 7 * 24 * 60, 240),
      minSeconds: clampInt(r.random?.minSeconds, -YEAR, YEAR, -3600),
      maxSeconds: clampInt(r.random?.maxSeconds, -YEAR, YEAR, 3600),
    },
    public: {
      enabled: r.public?.enabled === true,
      allowRemove: r.public?.allowRemove === true,
      stepSeconds: clampInt(r.public?.stepSeconds, 60, 24 * 3600, 600),
      perVisitorDailySeconds: clampInt(r.public?.perVisitorDailySeconds, 60, 7 * 24 * 3600, 3600),
      dailyCapSeconds: nullableCap(r.public?.dailyCapSeconds),
      showTimeLeft: r.public?.showTimeLeft !== false,
      shareWithPlayer: r.public?.shareWithPlayer === true,
    },
    combination: {
      enabled: r.combination?.enabled === true && digits.length > 0,
      digits: r.combination?.enabled === true && digits.length > 0 ? digits : null,
    },
  };
}
