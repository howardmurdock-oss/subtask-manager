// Live toy rooms against a running Worker:
//   npx wrangler dev --local --port 8799      (in one terminal)
//   node test/toy_room.local.ts               (in another)
import assert from 'node:assert/strict';

const BASE = (process.env.TIMER_BASE ?? 'http://127.0.0.1:8799').replace(/^http/, 'ws');
const topic = 'localtoycheck' + Math.random().toString(36).slice(2, 10);

function open(role: string): Promise<{ ws: WebSocket; got: string[] }> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${BASE}/toy?topic=${topic}&role=${role}`);
    const got: string[] = [];
    ws.onmessage = (e) => got.push(String(e.data));
    ws.onopen = () => resolve({ ws, got });
    ws.onerror = (e) => reject(e);
  });
}

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

const ctl = await open('ctl');
await wait(200);
assert.deepEqual(JSON.parse(ctl.got.at(-1)!), { sys: 'presence', owner: false, controllers: 1 });

const owner = await open('owner');
await wait(200);
assert.deepEqual(JSON.parse(ctl.got.at(-1)!), { sys: 'presence', owner: true, controllers: 1 });

ctl.ws.send('sealed-command');
await wait(200);
assert.ok(owner.got.includes('sealed-command'), 'partner -> owner');

owner.ws.send('sealed-state');
await wait(200);
assert.ok(ctl.got.includes('sealed-state'), 'owner -> partner');

ctl.ws.send('ping');
await wait(200);
assert.ok(ctl.got.includes('pong'));

// Nothing is kept: a partner arriving later gets presence, never old frames.
const late = await open('ctl');
await wait(200);
assert.ok(!late.got.includes('sealed-state'));

owner.ws.close();
await wait(300);
assert.deepEqual(JSON.parse(ctl.got.at(-1)!), { sys: 'presence', owner: false, controllers: 2 });

const bad = await fetch(`${BASE.replace(/^ws/, 'http')}/toy?topic=${topic}&role=admin`);
assert.equal(bad.status, 400);

ctl.ws.close();
late.ws.close();
console.log('toy room: all checks passed');
