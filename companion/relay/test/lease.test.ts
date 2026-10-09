import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { FencedError, InconsistentStore, Lease, sleep } from '../src/lease.ts';
import { silentLog } from '../src/log.ts';
import { S3Store } from '../src/store/s3.ts';
import { deleteForGood, isDeleted, Mutex, scoped, writeOnce, type Store } from '../src/store/store.ts';
import { INSTANCE, startTestRelay } from './harness.ts';
import { S3_CREDENTIALS, startS3Stub, type S3Stub } from './s3-stub.ts';

const stubs: S3Stub[] = [];
after(() => Promise.all(stubs.map((s) => s.close())));

async function bucket() {
    const stub = await startS3Stub({ ignoreIfNoneMatch: true });
    stubs.push(stub);
    return { stub, raw: new S3Store({ endpoint: stub.endpoint, bucket: stub.bucket, ...S3_CREDENTIALS }) };
}

test('a newer lease fences the older process: its writes fail with 503 from then on (§7)', async () => {
    const { raw } = await bucket();
    const store = scoped(raw, INSTANCE);
    let fencedCalls = 0;
    const first = await Lease.take(store, silentLog, { checkMs: 20, warmupMs: 0 }, () => fencedCalls++);
    assert.equal(first.hadPredecessor, false, 'a fresh instance has no one to wait for');
    const writes = first.lease.fenceStore();
    await writes.put('x', new Uint8Array([1]));
    const second = await Lease.take(store, silentLog, { checkMs: 20, warmupMs: 0 });
    assert.equal(second.hadPredecessor, true);
    await sleep(80);
    assert.equal(first.lease.fenced, true);
    assert.equal(fencedCalls, 1);
    await assert.rejects(writes.put('x', new Uint8Array([2])), FencedError);
    await assert.rejects(writes.delete('x'), FencedError);
    await second.lease.fenceStore().put('x', new Uint8Array([3]));
    first.lease.stop();
    second.lease.stop();
});

test('a write checks the lease first when the last check is stale, so a stopped timer cannot hide a takeover', async () => {
    const { raw } = await bucket();
    const store = scoped(raw, INSTANCE);
    const first = await Lease.take(store, silentLog, { checkMs: 10, warmupMs: 0 });
    first.lease.stop();
    const second = await Lease.take(store, silentLog, { checkMs: 10, warmupMs: 0 });
    await sleep(30);
    await assert.rejects(first.lease.fenceStore().put('x', new Uint8Array([1])), FencedError);
    second.lease.stop();
});

test('a restarted relay waits out the old one: it serves only health until then, and reads what landed late', async () => {
    const { stub, raw } = await bucket();
    const old = await startTestRelay({ raw });
    // A write the old process sent that has not landed yet when it stops.
    stub.hold((key) => key.endsWith('/late'));
    await assert.rejects(old.relay.store.put('late', new Uint8Array([7])), /status 500/);
    await old.close();

    const fresh = await startTestRelay({ raw, lease: { checkMs: 20, warmupMs: 300 }, waitReady: false });
    assert.equal((await fetch(`${fresh.url}/v0/health`)).status, 200);
    const early = await fetch(`${fresh.url}/v0/nothing-yet`);
    assert.equal(early.status, 503);
    assert.equal(early.headers.get('retry-after'), '5');
    stub.landHeld(); // within the warm-up
    await fresh.ready;
    assert.deepEqual(await fresh.relay.store.get('late'), new Uint8Array([7]));
    assert.deepEqual((await raw.list(`${INSTANCE}/leases/`)).length, 1, 'the earlier lease is retired');
    await assert.rejects(old.relay.store.put('again', new Uint8Array([1])), FencedError);
    await fresh.close();
});

test('two first starts at the same moment: after the wait, only the higher lease admits writes (§7)', async () => {
    const { raw } = await bucket();
    const store = scoped(raw, INSTANCE);
    // Both list the empty prefix before either writes its lease.
    let listed = 0;
    let release: () => void = () => {};
    const barrier = new Promise<void>((r) => (release = r));
    const gated: Store = {
        ...bindStore(store),
        list: async (prefix) => {
            const keys = await store.list(prefix);
            if (prefix === 'leases/' && listed < 2) {
                if (++listed === 2) release();
                await barrier;
            }
            return keys;
        },
    };
    const timing = { checkMs: 20, warmupMs: 100 };
    const [x, y] = await Promise.all([Lease.take(gated, silentLog, timing), Lease.take(gated, silentLog, timing)]);
    assert.equal(x.hadPredecessor || y.hadPredecessor, false, 'both found nothing before them');
    await sleep(timing.warmupMs);
    await Promise.all([x.lease.check(), y.lease.check()]);
    assert.equal([x.lease.fenced, y.lease.fenced].filter((f) => !f).length, 1, 'exactly one may write');
    const loser = x.lease.fenced ? x : y;
    await assert.rejects(loser.lease.fenceStore().put('k', new Uint8Array([1])), FencedError);
    x.lease.stop();
    y.lease.stop();
});

test('two relays started together: one becomes ready, the other is fenced before it reads or writes', async () => {
    const { raw } = await bucket();
    const timing = { checkMs: 20, warmupMs: 150 };
    const [a, b] = await Promise.all([
        startTestRelay({ raw, lease: timing, waitReady: false }),
        startTestRelay({ raw, lease: timing, waitReady: false }),
    ]);
    const outcomes = await Promise.allSettled([a.ready, b.ready]);
    assert.equal(outcomes.filter((o) => o.status === 'fulfilled').length, 1);
    assert.ok(outcomes.some((o) => o.status === 'rejected' && o.reason instanceof FencedError));
    await a.close();
    await b.close();
});

test('a write that lands after the next process is ready cannot replace what that process stored (§7.5)', async () => {
    const { stub, raw } = await bucket();
    const old = await startTestRelay({ raw });
    stub.hold((key) => key.endsWith('/objects/index/1')); // the object itself, not its intent
    await assert.rejects(old.relay.lock.run(() => writeOnce(old.relay.store, 'objects/index/1', Buffer.from('A'))), /status 500/);
    await old.close();
    stub.hold(() => false);

    const fresh = await startTestRelay({ raw });
    assert.equal(await fresh.relay.lock.run(() => writeOnce(fresh.relay.store, 'objects/index/1', Buffer.from('B'))), 'different');
    stub.landHeld(); // after the new process is ready
    assert.equal(Buffer.from((await fresh.relay.store.get('objects/index/1'))!).toString(), 'A');
    assert.equal(await fresh.relay.lock.run(() => writeOnce(fresh.relay.store, 'objects/index/1', Buffer.from('A'))), 'same');
    await fresh.close();
});

test('a name deleted for good refuses every later write, and a copy a late write brings back reads as deleted', async () => {
    const { stub, raw } = await bucket();
    const store = scoped(raw, INSTANCE);
    const lock = new Mutex();
    stub.hold((key) => key.endsWith('/objects/index/2'));
    await assert.rejects(lock.run(() => writeOnce(store, 'objects/index/2', Buffer.from('A'))), /status 500/);
    stub.hold(() => false);
    await deleteForGood(store, 'objects/index/2'); // the owner deletes the name before A lands
    assert.equal(await lock.run(() => writeOnce(store, 'objects/index/2', Buffer.from('B'))), 'different');
    stub.landHeld();
    assert.ok(await store.has('objects/index/2'), 'A landed');
    assert.ok(await isDeleted(store, 'objects/index/2'), 'and every reader treats it as deleted');
    assert.equal((await store.list('intents/objects/index/2/')).length, 1, 'the intent stays');
});

test('a late deletion cannot erase an upload acknowledged after it: the name is dead first', async () => {
    const { stub, raw } = await bucket();
    const store = scoped(raw, INSTANCE);
    const lock = new Mutex();
    assert.equal(await lock.run(() => writeOnce(store, 'objects/index/3', Buffer.from('A'))), 'created');
    stub.hold((key) => key.endsWith('/objects/index/3'));
    await assert.rejects(deleteForGood(store, 'objects/index/3'), /status 500/); // the tombstone is written; the deletion is held
    stub.hold(() => false);
    await deleteForGood(store, 'objects/index/3');
    assert.equal(await lock.run(() => writeOnce(store, 'objects/index/3', Buffer.from('A'))), 'different', 'no upload is acknowledged again');
    stub.landHeld();
    assert.equal(await store.get('objects/index/3'), null);
});

test('a store that does not show a completed write in its listings is refused at start (§13)', async () => {
    const stub = await startS3Stub({ ignoreIfNoneMatch: true, listLagMs: 60_000 });
    stubs.push(stub);
    const raw = new S3Store({ endpoint: stub.endpoint, bucket: stub.bucket, ...S3_CREDENTIALS });
    await assert.rejects(startTestRelay({ raw }), InconsistentStore);
});

function bindStore(store: Store): Store {
    return {
        get: (k) => store.get(k),
        has: (k) => store.has(k),
        put: (k, b) => store.put(k, b),
        putIfAbsent: (k, b) => store.putIfAbsent(k, b),
        sync: (k) => store.sync(k),
        delete: (k) => store.delete(k),
        list: (p) => store.list(p),
    };
}
