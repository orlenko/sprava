// Regressions from the review of part 5: pairing steps serialized with revocation and expiry, and joins whose
// late writes replace nothing.
import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { encodeB64, newId, tokenHash } from '../src/encoding.ts';
import { Devices } from '../src/devices.ts';
import { deviceKeys } from '../src/layout.ts';
import { pairings } from '../src/pairings.ts';
import { S3Store } from '../src/store/s3.ts';
import { scoped, type Store } from '../src/store/store.ts';
import { bearer, freshStore, INSTANCE, seedDevice, seedOwner, slowRequest, startTestRelay, WEB_ORIGIN, type TestRelay } from './harness.ts';
import { S3_CREDENTIALS, startS3Stub, type S3Stub } from './s3-stub.ts';

const A = encodeB64(new Uint8Array(32).fill(1));
const B = encodeB64(new Uint8Array(32).fill(2));
const HELLO = encodeB64(new Uint8Array(760).fill(3));
const KEY = new Uint8Array(395).fill(4);
const stubs: S3Stub[] = [];
after(() => Promise.all(stubs.map((s) => s.close())));

function client(t: TestRelay, owner: string) {
    const call = (method: string, path: string, token: string | null, body?: unknown) =>
        fetch(t.url + path, {
            method,
            headers: token ? bearer(token) : {},
            ...(body === undefined ? {} : { body: body instanceof Uint8Array ? body : JSON.stringify(body) }),
        });
    return {
        call,
        open: async () => (await (await call('POST', '/v0/pairings', owner, { owner_public_key: A, device_id: newId() })).json()) as { pairing_id: string; secret: string },
        join: (p: string, secret: string) => call('POST', `/v0/pairings/${p}/join`, null, { secret, device_public_key: B, hello: HELLO }),
    };
}

test('a revoked device cannot fetch or acknowledge its key, whenever its body arrives (§7.3)', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const t = await startTestRelay({ raw });
    const c = client(t, owner);
    const { pairing_id: p, secret } = await c.open();
    const { device_id: d, device_token: token } = (await (await c.join(p, secret)).json()) as { device_id: string; device_token: string };
    assert.equal((await c.call('PUT', `/v0/pairings/${p}/key`, owner, KEY)).status, 204);
    const fetching = slowRequest(`${t.url}/v0/pairings/${p}/key`, 'GET', { ...bearer(token), Origin: WEB_ORIGIN });
    const acking = slowRequest(`${t.url}/v0/pairings/${p}/ack`, 'POST', bearer(token));
    await new Promise((r) => setTimeout(r, 50));
    assert.equal((await c.call('DELETE', `/v0/devices/${d}`, owner)).status, 204);
    assert.equal((await fetching.finish()).status, 401);
    assert.equal((await acking.finish()).status, 401);
    assert.equal(await store.has(`pairings/${p}/ack`), false);
    await t.close();
});

test('installing a key while a self-revocation is half done neither deadlocks nor activates the device', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const t = await startTestRelay({ raw });
    const c = client(t, owner);
    const { pairing_id: p, secret } = await c.open();
    const { device_id: d } = (await (await c.join(p, secret)).json()) as { device_id: string };
    await store.put(deviceKeys(d).revocation, new Uint8Array([1])); // stored, its marker not yet written
    assert.equal((await c.call('PUT', `/v0/pairings/${p}/key`, owner, KEY)).status, 409);
    assert.ok(await store.has(deviceKeys(d).revoked), 'the marker is repaired under the lock already held');
    assert.equal(await store.has(deviceKeys(d).active), false);
    assert.equal((await c.call('GET', '/v0/devices', owner)).status, 200, 'the relay still answers');
    await t.close();
});

/** A store whose writes of `active` markers take a while, so an expiry can be attempted in the middle. */
function slowActivation(store: Store): Store {
    return {
        get: (k) => store.get(k),
        has: (k) => store.has(k),
        list: (p) => store.list(p),
        listTimes: (p) => store.listTimes(p),
        sync: (k) => store.sync(k),
        put: (k, b) => store.put(k, b),
        delete: (k) => store.delete(k),
        putIfAbsent: async (k, b) => {
            if (k.endsWith('/active')) await new Promise((r) => setTimeout(r, 150));
            return store.putIfAbsent(k, b);
        },
    };
}

test('expiry waits for an activation in progress and keeps the device it activated (§7.3)', async () => {
    const { raw: fs } = await freshStore();
    const raw = slowActivation(fs);
    const scopedStore = scoped(raw, INSTANCE);
    const owner = await seedOwner(scopedStore);
    const clock = { now: Date.UTC(2026, 9, 8, 12, 0, 0) };
    const t = await startTestRelay({ raw, now: () => clock.now });
    const c = client(t, owner);
    const { pairing_id: p, secret } = await c.open();
    const { device_id: d, device_token: token } = (await (await c.join(p, secret)).json()) as { device_id: string; device_token: string };
    clock.now += 10 * 60_000 - 1;
    const keyed = c.call('PUT', `/v0/pairings/${p}/key`, owner, KEY);
    await new Promise((r) => setTimeout(r, 50));
    clock.now += 2; // now past the expiry, while the activation is being written
    const expiring = c.call('GET', `/v0/pairings/${p}`, owner);
    assert.equal((await keyed).status, 204);
    assert.equal((await expiring).status, 404);
    assert.ok(await scopedStore.has(deviceKeys(d).record), 'the activated device stays');
    assert.equal((await fetch(`${t.url}/v0/devices/self`, { method: 'DELETE', body: new Uint8Array([1]), headers: bearer(token) })).status, 204);
    await t.close();
});

test('a join whose writes land after a restart replaces nothing: the token returned later keeps working', async () => {
    const stub = await startS3Stub({ ignoreIfNoneMatch: true });
    stubs.push(stub);
    const raw = new S3Store({ endpoint: stub.endpoint, bucket: stub.bucket, ...S3_CREDENTIALS });
    const owner = await seedOwner(scoped(raw, INSTANCE));
    const first = await startTestRelay({ raw });
    const { pairing_id: p, secret } = await client(first, owner).open();
    stub.hold((key) => key.endsWith('/record.json') || key.endsWith('/joined.json'));
    assert.equal((await client(first, owner).join(p, secret)).status, 500, 'the first join fails part-way');
    await first.close();
    stub.hold(() => false); // hold nothing more; what is held still lands later

    const second = await startTestRelay({ raw });
    const joined = await client(second, owner).join(p, secret);
    assert.equal(joined.status, 200);
    const { device_id: d, device_token: token } = (await joined.json()) as { device_id: string; device_token: string };
    stub.landHeld(); // the first join's writes land now
    await second.close();

    const third = await startTestRelay({ raw });
    assert.equal((await client(third, owner).call('GET', `/v0/pairings/${p}/key`, token)).status, 404, 'still authenticated: no key yet');
    assert.equal((await client(third, owner).call('PUT', `/v0/pairings/${p}/key`, owner, KEY)).status, 204);
    assert.deepEqual(new Uint8Array(await (await client(third, owner).call('GET', `/v0/pairings/${p}/key`, token)).arrayBuffer()), KEY);
    // The failed join's token marker had no record beside it at the second start, which deleted it (§7.8 rule 4).
    assert.deepEqual(await raw.list(`${INSTANCE}/${deviceKeys(d).tokens}`), [`${INSTANCE}/${deviceKeys(d).token(tokenHash(token))}`]);
    await third.close();
});

test('a join whose transcript may still land consumes the pairing: no second transcript is accepted (§7.3)', async () => {
    const stub = await startS3Stub({ ignoreIfNoneMatch: true });
    stubs.push(stub);
    const raw = new S3Store({ endpoint: stub.endpoint, bucket: stub.bucket, ...S3_CREDENTIALS });
    const owner = await seedOwner(scoped(raw, INSTANCE));
    const first = await startTestRelay({ raw });
    const { pairing_id: p, secret } = await client(first, owner).open();
    stub.hold((key) => key.endsWith(`/pairings/${p}/joined.json`)); // the transcript, after its intent
    assert.equal((await client(first, owner).join(p, secret)).status, 500);
    await first.close();
    stub.hold(() => false);

    const second = await startTestRelay({ raw });
    const res = await fetch(`${second.url}/v0/pairings/${p}/join`, {
        method: 'POST',
        body: JSON.stringify({ secret, device_public_key: encodeB64(new Uint8Array(32).fill(9)), hello: HELLO }),
    });
    assert.equal(res.status, 409);
    stub.landHeld();
    const seen = (await (await client(second, owner).call('GET', `/v0/pairings/${p}`, owner)).json()) as { device_public_key: string };
    assert.equal(seen.device_public_key, B, 'the transcript is the first join’s, and never changes');
    await second.close();
});

test('a join beyond 20 devices is refused, however many pairings were opened before (§7.3)', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    for (let i = 0; i < 19; i++) await seedDevice(store, { active: true });
    const t = await startTestRelay({ raw });
    const c = client(t, owner);
    const opened = [await c.open(), await c.open(), await c.open()];
    const statuses = [];
    for (const { pairing_id, secret } of opened) statuses.push((await c.join(pairing_id, secret)).status);
    assert.deepEqual(statuses, [200, 507, 507]);
    await t.close();
});

test('a deletion cut short leaves the pairing deleted for good, and its retry finishes it', async () => {
    const { raw: fs } = await freshStore();
    let failOnce = true;
    const raw: Store = {
        get: (k) => fs.get(k),
        has: (k) => fs.has(k),
        put: (k, b) => fs.put(k, b),
        putIfAbsent: (k, b) => fs.putIfAbsent(k, b),
        sync: (k) => fs.sync(k),
        list: (p) => fs.list(p),
        listTimes: (p) => fs.listTimes(p),
        delete: async (k) => {
            if (failOnce && k.endsWith('/joined.json')) {
                failOnce = false;
                throw new Error('injected delete failure');
            }
            return fs.delete(k);
        },
    };
    const owner = await seedOwner(scoped(raw, INSTANCE));
    const t = await startTestRelay({ raw });
    const c = client(t, owner);
    const { pairing_id: p, secret } = await c.open();
    assert.equal((await c.join(p, secret)).status, 200);
    assert.equal((await c.call('PUT', `/v0/pairings/${p}/key`, owner, KEY)).status, 204, 'the device is active');
    assert.equal((await c.call('DELETE', `/v0/pairings/${p}`, owner)).status, 500);
    // The QR code's secret cannot open the pairing again, before or after a restart.
    const other = { secret, device_public_key: encodeB64(new Uint8Array(32).fill(9)), hello: HELLO };
    assert.equal((await c.call('POST', `/v0/pairings/${p}/join`, null, other)).status, 404);
    assert.equal((await c.call('GET', `/v0/pairings/${p}`, owner)).status, 404);
    await t.close();
    const again = await startTestRelay({ raw });
    const c2 = client(again, owner);
    assert.equal((await c2.call('POST', `/v0/pairings/${p}/join`, null, other)).status, 404);
    assert.equal((await c2.call('DELETE', `/v0/pairings/${p}`, owner)).status, 204);
    assert.deepEqual(await scoped(raw, INSTANCE).list(`pairings/${p}/`), [`pairings/${p}/deleted`], 'only its tombstone stays');
    await again.close();
});

test('a flood of public joins is bounded: few admitted, a short queue, 503 beyond, and revocation gets through', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const t = await startTestRelay({ raw });
    const c = client(t, owner);
    const d = newId();
    const opened = (await (await c.call('POST', '/v0/pairings', owner, { owner_public_key: A, device_id: d })).json()) as { pairing_id: string; secret: string };
    let release: () => void = () => {};
    const held = t.relay.deviceLocks.run(d, () => new Promise<void>((r) => (release = r))); // slow storage holds the lock
    const gone = new AbortController();
    const send = (signal?: AbortSignal) =>
        fetch(`${t.url}/v0/pairings/${opened.pairing_id}/join`, {
            method: 'POST',
            body: JSON.stringify({ secret: opened.secret, device_public_key: B, hello: HELLO }),
            ...(signal ? { signal } : {}),
        })
            .then((r) => r.status)
            .catch(() => 0);
    const leaving = Array.from({ length: 4 }, () => send(gone.signal));
    const flood = Array.from({ length: 30 }, () => send());
    await new Promise((r) => setTimeout(r, 100));
    gone.abort();
    const revoking = c.call('DELETE', `/v0/devices/${d}`, owner);
    await new Promise((r) => setTimeout(r, 50));
    release();
    await held;
    assert.equal((await revoking).status, 204, 'the owner was never stuck behind the flood');
    const statuses = await Promise.all(flood);
    assert.ok(statuses.filter((s) => s === 503).length >= 22, statuses.join());
    assert.ok(statuses.filter((s) => s !== 503).length <= 8, statuses.join());
    await Promise.all(leaving);
    await t.close();
});

test('a pending device deleted with its pairing stays deleted when its activation lands late, across a restart (§7.3)', async () => {
    const stub = await startS3Stub({ ignoreIfNoneMatch: true });
    stubs.push(stub);
    const raw = new S3Store({ endpoint: stub.endpoint, bucket: stub.bucket, ...S3_CREDENTIALS });
    const owner = await seedOwner(scoped(raw, INSTANCE));
    const first = await startTestRelay({ raw });
    const c = client(first, owner);
    const { pairing_id: p, secret } = await c.open();
    const { device_id: d, device_token: token } = (await (await c.join(p, secret)).json()) as { device_id: string; device_token: string };
    stub.hold((key) => key.endsWith(`/devices/${d}/active`)); // the activation, after its intent
    assert.equal((await c.call('PUT', `/v0/pairings/${p}/key`, owner, KEY)).status, 500);
    stub.hold(() => false);
    assert.equal((await c.call('DELETE', `/v0/pairings/${p}`, owner)).status, 204);
    stub.landHeld(); // the activation lands after the deletion
    await first.close();
    const second = await startTestRelay({ raw });
    const self = await fetch(`${second.url}/v0/devices/self`, { method: 'DELETE', body: new Uint8Array([1]), headers: bearer(token) });
    assert.equal(self.status, 401, 'its token never works again');
    assert.ok(await scoped(raw, INSTANCE).has(deviceKeys(d).revoked));
    await second.close();
});

test('a join retried after its record was written is not counted against itself at 20 devices (§7.3)', async () => {
    const stub = await startS3Stub({ ignoreIfNoneMatch: true });
    stubs.push(stub);
    const raw = new S3Store({ endpoint: stub.endpoint, bucket: stub.bucket, ...S3_CREDENTIALS });
    const store = scoped(raw, INSTANCE);
    const owner = await seedOwner(store);
    for (let i = 0; i < 19; i++) await seedDevice(store, { active: true });
    const t = await startTestRelay({ raw });
    const c = client(t, owner);
    const { pairing_id: p, secret } = await c.open();
    stub.hold((key) => key.includes(`/intents/pairings/${p}/joined.json/`)); // the transcript's intent fails
    assert.equal((await c.join(p, secret)).status, 500, 'its token and record are written, its transcript is not');
    stub.hold(() => false);
    const retry = await c.join(p, secret);
    assert.equal(retry.status, 200, 'the joining device is not counted against itself');
    await t.close();
});

test('wrong secrets sent after a join are 409 and never delete the pairing or its device (§7.3)', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const t = await startTestRelay({ raw });
    const c = client(t, owner);
    const { pairing_id: p, secret } = await c.open();
    const joined = (await (await c.join(p, secret)).json()) as { device_id: string; device_token: string };
    for (let i = 0; i < 6; i++) assert.equal((await c.join(p, 'AAAAAAAAAAAAAAAAAAAAAA')).status, 409, 'a repeat join, whatever its secret');
    assert.equal((await c.join(p, secret)).status, 409);
    assert.equal((await c.call('GET', `/v0/pairings/${p}`, owner)).status, 200, 'the pairing stays');
    assert.equal((await c.call('PUT', `/v0/pairings/${p}/key`, owner, KEY)).status, 204, 'and its device can still be activated');
    assert.equal((await c.call('GET', `/v0/pairings/${p}/key`, joined.device_token)).status, 200);
    await t.close();
});

test('a deleted pairing costs no listing of its own: not when pairings are read, not in the sweep', async () => {
    const { raw: fs } = await freshStore();
    const listed: string[] = [];
    // Every call passes through; listings are recorded.
    const raw = new Proxy(fs, {
        get(target, name: keyof Store) {
            if (name === 'list') return (prefix: string) => (listed.push(prefix), target.list(prefix));
            const value = target[name];
            return typeof value === 'function' ? value.bind(target) : value;
        },
    });
    const owner = await seedOwner(scoped(raw, INSTANCE));
    const t = await startTestRelay({ raw });
    const c = client(t, owner);
    const { pairing_id: p } = await c.open();
    assert.equal((await c.call('DELETE', `/v0/pairings/${p}`, owner)).status, 204);
    assert.deepEqual(await scoped(raw, INSTANCE).list(`pairings/${p}/`), [`pairings/${p}/deleted`]);
    listed.length = 0;
    await c.open(); // reads every pairing, twice
    await pairings(t.relay, new Devices(t.relay)).sweep();
    assert.deepEqual(listed.filter((prefix) => prefix.includes(`/pairings/${p}/`)), []);
    await t.close();
});
