// Regressions from the review of part 6: reads and requests atomic with revocation, ordinals never given twice.
import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { newId } from '../src/encoding.ts';
import { deviceKeys } from '../src/layout.ts';
import { S3Store } from '../src/store/s3.ts';
import { mkdtemp, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { FsStore } from '../src/store/fs.ts';
import { Mutex, scoped, writeOnce, type Store } from '../src/store/store.ts';
import { bearer, freshStore, INSTANCE, seedDevice, seedOwner, slowRequest, startTestRelay, type Seeded } from './harness.ts';
import { S3_CREDENTIALS, startS3Stub, type S3Stub } from './s3-stub.ts';

const stubs: S3Stub[] = [];
after(() => Promise.all(stubs.map((s) => s.close())));

test('a device revoked while its read is in flight gets 401, not what was published after (§7.1, §7.5)', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const device = await seedDevice(store, { active: true });
    const t = await startTestRelay({ raw });
    const put = (name: string) => fetch(`${t.url}/v0/objects/${name}`, { method: 'PUT', body: new Uint8Array([1]), headers: bearer(owner) });
    await put('index/1');
    const reading = slowRequest(`${t.url}/v0/objects/index/2`, 'GET', bearer(device.token));
    const listing = slowRequest(`${t.url}/v0/objects?prefix=index/`, 'GET', bearer(device.token));
    await new Promise((r) => setTimeout(r, 50));
    assert.equal((await fetch(`${t.url}/v0/devices/${device.id}`, { method: 'DELETE', headers: bearer(owner) })).status, 204);
    await put('index/2'); // published for the remaining devices
    assert.equal((await reading.finish()).status, 401);
    assert.equal((await listing.finish()).status, 401);
    await t.close();
});

test('a request posted while a self-revocation is half done is refused, and nothing waits forever', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const device = await seedDevice(store, { active: true });
    const t = await startTestRelay({ raw });
    await store.put(deviceKeys(device.id).revocation, new Uint8Array([1])); // stored, its marker not yet written
    const answers = await Promise.all([
        fetch(`${t.url}/v0/requests/${newId()}`, { method: 'POST', body: new Uint8Array([1]), headers: bearer(device.token) }),
        fetch(`${t.url}/v0/devices/self`, { method: 'DELETE', body: new Uint8Array([1]), headers: bearer(device.token) }),
        fetch(`${t.url}/v0/objects?prefix=index/`, { headers: bearer(owner) }),
    ]);
    assert.deepEqual(answers.map((r) => r.status), [401, 401, 200]);
    assert.deepEqual(await store.list(`requests/${device.id}/`), []);
    await t.close();
});

test('a late copy of a drained request never shares an ordinal, so paging skips nothing (§7.6)', async () => {
    const stub = await startS3Stub({ ignoreIfNoneMatch: true });
    stubs.push(stub);
    const raw = new S3Store({ endpoint: stub.endpoint, bucket: stub.bucket, ...S3_CREDENTIALS });
    const owner = await seedOwner(scoped(raw, INSTANCE));
    const device: Seeded = await seedDevice(scoped(raw, INSTANCE), { active: true });
    const post = (url: string, r: string) => fetch(`${url}/v0/requests/${r}`, { method: 'POST', body: new Uint8Array([7]), headers: bearer(device.token) });
    const [a, b, c] = [newId(), newId(), newId()];

    const first = await startTestRelay({ raw });
    const drained = newId();
    assert.equal((await post(first.url, drained)).status, 201);
    await fetch(`${first.url}/v0/requests/${device.id}/${drained}`, { method: 'DELETE', headers: bearer(owner) }); // ordinal 1 is gone
    stub.hold((key) => key.includes(`-${a}`) && !key.includes('/intents/')); // the request itself, after its intent
    assert.equal((await post(first.url, a)).status, 500, 'the write of A fails, and will land later');
    await first.close();
    stub.hold(() => false);

    const second = await startTestRelay({ raw });
    const list = async (query: string) =>
        (await (await fetch(`${second.url}/v0/requests/${device.id}${query}`, { headers: bearer(owner) })).json()) as {
            requests: { request_id: string; ordinal: number }[];
            next: number | null;
        };
    assert.equal((await post(second.url, a)).status, 201, 'the device sends A again');
    for (const { request_id } of (await list('')).requests) {
        await fetch(`${second.url}/v0/requests/${device.id}/${request_id}`, { method: 'DELETE', headers: bearer(owner) });
    }
    assert.equal((await post(second.url, b)).status, 201);
    assert.equal((await post(second.url, c)).status, 201);
    stub.landHeld(); // the first A lands now, under its old ordinal

    const seen: string[] = [];
    let after = '';
    for (;;) {
        const page = await list(`?limit=1${after}`);
        seen.push(...page.requests.map((x) => x.request_id));
        if (page.next === null) break;
        after = `&after=${page.next}`;
    }
    // A's retry took A's own name back (its intent survived the restart), the owner deleted it for good, and the
    // late copy of that name reads as deleted: B and C, nothing skipped, nothing stale.
    assert.deepEqual(seen, [b, c]);
    const ordinals = (await list('')).requests.map((x) => x.ordinal);
    assert.equal(new Set(ordinals).size, ordinals.length, 'no two requests share an ordinal');
    await second.close();
});

test('rejected reads keep no state: a device at its limit stays bounded however often it calls (§7.5)', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const device = await seedDevice(store, { active: true });
    const clock = { now: Date.now() };
    const t = await startTestRelay({ raw, now: () => clock.now });
    await fetch(`${t.url}/v0/objects/index/1`, { method: 'PUT', body: new Uint8Array([1]), headers: bearer(owner) });
    const read = () => fetch(`${t.url}/v0/objects/index/1`, { headers: bearer(device.token) });
    for (let i = 0; i < 600; i++) await read();
    for (let i = 0; i < 300; i++) assert.equal((await read()).status, 429);
    clock.now += 3_600_000 + 1; // the window has passed: the 600 counted, not the 900 attempted, expire
    assert.equal((await read()).status, 200);
    await t.close();
});

test('a retried request is acknowledged with 409 only when its stored copy is there (§7.6)', async () => {
    const { raw, store } = await freshStore();
    await seedOwner(store);
    const device = await seedDevice(store, { active: true });
    const t = await startTestRelay({ raw });
    const r = newId();
    const post = (body: Uint8Array) => fetch(`${t.url}/v0/requests/${r}`, { method: 'POST', body, headers: bearer(device.token) });
    assert.equal((await post(new Uint8Array([7]))).status, 201);
    const [key] = await store.list(`requests/${device.id}/`);
    assert.equal((await post(new Uint8Array([7]))).status, 409, 'stored: the retry is told so');
    await store.delete(key!); // the stored copy is lost
    assert.equal((await post(new Uint8Array([7]))).status, 201, 'stored again, under its own ordinal');
    assert.deepEqual(await store.list(`requests/${device.id}/`), [key]);
    await store.delete(key!);
    assert.equal((await post(new Uint8Array([8]))).status, 503, 'other bytes are never taken for the lost request');
    await t.close();
});

test('a request missing from a listing stays listed, so no later one overtakes it (§7.6, §9.2)', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const device = await seedDevice(store, { active: true });
    const t = await startTestRelay({ raw });
    const [a, b] = [newId(), newId()];
    for (const r of [a, b]) {
        assert.equal((await fetch(`${t.url}/v0/requests/${r}`, { method: 'POST', body: new Uint8Array([1]), headers: bearer(device.token) })).status, 201);
    }
    const [first] = await store.list(`requests/${device.id}/`);
    await store.delete(first!); // A is missing from the bucket for now
    const listing = (await (await fetch(`${t.url}/v0/requests/${device.id}`, { headers: bearer(owner) })).json()) as { requests: { request_id: string }[] };
    assert.deepEqual(listing.requests.map((x) => x.request_id), [a, b]);
    assert.equal((await fetch(`${t.url}/v0/requests/${device.id}/${a}`, { headers: bearer(owner) })).status, 404, 'its body: the Mac backs off');
    assert.equal((await fetch(`${t.url}/v0/requests/${device.id}/${a}`, { method: 'DELETE', headers: bearer(owner) })).status, 204);
    const after = (await (await fetch(`${t.url}/v0/requests/${device.id}`, { headers: bearer(owner) })).json()) as { requests: { request_id: string }[] };
    assert.deepEqual(after.requests.map((x) => x.request_id), [b], 'gone only once the owner deleted it');
    await t.close();
});

test('a retry finding a copy whose write failed after it landed makes it durable before answering 409 (§7.6)', async () => {
    const root = await mkdtemp(join(tmpdir(), 'sprava-relay-'));
    let failNext = false;
    const syncs: string[] = [];
    const raw = new FsStore(root, {
        syncDir: async (dir) => {
            if (!/\/requests\/[^/]+$/.test(dir) || dir.includes('/intents/')) return; // a request body's folder
            syncs.push(dir);
            if (failNext) {
                failNext = false;
                throw new Error('injected sync failure');
            }
        },
    });
    const store = scoped(raw, INSTANCE);
    const owner = await seedOwner(store);
    const device = await seedDevice(store, { active: true });
    const t = await startTestRelay({ raw });
    const r = newId();
    const post = () => fetch(`${t.url}/v0/requests/${r}`, { method: 'POST', body: new Uint8Array([7]), headers: bearer(device.token) });
    failNext = true;
    assert.equal((await post()).status, 500, 'linked, but its folder sync failed');
    await fetch(`${t.url}/v0/requests/${device.id}`, { headers: bearer(owner) }); // the owner's listing finds it
    syncs.length = 0;
    assert.equal((await post()).status, 409);
    assert.ok(syncs.length > 0, 'synced before the 409');
    await t.close();
});

test('requests whose copies are missing stay listed after a restart, from their intents (§7.6, §9.2)', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const device = await seedDevice(store, { active: true });
    const first = await startTestRelay({ raw });
    const [a, b] = [newId(), newId()];
    for (const r of [a, b]) {
        assert.equal((await fetch(`${first.url}/v0/requests/${r}`, { method: 'POST', body: new Uint8Array([1]), headers: bearer(device.token) })).status, 201);
    }
    await first.close();
    const [copyOfA] = await store.list(`requests/${device.id}/`);
    await store.delete(copyOfA!); // lost while the relay was down
    const second = await startTestRelay({ raw });
    const listing = (await (await fetch(`${second.url}/v0/requests/${device.id}`, { headers: bearer(owner) })).json()) as { requests: { request_id: string }[] };
    assert.deepEqual(listing.requests.map((x) => x.request_id), [a, b]);
    assert.equal((await fetch(`${second.url}/v0/requests/${device.id}/${a}`, { headers: bearer(owner) })).status, 404);
    await second.close();
});

test('a deleted object name is dead: a later PUT is 409, and a copy a late write brings back is never served (§7.5)', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const device = await seedDevice(store, { active: true });
    const t = await startTestRelay({ raw });
    const call = (method: string, path: string, token: string, body?: Uint8Array) =>
        fetch(t.url + path, { method, headers: bearer(token), ...(body ? { body } : {}) });
    assert.equal((await call('PUT', '/v0/objects/index/1', owner, new Uint8Array([1]))).status, 204);
    assert.equal((await call('DELETE', '/v0/objects/index/1', owner)).status, 204);
    assert.equal((await call('PUT', '/v0/objects/index/1', owner, new Uint8Array([1]))).status, 410, 'gone, not other bytes');
    await store.put('objects/index/1', new Uint8Array([1])); // a late write lands
    assert.equal((await call('GET', '/v0/objects/index/1', device.token)).status, 404);
    assert.deepEqual(((await (await call('GET', '/v0/objects?prefix=index/', owner)).json()) as { names: string[] }).names, []);
    await t.close();
});

test('a request whose write failed keeps its name and bytes: a retry with other bytes is never stored (§7.6)', async () => {
    const stub = await startS3Stub({ ignoreIfNoneMatch: true });
    stubs.push(stub);
    const raw = new S3Store({ endpoint: stub.endpoint, bucket: stub.bucket, ...S3_CREDENTIALS });
    const owner = await seedOwner(scoped(raw, INSTANCE));
    const device = await seedDevice(scoped(raw, INSTANCE), { active: true });
    const t = await startTestRelay({ raw });
    const r = newId();
    const post = (body: number) => fetch(`${t.url}/v0/requests/${r}`, { method: 'POST', body: new Uint8Array([body]), headers: bearer(device.token) });
    stub.hold((key) => key.includes(`-${r}`) && !key.includes('/intents/')); // the copy, after its intent
    assert.equal((await post(1)).status, 500);
    stub.hold(() => false);
    assert.equal((await post(2)).status, 503, 'other bytes never take the name, nor another ordinal');
    stub.landHeld();
    assert.equal((await post(1)).status, 409, 'the first bytes, landed late, are the request');
    const listing = (await (await fetch(`${t.url}/v0/requests/${device.id}`, { headers: bearer(owner) })).json()) as { requests: unknown[] };
    assert.equal(listing.requests.length, 1);
    assert.deepEqual(new Uint8Array(await (await fetch(`${t.url}/v0/requests/${device.id}/${r}`, { headers: bearer(owner) })).arrayBuffer()), new Uint8Array([1]));
    await t.close();
});

test('what deletion leaves is bounded: drained requests leave no tombstones behind the floor (§7.6)', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const device = await seedDevice(store, { active: true });
    const clock = { now: Date.now() };
    const t = await startTestRelay({ raw, now: () => clock.now });
    const post = () => fetch(`${t.url}/v0/requests/${newId()}`, { method: 'POST', body: new Uint8Array([1]), headers: bearer(device.token) });
    const drain = async () => {
        const { requests } = (await (await fetch(`${t.url}/v0/requests/${device.id}`, { headers: bearer(owner) })).json()) as { requests: { request_id: string }[] };
        for (const { request_id } of requests) await fetch(`${t.url}/v0/requests/${device.id}/${request_id}`, { method: 'DELETE', headers: bearer(owner) });
    };
    for (let cycle = 0; cycle < 3; cycle++) {
        for (let i = 0; i < 5; i++) assert.equal((await post()).status, 201);
        await drain();
    }
    assert.deepEqual(await store.list(`tombstones/requests/${device.id}/`), [], 'the floor covers every drained name');
    assert.equal((await store.list(`floors/requests/${device.id}/`)).length, 1);
    assert.deepEqual(await store.list(`intents/requests/${device.id}/`), []);
    // A late copy below the floor counts as deleted, and is never listed again.
    const [floorKey] = await store.list(`floors/requests/${device.id}/`);
    const below = Number(floorKey!.split('/').at(-1)) - 1;
    await store.put(`requests/${device.id}/${String(below).padStart(16, '0')}-${newId()}`, new Uint8Array([9]));
    const { requests } = (await (await fetch(`${t.url}/v0/requests/${device.id}`, { headers: bearer(owner) })).json()) as { requests: unknown[] };
    assert.deepEqual(requests, []);
    await t.close();
});

test('a mailbox whose copies are all missing is found at start, and deleting from it is final', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const device = await seedDevice(store, { active: true });
    const first = await startTestRelay({ raw });
    const [a, b] = [newId(), newId()];
    for (const r of [a, b]) {
        assert.equal((await fetch(`${first.url}/v0/requests/${r}`, { method: 'POST', body: new Uint8Array([1]), headers: bearer(device.token) })).status, 201);
    }
    await first.close();
    for (const key of await store.list(`requests/${device.id}/`)) await store.delete(key);
    const second = await startTestRelay({ raw });
    assert.equal((await fetch(`${second.url}/v0/requests/${device.id}/${a}`, { method: 'DELETE', headers: bearer(owner) })).status, 204);
    const { requests } = (await (await fetch(`${second.url}/v0/requests/${device.id}`, { headers: bearer(owner) })).json()) as { requests: { request_id: string }[] };
    assert.deepEqual(requests.map((x) => x.request_id), [b]);
    await second.close();
});

test('reservations and their intents are bounded: blocks the floor covers go, intents with them (§7.6)', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const device = await seedDevice(store, { active: true });
    const lock = new Mutex();
    for (const block of [0, 1, 2]) {
        await lock.run(() => writeOnce(store, `ordinals/${device.id}/${String(block).padStart(16, '0')}`, Buffer.from('an earlier process')));
    }
    const t = await startTestRelay({ raw });
    for (let i = 0; i < 3; i++) {
        const r = newId();
        assert.equal((await fetch(`${t.url}/v0/requests/${r}`, { method: 'POST', body: new Uint8Array([1]), headers: bearer(device.token) })).status, 201);
        assert.equal((await fetch(`${t.url}/v0/requests/${device.id}/${r}`, { method: 'DELETE', headers: bearer(owner) })).status, 204);
    }
    assert.deepEqual(await store.list(`ordinals/${device.id}/`), [`ordinals/${device.id}/${String(3).padStart(16, '0')}`]);
    const intents = await store.list(`intents/ordinals/${device.id}/`);
    assert.equal(intents.length, 1, 'only the kept block has its intent');
    assert.ok(intents[0]!.startsWith(`intents/ordinals/${device.id}/${String(3).padStart(16, '0')}/`));
    await t.close();
});

test('on disk, retired requests leave no folders behind (§7.8)', async () => {
    const root = await mkdtemp(join(tmpdir(), 'sprava-relay-'));
    const raw = new FsStore(root);
    const store = scoped(raw, INSTANCE);
    const owner = await seedOwner(store);
    const device = await seedDevice(store, { active: true });
    const t = await startTestRelay({ raw });
    for (let i = 0; i < 10; i++) {
        const r = newId();
        await fetch(`${t.url}/v0/requests/${r}`, { method: 'POST', body: new Uint8Array([1]), headers: bearer(device.token) });
        await fetch(`${t.url}/v0/requests/${device.id}/${r}`, { method: 'DELETE', headers: bearer(owner) });
    }
    const instance = join(root, INSTANCE);
    const top = await readdir(instance);
    assert.ok(!top.includes('requests') && !top.includes('tombstones'), top.join());
    assert.ok(!(await readdir(join(instance, 'intents'))).includes('requests'), 'no folder per request under intents');
    await t.close();
});

test('a late copy of a deleted object is deleted when met, and the floor covers what is below the lowest kept (§7.5)', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const t = await startTestRelay({ raw });
    const call = (method: string, path: string, body?: Uint8Array) => fetch(t.url + path, { method, headers: bearer(owner), ...(body ? { body } : {}) });
    for (const r of [1, 2, 3]) assert.equal((await call('PUT', `/v0/objects/index/${r}`, new Uint8Array([r]))).status, 204);
    assert.equal((await call('DELETE', '/v0/objects/index/1')).status, 204);
    assert.equal((await call('DELETE', '/v0/objects/index/3')).status, 204, 'out of order: its tombstone stays above the floor');
    assert.deepEqual(await store.list('tombstones/objects/index/'), ['tombstones/objects/index/3'], 'the floor (2) covers 1');
    assert.deepEqual(await store.list('intents/objects/index/1/'), []);
    assert.equal((await call('PUT', '/v0/objects/index/1', new Uint8Array([1]))).status, 410, 'below the floor: gone');
    assert.equal((await call('PUT', '/v0/objects/index/3', new Uint8Array([3]))).status, 410, 'tombstoned above it: gone');
    assert.equal((await call('PUT', '/v0/objects/index/2', new Uint8Array([9]))).status, 409, 'other bytes than stored');
    await store.put('objects/index/1', new Uint8Array([1])); // late copies land
    await store.put('objects/index/3', new Uint8Array([3]));
    assert.deepEqual(((await (await call('GET', '/v0/objects?prefix=index/')).json()) as { names: string[] }).names, ['index/2']);
    assert.equal(await store.has('objects/index/1'), false, 'met, and deleted');
    assert.equal(await store.has('objects/index/3'), false);
    await t.close();
});

test('a floor never covers a live object: a view still kept below a deleted one, or one whose copy is missing, stays (§7.5)', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const t = await startTestRelay({ raw });
    const id = newId();
    const call = (method: string, n: number, body?: Uint8Array) =>
        fetch(`${t.url}/v0/objects/views/${id}/${n}`, { method, headers: bearer(owner), ...(body ? { body } : {}) });
    for (const n of [1, 2, 3]) assert.equal((await call('PUT', n, new Uint8Array([n]))).status, 204);
    assert.equal((await call('DELETE', 2)).status, 204, 'a later version deleted first');
    assert.equal((await call('GET', 1)).status, 200, 'the earlier one is still live');
    const [copy] = await store.list(`objects/views/${id}/1`);
    await store.delete(copy!); // the store loses view 1 for a while
    assert.equal((await call('DELETE', 3)).status, 204, 'compaction runs');
    const floors = (await store.list(`floors/objects/views/${id}/`)).map((key) => Number(key.split('/').at(-1)));
    assert.ok(floors.every((f) => f <= 1), 'a missing copy is not a deletion: no floor above 1');
    await store.put(`objects/views/${id}/1`, new Uint8Array([1])); // its copy is back
    assert.equal((await call('GET', 1)).status, 200);
    assert.equal((await call('PUT', 1, new Uint8Array([1]))).status, 204, 'a retry of the same bytes is fine, not gone');
    await t.close();
});

test('a floor read that finishes late never lowers a floor raised meanwhile (§7.5)', async () => {
    const { raw: fs } = await freshStore();
    let gate: Promise<void> | null = null;
    let open: () => void = () => {};
    const raw: Store = {
        get: (k) => fs.get(k),
        has: (k) => fs.has(k),
        put: (k, b) => fs.put(k, b),
        putIfAbsent: (k, b) => fs.putIfAbsent(k, b),
        sync: (k) => fs.sync(k),
        delete: (k) => fs.delete(k),
        listTimes: (p) => fs.listTimes(p),
        list: async (p) => {
            const keys = await fs.list(p);
            if (p.endsWith('/floors/objects/index/') && gate !== null) {
                const wait = gate;
                gate = null; // only the first read is held
                await wait;
            }
            return keys;
        },
    };
    const owner = await seedOwner(scoped(raw, INSTANCE));
    const device = await seedDevice(scoped(raw, INSTANCE), { active: true });
    const t = await startTestRelay({ raw });
    const call = (method: string, path: string, token: string, body?: Uint8Array) =>
        fetch(t.url + path, { method, headers: bearer(token), ...(body ? { body } : {}) });
    for (const n of [1, 2]) assert.equal((await call('PUT', `/v0/objects/index/${n}`, owner, new Uint8Array([n]))).status, 204);
    gate = new Promise((r) => (open = r));
    const reading = call('GET', '/v0/objects/index/1', device.token); // its floor read is held
    await new Promise((r) => setTimeout(r, 50));
    assert.equal((await call('DELETE', '/v0/objects/index/1', owner)).status, 204, 'raises the floor to 2');
    // Many other prefixes are asked about meanwhile; nothing of what is known about index/ is dropped.
    for (let i = 0; i < 1100; i++) await call('GET', `/v0/objects/views/${newId()}/1`, owner);
    open();
    assert.equal((await reading).status, 404, 'the late read sees the raised floor');
    await scoped(raw, INSTANCE).put('objects/index/1', new Uint8Array([1])); // a late copy lands
    assert.equal((await call('GET', '/v0/objects/index/1', device.token)).status, 404);
    await t.close();
});

test('an upload that failed keeps its name live until the owner deletes it; the floor never passes it alone (§7.5)', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const clock = { now: Date.now() };
    const t = await startTestRelay({ raw, now: () => clock.now });
    const call = (method: string, n: number, body?: Uint8Array) =>
        fetch(`${t.url}/v0/objects/index/${n}`, { method, headers: bearer(owner), ...(body ? { body } : {}) });
    assert.equal((await call('PUT', 1, new Uint8Array([1]))).status, 204);
    const digest = '0'.repeat(64);
    await store.put(`intents/objects/index/2/${digest}`, new Uint8Array()); // an upload whose copy never landed
    assert.equal((await call('PUT', 3, new Uint8Array([3]))).status, 204);
    clock.now += 30 * 24 * 3_600_000;
    assert.equal((await call('DELETE', 1)).status, 204);
    assert.deepEqual(await store.list('floors/objects/index/'), ['floors/objects/index/0000000000000002'], 'however old');
    assert.deepEqual(await store.list('intents/objects/index/2/'), [`intents/objects/index/2/${digest}`]);
    assert.equal((await call('DELETE', 2)).status, 204, 'the owner deletes it');
    assert.deepEqual(await store.list('floors/objects/index/'), ['floors/objects/index/0000000000000003']);
    assert.deepEqual(await store.list('intents/objects/index/2/'), []);
    await t.close();
});

test('the highest valid revision keeps its deletion across a restart (§3, §7.5)', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const top = '9007199254740991';
    const first = await startTestRelay({ raw });
    const call = (url: string, method: string, body?: Uint8Array) =>
        fetch(`${url}/v0/objects/index/${top}`, { method, headers: bearer(owner), ...(body ? { body } : {}) });
    assert.equal((await call(first.url, 'PUT', new Uint8Array([1]))).status, 204);
    assert.equal((await call(first.url, 'DELETE')).status, 204);
    await first.close();
    await store.put(`objects/index/${top}`, new Uint8Array([1])); // a late copy lands
    const second = await startTestRelay({ raw });
    assert.equal((await call(second.url, 'GET')).status, 404);
    assert.equal((await call(second.url, 'PUT', new Uint8Array([1]))).status, 410);
    await second.close();
});
