// Regressions from the review of part 4: claims that storage cannot undo, and revocation atomic with every
// request of the device in flight.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { CLAIM_TIMING } from '../src/claim.ts';
import { readConfig } from '../src/config.ts';
import { newId, newToken, tokenHash } from '../src/encoding.ts';
import { deviceKeys, ownerRecord } from '../src/layout.ts';
import { SlidingWindow } from '../src/limits.ts';
import { silentLog } from '../src/log.ts';
import { ClaimConflict, startRelay } from '../src/relay.ts';
import { S3Store } from '../src/store/s3.ts';
import { KeyedMutex, LockBusy, scoped, type Store } from '../src/store/store.ts';
import { bearer, freshStore, INSTANCE, seedDevice, seedOwner, seedOwnerHash, SETUP_CODE, slowRequest, startTestRelay, TEST_LEASE, WEB_ORIGIN } from './harness.ts';
import { S3_CREDENTIALS, startS3Stub } from './s3-stub.ts';
import { vectors } from './vectors.ts';

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

test('token-hash vector (§14 case 9): the relay names a token\'s marker by that hash (§7.8)', () => {
    const v = vectors['token-hash'];
    assert.equal(deviceKeys('{D}').token(tokenHash(v.token)), v.relay_token_marker);
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

test('a self-revocation whose proof is not the one stored is refused and revokes nothing (§7.4, §9.2)', async () => {
    const stub = await startS3Stub({ ignoreIfNoneMatch: true });
    const raw = new S3Store({ endpoint: stub.endpoint, bucket: stub.bucket, ...S3_CREDENTIALS });
    const store = scoped(raw, INSTANCE);
    const owner = await seedOwner(store);
    const device = await seedDevice(store, { active: true });
    await store.put(`requests/${device.id}/0000000000000001-${newId()}`, new Uint8Array([1]));
    const t = await startTestRelay({ raw });
    const revoke = (body: number) => fetch(`${t.url}/v0/devices/self`, { method: 'DELETE', body: new Uint8Array([body]), headers: bearer(device.token) });
    stub.hold((key) => key.endsWith(`/devices/${device.id}/revocation`)); // the proof, not its intent
    assert.equal((await revoke(1)).status, 500, 'its outcome is unknown');
    stub.hold(() => false);
    assert.equal((await revoke(2)).status, 409, 'another tab, another seal');
    assert.equal(await store.has(deviceKeys(device.id).revoked), false);
    assert.equal((await store.list(`requests/${device.id}/`)).length, 1);
    stub.landHeld();
    assert.deepEqual(new Uint8Array(await (await fetch(`${t.url}/v0/devices/${device.id}/revocation`, { headers: bearer(owner) })).arrayBuffer()), new Uint8Array([1]));
    await t.close();
    await stub.close();
});

test('queued claims are answered 503 at their deadline, the queue is bounded, and an expired claim never runs (§6)', async () => {
    const { raw: fs } = await freshStore();
    let stall: Promise<void> | null = null;
    let reads = 0;
    const raw: Store = {
        get: (k) => fs.get(k),
        has: (k) => fs.has(k),
        put: (k, b) => fs.put(k, b),
        putIfAbsent: (k, b) => fs.putIfAbsent(k, b),
        sync: (k) => fs.sync(k),
        delete: (k) => fs.delete(k),
        list: async (p) => {
            if (p.endsWith('/claims/') && stall !== null) {
                reads++;
                await stall;
            }
            return fs.list(p);
        },
    };
    const t = await startTestRelay({ raw, claimTiming: { ...CLAIM_TIMING, intervalMs: 40, maxWaitMs: 100, failureDelayMs: 1 } });
    let unstall: () => void = () => {};
    stall = new Promise((r) => (unstall = r));
    const body = { setup_code: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=', owner_token_sha256: tokenHash(newToken()) };
    const send = () => fetch(`${t.url}/v0/claim`, { method: 'POST', body: JSON.stringify(body) });
    const first = send(); // holds the pacer on the stalled storage
    await new Promise((r) => setTimeout(r, 20));
    const queued = [send(), send()];
    await new Promise((r) => setTimeout(r, 10));
    const started = performance.now();
    const overflow = await send();
    assert.equal(overflow.status, 503, 'beyond the queue');
    const answers = await Promise.all(queued);
    assert.deepEqual(answers.map((r) => r.status), [503, 503]);
    assert.ok(performance.now() - started < 1000, 'answered at their deadline, not when the stalled claim ends');
    assert.equal(answers[0]!.headers.get('retry-after'), '1');
    unstall();
    assert.equal((await first).status, 403);
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(reads, 1, 'the expired claims never ran');
    await t.close();
});

test('a device cannot pile up calls: its queue is bounded, a call leaves at its deadline or when its client goes', async () => {
    const locks = new KeyedMutex();
    let release: () => void = () => {};
    const holding = locks.run('D', () => new Promise<void>((r) => (release = r)));
    const ran: string[] = [];
    const bound = (signal: AbortSignal, waitMs = 5000) => ({ limit: 3, waitMs, signal });
    const gone = new AbortController();
    const first = locks.run('D', async () => void ran.push('first'), bound(new AbortController().signal));
    const left = locks.run('D', async () => void ran.push('left'), bound(gone.signal));
    const timed = locks.run('D', async () => void ran.push('timed'), bound(new AbortController().signal, 10));
    await assert.rejects(locks.run('D', async () => void ran.push('overflow'), bound(new AbortController().signal)), LockBusy);
    await assert.rejects(timed, LockBusy);
    gone.abort();
    await assert.rejects(left, LockBusy);
    const owner = locks.run('D', async () => void ran.push('owner'));
    release();
    await Promise.all([holding, first, owner]);
    assert.deepEqual(ran, ['first', 'owner'], 'refused calls never run; the owner gets through');
    assert.equal(locks.size, 0);
});

test('device listing pages refuse non-canonical numbers (§3)', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const t = await startTestRelay({ raw });
    for (const bad of ['01', '00050', '+5', '5.0']) {
        assert.equal((await fetch(`${t.url}/v0/devices?limit=${bad}`, { headers: bearer(owner) })).status, 400, bad);
    }
    await t.close();
});
