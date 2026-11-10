// Live toy control: the relay room between a toy's owner and partners.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  TOY_CTL_TAG,
  TOY_MAX_CONTROLLERS,
  TOY_MAX_PER_SECOND,
  TOY_OWNER_TAG,
  ToyRoom,
  spendFrame,
  toyRole,
  toyRoomName,
  validToyTopic,
} from '../src/toy_room.ts';

test('roles and topics are checked', () => {
  assert.equal(toyRole('owner'), 'owner');
  assert.equal(toyRole('ctl'), 'ctl');
  assert.equal(toyRole('admin'), null);
  assert.equal(toyRole(null), null);
  assert.equal(validToyTopic('a'.repeat(64)), true);
  assert.equal(validToyTopic('short'), false);
  assert.equal(validToyTopic('has/slash-in-it'), false);
  assert.equal(toyRoomName('abc'), 'toy:abc', 'a room never shares a hub with the topic itself');
});

test('a socket may send a limited number of frames a second', () => {
  let budget = null as Parameters<typeof spendFrame>[0];
  for (let i = 0; i < TOY_MAX_PER_SECOND; i++) {
    const r = spendFrame(budget, 1000 + i);
    assert.equal(r.ok, true);
    budget = r.budget;
  }
  assert.equal(spendFrame(budget, 1500).ok, false, 'over the limit inside the second');
  assert.equal(spendFrame(budget, 2000).ok, true, 'a new second, a new budget');
});

// A stand-in for the hibernation API: tagged sockets that record what they get.
class FakeSocket {
  sent: string[] = [];
  closed: number | null = null;
  attachment: unknown = null;
  tags: string[];
  constructor(tags: string[]) {
    this.tags = tags;
  }
  send(m: string) {
    if (this.closed !== null) throw new Error('closed');
    this.sent.push(m);
  }
  close(code: number) {
    this.closed = code;
  }
  serializeAttachment(v: unknown) {
    this.attachment = v;
  }
  deserializeAttachment() {
    return this.attachment;
  }
}

function fakeRoom() {
  const sockets: FakeSocket[] = [];
  const ctx = {
    acceptWebSocket(ws: FakeSocket, tags: string[]) {
      ws.tags.push(...tags);
      sockets.push(ws);
    },
    getWebSockets(tag?: string) {
      return sockets.filter((s) => s.closed === null && (!tag || s.tags.includes(tag)));
    },
    getTags(ws: FakeSocket) {
      return ws.tags;
    },
  };
  // WebSocketPair and the 101 Response exist only in the Workers runtime.
  const g = globalThis as any;
  g.WebSocketPair = class {
    0 = new FakeSocket([]);
    1 = new FakeSocket([]);
  };
  const RealResponse = g.Response;
  g.Response = class extends RealResponse {
    constructor(body: any, init: any) {
      super(body, init?.status === 101 ? { status: 200 } : init);
    }
  };
  const room = new ToyRoom(ctx as unknown as DurableObjectState);
  const join = (role: 'owner' | 'ctl') => {
    room.accept(role);
    return sockets[sockets.length - 1];
  };
  return { room, sockets, join };
}

test('partner frames reach only the owner; owner frames reach every partner', () => {
  const { room, join } = fakeRoom();
  const owner = join('owner');
  const a = join('ctl');
  const b = join('ctl');
  for (const s of [owner, a, b]) s.sent = [];

  room.message(a as unknown as WebSocket, 'cipher-from-a');
  assert.deepEqual(owner.sent, ['cipher-from-a']);
  assert.deepEqual(b.sent, [], 'one partner never sees another\'s commands');

  room.message(owner as unknown as WebSocket, 'state');
  assert.deepEqual(a.sent, ['state']);
  assert.deepEqual(b.sent, ['state']);
});

test('presence is announced as people come and go', () => {
  const { room, join } = fakeRoom();
  const a = join('ctl');
  assert.deepEqual(JSON.parse(a.sent.at(-1)!), { sys: 'presence', owner: false, controllers: 1 });

  const owner = join('owner');
  assert.deepEqual(JSON.parse(a.sent.at(-1)!), { sys: 'presence', owner: true, controllers: 1 });
  assert.deepEqual(JSON.parse(owner.sent.at(-1)!), { sys: 'presence', owner: true, controllers: 1 });

  owner.closed = 1000;
  room.closed(owner as unknown as WebSocket);
  assert.deepEqual(JSON.parse(a.sent.at(-1)!), { sys: 'presence', owner: false, controllers: 1 });
});

test('a reconnecting owner replaces the old connection', () => {
  const { join } = fakeRoom();
  const first = join('owner');
  const second = join('owner');
  assert.equal(first.closed, 4000);
  assert.equal(second.closed, null);
  assert.ok(second.tags.includes(TOY_OWNER_TAG));
});

test('the room holds a limited number of partners', () => {
  const { room, sockets } = fakeRoom();
  for (let i = 0; i < TOY_MAX_CONTROLLERS; i++) room.accept('ctl');
  assert.equal(room.accept('ctl').status, 429);
  assert.equal(sockets.filter((s) => s.tags.includes(TOY_CTL_TAG)).length, TOY_MAX_CONTROLLERS);
});

test('pings are answered, oversized frames dropped', () => {
  const { room, join } = fakeRoom();
  const owner = join('owner');
  const a = join('ctl');
  owner.sent = [];
  a.sent = [];
  room.message(a as unknown as WebSocket, 'ping');
  assert.deepEqual(a.sent, ['pong']);
  room.message(a as unknown as WebSocket, 'x'.repeat(9000));
  assert.deepEqual(owner.sent, []);
});

test('TURN logins: relay addresses only, never port 53', async () => {
  const { relayServers, mintTurnLogin } = await import('../src/toy_room.ts');
  const answer = {
    iceServers: [
      { urls: ['stun:stun.cloudflare.com:3478', 'stun:stun.cloudflare.com:53'] },
      {
        urls: [
          'turn:turn.cloudflare.com:3478?transport=udp',
          'turn:turn.cloudflare.com:53?transport=udp',
          'turns:turn.cloudflare.com:443?transport=tcp',
        ],
        username: 'u',
        credential: 'c',
      },
    ],
  };
  assert.deepEqual(relayServers(answer), [
    {
      urls: ['turn:turn.cloudflare.com:3478?transport=udp', 'turns:turn.cloudflare.com:443?transport=tcp'],
      username: 'u',
      credential: 'c',
    },
  ]);
  assert.deepEqual(relayServers({}), []);

  let asked: { url: string; init: RequestInit } | null = null;
  const fake = (async (url: string, init: RequestInit) => {
    asked = { url, init };
    return new Response(JSON.stringify(answer), { status: 201 });
  }) as unknown as typeof fetch;
  const servers = await mintTurnLogin(' key1 ', 'tok', fake);
  assert.equal(servers?.[0].username, 'u');
  assert.match(asked!.url, /\/turn\/keys\/key1\/credentials\/generate-ice-servers$/);
  assert.equal((asked!.init.headers as Record<string, string>).authorization, 'Bearer tok');

  assert.equal(await mintTurnLogin(undefined, 'tok', fake), null, 'no key, no login');
  const refusing = (async () => new Response('no', { status: 403 })) as unknown as typeof fetch;
  assert.equal(await mintTurnLogin('k', 't', refusing), null);
});
