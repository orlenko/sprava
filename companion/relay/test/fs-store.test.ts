import assert from 'node:assert/strict';
import { mkdtemp, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
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
