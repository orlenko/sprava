import assert from 'node:assert/strict';
import { test } from 'node:test';
import { newId } from '../src/encoding.ts';
import { deviceKeys } from '../src/layout.ts';
import { bearer, freshStore, seedDevice, seedOwner, startTestRelay, WEB_ORIGIN } from './harness.ts';

async function setup(now = Date.UTC(2026, 9, 8, 7, 30, 0)) {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const active = await seedDevice(store, { active: true, now });
    const pending = await seedDevice(store, { now });
    await store.put(`requests/${active.id}/0000000000000001-${newId()}`, new Uint8Array([1]));
    await store.put(`objects/devices/${active.id}/keys/1`, new Uint8Array([1]));
    const t = await startTestRelay({ raw, now: () => now });
    return { t, store, owner, active, pending };
}

const self = (url: string, token: string, body: Uint8Array = new Uint8Array([9, 9]), headers: Record<string, string> = {}) =>
    fetch(`${url}/v0/devices/self`, { method: 'DELETE', body, headers: { ...bearer(token), ...headers } });

test('the owner lists devices by id, with their derived state (§7.4)', async () => {
    const { t, owner, active, pending } = await setup();
    await self(t.url, active.token, undefined, { Origin: WEB_ORIGIN }); // to be seen this hour, then revoked
    const res = await fetch(`${t.url}/v0/devices`, { headers: bearer(owner) });
    const { devices, next } = (await res.json()) as { devices: Record<string, unknown>[]; next: unknown };
    assert.equal(next, null);
    const byId = Object.fromEntries(devices.map((d) => [d.device_id, d]));
    assert.deepEqual(Object.keys(byId), [active.id, pending.id].sort());
    assert.deepEqual(byId[active.id], { device_id: active.id, state: 'revoked', paired_at: '2026-10-08T07:30:00Z', last_seen: '2026-10-08T07:00:00Z' });
    assert.deepEqual(byId[pending.id], { device_id: pending.id, state: 'pending', paired_at: null, last_seen: null });
    await t.close();
});

test('the device list pages by id (§7.4)', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const ids = [];
    for (let i = 0; i < 5; i++) ids.push((await seedDevice(store, { active: true })).id);
    ids.sort();
    const t = await startTestRelay({ raw });
    const page = async (query: string) => (await (await fetch(`${t.url}/v0/devices${query}`, { headers: bearer(owner) })).json()) as { devices: { device_id: string }[]; next: string | null };
    const first = await page('?limit=2');
    assert.deepEqual(first.devices.map((d) => d.device_id), ids.slice(0, 2));
    assert.equal(first.next, ids[1]);
    const last = await page(`?limit=3&after=${first.next}`);
    assert.deepEqual(last.devices.map((d) => d.device_id), ids.slice(2));
    assert.equal(last.next, null);
    for (const bad of ['?limit=0', '?limit=51', '?limit=1.5', '?after=nope']) {
        assert.equal((await fetch(`${t.url}/v0/devices${bad}`, { headers: bearer(owner) })).status, 400, bad);
    }
    await t.close();
});

test('roles: devices cannot list or delete devices; a pending device cannot revoke itself (§7.1)', async () => {
    const { t, active, pending } = await setup();
    assert.equal((await fetch(`${t.url}/v0/devices`, { headers: bearer(active.token) })).status, 403);
    assert.equal((await fetch(`${t.url}/v0/devices/${pending.id}`, { method: 'DELETE', headers: bearer(active.token) })).status, 403);
    assert.equal((await self(t.url, pending.token)).status, 403);
    await t.close();
});

test('the owner deletes a device: the marker first, then everything else; the token stops at once (§7.4)', async () => {
    const { t, store, owner, active } = await setup();
    const del = () => fetch(`${t.url}/v0/devices/${active.id}`, { method: 'DELETE', headers: bearer(owner) });
    assert.equal((await del()).status, 204);
    assert.deepEqual(await store.list(`devices/${active.id}/`), [deviceKeys(active.id).revoked]);
    assert.deepEqual(await store.list(`requests/${active.id}/`), []);
    assert.deepEqual(await store.list(`objects/devices/${active.id}/`), []);
    assert.equal((await self(t.url, active.token)).status, 401);
    assert.equal((await del()).status, 204, 'repeating it is harmless');
    const listed = (await (await fetch(`${t.url}/v0/devices`, { headers: bearer(owner) })).json()) as { devices: { device_id: string }[] };
    assert.ok(!listed.devices.some((d) => d.device_id === active.id));
    assert.equal((await fetch(`${t.url}/v0/devices/nope`, { method: 'DELETE', headers: bearer(owner) })).status, 400);
    await t.close();
});

test('a device revokes itself: revocation, then marker, then its requests go; record and revocation stay (§7.4)', async () => {
    const { t, store, owner, active } = await setup();
    assert.equal((await self(t.url, active.token, new Uint8Array())).status, 400);
    assert.equal((await self(t.url, active.token, new Uint8Array(1025))).status, 413);
    assert.equal((await self(t.url, active.token, new Uint8Array([1, 2, 3]), { Origin: WEB_ORIGIN })).status, 204);
    assert.equal((await self(t.url, active.token)).status, 401);
    assert.ok(await store.has(deviceKeys(active.id).revoked));
    assert.ok(await store.has(deviceKeys(active.id).record));
    assert.deepEqual(await store.list(`requests/${active.id}/`), []);
    const rev = await fetch(`${t.url}/v0/devices/${active.id}/revocation`, { headers: bearer(owner) });
    assert.deepEqual(new Uint8Array(await rev.arrayBuffer()), new Uint8Array([1, 2, 3]));
    assert.equal((await fetch(`${t.url}/v0/devices/${active.id}`, { method: 'DELETE', headers: bearer(owner) })).status, 204);
    assert.equal((await fetch(`${t.url}/v0/devices/${active.id}/revocation`, { headers: bearer(owner) })).status, 404);
    await t.close();
});

test('a stored revocation without its marker stops the token before it is admitted (§7.8 rule 1)', async () => {
    const { t, store, active } = await setup();
    await store.put(deviceKeys(active.id).revocation, new Uint8Array([1])); // a write that landed after the start
    assert.equal((await self(t.url, active.token)).status, 401);
    assert.ok(await store.has(deviceKeys(active.id).revoked));
    await t.close();
});
