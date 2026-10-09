import assert from 'node:assert/strict';
import { mkdtemp, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, relative } from 'node:path';
import { test } from 'node:test';
import { FsStore } from '../src/store/fs.ts';
import { Mutex } from '../src/store/store.ts';
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
    assert.deepEqual(events, ['sync a/b', 'sync a/b', 'sync a/b'], 'one sync per change; a missing key changes nothing');
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
