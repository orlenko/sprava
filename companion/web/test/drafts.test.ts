import assert from 'node:assert/strict';
import { test } from 'node:test';
import { IDBFactory, IDBKeyRange, IDBObjectStore } from 'fake-indexeddb';
import { BrowserStore } from '../src/browser-store.ts';
import { DraftError } from '../src/drafts.ts';
import { encodeB64 } from '../src/encoding.ts';
import { id, otherId, key, publicBytes, raw, sealed } from './owner-fixture.ts';
globalThis.IDBKeyRange = IDBKeyRange;
const time = '2026-10-08T07:06:05Z';
async function paired() {
    const factory = new IDBFactory(), store = await BrowserStore.open('fixture', factory), r = await store.reserve(id);
    assert.ok(r);
    await store.install(r, { deviceId: id, relayOrigin: 'https://relay.example', instanceId: '0'.repeat(32), token: encodeB64(raw),
        expiresAt: time, deviceKey: await key(), wrapKey: await key(), delivery: sealed(`pairings/${id}/key`, 'wrap', 1,
            { device_id: id, epoch: 1, min_index_revision: 5, account_key: encodeB64(raw), owner_signing_key: encodeB64(publicBytes) }, false) });
    return { factory, store, generation: r.generation };
}
test('encrypted drafts preserve incomplete input, survive reopening and retain independent window editors', async () => {
    const { factory, store, generation } = await paired();
    const text = 'Invented draft\ud800\u0000 🦉';
    assert.equal(await store.saveDraft(generation, id, 1, text, time), true);
    await store.saveDraft(generation, otherId, 1, 'Invented other window', time);
    store.close(); const reopened = await BrowserStore.open('fixture', factory);
    const page = await reopened.readDrafts(1);
    assert.equal(page.drafts[0]!.text, text); assert.equal(page.next, id);
    assert.equal((await reopened.readDrafts(1, page.next)).drafts[0]!.text, 'Invented other window');
    const request = factory.open('fixture', 1);
    const db = await new Promise<IDBDatabase>(resolve => { request.onsuccess = () => resolve(request.result); });
    const saved = await new Promise<unknown>((resolve, reject) => {
        const tx = db.transaction('drafts', 'readonly'), request = tx.objectStore('drafts').getAll();
        tx.oncomplete = () => resolve(request.result); tx.onabort = () => reject(tx.error);
    });
    assert.equal(JSON.stringify(saved).includes('Invented'), false);
    db.close(); reopened.close();
});
test('late draft encryptions cannot overwrite newer revisions and stale generations cannot save', async () => {
    const { store, generation } = await paired();
    await Promise.all(Array.from({ length: 15 }, (_, i) => store.saveDraft(generation, id, i + 1, `Invented revision ${i + 1}`, time)));
    assert.equal((await store.readDrafts()).drafts[0]!.text, 'Invented revision 15');
    assert.equal(await store.saveDraft(generation, id, 14, 'Invented late text', time), false);
    assert.equal(await store.saveDraft(otherId, id, 16, 'Invented retired draft', time), false);
    await assert.rejects(store.saveDraft(generation, id, 16, 'x'.repeat(20001), time), DraftError);
    store.close();
});
test('enqueue and matching draft deletion commit together, while newer editor revisions remain', async () => {
    const { store, generation } = await paired();
    await store.saveDraft(generation, id, 1, 'Invented queued note', time);
    const put = IDBObjectStore.prototype.add;
    IDBObjectStore.prototype.add = function (...args: Parameters<IDBObjectStore['add']>) {
        if (this.name === 'outbox') throw new Error('Invented storage failure'); return put.apply(this, args);
    };
    try { await assert.rejects(store.enqueue({ type: 'note', text: 'Invented queued note' }, time, generation, [{ editorId: id, revision: 1 }])); }
    finally { IDBObjectStore.prototype.add = put; }
    assert.equal((await store.readDrafts()).drafts[0]!.text, 'Invented queued note');
    assert.equal((await store.readOutbox()).entries.length, 0); assert.equal((await store.read()).pairing!.nextSeq, 1);
    await store.saveDraft(generation, id, 2, 'Invented newer editor', time);
    await store.enqueue({ type: 'note', text: 'Invented queued note' }, time, generation, [{ editorId: id, revision: 1 }]);
    assert.equal((await store.readDrafts()).drafts[0]!.revision, 2);
    await store.enqueue({ type: 'note', text: 'Invented newer editor' }, time, generation, [{ editorId: id, revision: 2 }]);
    assert.deepEqual((await store.readDrafts()).drafts, []); store.close();
});
