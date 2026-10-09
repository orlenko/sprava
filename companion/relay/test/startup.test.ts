import assert from 'node:assert/strict';
import { test } from 'node:test';
import { newId } from '../src/encoding.ts';
import { deviceKeys, pairingKeys } from '../src/layout.ts';
import { bearer, freshStore, seedDevice, seedOwner, startTestRelay } from './harness.ts';

const NOW = Date.UTC(2026, 9, 8, 12, 0, 0);
const EXPIRED = NOW - 60_000;

test('the repairs and cleanups at start, in the order of §7.8', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);

    // 1. A self-revocation cut short between the revocation and the marker.
    const selfRevoked = await seedDevice(store, { active: true, now: NOW });
    await store.put(deviceKeys(selfRevoked.id).revocation, new Uint8Array([1]));
    // 2. A pairing keyed but its device's activation marker never written.
    const keyed = await seedDevice(store, { now: NOW });
    await store.put(pairingKeys(keyed.pairing).keySha, new Uint8Array(Buffer.from('0'.repeat(64))));
    // 2. The same for an acknowledged pairing of a revoked device: it stays revoked, never active.
    const revokedAck = await seedDevice(store, { now: NOW });
    await store.put(pairingKeys(revokedAck.pairing).ack, new Uint8Array());
    await store.put(deviceKeys(revokedAck.id).revoked, new Uint8Array());
    // 3. An expired pairing whose device is pending, and one whose device was made active.
    const expiredPending = await seedDevice(store, { now: EXPIRED - 600_000, expiresAt: EXPIRED });
    const expiredActive = await seedDevice(store, { active: true, now: EXPIRED - 600_000, expiresAt: EXPIRED });
    // 4. Pairing parts without created.json, and device parts without record.json.
    const strayPairing = newId();
    await store.put(pairingKeys(strayPairing).joined, new Uint8Array([1]));
    const strayDevice = newId();
    await store.put(deviceKeys(strayDevice).lastSeen, new Uint8Array([1]));
    await store.put(deviceKeys(strayDevice).active, new Uint8Array());
    // 5. A pending device whose pairing is gone.
    const orphan = await seedDevice(store, { now: NOW });
    for (const key of Object.values(pairingKeys(orphan.pairing))) await store.delete(key);
    // 6. An owner deletion cut short after the marker; and a self-revoked device waiting for the owner.
    const halfDeleted = await seedDevice(store, { active: true, now: NOW });
    await store.put(deviceKeys(halfDeleted.id).revoked, new Uint8Array());
    await store.put(`requests/${halfDeleted.id}/0000000000000001-${newId()}`, new Uint8Array([1]));
    const waiting = await seedDevice(store, { active: true, now: NOW });
    await store.put(deviceKeys(waiting.id).revocation, new Uint8Array([1]));
    await store.put(deviceKeys(waiting.id).revoked, new Uint8Array());

    const t = await startTestRelay({ raw, now: () => NOW });
    const has = (key: string) => store.has(key);

    assert.ok(await has(deviceKeys(selfRevoked.id).revoked), 'rule 1');
    assert.ok(await has(deviceKeys(keyed.id).active), 'rule 2');
    assert.ok(!(await has(deviceKeys(revokedAck.id).active)), 'rule 2 spares a revoked device');
    assert.deepEqual(await store.list(`devices/${revokedAck.id}/`), [deviceKeys(revokedAck.id).revoked], 'and rule 6 finishes its deletion');
    assert.ok(!(await has(deviceKeys(expiredPending.id).record)), 'rule 3: a pending device goes with its pairing');
    assert.deepEqual(await store.list(`pairings/${expiredPending.pairing}/`), []);
    assert.deepEqual(await store.list(`pairings/${expiredActive.pairing}/`), []);
    assert.ok(await has(deviceKeys(expiredActive.id).record), 'rule 3: an active device stays');
    assert.deepEqual(await store.list(`pairings/${strayPairing}/`), [], 'rule 4');
    assert.deepEqual(await store.list(`devices/${strayDevice}/`), [], 'rule 4');
    assert.ok(!(await has(deviceKeys(orphan.id).record)), 'rule 5');
    assert.deepEqual(await store.list(`devices/${halfDeleted.id}/`), [deviceKeys(halfDeleted.id).revoked], 'rule 6');
    assert.deepEqual(await store.list(`requests/${halfDeleted.id}/`), [], 'rule 6');
    assert.ok(await has(deviceKeys(waiting.id).record), 'rule 6 keeps a self-revoked device for the owner');
    assert.ok(await has(deviceKeys(waiting.id).revocation));

    const listed = (await (await fetch(`${t.url}/v0/devices`, { headers: bearer(owner) })).json()) as { devices: { device_id: string; state: string }[] };
    const states = Object.fromEntries(listed.devices.map((d) => [d.device_id, d.state]));
    assert.deepEqual(states, {
        [selfRevoked.id]: 'revoked',
        [keyed.id]: 'active',
        [expiredActive.id]: 'active',
        [waiting.id]: 'revoked',
    });
    await t.close();
});

test('a revoked token stays refused after a restart; an active one keeps working', async () => {
    const { raw, store } = await freshStore();
    await seedOwner(store);
    const gone = await seedDevice(store, { active: true });
    const kept = await seedDevice(store, { active: true });
    await store.put(deviceKeys(gone.id).revoked, new Uint8Array());
    const t = await startTestRelay({ raw });
    const self = (token: string) => fetch(`${t.url}/v0/devices/self`, { method: 'DELETE', body: new Uint8Array([1]), headers: bearer(token) });
    assert.equal((await self(gone.token)).status, 401);
    assert.equal((await self(kept.token)).status, 204);
    await t.close();
});
