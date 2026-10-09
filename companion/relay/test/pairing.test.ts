import assert from 'node:assert/strict';
import { test } from 'node:test';
import { encodeB64, newId, newToken } from '../src/encoding.ts';
import { deviceKeys, pairingKeys } from '../src/layout.ts';
import { bearer, freshStore, seedDevice, seedOwner, startTestRelay, WEB_ORIGIN, type TestRelay } from './harness.ts';

const A = encodeB64(new Uint8Array(32).fill(1));
const B = encodeB64(new Uint8Array(32).fill(2));
const HELLO = encodeB64(new Uint8Array(760).fill(3));
const KEY = new Uint8Array(395).fill(4);

async function setup(clock = { now: Date.UTC(2026, 9, 8, 12, 0, 0) }) {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const t = await startTestRelay({ raw, now: () => clock.now });
    const call = (method: string, path: string, token: string | null, body?: unknown, headers: Record<string, string> = {}) =>
        fetch(t.url + path, {
            method,
            headers: { ...(token ? bearer(token) : {}), ...headers },
            ...(body === undefined ? {} : { body: body instanceof Uint8Array ? body : JSON.stringify(body) }),
        });
    const open = async (d = newId()) => {
        const res = await call('POST', '/v0/pairings', owner, { owner_public_key: A, device_id: d });
        assert.equal(res.status, 200);
        return { d, ...((await res.json()) as { pairing_id: string; secret: string; expires_at: string }) };
    };
    const join = (p: string, secret: string) => call('POST', `/v0/pairings/${p}/join`, null, { secret, device_public_key: B, hello: HELLO }, { Origin: WEB_ORIGIN });
    return { t, store, owner, call, open, join, clock };
}

const state = async (s: { call: Function; owner: string }, p: string) => ((await (await s.call('GET', `/v0/pairings/${p}`, s.owner)).json()) as { state: string }).state;

test('a pairing from open to acknowledged (§7.3)', async () => {
    const s = await setup();
    const { d, pairing_id: p, secret, expires_at } = await s.open();
    assert.equal(expires_at, '2026-10-08T12:10:00Z');
    assert.deepEqual(await (await s.call('GET', `/v0/pairings/${p}`, s.owner)).json(), { state: 'open', device_id: null, device_public_key: null, hello: null });

    const joined = await s.join(p, secret);
    assert.equal(joined.status, 200);
    assert.equal(joined.headers.get('access-control-allow-origin'), WEB_ORIGIN);
    const { device_id, device_token } = (await joined.json()) as { device_id: string; device_token: string };
    assert.equal(device_id, d);
    assert.deepEqual(await (await s.call('GET', `/v0/pairings/${p}`, s.owner)).json(), { state: 'joined', device_id: d, device_public_key: B, hello: HELLO });
    assert.equal((await s.join(p, secret)).status, 409, 'a join works once');

    assert.equal((await s.call('GET', `/v0/pairings/${p}/key`, device_token)).status, 404, 'no key yet');
    assert.equal((await s.call('POST', `/v0/pairings/${p}/ack`, device_token)).status, 409);
    assert.equal((await s.call('DELETE', '/v0/devices/self', device_token, new Uint8Array([1]))).status, 403, 'a pending device can do nothing else');

    assert.equal((await s.call('PUT', `/v0/pairings/${p}/key`, s.owner, KEY)).status, 204);
    assert.ok(await s.store.has(deviceKeys(d).active));
    assert.equal(await state(s, p), 'keyed');
    assert.equal((await s.call('PUT', `/v0/pairings/${p}/key`, s.owner, KEY)).status, 204, 'a retry');
    assert.equal((await s.call('PUT', `/v0/pairings/${p}/key`, s.owner, new Uint8Array(395).fill(5))).status, 409, 'other bytes');
    const key = await s.call('GET', `/v0/pairings/${p}/key`, device_token, undefined, { Origin: WEB_ORIGIN });
    assert.deepEqual(new Uint8Array(await key.arrayBuffer()), KEY);

    assert.equal((await s.call('POST', `/v0/pairings/${p}/ack`, device_token)).status, 204);
    assert.equal((await s.call('POST', `/v0/pairings/${p}/ack`, device_token)).status, 204, 'repeating it is harmless');
    assert.equal(await state(s, p), 'acknowledged');
    assert.equal(await s.store.get(pairingKeys(p).key), null);
    assert.ok(await s.store.has(pairingKeys(p).keySha));
    assert.equal((await s.call('GET', `/v0/pairings/${p}/key`, device_token)).status, 404);
    assert.equal((await s.call('PUT', `/v0/pairings/${p}/key`, s.owner, KEY)).status, 204, 'a late retry after the ack');
    assert.equal(await s.store.get(pairingKeys(p).key), null, 'does not bring the payload back');
    const listed = (await (await s.call('GET', '/v0/devices', s.owner)).json()) as { devices: { device_id: string; state: string }[] };
    assert.deepEqual(listed.devices.map((x) => [x.device_id, x.state]), [[d, 'active']]);
    await s.t.close();
});

test('a wrong secret is 403, and the fifth deletes the pairing (§7.3)', async () => {
    const s = await setup();
    const { pairing_id: p, secret } = await s.open();
    const wrong = encodeB64(new Uint8Array(16));
    for (let i = 0; i < 5; i++) assert.equal((await s.join(p, wrong)).status, 403);
    assert.equal((await s.join(p, secret)).status, 404);
    assert.deepEqual(await s.store.list(`pairings/${p}/`), [`pairings/${p}/deleted`], 'only its tombstone stays');
    await s.t.close();
});

test('device ids are never reused, and the limits are 3 open pairings and 20 devices (§7.3)', async () => {
    const s = await setup();
    const first = await s.open();
    const again = await s.call('POST', '/v0/pairings', s.owner, { owner_public_key: A, device_id: first.d });
    assert.equal(again.status, 409);
    await s.open();
    await s.open();
    assert.equal((await s.call('POST', '/v0/pairings', s.owner, { owner_public_key: A, device_id: newId() })).status, 507);
    for (const bad of [{ owner_public_key: A }, { owner_public_key: encodeB64(new Uint8Array(31)), device_id: newId() }, { owner_public_key: A, device_id: 'x' }]) {
        assert.equal((await s.call('POST', '/v0/pairings', s.owner, bad)).status, 400);
    }
    assert.equal((await s.call('POST', '/v0/pairings', s.owner, { owner_public_key: A, device_id: newId() }, { Origin: WEB_ORIGIN })).status, 403);
    await s.t.close();

    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    for (let i = 0; i < 20; i++) await seedDevice(store, { active: true });
    const orphan = await seedDevice(store);
    const t = await startTestRelay({ raw });
    for (const key of Object.values(pairingKeys(orphan.pairing))) await store.delete(key); // after the start's cleanup
    const res = await fetch(`${t.url}/v0/pairings`, { method: 'POST', headers: bearer(owner), body: JSON.stringify({ owner_public_key: A, device_id: newId() }) });
    assert.equal(res.status, 507);
    assert.equal(await store.has(deviceKeys(orphan.id).record), false, 'an orphaned pending record never holds a slot (§7.8 rule 5)');
    await t.close();
});

test('expiry: a pairing goes after 10 minutes, with its device only if that is still pending (§7.3)', async () => {
    const s = await setup();
    const pendingPairing = await s.open();
    const pending = (await (await s.join(pendingPairing.pairing_id, pendingPairing.secret)).json()) as { device_token: string };
    const activePairing = await s.open();
    const active = (await (await s.join(activePairing.pairing_id, activePairing.secret)).json()) as { device_token: string };
    assert.equal((await s.call('PUT', `/v0/pairings/${activePairing.pairing_id}/key`, s.owner, KEY)).status, 204);
    s.clock.now += 10 * 60_000;
    assert.equal((await s.call('GET', `/v0/pairings/${pendingPairing.pairing_id}`, s.owner)).status, 404);
    assert.equal((await s.call('GET', `/v0/pairings/${activePairing.pairing_id}/key`, active.device_token)).status, 404);
    assert.equal(await s.store.has(deviceKeys(pendingPairing.d).record), false);
    assert.equal(await s.store.has(deviceKeys(activePairing.d).record), true);
    assert.equal((await s.call('GET', `/v0/pairings/${pendingPairing.pairing_id}/key`, pending.device_token)).status, 401);
    assert.equal((await s.call('DELETE', '/v0/devices/self', active.device_token, new Uint8Array([1]))).status, 204);
    await s.t.close();
});

test('the owner deletes a pairing, and its device if pending; a device uses only its own pairing (§7.3)', async () => {
    const s = await setup();
    const one = await s.open();
    const two = await s.open();
    const device = (await (await s.join(one.pairing_id, one.secret)).json()) as { device_token: string };
    assert.equal((await s.call('GET', `/v0/pairings/${two.pairing_id}/key`, device.device_token)).status, 403);
    assert.equal((await s.call('GET', `/v0/pairings/${one.pairing_id}`, device.device_token)).status, 403);
    assert.equal((await s.call('DELETE', `/v0/pairings/${one.pairing_id}`, s.owner)).status, 204);
    assert.equal((await s.call('DELETE', `/v0/pairings/${one.pairing_id}`, s.owner)).status, 204);
    assert.equal((await s.call('GET', `/v0/pairings/${one.pairing_id}/key`, device.device_token)).status, 401);
    assert.deepEqual(await s.store.list(`devices/${one.d}/`), []);
    assert.equal((await s.call('PUT', `/v0/pairings/${two.pairing_id}/key`, s.owner, KEY)).status, 409, 'nobody joined it');
    assert.equal((await s.call('GET', `/v0/pairings/${newToken().slice(0, 22)}`, s.owner)).status, 404);
    await s.t.close();
});

test('a revoked device cannot be keyed', async () => {
    const s = await setup();
    const { d, pairing_id: p, secret } = await s.open();
    await s.join(p, secret);
    assert.equal((await s.call('DELETE', `/v0/devices/${d}`, s.owner)).status, 204);
    assert.equal((await s.call('PUT', `/v0/pairings/${p}/key`, s.owner, KEY)).status, 409);
    assert.equal(await s.store.has(deviceKeys(d).active), false);
    await s.t.close();
});
