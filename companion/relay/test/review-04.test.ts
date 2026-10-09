// Regressions from the review of part 4: claims that storage cannot undo, and revocation atomic with every
// request of the device in flight.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { CLAIM_TIMING } from '../src/claim.ts';
import { readConfig } from '../src/config.ts';
import { newToken, tokenHash } from '../src/encoding.ts';
import { deviceKeys, ownerRecord } from '../src/layout.ts';
import { SlidingWindow } from '../src/limits.ts';
import { silentLog } from '../src/log.ts';
import { ClaimConflict, startRelay } from '../src/relay.ts';
import { KeyedMutex } from '../src/store/store.ts';
import { bearer, freshStore, INSTANCE, seedDevice, seedOwner, seedOwnerHash, SETUP_CODE, slowRequest, startTestRelay, TEST_LEASE, WEB_ORIGIN } from './harness.ts';

const fast = { ...CLAIM_TIMING, intervalMs: 1, failureDelayMs: 1 };
const claimWith = (url: string, setupCode: string, hash: string) =>
    fetch(`${url}/v0/claim`, { method: 'POST', body: JSON.stringify({ setup_code: setupCode, owner_token_sha256: hash }) });

test('a claimed relay never becomes claimable again because its records vanished (§6)', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const t = await startTestRelay({ raw, env: { SPRAVA_SETUP_CODE: '' }, claimTiming: fast });
    for (const key of await store.list('')) if (!key.startsWith('leases/')) await store.delete(key);
    for (const code of ['', SETUP_CODE]) assert.equal((await claimWith(t.url, code, tokenHash(newToken()))).status, 409);
    assert.equal((await fetch(`${t.url}/v0/devices`, { headers: bearer(owner) })).status, 200, 'the owner keeps access');
    await t.close();
});

test('a claim that landed after the start is adopted on its retry: health and the owner token work at once (§6)', async () => {
    const t = await startTestRelay({ claimTiming: fast });
    const token = newToken();
    await seedOwnerHash(t.relay.store, tokenHash(token)); // the write an earlier process began
    assert.equal((await claimWith(t.url, SETUP_CODE, tokenHash(token))).status, 204);
    assert.equal(((await (await fetch(`${t.url}/v0/health`)).json()) as { claimed: boolean }).claimed, true);
    assert.equal((await fetch(`${t.url}/v0/devices`, { headers: bearer(token) })).status, 200);
    assert.equal((await claimWith(t.url, SETUP_CODE, tokenHash(newToken()))).status, 409);
    await t.close();
});

test('a second claim in storage, or an owner record without its claim, fails the start closed (§6)', async () => {
    const config = readConfig({ SPRAVA_INSTANCE: INSTANCE, SPRAVA_WEB_ORIGIN: WEB_ORIGIN, SPRAVA_STORAGE: 'fs:/unused' });
    const two = await freshStore();
    await seedOwnerHash(two.store, 'a'.repeat(64));
    await two.store.put(`claims/${'b'.repeat(64)}`, ownerRecord('b'.repeat(64))); // a late write of another claim
    await assert.rejects(startRelay(config, two.store, { log: silentLog, lease: TEST_LEASE }), ClaimConflict);
    const bare = await freshStore();
    await bare.store.put('owner.json', ownerRecord('a'.repeat(64)));
    await assert.rejects(startRelay(config, bare.store, { log: silentLog, lease: TEST_LEASE }), ClaimConflict);
    const cut = await freshStore();
    await cut.store.put(`claims/${'a'.repeat(64)}`, ownerRecord('a'.repeat(64)));
    const started = await startRelay(config, cut.store, { log: silentLog, lease: TEST_LEASE });
    await started.ready;
    assert.deepEqual(await cut.store.get('owner.json'), ownerRecord('a'.repeat(64)), 'a claim cut short is finished');
    started.stop();
});

test('an unreadable record stops the start; it is never taken for a missing one and deleted', async () => {
    const { raw, store } = await freshStore();
    await seedOwner(store);
    const device = await seedDevice(store);
    await store.put(deviceKeys(device.id).record, new Uint8Array(Buffer.from('{not json')));
    await assert.rejects(startTestRelay({ raw }), /unreadable/);
    assert.ok(await store.has(deviceKeys(device.id).record));
});

test('a self-revocation whose body arrives after the owner deleted the device writes nothing (§7.4)', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const device = await seedDevice(store, { active: true });
    const t = await startTestRelay({ raw });
    const slow = slowRequest(`${t.url}/v0/devices/self`, 'DELETE', bearer(device.token));
    await new Promise((r) => setTimeout(r, 50));
    assert.equal((await fetch(`${t.url}/v0/devices/${device.id}`, { method: 'DELETE', headers: bearer(owner) })).status, 204);
    assert.equal((await slow.finish()).status, 401);
    assert.deepEqual(await store.list(`devices/${device.id}/`), [deviceKeys(device.id).revoked]);
    await t.close();
});

test('a stored revocation without its marker is repaired under the lock while device calls run, without a deadlock', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const device = await seedDevice(store, { active: true });
    const t = await startTestRelay({ raw });
    await store.put(deviceKeys(device.id).revocation, new Uint8Array([1]));
    const answers = await Promise.all([
        fetch(`${t.url}/v0/devices`, { headers: bearer(owner) }),
        fetch(`${t.url}/v0/devices/self`, { method: 'DELETE', body: new Uint8Array([1]), headers: bearer(device.token) }),
        fetch(`${t.url}/v0/devices/${device.id}`, { method: 'DELETE', headers: bearer(owner) }),
    ]);
    assert.deepEqual(answers.map((r) => r.status), [200, 401, 204]);
    await t.close();
});

test('counters keep no more than their limit per key, nor more keys than their bound', () => {
    const window = new SlidingWindow(60_000, 3, 100);
    for (let i = 0; i < 1000; i++) window.admit('one', 1000 + i);
    assert.equal(window.count('one'), 3);
    for (let i = 0; i < 1000; i++) window.admit(`address-${i}`, 2000);
    assert.ok(window.size <= 100);
    const locks = new KeyedMutex();
    return Promise.all(['a', 'b', 'a'].map((k) => locks.run(k, async () => undefined))).then(() => assert.equal(locks.size, 0));
});
