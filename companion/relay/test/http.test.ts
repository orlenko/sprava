import assert from 'node:assert/strict';
import { mkdtemp } from 'node:fs/promises';
import { request } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { ConfigError, readConfig } from '../src/config.ts';
import { newToken } from '../src/encoding.ts';
import { createHandler, HttpError, type Principal, type Route } from '../src/http.ts';
import { jsonLog, silentLog } from '../src/log.ts';
import { startRelay } from '../src/relay.ts';
import { FsStore } from '../src/store/fs.ts';
import { scoped } from '../src/store/store.ts';
import { INSTANCE, serve, startTestRelay, TEST_LEASE, WEB_ORIGIN } from './harness.ts';

test('health says the protocol, whether the relay is claimed, and its instance; nothing else (§7.2)', async () => {
    const t = await startTestRelay();
    const res = await fetch(`${t.url}/v0/health`);
    assert.equal(res.status, 200);
    assert.equal(await res.text(), `{"protocol":0,"claimed":false,"instance":"${INSTANCE}"}`);
    assert.equal(res.headers.get('access-control-allow-origin'), null);
    await t.close();
});

/** A GET that sends the path exactly as written; fetch would normalize dot segments away first. */
function rawGet(url: string): Promise<{ status: number; type: string; body: string }> {
    const { origin, pathname } = new URL(url);
    const path = url.slice(origin.length) || pathname;
    return new Promise((resolve, reject) => {
        const req = request(origin, { path }, (res) => {
            let body = '';
            res.on('data', (c) => (body += c));
            res.on('end', () => resolve({ status: res.statusCode ?? 0, type: String(res.headers['content-type'] ?? ''), body }));
        });
        req.on('error', reject);
        req.end();
    });
}

test('`/` and every path outside /v0/ are 404 (§13)', async () => {
    const t = await startTestRelay();
    for (const path of ['/', '/index.html', '/v1/health', '/v0', '/v0/nothing', '/outside/../v0/health', '/v0/../v0/health', '/v0/%2e%2E/v0/health', '/v0/./health', '/v0/x\\..\\health', '/v0/x%5C..%5chealth', '/v0\\health', '//', '//v0/health']) {
        const res = await rawGet(t.url + path);
        assert.equal(res.status, 404, path);
        assert.match(res.type, /application\/json/);
        assert.ok(typeof (JSON.parse(res.body) as { error: unknown }).error === 'string');
    }
    await t.close();
});

test('cross-origin rules (§7.7)', async (s) => {
    const t = await startTestRelay();
    await s.test('a foreign Origin is refused before anything else', async () => {
        for (const path of ['/v0/health', '/v0/nothing', '/']) {
            const res = await fetch(t.url + path, { headers: { Origin: 'https://elsewhere.example.org' } });
            assert.equal(res.status, 403, path);
            assert.equal(res.headers.get('access-control-allow-origin'), null);
        }
    });
    await s.test('the web origin is answered with its own origin, ETag exposed, and no credentials', async () => {
        const res = await fetch(`${t.url}/v0/health`, { headers: { Origin: WEB_ORIGIN } });
        assert.equal(res.status, 200);
        assert.equal(res.headers.get('access-control-allow-origin'), WEB_ORIGIN);
        assert.equal(res.headers.get('access-control-expose-headers'), 'ETag');
        assert.equal(res.headers.get('vary'), 'Origin');
        assert.equal(res.headers.get('access-control-allow-credentials'), null);
    });
    await s.test('preflight: GET and POST, and DELETE only for /v0/devices/self', async () => {
        const res = await fetch(`${t.url}/v0/requests/AAAAAAAAAAAAAAAAAAAAAA`, { method: 'OPTIONS', headers: { Origin: WEB_ORIGIN } });
        assert.equal(res.status, 204);
        assert.equal(res.headers.get('access-control-allow-methods'), 'GET, POST');
        assert.equal(res.headers.get('access-control-allow-headers'), 'Authorization, Content-Type, If-None-Match');
        assert.equal(res.headers.get('access-control-max-age'), '600');
        assert.equal(res.headers.get('access-control-allow-origin'), WEB_ORIGIN);
        const self = await fetch(`${t.url}/v0/devices/self`, { method: 'OPTIONS', headers: { Origin: WEB_ORIGIN } });
        assert.equal(self.headers.get('access-control-allow-methods'), 'GET, POST, DELETE');
        const plain = await fetch(`${t.url}/v0/health`, { method: 'OPTIONS' });
        assert.equal(plain.status, 404);
    });
    await t.close();
});

test('an unclaimed relay refuses to start without a well-formed setup code (§6); a claimed one ignores it', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'sprava-relay-'));
    const env = { SPRAVA_INSTANCE: INSTANCE, SPRAVA_WEB_ORIGIN: WEB_ORIGIN, SPRAVA_STORAGE: `fs:${dir}` };
    const store = scoped(new FsStore(dir), INSTANCE);
    await assert.rejects(startRelay(readConfig(env), store, { log: silentLog, lease: TEST_LEASE }), ConfigError);
    await assert.rejects(startRelay(readConfig({ ...env, SPRAVA_SETUP_CODE: 'not-a-code' }), store, { log: silentLog, lease: TEST_LEASE }), ConfigError);
    await store.put('owner.json', Buffer.from('{"owner_token_sha256":"' + 'a'.repeat(64) + '"}'));
    const { relay } = await startRelay(readConfig({ ...env, SPRAVA_SETUP_CODE: 'not-a-code' }), store, { log: silentLog, lease: TEST_LEASE });
    assert.equal(relay.claimed, true);
});

// The core alone, with routes made for the test.
const owner = newToken();
const pending = newToken();
const unusedToken = newToken();
async function core(options: { claimed?: boolean; bodyTimeoutMs?: number } = {}) {
    const logs: string[] = [];
    const calls: string[] = [];
    const routes: Route[] = [
        { method: 'GET', path: '/v0/owned/:id', access: ['owner'], browser: false, handle: async (c) => ({ status: 200, json: { id: c.params.id } }) },
        { method: 'GET', path: '/v0/key', access: ['pending', 'active'], browser: true, handle: async () => ({ status: 200, bytes: new Uint8Array([1, 2]) }) },
        {
            method: 'POST',
            path: '/v0/echo',
            access: ['public'],
            browser: true,
            body: { kind: 'json', limit: 64 },
            handle: async (c) => ({ status: 200, json: { a: c.json.a } }),
        },
        {
            method: 'PUT',
            path: '/v0/bytes/*name',
            access: ['public'],
            browser: false,
            body: { kind: 'bytes', limit: 16 },
            handle: async (c) => {
                calls.push(c.params.name!);
                return { status: 200, json: { size: c.body.length, name: c.params.name } };
            },
        },
        { method: 'GET', path: '/v0/broken', access: ['public'], browser: true, handle: async () => Promise.reject(new Error('secret detail')) },
        { method: 'GET', path: '/v0/refused', access: ['public'], browser: true, handle: async () => Promise.reject(new HttpError(409, 'Taken.')) },
    ];
    const authenticate = async (token: string): Promise<Principal | null> => {
        calls.push('authenticate');
        if (token === owner) return { kind: 'owner' };
        if (token === pending) return { kind: 'device', id: 'D', active: false, pairing: 'P' };
        return null;
    };
    const handler = createHandler({
        routes,
        webOrigin: WEB_ORIGIN,
        log: jsonLog((line) => logs.push(line)),
        authenticate,
        isClaimed: () => options.claimed ?? true,
        bodyTimeoutMs: options.bodyTimeoutMs ?? 2000,
    });
    const served = await serve(handler);
    return { ...served, logs, calls, close: () => new Promise<void>((r) => served.server.close(() => r())) };
}

test('tokens and roles (§7, §7.1)', async () => {
    const c = await core();
    const get = (path: string, token?: string, origin?: string) =>
        fetch(c.url + path, { headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(origin ? { Origin: origin } : {}) } });
    assert.equal((await get('/v0/owned/x')).status, 401, 'no token');
    assert.equal((await get('/v0/owned/x', unusedToken)).status, 401, 'unknown token');
    c.calls.length = 0;
    assert.equal((await get('/v0/owned/x', owner + '=')).status, 401, 'padded token');
    assert.equal((await get('/v0/owned/x', 'short')).status, 401, 'short token');
    assert.deepEqual(c.calls, [], 'a malformed bearer value is refused without hashing');
    assert.equal((await get('/v0/owned/x', owner)).status, 200);
    assert.equal((await get('/v0/owned/x', pending)).status, 403, 'a device on an owner endpoint');
    assert.equal((await get('/v0/key', pending)).status, 200);
    assert.equal((await get('/v0/key', owner)).status, 403);
    assert.equal((await get('/v0/owned/x', owner, WEB_ORIGIN)).status, 403, 'an owner endpoint with an Origin header');
    await c.close();
});

test('JSON bodies are read strictly (§3.1)', async () => {
    const c = await core();
    const post = (body: string) => fetch(`${c.url}/v0/echo`, { method: 'POST', body, headers: { 'Content-Type': 'application/json' } });
    assert.deepEqual(await (await post('{"a":"x"}')).json(), { a: 'x' });
    for (const bad of ['{"a":1,"a":2}', '{"a":"\\ud800"}', '[1]', '"a"', '{']) {
        const res = await post(bad);
        assert.equal(res.status, 400, bad);
        assert.doesNotMatch(await res.text(), /ud800|"a"/, 'the error never echoes the request');
    }
    await c.close();
});

test('bodies over their limit are 413, by Content-Length or as they stream (§7)', async () => {
    const c = await core();
    const res = await fetch(`${c.url}/v0/bytes/a/b`, { method: 'PUT', body: new Uint8Array(17) });
    assert.equal(res.status, 413);
    assert.deepEqual(c.calls, []);
    const ok = await fetch(`${c.url}/v0/bytes/a/b`, { method: 'PUT', body: new Uint8Array(16) });
    assert.deepEqual(await ok.json(), { size: 16, name: 'a/b' });
    const streamed = await new Promise<number>((resolve, reject) => {
        const req = request(`${c.url}/v0/bytes/x`, { method: 'PUT' }, (r) => resolve(r.statusCode ?? 0));
        req.on('error', reject);
        req.write(new Uint8Array(10));
        setTimeout(() => req.write(new Uint8Array(10)), 20);
    });
    assert.equal(streamed, 413);
    assert.deepEqual(c.calls, ['a/b']);
    await c.close();
});

test('a body that does not arrive in time is dropped, and nothing is handled (§7)', async () => {
    const c = await core({ bodyTimeoutMs: 100 });
    const outcome = await new Promise<string>((resolve) => {
        const req = request(`${c.url}/v0/bytes/slow`, { method: 'PUT', headers: { 'Content-Length': '10' } }, (r) => resolve(`status ${r.statusCode}`));
        req.on('error', () => resolve('dropped'));
        req.write(new Uint8Array(5));
    });
    assert.equal(outcome, 'dropped');
    assert.deepEqual(c.calls, []);
    await c.close();
});

test('errors are plain sentences that reveal nothing, and logs carry the pattern, never an id (§7, §12)', async () => {
    const c = await core();
    const broken = await fetch(`${c.url}/v0/broken`);
    assert.equal(broken.status, 500);
    assert.doesNotMatch(await broken.text(), /secret detail/);
    const refused = await fetch(`${c.url}/v0/refused`);
    assert.equal(refused.status, 409);
    assert.deepEqual(await refused.json(), { error: 'Taken.' });
    await fetch(`${c.url}/v0/owned/AAAAAAAAAAAAAAAAAAAAAA`, { headers: { Authorization: `Bearer ${owner}` } });
    await fetch(`${c.url}/v0/key`, { headers: { Authorization: `Bearer ${pending}` } });
    const text = c.logs.join('\n');
    assert.match(text, /"route":"\/v0\/owned\/:id"/);
    assert.doesNotMatch(text, /AAAAAAAAAAAAAAAAAAAAAA|secret detail/);
    assert.ok(!text.includes(owner) && !text.includes(pending));
    await c.close();
});

test('while unclaimed, only health and claim are served (§6)', async () => {
    const c = await core({ claimed: false });
    assert.equal((await fetch(`${c.url}/v0/owned/x`, { headers: { Authorization: `Bearer ${owner}` } })).status, 401);
    assert.equal((await fetch(`${c.url}/v0/echo`, { method: 'POST', body: '{}' })).status, 404);
    await c.close();
});

test('the hourly count per device names no device (§12)', () => {
    let now = Date.UTC(2026, 9, 8, 7, 0, 0);
    const lines: string[] = [];
    const log = jsonLog((line) => lines.push(line), () => now);
    log.device('device-one');
    log.device('device-one');
    log.device('device-two');
    now += 3_600_000;
    log.request('GET', '/v0/health', 200, 1);
    assert.equal(lines[0], '{"event":"device-calls","hour":"2026-10-08T07:00:00.000Z","perDevice":[2,1]}');
});
