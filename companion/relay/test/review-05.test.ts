// Regressions from the review of part 5: pairing steps serialized with revocation and expiry, and joins whose
// late writes replace nothing.
import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { encodeB64, newId, tokenHash } from '../src/encoding.ts';
import { deviceKeys } from '../src/layout.ts';
import { S3Store } from '../src/store/s3.ts';
import { scoped, type Store } from '../src/store/store.ts';
import { bearer, freshStore, INSTANCE, seedOwner, slowRequest, startTestRelay, WEB_ORIGIN, type TestRelay } from './harness.ts';
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
