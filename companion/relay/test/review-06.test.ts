// Regressions from the review of part 6: reads and requests atomic with revocation, ordinals never given twice.
import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { newId } from '../src/encoding.ts';
import { deviceKeys } from '../src/layout.ts';
import { S3Store } from '../src/store/s3.ts';
import { scoped } from '../src/store/store.ts';
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
    assert.deepEqual(seen, [a, b, c], 'A again (the Mac discards it as a duplicate), then B and C');
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
