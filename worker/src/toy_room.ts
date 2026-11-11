/**
 * Live toy control: a relay room between one toy's owner and the partners
 * steering it.
 *
 * The owner's app joins its own room while a toy is connected; a partner's
 * control panel joins the same room while it is open. Frames from a partner go
 * to the owner and frames from the owner go to every partner. Nothing is
 * stored: a command that finds nobody listening is gone, which is the point -
 * a buzz meant for now must never turn up hours later.
 *
 * Frames are ciphertext under the owner's pairing secret, so the room can no
 * more read them than the hub can read a directive. The owner's app decides
 * who may do what; the room only carries, counts and announces who is there.
 */

export type ToyRole = 'owner' | 'ctl';

export const TOY_OWNER_TAG = 'toy-owner';
export const TOY_CTL_TAG = 'toy-ctl';

/** Partners one toy can have watching at once. */
export const TOY_MAX_CONTROLLERS = 10;
/** A command is a few hundred bytes; a metronome setting under 2k. */
export const TOY_MAX_FRAME = 8 * 1024;
/** Frames a socket may send per second. A slider sends ~10. */
export const TOY_MAX_PER_SECOND = 25;

export function toyRole(value: string | null): ToyRole | null {
  return value === 'owner' || value === 'ctl' ? value : null;
}

export function toyRoomName(topic: string): string {
  return `toy:${topic}`;
}

/** A hashed topic, as the app makes them. */
export function validToyTopic(topic: string | null): topic is string {
  return typeof topic === 'string' && /^[A-Za-z0-9_-]{8,128}$/.test(topic);
}

export interface FrameBudget {
  /** Start of the current one-second window. */
  w: number;
  /** Frames sent in it. */
  n: number;
}

/** Whether one more frame fits this second, and the budget after it. */
export function spendFrame(budget: FrameBudget | null, now: number): { ok: boolean; budget: FrameBudget } {
  if (!budget || now - budget.w >= 1000) return { ok: true, budget: { w: now, n: 1 } };
  if (budget.n >= TOY_MAX_PER_SECOND) return { ok: false, budget };
  return { ok: true, budget: { w: budget.w, n: budget.n + 1 } };
}

/** What the room says about who is present. Plain JSON, unlike relayed frames. */
export function presenceFrame(ownerOnline: boolean, controllers: number): string {
  return JSON.stringify({ sys: 'presence', owner: ownerOnline, controllers });
}

/**
 * The room itself, living inside a TopicHub instance named for it so it costs
 * no new Durable Object class. Uses the hibernation API: sockets are tagged by
 * role, and an idle room leaves memory.
 */
export class ToyRoom {
  private readonly ctx: DurableObjectState;

  constructor(ctx: DurableObjectState) {
    this.ctx = ctx;
  }

  static isToySocket(ctx: DurableObjectState, ws: WebSocket): boolean {
    const tags = ctx.getTags(ws);
    return tags.includes(TOY_OWNER_TAG) || tags.includes(TOY_CTL_TAG);
  }

  private owners(except?: WebSocket): WebSocket[] {
    return this.ctx.getWebSockets(TOY_OWNER_TAG).filter((ws) => ws !== except);
  }

  private controllers(except?: WebSocket): WebSocket[] {
    return this.ctx.getWebSockets(TOY_CTL_TAG).filter((ws) => ws !== except);
  }

  accept(role: ToyRole): Response {
    if (role === 'ctl' && this.controllers().length >= TOY_MAX_CONTROLLERS) {
      return new Response(JSON.stringify({ error: 'room-full' }), { status: 429 });
    }
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];

    if (role === 'owner') {
      // One owner at a time: a reconnect replaces the connection it lost.
      for (const old of this.owners()) {
        try {
          old.close(4000, 'replaced');
        } catch {
          // Already gone.
        }
      }
    }

    this.ctx.acceptWebSocket(server, [role === 'owner' ? TOY_OWNER_TAG : TOY_CTL_TAG]);
    server.serializeAttachment({ w: 0, n: 0 } satisfies FrameBudget);

    if (role === 'owner') {
      this.announce(undefined, server);
    } else {
      this.announce();
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  message(ws: WebSocket, message: string | ArrayBuffer): void {
    if (typeof message !== 'string') return;
    if (message === 'ping') {
      ws.send('pong');
      return;
    }
    if (message.length > TOY_MAX_FRAME) return;

    const spent = spendFrame(ws.deserializeAttachment() as FrameBudget | null, Date.now());
    if (!spent.ok) return;
    ws.serializeAttachment(spent.budget);

    const fromOwner = this.ctx.getTags(ws).includes(TOY_OWNER_TAG);
    const targets = fromOwner ? this.controllers() : this.owners();
    for (const target of targets) {
      try {
        target.send(message);
      } catch {
        // Gone; its close handler will announce it.
      }
    }
  }

  closed(ws: WebSocket): void {
    this.announce(ws);
  }

  /** Tells everyone in the room who is there, leaving out a socket going away. */
  private announce(leaving?: WebSocket, joiningOwner?: WebSocket): void {
    const owners = this.owners(leaving);
    const ownerOnline = owners.length > 0 || joiningOwner !== undefined;
    const controllers = this.controllers(leaving);
    const frame = presenceFrame(ownerOnline, controllers.length);
    const everyone = [...owners, ...controllers];
    if (joiningOwner && !everyone.includes(joiningOwner)) everyone.push(joiningOwner);
    for (const ws of everyone) {
      try {
        ws.send(frame);
      } catch {
        // Gone.
      }
    }
  }
}

// ---------------------------------------------------------------------------
// TURN logins for toy sessions
//
// Sessions run over WebRTC, relayed by Cloudflare's TURN service: billed by
// data, not by time, and a toy session is a trickle of data. The long-lived
// TURN key stays here; each session is handed a short-lived login.
// ---------------------------------------------------------------------------

/** How long a session's TURN login lasts. A longer session asks again. */
export const TURN_TTL_SECONDS = 3 * 60 * 60;

export interface IceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

/**
 * Keeps what a toy session should use: TURN only (every session is relayed,
 * so partners never learn each other's address), minus port 53, which some
 * networks and Chrome refuse and which only slows connecting.
 */
export function relayServers(raw: unknown): IceServer[] {
  const servers = (raw as { iceServers?: unknown })?.iceServers;
  const list = Array.isArray(servers) ? servers : servers ? [servers] : [];
  const out: IceServer[] = [];
  for (const s of list as Array<Record<string, unknown>>) {
    const urls = (Array.isArray(s?.urls) ? s.urls : [s?.urls]).filter(
      (u): u is string => typeof u === 'string' && /^turns?:/.test(u) && !/:53(\?|$)/.test(u),
    );
    if (urls.length === 0) continue;
    out.push({
      urls,
      ...(typeof s.username === 'string' ? { username: s.username } : {}),
      ...(typeof s.credential === 'string' ? { credential: s.credential } : {}),
    });
  }
  return out;
}

/** A fresh TURN login from Cloudflare, or null if none could be had. */
export async function mintTurnLogin(
  keyId: string | undefined,
  apiToken: string | undefined,
  fetcher: typeof fetch = fetch,
): Promise<IceServer[] | null> {
  if (!keyId || !apiToken) return null;
  try {
    const res = await fetcher(
      `https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(keyId.trim())}/credentials/generate-ice-servers`,
      {
        method: 'POST',
        headers: { authorization: `Bearer ${apiToken.trim()}`, 'content-type': 'application/json' },
        body: JSON.stringify({ ttl: TURN_TTL_SECONDS }),
      },
    );
    if (!res.ok) return null;
    const servers = relayServers(await res.json());
    return servers.length > 0 ? servers : null;
  } catch {
    return null;
  }
}
