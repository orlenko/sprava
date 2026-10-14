import assert from 'node:assert/strict';
import { test } from 'node:test';
import { IDBFactory, IDBKeyRange } from 'fake-indexeddb';
import { BrowserStore, StorageError } from '../src/browser-store.ts';
import { removePairing } from '../src/pairing-removal.ts';
import { encodeB64 } from '../src/encoding.ts';
import { openObject } from '../src/sealed.ts';
import { id, key, publicBytes, raw, sealed } from './owner-fixture.ts';
globalThis.IDBKeyRange = IDBKeyRange;
const time = '2026-10-08T07:06:05Z', clock = () => Date.parse(time);
const locks = { request: async (_name: string, _options: object, run: () => unknown) => run() } as Pick<LockManager, 'request'>;
async function paired() {
    const factory = new IDBFactory(), store = await BrowserStore.open('fixture', factory);
    const install = async () => {
        const r = await store.reserve(id); assert.ok(r);
        await store.install(r, { deviceId: id, relayOrigin: 'https://relay.example', instanceId: '0'.repeat(32),
            token: encodeB64(raw), expiresAt: time, deviceKey: await key(), wrapKey: await key(),
            delivery: sealed(`pairings/${id}/key`, 'wrap', 1, { device_id: id, epoch: 1, min_index_revision: 5,
                account_key: encodeB64(raw), owner_signing_key: encodeB64(publicBytes) }, false) });
        return r.generation;
    };
    const generation = await install(); return { store, factory, generation, install };
}

test('removal sends an instance-bound revocation, waits for the send lock and retains unresolved actions', async () => {
    const { store, generation } = await paired();
    const attempted = await store.enqueue({ type: 'note', text: 'Invented attempted note' }, time);
    await store.beginAttempt(clock());
    await store.enqueue({ type: 'note', text: 'Invented queued note' }, time);
    const reached = Promise.withResolvers<void>(), release = Promise.withResolvers<void>();
    const removal = removePairing(store, generation, { clock,
        locks: { request: async (_name: string, options: LockOptions, run: () => unknown) => {
            assert.equal(options.mode, 'exclusive'); reached.resolve(); await release.promise; return run();
        } } as Pick<LockManager, 'request'>,
        notify: value => assert.equal(value, generation), fetcher: async (input, options) => {
            assert.equal(String(input), 'https://relay.example/v0/devices/self'); assert.equal(options!.method, 'DELETE');
            const payload = await openObject(`devices/${id}/revocation`, 0, await key(), options!.body as Uint8Array);
            assert.equal(payload.instance, '0'.repeat(32)); assert.equal(payload.pairing_generation, generation);
            return new Response(null, { status: 204 });
        } });
    await reached.promise; assert.equal((await store.read()).pairing!.generation, generation);
    release.resolve();
    assert.deepEqual(await removal, { removed: true, revokeConfirmed: true, counts: { notSent: 1, unresolved: 1 } });
    const state = await store.read(); assert.deepEqual(state, { version: 1, viewMarks: {} });
    const entries = (await store.readOutbox()).entries;
    assert.deepEqual(entries.map(e => e.state), ['unresolved', 'not sent']);
    assert.equal(entries[0]!.requestId, attempted.requestId);
    store.close();
});

test('an offline or refused revocation still removes locally and reports lack of confirmation', async () => {
    for (const response of [401, 404, 500, null]) {
        const { store, generation } = await paired();
        const result = await removePairing(store, generation, { clock, locks, fetcher: async () => {
            if (response === null) throw new TypeError('Invented offline fixture');
            return new Response(null, { status: response });
        } });
        assert.equal(result.removed, true); assert.equal(result.revokeConfirmed, false);
        assert.equal((await store.read()).pairing, undefined); store.close();
    }
});

test('a late removal of G cannot erase replacement keys or alter its queued actions', async () => {
    const { store, generation, install } = await paired(); let replacement: string | undefined;
    const result = await removePairing(store, generation, { clock, locks, fetcher: async () => {
        await store.removePairing(generation); replacement = await install();
        await store.enqueue({ type: 'note', text: 'Invented replacement note' }, time);
        return new Response(null, { status: 204 });
    } });
    assert.equal(result.removed, false); assert.notEqual(replacement, generation);
    assert.equal((await store.read()).pairing!.generation, replacement);
    assert.equal((await store.readOutbox()).entries[0]!.state, 'queued');
    assert.equal((await store.read()).pairing!.nextSeq, 2);
    store.close();
});

test('an aborted strict removal preserves the pairing, cache and queue together', async () => {
    const { store, factory, generation } = await paired();
    await store.acceptIndex(5, 1, sealed('index/5', 'account', 1,
        { revision: 5, generated_at: time, binders: [] }));
    await store.enqueue({ type: 'note', text: 'Invented queued note' }, time);
    const request = factory.open('fixture', 1);
    const db = await new Promise<IDBDatabase>(resolve => { request.onsuccess = () => resolve(request.result); });
    const proto = Object.getPrototypeOf(db), transaction = proto.transaction;
    proto.transaction = function (...args: unknown[]) {
        const tx = transaction.apply(this, args);
        if (args[1] === 'readwrite') { assert.equal((args[2] as IDBTransactionOptions).durability, 'strict'); queueMicrotask(() => tx.abort()); }
        return tx;
    };
    try {
        await assert.rejects(store.removePairing(generation), StorageError);
        assert.equal((await store.read()).pairing!.generation, generation);
        assert.equal((await store.read()).index!.revision, 5);
        assert.equal((await store.readOutbox()).entries[0]!.state, 'queued');
    } finally { proto.transaction = transaction; db.close(); store.close(); }
});
