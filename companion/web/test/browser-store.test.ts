import assert from 'node:assert/strict';
import { test } from 'node:test';
import { IDBFactory, IDBObjectStore } from 'fake-indexeddb';
import { BrowserStore, StorageError } from '../src/browser-store.ts';
import { PayloadError } from '../src/payload.ts';
import { encodeB64 } from '../src/encoding.ts';
import { bucketNames } from '../src/view-payloads.ts';
import { id, otherId, key, publicBytes, raw, sealed } from './owner-fixture.ts';

const indexBytes = (revision: number, version = 7, binders = true, epoch = 1) => sealed(`index/${revision}`, 'account', epoch,
    { revision, generated_at: '2026-10-08T07:06:05Z', binders: binders ? [
        { id, name: 'Invented binder', view_version: version, key: encodeB64(raw) }] : [] });
const viewBytes = (version = 7, epoch = 1) => sealed(`views/${id}/${version}`, id, epoch,
    { version, generated_at: '2026-10-08T07:06:05Z', today: null,
        binder: { name: 'Invented binder', description: null }, notes_omitted: false,
        items: [], closed: [], documents: [], buckets: Object.fromEntries(bucketNames.map(b => [b, []])) });
async function installation(floor = 5) {
    return { deviceId: id, relayOrigin: 'https://relay.example', instanceId: '0'.repeat(32),
        token: encodeB64(raw), expiresAt: '2026-10-08T07:16:05Z', deviceKey: await key(), wrapKey: await key(),
        delivery: sealed(`pairings/${id}/key`, 'wrap', 1, { device_id: id, epoch: 1,
            min_index_revision: floor, account_key: encodeB64(raw), owner_signing_key: encodeB64(publicBytes) }, false) };
}
async function paired(factory = new IDBFactory(), name = 'fixture') {
    const store = await BrowserStore.open(name, factory), reservation = await store.reserve(id);
    assert.ok(reservation); assert.equal(await store.install(reservation, await installation()), true);
    return store;
}

test('reservations cancel old flows and an installed pairing cannot be replaced (§5.2)', async () => {
    const store = await BrowserStore.open('fixture', new IDBFactory());
    const old = await store.reserve(id), current = await store.reserve(id);
    assert.ok(old && current); assert.notEqual(old.generation, current.generation);
    assert.equal(await store.install(old, await installation()), false);
    assert.equal(await store.install(current, await installation()), true);
    assert.equal(await store.reserve(otherId), null);
    assert.equal(await store.install(old, await installation()), false);
    assert.equal(await store.acknowledged(old.generation, id), false);
    assert.equal((await store.read()).pairing!.acknowledgementPending, true);
    assert.equal(await store.acknowledged(current.generation, id), true);
    assert.equal((await store.read()).pairing!.acknowledgementPending, false);
    store.close();
});

test('invalid installation metadata or a damaged delivery does not consume the reservation', async () => {
    const store = await BrowserStore.open('fixture', new IDBFactory()), reservation = await store.reserve(id);
    assert.ok(reservation);
    for (const change of [{ relayOrigin: 'https://relay.example/path' }, { relayOrigin: 'http://relay.example' },
        { token: 'invalid' }, { instanceId: id }, { expiresAt: 'invalid' }])
        await assert.rejects(store.install(reservation, { ...await installation(), ...change }), StorageError);
    await assert.rejects(store.install(reservation, { ...await installation(), delivery: new Uint8Array() }), PayloadError);
    assert.equal((await store.read()).pairing, undefined);
    assert.equal((await store.read()).reservation!.generation, reservation.generation);
    store.close();
});

test('encrypted caches and non-extractable keys survive closing/reopening; plaintext is not persisted', async () => {
    const factory = new IDBFactory(), store = await paired(factory);
    assert.equal(await store.acceptIndex(5, 1, indexBytes(5)), true);
    assert.equal(await store.acceptView(id, 7, viewBytes()), true);
    store.close();
    const reopened = await BrowserStore.open('fixture', factory), state = await reopened.read();
    assert.deepEqual(Object.keys(state.index!.binders[0]!).sort(), ['id', 'key', 'viewVersion']);
    assert.deepEqual((await reopened.readView(id))!.bytes, viewBytes());
    assert.equal(state.pairing!.accountKey.extractable, false);
    assert.equal(state.pairing!.deviceKey.extractable, false);
    assert.equal(state.index!.binders[0]!.key.extractable, false);
    await assert.rejects(crypto.subtle.exportKey('raw', state.pairing!.accountKey));
    assert.equal(JSON.stringify(state).includes('Invented binder'), false);
    assert.equal(await reopened.acceptIndex(6, 1, indexBytes(6)), true);
    reopened.close();
});

test('pairing floor, index rollback, exact view version and persistent view high-water marks are enforced', async () => {
    const store = await paired();
    assert.equal(await store.acceptIndex(4, 1, indexBytes(4)), false);
    assert.equal(await store.acceptIndex(5, 1, indexBytes(5)), true);
    assert.equal(await store.acceptView(id, 6, viewBytes(6)), false);
    assert.equal(await store.acceptView(id, 7, viewBytes()), true);
    assert.equal(await store.acceptIndex(6, 1, indexBytes(6, 8)), true);
    assert.equal(await store.readView(id), undefined, 'outdated cache is hidden');
    assert.equal(await store.acceptView(id, 7, viewBytes()), false);
    assert.equal(await store.acceptView(id, 8, viewBytes(8)), true);
    assert.equal(await store.acceptIndex(5, 1, indexBytes(5)), false);
    assert.equal(await store.acceptIndex(7, 1, indexBytes(7, 7)), true);
    assert.equal(await store.acceptView(id, 7, viewBytes()), false);
    assert.equal((await store.read()).viewMarks[id], 8);
    store.close();
});

test('removing a binder deletes its cached view and key atomically, while retaining its version floor', async () => {
    const store = await paired();
    await store.acceptIndex(5, 1, indexBytes(5)); await store.acceptView(id, 7, viewBytes());
    await store.acceptIndex(6, 1, indexBytes(6, 7, false));
    const state = await store.read();
    assert.deepEqual(state.index!.binders, []); assert.equal(await store.readView(id), undefined);
    assert.equal(state.viewMarks[id], 7);
    assert.equal(await store.acceptView(id, 7, viewBytes()), false);
    store.close();
});

test('concurrent windows cannot commit an index rollback or accept a view forbidden by the new index', async () => {
    const factory = new IDBFactory(), first = await paired(factory), second = await BrowserStore.open('fixture', factory);
    await first.acceptIndex(5, 1, indexBytes(5));
    const view = first.acceptView(id, 7, viewBytes());
    await second.acceptIndex(6, 1, indexBytes(6, 8));
    await view;
    assert.equal(await first.acceptView(id, 7, viewBytes()), false);
    await Promise.all([first.acceptIndex(8, 1, indexBytes(8, 8)), second.acceptIndex(7, 1, indexBytes(7, 8))]);
    assert.equal((await first.read()).index!.revision, 8);
    first.close(); second.close();
});

test('rotation commits key/epoch together, preserves the owner pin and refuses old epochs', async () => {
    const store = await paired(); await store.acceptIndex(5, 1, indexBytes(5));
    const bytes = sealed(`devices/${id}/keys/2`, 'device', 2, { device_id: id, epoch: 2, account_key: encodeB64(raw) });
    assert.equal(await store.acceptKeys(2, bytes), true);
    const state = await store.read();
    assert.equal(state.pairing!.epoch, 2); assert.equal(state.index!.epoch, 1);
    assert.equal(await store.readView(id), undefined, 'previous-epoch cache is hidden');
    assert.equal(state.pairing!.ownerKey.extractable, false);
    assert.equal(await store.acceptKeys(1, bytes), false);
    assert.equal(await store.acceptIndex(6, 1, indexBytes(6)), false);
    assert.equal(await store.acceptView(id, 7, viewBytes()), false);
    assert.equal(await store.acceptIndex(6, 2, indexBytes(6, 7, true, 2)), true);
    assert.equal(await store.acceptView(id, 7, viewBytes(7, 2)), true);
    store.close();
});

test('an aborted strict write never reports success or installs state (§10.2)', async () => {
    const factory = new IDBFactory(), store = await BrowserStore.open('fixture', factory);
    const request = factory.open('fixture', 1);
    const db = await new Promise<IDBDatabase>((resolve, reject) => {
        request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
    });
    const proto = Object.getPrototypeOf(db), transaction = proto.transaction;
    let strict = false;
    proto.transaction = function (...args: unknown[]) {
        const tx = transaction.apply(this, args);
        if (args[1] === 'readwrite') {
            strict = (args[2] as IDBTransactionOptions).durability === 'strict';
            tx.addEventListener('complete', () => assert.fail('aborted write completed'));
            queueMicrotask(() => tx.abort());
        }
        return tx;
    };
    try {
        await assert.rejects(store.reserve(id), StorageError);
        assert.equal(strict, true); assert.equal((await store.read()).reservation, undefined);
    } finally { proto.transaction = transaction; store.close(); db.close(); }
});

test('a view validated against a superseded index cannot commit after another window removes its binder', async () => {
    const factory = new IDBFactory(), first = await paired(factory), second = await BrowserStore.open('fixture', factory);
    await first.acceptIndex(5, 1, indexBytes(5));
    const reached = Promise.withResolvers<void>(), release = Promise.withResolvers<void>();
    const subtle = crypto.subtle, decrypt = subtle.decrypt;
    let pause = true;
    subtle.decrypt = async function (...args: Parameters<SubtleCrypto['decrypt']>) {
        if (pause) { pause = false; reached.resolve(); await release.promise; }
        return decrypt.apply(this, args);
    };
    try {
        const accepting = first.acceptView(id, 7, viewBytes());
        await reached.promise;
        await second.acceptIndex(6, 1, indexBytes(6, 7, false));
        release.resolve();
        assert.equal(await accepting, false);
        const state = await first.read();
        assert.equal(await first.readView(id), undefined); assert.equal(state.viewMarks[id], undefined);
    } finally { release.resolve(); subtle.decrypt = decrypt; first.close(); second.close(); }
});


test('updating one large view writes only its record and metadata, without cloning another cached view', async () => {
    const store = await paired();
    const bytes = sealed('index/5', 'account', 1, { revision: 5, generated_at: '2026-10-08T07:06:05Z',
        binders: [id, otherId].map(id => ({ id, name: 'Invented binder', view_version: 7, key: encodeB64(raw) })) });
    await store.acceptIndex(5, 1, bytes);
    const large = (binderId: string) => sealed(`views/${binderId}/7`, binderId, 1, {
        version: 7, generated_at: '2026-10-08T07:06:05Z', today: null, notes_omitted: false,
        binder: { name: 'Invented binder', description: 'x'.repeat(500000) }, items: [], closed: [], documents: [],
        buckets: Object.fromEntries(bucketNames.map(b => [b, []])) });
    await store.acceptView(id, 7, large(id)); const otherBytes = large(otherId);
    await store.acceptView(otherId, 7, otherBytes);
    const put = IDBObjectStore.prototype.put, writes: { store: string; key: unknown; size: number }[] = [];
    IDBObjectStore.prototype.put = function (value: unknown, key?: IDBValidKey) {
        writes.push({ store: this.name, key, size: JSON.stringify(value).length });
        return put.call(this, value, key);
    };
    try {
        await store.acceptView(id, 7, viewBytes());
        assert.deepEqual(writes.map(w => [w.store, w.key]), [['views', id], ['state', 'current']]);
        assert.ok(writes.every(w => w.size < 20000), 'neither write contains any old large view');
        assert.equal(Object.hasOwn(await store.read(), 'views'), false);
        assert.deepEqual((await store.readView(otherId))!.bytes, otherBytes);
    } finally { IDBObjectStore.prototype.put = put; store.close(); }
});
