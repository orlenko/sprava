import assert from 'node:assert/strict';
import { test } from 'node:test';
import { IDBFactory, IDBKeyRange, IDBObjectStore } from 'fake-indexeddb';
import { BrowserStore } from '../src/browser-store.ts';
import { OutboxError } from '../src/outbox.ts';
import { PayloadError } from '../src/payload.ts';
import { encodeB64 } from '../src/encoding.ts';
import { openObject } from '../src/sealed.ts';
import { unsignedValue } from '../../shared/json.ts';
import { id, key, raw, publicBytes, sealed } from './owner-fixture.ts';
const time = '2026-10-08T07:06:05Z';
const note = () => ({ type: 'note' as const, text: 'Invented pending note' });
globalThis.IDBKeyRange = IDBKeyRange;
async function paired() {
    const factory = new IDBFactory(), store = await BrowserStore.open('fixture', factory), r = await store.reserve(id);
    assert.ok(r);
    await store.install(r, { deviceId: id, relayOrigin: 'https://relay.example', instanceId: '0'.repeat(32),
        token: encodeB64(raw), expiresAt: time, deviceKey: await key(), wrapKey: await key(),
        delivery: sealed(`pairings/${id}/key`, 'wrap', 1, { device_id: id, epoch: 1, min_index_revision: 0,
            account_key: encodeB64(raw), owner_signing_key: encodeB64(publicBytes) }, false) });
    return { factory, store };
}
async function database(factory: IDBFactory): Promise<IDBDatabase> {
    const request = factory.open('fixture', 1);
    return new Promise((resolve, reject) => {
        request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
    });
}

test('sequence and sealed action persist together across reopen, with no plaintext in the outbox', async () => {
    const { factory, store } = await paired(), entry = await store.enqueue(note(), time);
    assert.equal(entry.state, 'queued'); assert.equal(entry.seq, 1); assert.ok(entry.bytes);
    store.close();
    const reopened = await BrowserStore.open('fixture', factory);
    assert.equal((await reopened.read()).pairing!.nextSeq, 2);
    const page = await reopened.readOutbox();
    assert.equal(page.entries[0]!.requestId, entry.requestId); assert.equal(page.next, null);
    assert.equal(Object.hasOwn(page.entries[0]!, 'bytes'), false);
    assert.equal(JSON.stringify(page).includes(note().text), false);
    const db = await database(factory), tx = db.transaction('outbox', 'readonly');
    const request = tx.objectStore('outbox').get([entry.generation, entry.seq, entry.requestId]);
    const stored = await new Promise<typeof entry>(resolve => { tx.oncomplete = () => resolve(request.result); });
    const opened = await openObject(`requests/${id}/${stored.requestId}`, 1, await key(), stored.bytes!);
    assert.equal(opened.text, note().text); assert.equal(unsignedValue(opened.seq), 1);
    db.close(); reopened.close();
});

test('invalid actions and timestamps do not consume numbers or create pending entries', async () => {
    const { store } = await paired();
    await assert.rejects(store.enqueue({ type: 'note', text: 'x'.repeat(10001) }, time), PayloadError);
    await assert.rejects(store.enqueue(note(), 'invalid'), PayloadError);
    assert.equal((await store.read()).pairing!.nextSeq, 1); assert.deepEqual((await store.readOutbox()).entries, []);
    store.close();
});

test('concurrent windows allocate unique consecutive sequences and ciphertext matching each saved sequence', async () => {
    const { store, factory } = await paired(), second = await BrowserStore.open('fixture', factory);
    const entries = await Promise.all(Array.from({ length: 10 }, (_, i) => (i % 2 ? store : second).enqueue(note(), time)));
    assert.deepEqual(entries.map(e => e.seq).sort((a, b) => a - b), [1,2,3,4,5,6,7,8,9,10]);
    assert.equal(new Set(entries.map(e => e.requestId)).size, 10);
    assert.equal((await store.read()).pairing!.nextSeq, 11);
    for (const e of entries) {
        const opened = await openObject(`requests/${id}/${e.requestId}`, 1, await key(), e.bytes!);
        assert.equal(unsignedValue(opened.seq), e.seq);
    }
    const first = await store.readOutbox(4), next = await store.readOutbox(4, first.next!);
    assert.deepEqual(first.entries.map(e => e.seq), [1,2,3,4]); assert.deepEqual(next.entries.map(e => e.seq), [5,6,7,8]);
    assert.deepEqual((await store.readOutbox(4, next.next!)).entries.map(e => e.seq), [9,10]);
    store.close(); second.close();
});

test('a failed outbox write aborts the sequence update and never reports a pending action', async () => {
    const { store } = await paired(), add = IDBObjectStore.prototype.add;
    IDBObjectStore.prototype.add = function (...args: Parameters<IDBObjectStore['add']>) {
        if (this.name === 'outbox') throw new DOMException('Invented quota failure', 'QuotaExceededError');
        return add.apply(this, args);
    };
    try {
        await assert.rejects(store.enqueue(note(), time), OutboxError);
        assert.equal((await store.read()).pairing!.nextSeq, 1); assert.deepEqual((await store.readOutbox()).entries, []);
    } finally { IDBObjectStore.prototype.add = add; store.close(); }
});

test('removing a pairing during encryption records an unsent action of the original generation, without ciphertext', async () => {
    const { store, factory } = await paired(), old = (await store.read()).pairing!, db = await database(factory);
    const reached = Promise.withResolvers<void>(), release = Promise.withResolvers<void>();
    const subtle = crypto.subtle, encrypt = subtle.encrypt;
    subtle.encrypt = async function (...args: Parameters<SubtleCrypto['encrypt']>) {
        reached.resolve(); await release.promise; return encrypt.apply(this, args);
    };
    try {
        const pending = store.enqueue(note(), time); await reached.promise;
        const tx = db.transaction('state', 'readwrite', { durability: 'strict' }), state = tx.objectStore('state');
        const request = state.get('current'); request.onsuccess = () => {
            const value = request.result; delete value.pairing; state.put(value, 'current');
        };
        await new Promise<void>(resolve => { tx.oncomplete = () => resolve(); }); release.resolve();
        const entry = await pending;
        assert.equal(entry.generation, old.generation); assert.equal(entry.state, 'not sent'); assert.equal(entry.bytes, undefined);
        assert.equal((await store.read()).pairing, undefined);
        assert.equal((await store.readOutbox()).entries[0]!.state, 'not sent');
    } finally { release.resolve(); subtle.encrypt = encrypt; db.close(); store.close(); }
});
