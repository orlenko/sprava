import assert from 'node:assert/strict';
import { test } from 'node:test';
import { IDBFactory } from 'fake-indexeddb';
import { BrowserStore } from '../src/browser-store.ts';
import { refresh } from '../src/refresh.ts';
import { readDisplayCache } from '../src/display-cache.ts';
import { encodeB64 } from '../src/encoding.ts';
import { bucketNames } from '../src/view-payloads.ts';
import { writeJson } from '../../shared/json.ts';
import { id, key, publicBytes, raw, sealed } from './owner-fixture.ts';

const timestamp = '2026-10-08T07:06:05Z';
const index = (r: number, v = 7, e = 1) => sealed(`index/${r}`, 'account', e,
    { revision: r, generated_at: timestamp, binders: [{ id, name: 'Invented binder', view_version: v, key: encodeB64(raw) }] });
const view = (v = 7, e = 1) => sealed(`views/${id}/${v}`, id, e, { version: v, generated_at: timestamp,
    today: null, binder: { name: 'Invented binder', description: null }, notes_omitted: false,
    items: [], closed: [], documents: [], buckets: Object.fromEntries(bucketNames.map(b => [b, []])) });
async function paired(factory = new IDBFactory()) {
    const store = await BrowserStore.open('fixture', factory), reservation = await store.reserve(id);
    assert.ok(reservation);
    await store.install(reservation, { deviceId: id, relayOrigin: 'https://relay.example', instanceId: '0'.repeat(32),
        token: encodeB64(raw), expiresAt: timestamp, deviceKey: await key(), wrapKey: await key(),
        delivery: sealed(`pairings/${id}/key`, 'wrap', 1, { device_id: id, epoch: 1, min_index_revision: 5,
            account_key: encodeB64(raw), owner_signing_key: encodeB64(publicBytes) }, false) });
    await store.acknowledged(reservation.generation, id);
    return store;
}
function api(listings: Record<string, string[]>, objects: Record<string, Uint8Array>, calls: string[],
    before?: (path: string) => Promise<void>): typeof fetch {
    return async input => {
        const u = new URL(String(input)), path = u.pathname.slice('/v0/objects/'.length);
        calls.push(u.pathname + u.search);
        await before?.(path);
        if (u.pathname === '/v0/objects') {
            const prefix = u.searchParams.get('prefix')!, below = Number(u.searchParams.get('below') ?? Infinity);
            const names = (listings[prefix] ?? []).filter(n => Number(n.split('/').at(-1)) < below).slice(0, 5);
            return Response.json({ names, next: null });
        }
        return objects[path] ? new Response(new Uint8Array(objects[path])) : new Response(null, { status: 404 });
    };
}

test('refresh rotates first, skips invalid candidates, and admits an exact view for display', async () => {
    const store = await paired(), calls: string[] = [];
    const keys = `devices/${id}/keys/2`;
    const result = await refresh(store, id, { clock: () => 1234, fetcher: api({
        [`devices/${id}/keys/`]: [keys], 'index/': ['index/6', 'index/5'] }, {
        [keys]: sealed(keys, 'device', 2, { device_id: id, epoch: 2, account_key: encodeB64(raw) }),
        'index/6': new Uint8Array([0]), 'index/5': index(5, 7, 2), [`views/${id}/7`]: view(7, 2) }, calls) });
    assert.deepEqual(result, { status: 'reached', lastReachedAt: 1234 });
    assert.ok(decodeURIComponent(calls[0]!).includes('/keys/')); assert.equal((await store.read()).pairing!.epoch, 2);
    const display = await readDisplayCache(store, id);
    assert.equal(display.index!.binders[0]!.name, 'Invented binder'); assert.equal(display.view!.version, 7);
    assert.equal(JSON.stringify(await store.read()).includes('Invented binder'), false);
    store.close();
});

test('at most five candidates per prefix; rollback and unsigned objects never replace an offline cache', async () => {
    const store = await paired(), calls: string[] = [];
    await store.acceptIndex(5, 1, index(5)); await store.acceptView(id, 7, view());
    await refresh(store, id, { fetcher: api({ 'index/': [10, 9, 8, 7, 6, 5].map(r => `index/${r}`) }, {}, calls) });
    assert.equal(calls.filter(c => /^\/v0\/objects\/index\//.test(c)).length, 5);
    assert.equal((await store.read()).index!.revision, 5);
    const offline = await refresh(store, id, { fetcher: async () => { throw new TypeError('Offline'); } });
    assert.equal(offline.status, 'offline'); assert.equal((await readDisplayCache(store, id)).view!.version, 7);
    const rollbackCalls: string[] = [];
    await refresh(store, id, { fetcher: api({ 'index/': ['index/4'] }, { 'index/4': index(4) }, rollbackCalls) });
    assert.equal(rollbackCalls.some(c => c.endsWith('/index/4')), false);
    store.close();
});

test('404 view re-lists the index once and follows its new exact version', async () => {
    const store = await paired(), calls: string[] = [], listings = { 'index/': ['index/5'] };
    await refresh(store, id, { fetcher: api(listings, { 'index/5': index(5), 'index/6': index(6, 8),
        [`views/${id}/8`]: view(8) }, calls, async path => {
        if (path === `views/${id}/7`) listings['index/'] = ['index/6'];
    }) });
    assert.equal(calls.filter(c => c.includes('prefix=index%2F')).length, 2);
    assert.equal((await readDisplayCache(store, id)).view!.version, 8);
    store.close();
});

test('generation-bound admission refuses even otherwise valid objects belonging to a prior flow', async () => {
    const store = await paired();
    assert.equal(await store.acceptIndex(5, 1, index(5), 'old-generation'), false);
    assert.equal(await store.acceptKeys(2, new Uint8Array(), 'old-generation'), false);
    assert.equal(await store.acceptView(id, 7, view(), 'old-generation'), false);
    assert.equal(await store.acceptOutcomes(1, new Uint8Array(), 'old-generation'), false);
    assert.equal((await store.read()).index, undefined);
    store.close();
});

test('display decrypting an old index cannot expose a binder removed by another window', async () => {
    const store = await paired(); await store.acceptIndex(5, 1, index(5)); await store.acceptView(id, 7, view());
    const reached = Promise.withResolvers<void>(), release = Promise.withResolvers<void>();
    const decrypt = crypto.subtle.decrypt; let pause = true;
    crypto.subtle.decrypt = async function (...args: Parameters<SubtleCrypto['decrypt']>) {
        if (pause) { pause = false; reached.resolve(); await release.promise; }
        return decrypt.apply(this, args);
    };
    try {
        const displaying = readDisplayCache(store, id); await reached.promise;
        await store.acceptIndex(6, 1, sealed('index/6', 'account', 1,
            { revision: 6, generated_at: timestamp, binders: [] }));
        release.resolve(); const display = await displaying;
        assert.deepEqual(display.index!.binders, []); assert.equal(display.view, undefined);
    } finally { release.resolve(); crypto.subtle.decrypt = decrypt; store.close(); }
});

test('authentication refusal retains keys/cache and stops further HTTP; storage failure stays visible', async () => {
    const store = await paired(); await store.acceptIndex(5, 1, index(5));
    let calls = 0;
    assert.equal((await refresh(store, id, { fetcher: async () => { calls++; return new Response(null, { status: 401 }); } })).status, 'refused');
    assert.equal(calls, 1); assert.equal((await readDisplayCache(store)).index!.revision, 5);
    store.close(); await assert.rejects(refresh(store));
});

test('outcomes still advance when all index candidates are invalid', async () => {
    const store = await paired(), name = `devices/${id}/outcomes/7`, calls: string[] = [];
    const value = { device_id: id, revision: 7, generated_at: timestamp, outcomes: [], pad: '' };
    value.pad = ' '.repeat(512 - writeJson(value).length);
    await refresh(store, undefined, { fetcher: api({ 'index/': ['index/5'],
        [`devices/${id}/outcomes/`]: [name] }, { 'index/5': new Uint8Array(), [name]: sealed(name, 'device', 0, value) }, calls) });
    assert.equal((await store.read()).pairing!.outcomesRevision, 7);
    assert.equal((await store.read()).index, undefined); store.close();
});

test('a delayed reply stops when a different pairing is installed, even with the same fixture keys', async () => {
    const factory = new IDBFactory(), store = await paired(factory), calls: string[] = [];
    const initial = (await store.read()).pairing!.generation;
    let replacement: BrowserStore | undefined;
    try {
        const result = await refresh(store, id, { fetcher: api({ 'index/': ['index/5'] }, { 'index/5': index(5) }, calls,
            async path => {
                if (path !== 'index/5') return;
                // Emulate explicit removal and re-pairing by another window with invented state only.
                const request = factory.open('fixture', 1);
                const db = await new Promise<IDBDatabase>(resolve => { request.onsuccess = () => resolve(request.result); });
                await new Promise<void>((resolve, reject) => {
                    const tx = db.transaction('state', 'readwrite', { durability: 'strict' });
                    tx.objectStore('state').clear(); tx.oncomplete = () => resolve(); tx.onabort = () => reject(tx.error);
                });
                db.close(); replacement = await paired(factory);
            }) });
        assert.equal(result.status, 'stale');
        assert.notEqual((await store.read()).pairing!.generation, initial);
        assert.equal((await store.read()).index, undefined);
    } finally { replacement?.close(); store.close(); }
});

test('404 recovery shares the original five-candidate index budget', async () => {
    const store = await paired(), calls: string[] = [], listings = { 'index/': ['index/9', 'index/8', 'index/7', 'index/6', 'index/5'] };
    await refresh(store, id, { fetcher: api(listings, { 'index/5': index(5), 'index/10': index(10, 8) }, calls,
        async path => { if (path === `views/${id}/7`) listings['index/'] = ['index/10']; }) });
    assert.equal(calls.filter(c => /^\/v0\/objects\/index\//.test(c)).length, 5);
    assert.equal((await store.read()).index!.revision, 5); store.close();
});
