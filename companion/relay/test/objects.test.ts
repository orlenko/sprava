import assert from 'node:assert/strict';
import { test } from 'node:test';
import { newId } from '../src/encoding.ts';
import { parseName } from '../src/objects.ts';
import { bearer, freshStore, seedDevice, seedOwner, sendOversized, startTestRelay, WEB_ORIGIN } from './harness.ts';

async function setup() {
    const { raw, store } = await freshStore();
    const owner = await seedOwner(store);
    const device = await seedDevice(store, { active: true });
    const other = await seedDevice(store, { active: true });
    const clock = { now: Date.now() };
    const t = await startTestRelay({ raw, now: () => clock.now });
    const call = (method: string, path: string, token: string, body?: Uint8Array, headers: Record<string, string> = {}) =>
        fetch(t.url + path, { method, headers: { ...bearer(token), ...headers }, ...(body ? { body } : {}) });
    return { t, store, owner, device, other, call, clock };
}

const bytes = (n: number, fill = 1) => new Uint8Array(n).fill(fill);
const names = async (res: Response) => (await res.json()) as { names: string[]; next: number | null };

test('object names are exactly the four forms of §7.5', () => {
    const id = newId();
    for (const good of ['index/1', `views/${id}/7`, `devices/${id}/keys/1`, `devices/${id}/outcomes/9007199254740991`]) assert.ok(parseName(good), good);
    for (const bad of ['index/0', 'index/01', 'index/1/x', 'index/', 'index/-1', 'index/9007199254740992', `views/x/1`, `devices/${id}/other/1`, `devices/${id}/keys`, 'owner.json']) {
        assert.equal(parseName(bad), null, bad);
    }
});

test('the owner writes each name once; identical bytes are a harmless retry (§7.5)', async () => {
    const s = await setup();
    assert.equal((await s.call('PUT', '/v0/objects/index/1', s.owner, bytes(10))).status, 204);
    assert.equal((await s.call('PUT', '/v0/objects/index/1', s.owner, bytes(10))).status, 204);
    assert.equal((await s.call('PUT', '/v0/objects/index/1', s.owner, bytes(10, 2))).status, 409);
    assert.deepEqual(new Uint8Array(await (await s.call('GET', '/v0/objects/index/1', s.owner)).arrayBuffer()), bytes(10));
    assert.ok(await s.store.has('objects/index/1'));
    assert.equal((await s.call('PUT', '/v0/objects/index/01', s.owner, bytes(10))).status, 404);
    assert.equal(await sendOversized(`${s.t.url}/v0/objects/index/2`, 'PUT', bearer(s.owner), bytes(1024 * 1024 + 1)), 413);
    assert.equal((await s.call('PUT', '/v0/objects/index/2', s.owner, bytes(1024 * 1024))).status, 204);
    assert.equal((await s.call('PUT', '/v0/objects/index/3', s.device.token, bytes(1))).status, 403);
    assert.equal((await s.call('PUT', '/v0/objects/index/3', s.owner, bytes(1), { Origin: WEB_ORIGIN })).status, 403);
    assert.equal((await s.call('DELETE', '/v0/objects/index/1', s.owner)).status, 204);
    assert.equal((await s.call('DELETE', '/v0/objects/index/1', s.owner)).status, 204);
    assert.equal((await s.call('GET', '/v0/objects/index/1', s.owner)).status, 404);
    await s.t.close();
});

test('a device reads the index, views and its own keys and outcomes; anything else is 404 (§7.1)', async () => {
    const s = await setup();
    const view = `views/${newId()}/3`;
    for (const name of ['index/1', view, `devices/${s.device.id}/keys/1`, `devices/${s.other.id}/keys/1`, `devices/${s.device.id}/outcomes/1`]) {
        assert.equal((await s.call('PUT', `/v0/objects/${name}`, s.owner, bytes(4))).status, 204);
    }
    const get = (name: string, headers: Record<string, string> = {}) => s.call('GET', `/v0/objects/${name}`, s.device.token, undefined, headers);
    for (const name of ['index/1', view, `devices/${s.device.id}/keys/1`, `devices/${s.device.id}/outcomes/1`]) assert.equal((await get(name)).status, 200, name);
    assert.equal((await get(`devices/${s.other.id}/keys/1`)).status, 404);
    const res = await get('index/1', { Origin: WEB_ORIGIN });
    const etag = res.headers.get('etag')!;
    assert.match(etag, /^"[0-9a-f]{64}"$/);
    assert.equal(res.headers.get('access-control-allow-origin'), WEB_ORIGIN);
    assert.equal((await get('index/1', { 'If-None-Match': etag })).status, 304);
    const list = (prefix: string) => s.call('GET', `/v0/objects?prefix=${encodeURIComponent(prefix)}`, s.device.token);
    assert.deepEqual(await names(await list('index/')), { names: ['index/1'], next: null });
    assert.deepEqual(await names(await list(`devices/${s.device.id}/outcomes/`)), { names: [`devices/${s.device.id}/outcomes/1`], next: null });
    assert.equal((await list(`devices/${s.other.id}/keys/`)).status, 404);
    assert.equal((await list(view.slice(0, -1))).status, 404, 'a device lists no views');
    assert.equal((await s.call('GET', `/v0/objects?prefix=${encodeURIComponent(view.slice(0, -1))}`, s.owner)).status, 200);
    await s.t.close();
});

test('a listing is newest first by number, paged with below (§7.5)', async () => {
    const s = await setup();
    for (const r of [1, 2, 9, 10, 11, 100]) await s.call('PUT', `/v0/objects/index/${r}`, s.owner, bytes(1));
    const list = (query: string) => s.call('GET', `/v0/objects?prefix=index/${query}`, s.owner);
    assert.deepEqual(await names(await list('')), { names: ['index/100', 'index/11', 'index/10', 'index/9', 'index/2', 'index/1'], next: null });
    const first = await names(await list('&limit=4'));
    assert.deepEqual(first, { names: ['index/100', 'index/11', 'index/10', 'index/9'], next: 9 });
    assert.deepEqual(await names(await list(`&limit=4&below=${first.next}`)), { names: ['index/2', 'index/1'], next: null });
    for (const bad of ['&limit=0', '&limit=101', '&below=01', '&below=x']) assert.equal((await list(bad)).status, 400, bad);
    assert.equal((await s.call('GET', '/v0/objects?prefix=owner', s.owner)).status, 400);
    await s.t.close();
});

test('a device makes at most 600 reads and listings an hour (§7.5)', async () => {
    const s = await setup();
    await s.call('PUT', '/v0/objects/index/1', s.owner, bytes(1));
    for (let i = 0; i < 600; i++) assert.equal((await s.call('GET', '/v0/objects/index/1', s.device.token)).status, 200);
    assert.equal((await s.call('GET', '/v0/objects?prefix=index/', s.device.token)).status, 429);
    assert.equal((await s.call('GET', '/v0/objects/index/1', s.other.token)).status, 200, 'another device has its own count');
    assert.equal((await s.call('GET', '/v0/objects/index/1', s.owner)).status, 200, 'the owner has none');
    s.clock.now += 3_600_000;
    assert.equal((await s.call('GET', '/v0/objects/index/1', s.device.token)).status, 200);
    await s.t.close();
});
