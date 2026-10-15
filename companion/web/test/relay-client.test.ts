import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createServer } from 'node:http';
import { RelayClient, RelayError } from '../src/relay-client.ts';
import { encodeB64 } from '../src/encoding.ts';
import { id, otherId, raw } from './owner-fixture.ts';
const bearer = encodeB64(raw), origin = 'https://relay.example';
const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status });
const fixture = () => ({ protocol: 0, claimed: true, instance: '0'.repeat(32) });
const fake = (handler: (input: string, init: RequestInit) => Promise<Response> | Response): typeof fetch =>
    ((input, init) => Promise.resolve(handler(String(input), init!))) as typeof fetch;

test('only constructed device routes receive canonical bearer tokens; requests disable redirects, credentials and referrers', async () => {
    const calls: { url: string; init: RequestInit }[] = [];
    const client = new RelayClient(origin, id, fake((url, init) => { calls.push({ url, init }); return new Response(new Uint8Array([1,2,3])); }));
    const reply = await client.getObject(`views/${otherId}/7`, bearer);
    assert.deepEqual(reply.value, new Uint8Array([1,2,3]));
    const call = calls[0]!; assert.equal(call.url, `${origin}/v0/objects/views/${otherId}/7`);
    assert.equal((call.init.headers as Record<string, string>).Authorization, `Bearer ${bearer}`);
    assert.equal(call.init.redirect, 'error'); assert.equal(call.init.credentials, 'omit');
    assert.equal(call.init.referrerPolicy, 'no-referrer'); assert.equal(call.init.cache, 'no-store'); assert.equal(call.init.mode, 'cors');
    for (const name of [`devices/${otherId}/keys/1`, 'index/01', 'index/9007199254740992', '../credential', '//elsewhere/index/1'])
        assert.throws(() => client.getObject(name, bearer), RelayError);
    await assert.rejects(client.getObject('index/1', bearer + '='), RelayError);
    assert.equal(calls.length, 1);
    for (const value of ['http://relay.example', origin + '/path', 'https://user:secret@relay.example'])
        assert.throws(() => new RelayClient(value, id), RelayError);
});

test('health and join parse strict JSON and known fields, verify linked device identity and never surface remote error text', async () => {
    let response = json({ ...fixture(), ignored: 'discarded' }), media: unknown;
    const client = new RelayClient(origin, id, fake((_url, init) => { media = (init.headers as Record<string,string>)['Content-Type']; return response; }));
    assert.deepEqual((await client.health()).value, { instance: '0'.repeat(32), claimed: true });
    for (const body of ['{"protocol":0,"protocol":0,"claimed":true,"instance":"' + '0'.repeat(32) + '"}',
        JSON.stringify({ ...fixture(), protocol: 1 }), JSON.stringify({ ...fixture(), instance: id })]) {
        response = new Response(body); await assert.rejects(client.health(), RelayError);
    }
    response = json({ device_id: id, device_token: bearer, expires_at: '2026-10-08T07:06:05Z', owner_public_key: 'ignored' });
    assert.deepEqual((await client.join(id, otherId, raw, new Uint8Array(512))).value,
        { token: bearer, expiresAt: '2026-10-08T07:06:05Z' }); assert.equal(media, 'application/json');
    response = json({ device_id: otherId, device_token: bearer, expires_at: '2026-10-08T07:06:05Z' });
    await assert.rejects(client.join(id, otherId, raw, new Uint8Array(512)), RelayError);
    response = json({ error: 'Invented untrusted error text' }, 401);
    assert.deepEqual(await client.health(), { status: 401 });
    response = json({ error: 'Invented untrusted error text' }, 401);
    assert.deepEqual(await client.getObject('index/1', bearer), { status: 401 });
});

test('object listings are bounded, scope checked, strictly newest first and canonical in number syntax', async () => {
    let response = json({ names: ['index/7', 'index/6'], next: 6 }); let url = '';
    const client = new RelayClient(origin, id, fake((value) => { url = value; return response; }));
    assert.deepEqual((await client.list('index', bearer)).value, { names: ['index/7', 'index/6'], next: 6 });
    assert.equal(new URL(url).searchParams.get('limit'), '5');
    for (const value of [{ names: ['index/7', 'index/7'], next: null }, { names: ['index/6', 'index/7'], next: null },
        { names: ['index/7', 'views/' + id + '/6'], next: null }, { names: ['index/01'], next: null },
        { names: ['index/7'], next: 8 }, { names: [], next: 1 }, { names: Array(6).fill('index/7'), next: null }]) {
        response = json(value); await assert.rejects(client.list('index', bearer), RelayError);
    }
    response = json({ names: ['index/8'], next: null }); await assert.rejects(client.list('index', bearer, 8), RelayError);
});

test('declared oversize is refused before a reader opens; dishonest lengths and oversized errors abort while streaming', async () => {
    let reads = 0, lastSignal: AbortSignal | undefined;
    const declared = new Response(new Uint8Array(1), { headers: { 'Content-Length': '4097' } });
    const getReader = declared.body!.getReader.bind(declared.body!);
    declared.body!.getReader = (() => { reads++; return getReader(); }) as ReadableStream<Uint8Array<ArrayBuffer>>['getReader'];
    let response = declared;
    const client = new RelayClient(origin, id, fake((_url, init) => { lastSignal = init.signal!; return response; }));
    await assert.rejects(client.health(), RelayError); assert.equal(reads, 0); assert.equal(lastSignal!.aborted, true);
    for (const status of [200, 401]) {
        let cancelled = false;
        response = new Response(new ReadableStream<Uint8Array>({ start(controller) {
            controller.enqueue(new Uint8Array(status === 200 ? 1048576 : 4096)); controller.enqueue(new Uint8Array(1));
        }, cancel() { cancelled = true; } }), { status, headers: { 'Content-Length': '1' } });
        await assert.rejects(client.getObject('index/1', bearer), RelayError);
        assert.equal(cancelled, true); assert.equal(lastSignal!.aborted, true);
    }
});

test('cancellation and the 30-second deadline interrupt a stalled response without waiting for stream cancellation', async context => {
    context.mock.timers.enable({ apis: ['setTimeout'] });
    const reached = Promise.withResolvers<void>(); let signal: AbortSignal | undefined;
    const client = new RelayClient(origin, id, fake((_url, init) => {
        signal = init.signal!; reached.resolve(); return new Response(new ReadableStream({ cancel() { return new Promise(() => {}); } }));
    }));
    const pending = client.health(); await reached.promise; context.mock.timers.tick(30000);
    await assert.rejects(pending, RelayError); assert.equal(signal!.aborted, true); context.mock.timers.reset();
    const controller = new AbortController(); controller.abort();
    await assert.rejects(client.health(controller.signal), RelayError);
});

test('native fetch refuses a redirect before a bearer token can reach its target', async () => {
    let redirected = 0;
    const target = createServer((_request, response) => { redirected++; response.end(); });
    const source = createServer((_request, response) => {
        const address = target.address(); assert.ok(address && typeof address === 'object');
        response.writeHead(302, { Location: `http://localhost:${address.port}/invented-target` }); response.end();
    });
    try {
        await new Promise<void>(resolve => target.listen(0, '127.0.0.1', resolve));
        await new Promise<void>(resolve => source.listen(0, '127.0.0.1', resolve));
        const address = source.address(); assert.ok(address && typeof address === 'object');
        await assert.rejects(new RelayClient(`http://localhost:${address.port}`, id).getObject('index/1', bearer), RelayError);
        assert.equal(redirected, 0);
    } finally {
        await Promise.all([new Promise<void>(resolve => source.close(() => resolve())), new Promise<void>(resolve => target.close(() => resolve()))]);
    }
});

test('an injected native-style fetch function is invoked without the client object as its receiver', async () => {
    const fetcher = function (this: unknown): Promise<Response> {
        assert.equal(this, undefined, 'browser fetch rejects a RelayClient receiver');
        return Promise.resolve(json(fixture()));
    } as typeof fetch;
    assert.equal((await new RelayClient(origin, id, fetcher).health()).value!.claimed, true);
});
