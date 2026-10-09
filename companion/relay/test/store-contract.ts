// What every store backend must do, run against each one.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { deleteAll, Mutex, scoped, writeOnce, type Store } from '../src/store/store.ts';

const bytes = (text: string): Uint8Array => new Uint8Array(Buffer.from(text));

/** `honoursIfAbsent: false` for a store that overwrites despite a conditional write, as some do (§6, step 5). */
export function storeContract(name: string, open: () => Promise<Store>, options: { honoursIfAbsent?: boolean } = {}): void {
    test(`${name}: get, has, put and delete`, async () => {
        const store = await open();
        assert.equal(await store.get('a/b'), null);
        assert.equal(await store.has('a/b'), false);
        await store.put('a/b', bytes('one'));
        assert.deepEqual(await store.get('a/b'), bytes('one'));
        await store.put('a/b', bytes('two'));
        assert.deepEqual(await store.get('a/b'), bytes('two'));
        assert.equal(await store.has('a/b'), true);
        await store.delete('a/b');
        await store.delete('a/b');
        assert.equal(await store.get('a/b'), null);
    });

    test(`${name}: putIfAbsent writes only a new key`, { skip: options.honoursIfAbsent === false }, async () => {
        const store = await open();
        assert.equal(await store.putIfAbsent('k/1', bytes('first')), true);
        assert.equal(await store.putIfAbsent('k/1', bytes('second')), false);
        assert.deepEqual(await store.get('k/1'), bytes('first'));
    });

    test(`${name}: list returns every key under a prefix, in byte order`, async () => {
        const store = await open();
        for (const key of ['r/D/0000000000000002-x', 'r/D/0000000000000010-y', 'r/D/0000000000000001-z', 'r/E/1', 'rr/1', 'r/Dx']) {
            await store.put(key, bytes(key));
        }
        assert.deepEqual(await store.list('r/D/'), ['r/D/0000000000000001-z', 'r/D/0000000000000002-x', 'r/D/0000000000000010-y']);
        assert.deepEqual(await store.list('r/D'), ['r/D/0000000000000001-z', 'r/D/0000000000000002-x', 'r/D/0000000000000010-y', 'r/Dx']);
        assert.deepEqual(await store.list('nothing/'), []);
        await deleteAll(store, 'r/');
        assert.deepEqual(await store.list('r'), ['rr/1']);
    });

    test(`${name}: a scoped store reads and writes only under its instance (§6, §7.8)`, async () => {
        const store = await open();
        const one = scoped(store, '0'.repeat(32));
        const two = scoped(store, '1'.repeat(32));
        await one.put('owner.json', bytes('{}'));
        assert.equal(await two.get('owner.json'), null);
        assert.deepEqual(await one.list(''), ['owner.json']);
        assert.deepEqual(await store.list(''), [`${'0'.repeat(32)}/owner.json`]);
    });

    test(`${name}: write-once objects keep their first writer's bytes (§7.8)`, async () => {
        const store = await open();
        const lock = new Mutex();
        assert.equal(await lock.run(() => writeOnce(store, 'w/1', bytes('a'))), 'created');
        assert.equal(await lock.run(() => writeOnce(store, 'w/1', bytes('a'))), 'same');
        assert.equal(await lock.run(() => writeOnce(store, 'w/1', bytes('b'))), 'different');
        assert.deepEqual(await store.get('w/1'), bytes('a'));
        const results = await Promise.all(['x', 'y', 'z'].map((t) => lock.run(() => writeOnce(store, 'w/2', bytes(t)))));
        assert.deepEqual(results, ['created', 'different', 'different']);
    });
}
