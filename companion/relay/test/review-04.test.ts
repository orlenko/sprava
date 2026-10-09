// Regressions from the review of part 4: claims that storage cannot undo, and revocation atomic with every
// request of the device in flight.
import assert from 'node:assert/strict';
import { readdirSync } from 'node:fs';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { CLAIM_TIMING } from '../src/claim.ts';
import { readConfig } from '../src/config.ts';
import { newId, newToken, sha256Hex, tokenHash } from '../src/encoding.ts';
import { deviceKeys, ownerRecord } from '../src/layout.ts';
import { SlidingWindow } from '../src/limits.ts';
import { silentLog } from '../src/log.ts';
import { ClaimConflict, startRelay } from '../src/relay.ts';
import { FsStore } from '../src/store/fs.ts';
import { S3Store } from '../src/store/s3.ts';
import { KeyedMutex, LockBusy, scoped, type Store } from '../src/store/store.ts';
import { bearer, freshStore, INSTANCE, seedDevice, seedOwner, seedOwnerHash, SETUP_CODE, slowRequest, startTestRelay, TEST_LEASE, WEB_ORIGIN } from './harness.ts';
import { S3_CREDENTIALS, startS3Stub, type S3Stub } from './s3-stub.ts';
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

/** Two tokens whose claims sort as [lower, higher] by the name of their claim (README, trade-off A). */
function orderedTokens(): [string, string] {
    const [x, y] = [newToken(), newToken()];
    const name = (t: string) => sha256Hex(ownerRecord(tokenHash(t)));
    return name(x) < name(y) ? [x, y] : [y, x];
}

/** A bucket whose listing of claims first lands what the stub holds: an intent landing mid-claim. */
function landingOnClaimList(stub: S3Stub, raw: Store, armed: { on: boolean }): Store {
    return {
        get: (k) => raw.get(k),
        has: (k) => raw.has(k),
        put: (k, b) => raw.put(k, b),
        putIfAbsent: (k, b) => raw.putIfAbsent(k, b),
        sync: (k) => raw.sync(k),
        delete: (k) => raw.delete(k),
        list: async (p) => {
            if (armed.on && p.endsWith('/claims/')) {
                armed.on = false;
                stub.landHeld();
            }
            return raw.list(p);
        },
    };
}

test('a late intent that lands mid-claim and sorts lower takes the slot; its holder completes the claim (§6)', async () => {
    const stub = await startS3Stub({ ignoreIfNoneMatch: true });
    const s3 = new S3Store({ endpoint: stub.endpoint, bucket: stub.bucket, ...S3_CREDENTIALS });
    const armed = { on: false };
    const raw = landingOnClaimList(stub, s3, armed);
    const [a, b] = orderedTokens(); // A sorts lower
    const first = await startTestRelay({ raw, claimTiming: fast });
    stub.hold((key) => key.includes('/claims/'));
    assert.equal((await claimWith(first.url, SETUP_CODE, tokenHash(a))).status, 500, "A's intent is delayed");
    stub.hold(() => false);
    await first.close();
    const second = await startTestRelay({ raw, claimTiming: fast });
    armed.on = true; // A's intent lands between B's intent and B's listing
    assert.equal((await claimWith(second.url, SETUP_CODE, tokenHash(b))).status, 409, 'A binds the slot');
    assert.equal((await claimWith(second.url, SETUP_CODE, tokenHash(b))).status, 409);
    assert.equal((await claimWith(second.url, SETUP_CODE, tokenHash(a))).status, 204, "A's retry completes it");
    await second.close();
    const third = await startTestRelay({ raw, claimTiming: fast });
    assert.equal(third.relay.ownerHash, tokenHash(a));
    await third.close();
    await stub.close();
});

test('a late intent that lands mid-claim and sorts higher changes nothing: the claim completes (§6)', async () => {
    const stub = await startS3Stub({ ignoreIfNoneMatch: true });
    const s3 = new S3Store({ endpoint: stub.endpoint, bucket: stub.bucket, ...S3_CREDENTIALS });
    const armed = { on: false };
    const raw = landingOnClaimList(stub, s3, armed);
    const [b, a] = orderedTokens(); // A sorts higher
    const first = await startTestRelay({ raw, claimTiming: fast });
    stub.hold((key) => key.includes('/claims/'));
    assert.equal((await claimWith(first.url, SETUP_CODE, tokenHash(a))).status, 500, "A's intent is delayed");
    stub.hold(() => false);
    await first.close();
    const second = await startTestRelay({ raw, claimTiming: fast });
    armed.on = true;
    assert.equal((await claimWith(second.url, SETUP_CODE, tokenHash(b))).status, 204, 'B is the lowest: it binds and completes');
    assert.equal((await claimWith(second.url, SETUP_CODE, tokenHash(a))).status, 409);
    await second.close();
    const third = await startTestRelay({ raw, claimTiming: fast });
    assert.equal(third.relay.ownerHash, tokenHash(b));
    await third.close();
    await stub.close();
});

test('a claim whose owner record is delayed across a restart binds the slot against a higher claim; its retry succeeds (§6)', async () => {
    const stub = await startS3Stub({ ignoreIfNoneMatch: true });
    const raw = new S3Store({ endpoint: stub.endpoint, bucket: stub.bucket, ...S3_CREDENTIALS });
    const first = await startTestRelay({ raw, claimTiming: fast });
    const [a, b] = orderedTokens();
    stub.hold((key) => key.includes('/owner/')); // A's intent is durable; its record is delayed
    assert.equal((await claimWith(first.url, SETUP_CODE, tokenHash(a))).status, 500);
    await first.close();
    stub.hold(() => false);
    const second = await startTestRelay({ raw, claimTiming: fast });
    assert.equal((await claimWith(second.url, SETUP_CODE, tokenHash(b))).status, 409, 'the slot is bound to A');
    assert.equal((await claimWith(second.url, SETUP_CODE, tokenHash(a))).status, 204, "A's retry completes it");
    stub.landHeld(); // the delayed record lands: the same name and bytes
    await second.close();
    const third = await startTestRelay({ raw, claimTiming: fast });
    assert.equal(third.relay.ownerHash, tokenHash(a));
    assert.equal((await claimWith(third.url, SETUP_CODE, tokenHash(b))).status, 409);
    await third.close();
    await stub.close();
});

test('a late owner record of a higher claim never replaces the acknowledged owner (§6)', async () => {
    const stub = await startS3Stub({ ignoreIfNoneMatch: true });
    const raw = new S3Store({ endpoint: stub.endpoint, bucket: stub.bucket, ...S3_CREDENTIALS });
    const [b, a] = orderedTokens(); // A sorts higher
    const first = await startTestRelay({ raw, claimTiming: fast });
    stub.hold((key) => key.includes('/owner/')); // A's intent is durable; its record is delayed
    assert.equal((await claimWith(first.url, SETUP_CODE, tokenHash(a))).status, 500);
    await first.close();
    stub.hold(() => false);
    const second = await startTestRelay({ raw, claimTiming: fast });
    assert.equal((await claimWith(second.url, SETUP_CODE, tokenHash(b))).status, 204, 'B is lower: it binds');
    stub.landHeld(); // A's record lands after B was acknowledged
    await second.close();
    const third = await startTestRelay({ raw, claimTiming: fast });
    assert.equal(third.relay.ownerHash, tokenHash(b), 'the lowest record is the owner');
    await third.close();
    await stub.close();
});

test('only an owner record that cannot be read fails the start; claim intents are kept (§6)', async () => {
    const config = readConfig({ SPRAVA_INSTANCE: INSTANCE, SPRAVA_WEB_ORIGIN: WEB_ORIGIN, SPRAVA_STORAGE: 'fs:/unused' });
    const bad = await freshStore();
    await bad.store.put(`claims/${'0'.repeat(64)}`, new Uint8Array());
    await bad.store.put(`owner/${'0'.repeat(64)}`, new Uint8Array(Buffer.from('{"owner_token_sha256":"nope"}')));
    await assert.rejects(startRelay(config, bad.store, { log: silentLog, lease: TEST_LEASE }), ClaimConflict);
    const good = await freshStore();
    await seedOwnerHash(good.store, 'a'.repeat(64));
    await good.store.put(`claims/${'f'.repeat(64)}`, new Uint8Array());
    const started = await startRelay(config, good.store, { log: silentLog, lease: TEST_LEASE });
    await started.ready;
    assert.equal(started.relay.ownerHash, 'a'.repeat(64));
    assert.equal((await good.store.list(`claims/${'f'.repeat(64)}`)).length, 1, 'never deleted');
    started.stop();
});

test('throttled wrong codes still count: the throttle holds while failures go on (§6 step 4)', () => {
    const window = new SlidingWindow(10 * 60_000, 5);
    let now = 0;
    const answers: boolean[] = [];
    for (let i = 0; i < 5; i++) answers.push(window.record('address', now) >= 5);
    for (let minute = 1; minute <= 12; minute++) {
        now = minute * 60_000;
        answers.push(window.record('address', now) >= 5);
    }
    assert.deepEqual(answers.slice(0, 5), [false, false, false, false, false]);
    assert.ok(answers.slice(5).every((throttled) => throttled), 'a failure a minute keeps it throttled');
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
    assert.deepEqual(ran, ['first', 'owner'], 'refused calls never run; an unbounded call is never refused');
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

test("the owner's revocation takes the lock with priority: it waits only for the running call, and queued device calls are refused", async () => {
    const locks = new KeyedMutex();
    let release: () => void = () => {};
    const holding = locks.run('D', () => new Promise<void>((r) => (release = r)));
    const ran: string[] = [];
    const bound = { limit: 3, waitMs: 5000, signal: new AbortController().signal };
    const device = (n: number) => locks.run('D', async () => void ran.push(`device ${n}`), bound);
    const queued = [device(1), device(2), device(3)];
    await assert.rejects(device(4), LockBusy, 'the device queue is full');
    const plain = locks.run('D', async () => void ran.push('owner listing'));
    const revocation = locks.run('D', async () => void ran.push('revocation'), undefined, true);
    for (const call of queued) await assert.rejects(call, LockBusy, 'queued device calls are refused');
    await assert.rejects(device(5), LockBusy, 'and new ones, while the revocation waits');
    release();
    await Promise.all([holding, revocation, plain]);
    assert.deepEqual(ran, ['revocation', 'owner listing']);
    await locks.run('D', async () => void ran.push('device 6'), bound);
    assert.deepEqual(ran.at(-1), 'device 6', 'after it, device calls are admitted again');
});

test("the owner's revocation of a device is answered while that device keeps its queue full", async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const device = await seedDevice(store, { active: true });
    const t = await startTestRelay({ raw });
    let release: () => void = () => {};
    const running = t.relay.deviceLocks.run(device.id, () => new Promise<void>((r) => (release = r))); // a slow call
    const flood = Array.from({ length: 12 }, () =>
        fetch(`${t.url}/v0/devices/self`, { method: 'DELETE', body: new Uint8Array(), headers: bearer(device.token) }).then((r) => r.status),
    );
    await new Promise((r) => setTimeout(r, 50));
    const revoking = fetch(`${t.url}/v0/devices/${device.id}`, { method: 'DELETE', headers: bearer(owner) });
    await new Promise((r) => setTimeout(r, 50));
    release();
    await running;
    assert.equal((await revoking).status, 204);
    assert.ok((await Promise.all(flood)).every((s) => s === 503), 'every queued device call was refused');
    await t.close();
});

test('a claim retry makes an owner record found readable but not durable durable before answering (§6, invariant 2)', async () => {
    const root = await mkdtemp(join(tmpdir(), 'sprava-relay-'));
    let fail = false;
    const synced: string[] = [];
    const raw = new FsStore(root, {
        syncDir: async (dir) => {
            if (!dir.endsWith('/owner')) return; // the folder that holds owner records
            synced.push(dir);
            if (fail && readdirSync(dir).some((n) => !n.startsWith('.'))) { // right after the record is linked
                fail = false;
                throw new Error('injected sync failure');
            }
        },
    });
    const t = await startTestRelay({ raw, claimTiming: fast });
    const hash = tokenHash(newToken());
    fail = true; // the next sync of the owner folder that holds a record
    assert.equal((await claimWith(t.url, SETUP_CODE, hash)).status, 500, 'linked, but its folder sync failed');
    synced.length = 0;
    assert.equal((await claimWith(t.url, SETUP_CODE, hash)).status, 204);
    assert.ok(synced.length > 0, 'the claim was synced before the 204');
    await t.close();
});

test("a self-revocation that lands after the owner deleted the device is never served (§7.4, invariant 5)", async () => {
    const stub = await startS3Stub({ ignoreIfNoneMatch: true });
    const raw = new S3Store({ endpoint: stub.endpoint, bucket: stub.bucket, ...S3_CREDENTIALS });
    const store = scoped(raw, INSTANCE);
    const owner = await seedOwner(store);
    const device = await seedDevice(store, { active: true });
    const t = await startTestRelay({ raw });
    stub.hold((key) => key.endsWith(`/devices/${device.id}/revocation`));
    assert.equal((await fetch(`${t.url}/v0/devices/self`, { method: 'DELETE', body: new Uint8Array([1]), headers: bearer(device.token) })).status, 500);
    stub.hold(() => false);
    assert.equal((await fetch(`${t.url}/v0/devices/${device.id}`, { method: 'DELETE', headers: bearer(owner) })).status, 204);
    stub.landHeld();
    assert.ok(await store.has(deviceKeys(device.id).revocation), 'the late write landed');
    assert.equal((await fetch(`${t.url}/v0/devices/${device.id}/revocation`, { headers: bearer(owner) })).status, 404);
    await t.close();
    await stub.close();
});

test('a self-revocation cut short before its requests were deleted is finished at start; the proof stays (§7.4, §7.8)', async () => {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const device = await seedDevice(store, { active: true });
    await store.put(deviceKeys(device.id).revocation, new Uint8Array([1]));
    await store.put(deviceKeys(device.id).revoked, new Uint8Array());
    await store.put(`requests/${device.id}/0000000000000001-${newId()}`, new Uint8Array([1])); // left behind
    const t = await startTestRelay({ raw });
    assert.deepEqual(await store.list(`requests/${device.id}/`), []);
    assert.ok(await store.has(deviceKeys(device.id).record));
    assert.equal((await fetch(`${t.url}/v0/devices/${device.id}/revocation`, { headers: bearer(owner) })).status, 200);
    await t.close();
});

test("two claims whose records are both delayed: the higher one's retry is refused, and the lower one owns (§6, trade-off A)", async () => {
    const stub = await startS3Stub({ ignoreIfNoneMatch: true });
    const raw = new S3Store({ endpoint: stub.endpoint, bucket: stub.bucket, ...S3_CREDENTIALS });
    const [b, a] = orderedTokens(); // B sorts lower
    const t = await startTestRelay({ raw, claimTiming: fast });
    const heldA = (key: string) => key.endsWith(`/owner/${sha256Hex(ownerRecord(tokenHash(a)))}`);
    const heldB = (key: string) => key.endsWith(`/owner/${sha256Hex(ownerRecord(tokenHash(b)))}`);
    stub.hold(heldA);
    assert.equal((await claimWith(t.url, SETUP_CODE, tokenHash(a))).status, 500, "A's record delayed");
    stub.hold(heldB);
    assert.equal((await claimWith(t.url, SETUP_CODE, tokenHash(b))).status, 500, "B's lower record delayed");
    stub.hold(() => false);
    stub.landHeld(heldA); // A's record lands
    assert.equal((await claimWith(t.url, SETUP_CODE, tokenHash(a))).status, 409, "A's retry is refused: B's intent is lower");
    stub.landHeld(heldB); // then B's
    assert.equal((await claimWith(t.url, SETUP_CODE, tokenHash(b))).status, 204, "B's retry completes");
    await t.close();
    const again = await startTestRelay({ raw, claimTiming: fast });
    assert.equal(again.relay.ownerHash, tokenHash(b));
    await again.close();
    await stub.close();
});
