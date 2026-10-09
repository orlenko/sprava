import assert from 'node:assert/strict';
import { mkdtemp, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, relative } from 'node:path';
import { test } from 'node:test';
import { FsStore } from '../src/store/fs.ts';
import { Mutex, writeOnce } from '../src/store/store.ts';
import { storeContract } from './store-contract.ts';

storeContract('fs', async () => new FsStore(await mkdtemp(join(tmpdir(), 'sprava-relay-'))));

test('fs: no temporary file is left behind, and keys cannot leave the folder', async () => {
    const root = await mkdtemp(join(tmpdir(), 'sprava-relay-'));
    const store = new FsStore(root);
    await store.put('a/b', new Uint8Array([1]));
    await store.putIfAbsent('a/b', new Uint8Array([2]));
    assert.deepEqual(await readdir(join(root, 'a')), ['b']);
    for (const key of ['../x', 'a//b', '/a', 'a/./b', 'a/.tmp-1']) {
        await assert.rejects(() => store.put(key, new Uint8Array()), /invalid store key/, key);
    }
});

test('fs: a write is acknowledged only after its file and folder are synced, new parents included', async () => {
    const root = await mkdtemp(join(tmpdir(), 'sprava-relay-'));
    const events: string[] = [];
    const store = new FsStore(root, {
        syncDir: async (dir) => {
            events.push(`sync ${relative(root, dir) || '.'}`);
        },
    });
    await store.put('a/b/c', new Uint8Array([1]));
    events.push('put done');
    assert.deepEqual(events, ['sync .', 'sync a', 'sync a/b', 'put done']);
    events.length = 0;
    await store.putIfAbsent('a/b/d', new Uint8Array([1]));
    await store.putIfAbsent('a/b/d', new Uint8Array([2]));
    await store.delete('a/b/c');
    await store.delete('a/b/c');
    assert.deepEqual(events, ['sync a/b', 'sync a/b', 'sync a/b', 'sync a/b'], 'one sync per change, and per deletion even of a missing key');
});

test('fs: a failed write leaves no temporary file, and listings stay inside the folder', async () => {
    const root = await mkdtemp(join(tmpdir(), 'sprava-relay-'));
    const store = new FsStore(root);
    await store.put('a/b', new Uint8Array([1]));
    await assert.rejects(store.put('a', new Uint8Array([2])), 'a file cannot replace a folder');
    assert.deepEqual(await readdir(root), ['a']);
    for (const prefix of ['../', '../x', 'a/../', '/a', 'a//b']) {
        await assert.rejects(store.list(prefix), /invalid store prefix/, prefix);
    }
    assert.deepEqual(await store.list(''), ['a/b']);
});

test('fs: a folder whose sync failed is synced again on the next write, not taken as durable', async () => {
    const root = await mkdtemp(join(tmpdir(), 'sprava-relay-'));
    const events: string[] = [];
    let failOn: string | null = '.';
    const store = new FsStore(root, {
        syncDir: async (dir) => {
            const name = relative(root, dir) || '.';
            events.push(`sync ${name}`);
            if (name === failOn) {
                failOn = null;
                throw new Error('injected sync failure');
            }
        },
    });
    await assert.rejects(store.put('x/y', new Uint8Array([1])), /injected/);
    events.length = 0;
    await store.put('x/y', new Uint8Array([1]));
    assert.deepEqual(events, ['sync .', 'sync x'], 'the parent of the new folder is synced on the retry');
});

test('fs: a retry of a write whose last sync failed is acknowledged only after the sync is done (§7.8)', async () => {
    const root = await mkdtemp(join(tmpdir(), 'sprava-relay-'));
    const events: string[] = [];
    let failures = 0;
    const store = new FsStore(root, {
        syncDir: async (dir) => {
            const name = relative(root, dir) || '.';
            events.push(`sync ${name}`);
            if (name === 'k' && failures === 0) {
                failures++;
                throw new Error('injected sync failure');
            }
        },
    });
    const lock = new Mutex();
    await assert.rejects(lock.run(() => writeOnce(store, 'k/1', new Uint8Array([1]))), /injected/);
    assert.equal(failures, 1);
    assert.deepEqual(await store.get('k/1'), new Uint8Array([1]), 'readable, but not yet durable');
    events.length = 0;
    assert.equal(await lock.run(() => writeOnce(store, 'k/1', new Uint8Array([1]))), 'same');
    assert.deepEqual(events, ['sync k'], 'the retry synced the entry before saying so');
});

test('fs: keys that differ only in case never share a file, on any folder (§3 ids)', async () => {
    const root = await mkdtemp(join(tmpdir(), 'sprava-relay-'));
    const store = new FsStore(root);
    const upper = `views/${'A'.repeat(22)}/1`;
    const lower = `views/a${'A'.repeat(21)}/1`;
    await store.put(upper, new Uint8Array([1]));
    assert.equal(await store.putIfAbsent(lower, new Uint8Array([2])), true);
    assert.deepEqual(await store.get(upper), new Uint8Array([1]));
    assert.deepEqual(await store.get(lower), new Uint8Array([2]));
    assert.deepEqual(await store.list('views/'), [upper, lower].sort());
    assert.deepEqual(await store.list(`views/a`), [lower]);
    await assert.rejects(store.put('a/b^c', new Uint8Array()), /invalid store key/);
    await assert.rejects(store.put('a/é', new Uint8Array()), /invalid store key/);
});

test('fs: a root written with a trailing slash or dot segments works like the plain one', async () => {
    const root = await mkdtemp(join(tmpdir(), 'sprava-relay-'));
    for (const written of [`${root}/`, `${root}/./`, `${root}/x/..`]) {
        const store = new FsStore(written);
        await store.put('a/b', new Uint8Array([1]));
        assert.deepEqual(await new FsStore(root).get('a/b'), new Uint8Array([1]));
    }
});

test('fs: a retried deletion whose first folder sync failed syncs before it is acknowledged (§7.8)', async () => {
    const root = await mkdtemp(join(tmpdir(), 'sprava-relay-'));
    const events: string[] = [];
    let fail = false;
    const store = new FsStore(root, {
        syncDir: async (dir) => {
            events.push(`sync ${relative(root, dir) || '.'}`);
            if (fail) {
                fail = false;
                throw new Error('injected sync failure');
            }
        },
    });
    await store.put('k/1', new Uint8Array([1]));
    fail = true;
    await assert.rejects(store.delete('k/1'), /injected/);
    events.length = 0;
    await store.delete('k/1');
    assert.deepEqual(events, ['sync k'], 'the file was already gone, and the folder is synced all the same');
    await store.delete('never/1');
});

test('the mutex runs work one at a time and survives a failure', async () => {
    const lock = new Mutex();
    const order: string[] = [];
    const slow = lock.run(async () => {
        await new Promise((r) => setTimeout(r, 20));
        order.push('slow');
    });
    const failing = lock.run(async () => {
        order.push('failing');
        throw new Error('expected');
    });
    const fast = lock.run(async () => {
        order.push('fast');
    });
    await slow;
    await assert.rejects(failing);
    await fast;
    assert.deepEqual(order, ['slow', 'failing', 'fast']);
});
