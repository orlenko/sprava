import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { FencedError, Lease, sleep } from '../src/lease.ts';
import { silentLog } from '../src/log.ts';
import { S3Store } from '../src/store/s3.ts';
import { scoped } from '../src/store/store.ts';
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
