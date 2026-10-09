import assert from 'node:assert/strict';
import { test } from 'node:test';
import { newId } from '../src/encoding.ts';
import type { Store } from '../src/store/store.ts';
import { bearer, freshStore, seedDevice, seedOwner, sendOversized, startTestRelay, WEB_ORIGIN, type Seeded } from './harness.ts';

const DAY = 24 * 3_600_000;
const ord = (n: number) => String(n).padStart(16, '0');
type Listing = { requests: { request_id: string; ordinal: number; received_at: string }[]; next: number | null };

async function setup(options: { raw?: Store; store?: Store; owner?: string; device?: Seeded; now?: number } = {}) {
    const fresh = options.raw && options.store ? { raw: options.raw, store: options.store } : await freshStore();
    const owner = options.owner ?? (await seedOwner(fresh.store));
    const device = options.device ?? (await seedDevice(fresh.store, { active: true }));
    const clock = { now: options.now ?? Date.now() };
    const t = await startTestRelay({ raw: fresh.raw, now: () => clock.now });
    const post = (r: string, body: Uint8Array = new Uint8Array(1024).fill(7), token = device.token) =>
        fetch(`${t.url}/v0/requests/${r}`, { method: 'POST', body, headers: { ...bearer(token), Origin: WEB_ORIGIN } });
    const list = async (query = '') => (await (await fetch(`${t.url}/v0/requests/${device.id}${query}`, { headers: bearer(owner) })).json()) as Listing;
    const read = (r: string) => fetch(`${t.url}/v0/requests/${device.id}/${r}`, { headers: bearer(owner) });
    return { t, ...fresh, owner, device, clock, post, list, read };
}

test('a device posts requests; the owner lists them by ordinal, reads and deletes them (§7.6)', async () => {
    const s = await setup();
    const [r1, r2, r3] = [newId(), newId(), newId()];
    assert.equal((await s.post(r1, new Uint8Array([1]))).status, 201);
    assert.equal((await s.post(r2, new Uint8Array([2]))).status, 201);
    assert.equal((await s.post(r1, new Uint8Array([9]))).status, 409, 'a retry keeps the stored bytes');
    assert.equal((await s.post(r3, new Uint8Array([3]))).status, 201);
    assert.ok(await s.store.has(`requests/${s.device.id}/${ord(1)}-${r1}`));
    const all = await s.list();
    assert.deepEqual(all.requests.map((x) => [x.request_id, x.ordinal]), [[r1, 1], [r2, 2], [r3, 3]]);
    assert.match(all.requests[0]!.received_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    assert.equal(all.next, null);
    const first = await s.list('?limit=2');
    assert.deepEqual([first.requests.length, first.next], [2, 2]);
    assert.deepEqual((await s.list(`?limit=2&after=${first.next}`)).requests.map((x) => x.request_id), [r3]);
    assert.deepEqual(new Uint8Array(await (await s.read(r1)).arrayBuffer()), new Uint8Array([1]));
    assert.equal((await fetch(`${s.t.url}/v0/requests/${s.device.id}/${r1}`, { method: 'DELETE', headers: bearer(s.owner) })).status, 204);
    assert.equal((await s.read(r1)).status, 404);
    assert.equal((await s.post(newId())).status, 201);
    assert.deepEqual((await s.list()).requests.map((x) => x.ordinal), [2, 3, 4]);
    await s.t.close();
});

test('who may post, and what (§7.1, §7.6)', async () => {
    const s = await setup();
    const pending = await seedDevice(s.store);
    assert.equal((await s.post(newId(), undefined, s.owner)).status, 403);
    assert.equal((await s.post('not-an-id')).status, 400);
    assert.equal((await s.post(newId(), new Uint8Array())).status, 400);
    assert.equal(await sendOversized(`${s.t.url}/v0/requests/${newId()}`, 'POST', bearer(s.device.token), new Uint8Array(64 * 1024 + 1)), 413);
    assert.equal((await s.post(newId(), new Uint8Array(64 * 1024))).status, 201);
    assert.equal((await fetch(`${s.t.url}/v0/requests/${s.device.id}`, { headers: { ...bearer(s.owner), Origin: WEB_ORIGIN } })).status, 403);
    assert.equal((await fetch(`${s.t.url}/v0/requests/${s.device.id}`, { headers: bearer(s.device.token) })).status, 403);
    void pending;
    await s.t.close();
});

test('at most 120 requests an hour, and 1,000 waiting, per device (§7.6)', async () => {
    const s = await setup();
    for (let i = 0; i < 120; i++) assert.equal((await s.post(newId(), new Uint8Array([1]))).status, 201);
    assert.equal((await s.post(newId())).status, 429);
    s.clock.now += 3_600_000;
    assert.equal((await s.post(newId())).status, 201);
    await s.t.close();

    const { raw, store } = await freshStore();
    const device = await seedDevice(store, { active: true });
    for (let i = 1; i <= 1000; i++) await store.put(`requests/${device.id}/${ord(i)}-${newId()}`, new Uint8Array([1]));
    const full = await setup({ raw, store, device });
    assert.equal((await full.post(newId())).status, 507);
    await full.t.close();
});

test('ordinals come from what is stored, and a late copy of one request is dropped (§7.6, §7.8)', async () => {
    const { raw, store } = await freshStore();
    const device = await seedDevice(store, { active: true });
    const [a, b] = [newId(), newId()];
    await store.put(`requests/${device.id}/${ord(4)}-${a}`, new Uint8Array([1]));
    await store.put(`requests/${device.id}/${ord(7)}-${b}`, new Uint8Array([2]));
    await store.put(`requests/${device.id}/${ord(9)}-${a}`, new Uint8Array([1]));
    const s = await setup({ raw, store, device });
    assert.equal(await store.has(`requests/${device.id}/${ord(9)}-${a}`), false, 'the copy with the higher ordinal goes');
    assert.equal((await s.post(a)).status, 409);
    const c = newId();
    assert.equal((await s.post(c)).status, 201);
    assert.ok(await store.has(`requests/${device.id}/${ord(10)}-${c}`), 'above every stored ordinal');
    // A write begun before a restart lands after it: found as soon as the owner lists.
    const late = newId();
    await store.put(`requests/${device.id}/${ord(10)}-${late}`, new Uint8Array([5]));
    assert.equal((await s.read(late)).status, 404);
    assert.deepEqual((await s.list()).requests.map((x) => x.ordinal), [4, 7, 10, 10]);
    assert.equal((await s.read(late)).status, 200);
    await s.t.close();
});

test('requests not collected within 30 days are deleted; a revoked device posts nothing (§7.6, §7.4)', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const device = await seedDevice(store, { active: true });
    await store.put(`requests/${device.id}/${ord(1)}-${newId()}`, new Uint8Array([1]));
    const s = await setup({ raw, store, owner, device, now: Date.now() + 31 * DAY });
    assert.deepEqual(await store.list(`requests/${device.id}/`), []);
    assert.equal((await s.post(newId())).status, 201);
    assert.equal((await fetch(`${s.t.url}/v0/devices/${device.id}`, { method: 'DELETE', headers: bearer(owner) })).status, 204);
    assert.deepEqual(await store.list(`requests/${device.id}/`), []);
    assert.equal((await s.post(newId())).status, 401);
    assert.deepEqual((await s.list()).requests, []);
    await s.t.close();
});
