// Optional real-browser persistence check. Uses only a fresh, disposable profile and invented data.
import assert from 'node:assert/strict';
import { createCipheriv, createDecipheriv, createPrivateKey, createPublicKey, diffieHellman, hkdfSync } from 'node:crypto';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { decodeB64, encodeB64, joinBytes, utf8 } from '../src/encoding.ts';
import { bucketNames } from '../src/view-payloads.ts';
import { writeJson } from '../../shared/json.ts';
import { id, publicBytes, raw, sealed } from './owner-fixture.ts';

const ownerPrivate = createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), Buffer.from(raw)]),
    format: 'der', type: 'pkcs8' });
const ownerPublic = new Uint8Array(createPublicKey(ownerPrivate).export({ format: 'der', type: 'spki' }).subarray(-32));
let delivery: Uint8Array, deviceKeyBytes: Uint8Array;
const fixtures = {
    id, ownerPublic: [...ownerPublic], token: encodeB64(raw),
    index: [...sealed('index/5', 'account', 1, { revision: 5, generated_at: '2026-10-08T07:06:05Z',
        binders: [{ id, name: 'Invented binder', view_version: 7, key: encodeB64(raw) }] })],
    view: [...sealed(`views/${id}/7`, id, 1, { version: 7, generated_at: '2026-10-08T07:06:05Z', today: null,
        binder: { name: 'Invented binder', description: null }, notes_omitted: false,
        items: [], closed: [], documents: [], buckets: Object.fromEntries(bucketNames.map(b => [b, []])) })],
};
function page(write: boolean): string {
    return `<!doctype html><html><body>WAIT<script type="module">
import { BrowserStore } from '/modules/web/src/browser-store.js';
import { openView } from '/modules/web/src/view-payloads.js';
import { sendOne } from '/modules/web/src/sender.js';
import { RelayClient } from '/modules/web/src/relay-client.js';
import { pairDevice } from '/modules/web/src/pairing-flow.js';
const f = ${JSON.stringify(fixtures)};
let stage = 'init';
const check = value => { if (!value) throw Error('check failed'); };
try {
    stage = 'health';
    const client = new RelayClient(location.origin, f.id);
    const health = await client.health(); check(health.value.instance === '0'.repeat(32));
    stage = 'storage';
    const store = await BrowserStore.open('disposable-fixture');
    if (${write}) {
        const paired = await pairDevice(store, { relayOrigin: location.origin, pairingId: f.id, deviceId: f.id,
            secret: f.id, ownerPublicKey: new Uint8Array(f.ownerPublic) }, 'Invented phone',
            { onCode: code => check(/^[0-9]{6}$/.test(code)) });
        check(paired.acknowledgement === 'acknowledged');
        check(await store.acceptIndex(5, 1, new Uint8Array(f.index)));
        check(await store.acceptView(f.id, 7, new Uint8Array(f.view)));
        const entry = await store.enqueue({ type: 'note', text: 'Invented queued note' }, '2026-10-08T07:06:05Z');
        check(entry.seq === 1 && entry.state === 'queued');
        stage = 'send';
        check(await sendOne(store, async (attempt, signal) => {
            const pending = await store.readOutbox();
            check(pending.entries[0].state === 'attempted' && attempt.entry.bytes.length > 0);
            return client.send(attempt, signal);
        }) === 'recorded');
    }
    stage = 'after-send';
    const state = await store.read();
    check(state.pairing?.epoch === 1 && state.pairing.nextSeq === 2 && !state.pairing.acknowledgementPending);
    const cached = await store.readView(f.id);
    check(state.index?.revision === 5 && state.viewMarks[f.id] === 7 && cached?.version === 7);
    const outbox = await store.readOutbox();
    check(outbox.entries.length === 1 && outbox.entries[0].state === 'sent' && outbox.entries[0].seq === 1);
    check(outbox.entries[0].generation === state.pairing.generation && !JSON.stringify(outbox).includes('Invented queued note'));
    const p = state.pairing, b = state.index.binders[0];
    check(!p.accountKey.extractable && !p.deviceKey.extractable && !p.ownerKey.extractable && !b.key.extractable);
    const view = await openView(f.id, 7, 1, b.key, p.ownerKey, cached.bytes);
    check(view.binder.name === 'Invented binder');
    check(!JSON.stringify(state).includes('Invented binder'));
    if (!${write}) {
        const published = await client.getObject('devices/' + f.id + '/outcomes/1', f.token);
        check(published.status === 200 && await store.acceptOutcomes(1, published.value));
        check((await store.readOutbox()).entries.length === 0 && (await store.read()).pairing.outcomesRevision === 1);
    }
    store.close(); document.body.textContent = 'PASS';
} catch { document.body.textContent = 'FAIL:' + stage; }
</script></body></html>`;
}
let sentId: string | undefined;
const server = createServer(async (request, response) => {
    const pathname = new URL(request.url!, 'http://localhost').pathname;
    if (pathname === '/v0/health') {
        response.setHeader('Content-Type', 'application/json');
        response.end(JSON.stringify({ protocol: 0, claimed: true, instance: '0'.repeat(32) })); return;
    }
    if (pathname === `/v0/pairings/${id}/join` && request.method === 'POST') {
        const chunks: Buffer[] = [];
        for await (const chunk of request) chunks.push(chunk);
        const payload = JSON.parse(Buffer.concat(chunks).toString('utf8')), B = decodeB64(payload.device_public_key)!;
        const peer = createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), Buffer.from(B)]),
            format: 'der', type: 'spki' });
        const shared = diffieHellman({ privateKey: ownerPrivate, publicKey: peer });
        const info = (kind: string) => joinBytes(utf8(`sprava-companion/v0 ${kind}`), ownerPublic, B, decodeB64(id)!);
        const wrap = new Uint8Array(hkdfSync('sha256', shared, utf8(id), info('wrap'), 32));
        deviceKeyBytes = new Uint8Array(hkdfSync('sha256', shared, utf8(id), info('device'), 32));
        const nonce = new Uint8Array(12), cipher = createCipheriv('aes-256-gcm', wrap, nonce);
        cipher.setAAD(utf8(`sprava-companion/v0|pairings/${id}/key|wrap|1`));
        const value = writeJson({ account_key: fixtures.token, epoch: 1, device_id: id,
            min_index_revision: 5, owner_signing_key: encodeB64(publicBytes) });
        delivery = writeJson({ v: 0, kid: 'wrap', e: 1, n: encodeB64(nonce),
            c: encodeB64(Buffer.concat([cipher.update(value), cipher.final(), cipher.getAuthTag()])) });
        response.setHeader('Content-Type', 'application/json');
        response.end(JSON.stringify({ device_id: id, device_token: fixtures.token,
            expires_at: new Date(Date.now() + 600000).toISOString().replace(/\.\d{3}Z$/, 'Z') })); return;
    }
    if (pathname === `/v0/pairings/${id}/key` && delivery) { response.end(delivery); return; }
    if (pathname === `/v0/pairings/${id}/ack`) { response.writeHead(204); response.end(); return; }
    const requestId = /^\/v0\/requests\/([A-Za-z0-9_-]{22})$/.exec(pathname)?.[1];
    if (requestId && request.method === 'POST') {
        let stage = 'authorization';
        try {
            assert.equal(request.headers.authorization, `Bearer ${fixtures.token}`);
            stage = 'media';
            assert.equal(request.headers['content-type'], 'application/octet-stream');
            const chunks: Buffer[] = []; let count = 0;
            for await (const chunk of request) { count += chunk.length; assert.ok(count <= 65536); chunks.push(chunk); }
            stage = 'envelope';
            const envelope = JSON.parse(Buffer.concat(chunks).toString('utf8'));
            const cipher = decodeB64(envelope.c)!;
            stage = 'decrypt';
            const decipher = createDecipheriv('aes-256-gcm', deviceKeyBytes, decodeB64(envelope.n)!);
            decipher.setAAD(utf8(`sprava-companion/v0|requests/${id}/${requestId}|device|1`));
            decipher.setAuthTag(cipher.subarray(-16));
            const plain = Buffer.concat([decipher.update(cipher.subarray(0, -16)), decipher.final()]);
            const payload = JSON.parse(plain.toString('utf8'));
            stage = 'payload';
            assert.equal(payload.seq, 1); assert.equal(payload.text, 'Invented queued note');
            sentId = requestId; response.writeHead(201); response.end();
        } catch { process.stdout.write('Fixture rejected at ' + stage + '\n'); response.writeHead(400); response.end(); }
        return;
    }
    if (pathname === `/v0/objects/devices/${id}/outcomes/1` && sentId) {
        const payload = { device_id: id, revision: 1, generated_at: '2026-10-08T07:06:05Z',
            outcomes: [{ request_id: sentId, seq: 1, outcome: 'applied', decided_at: '2026-10-08T07:06:05Z' }], pad: '' };
        payload.pad = ' '.repeat(640 - writeJson(payload).length);
        response.setHeader('Content-Type', 'application/octet-stream');
        response.end(sealed(`devices/${id}/outcomes/1`, 'device', 0, payload, true, undefined, deviceKeyBytes)); return;
    }
    if (pathname === '/write' || pathname === '/read') {
        response.setHeader('Content-Type', 'text/html'); response.end(page(pathname === '/write')); return;
    }
    if (/^\/modules\/(?:web\/src|shared)\/[a-z-]+\.js$/.test(pathname)) {
        try {
            const bytes = await readFile(new URL(`../dist/${pathname.slice('/modules/'.length)}`, import.meta.url));
            response.setHeader('Content-Type', 'text/javascript'); response.end(bytes); return;
        } catch { /* Only built test modules are served. */ }
    }
    response.writeHead(404); response.end();
});
const profile = await mkdtemp(join(tmpdir(), 'sprava-companion-chrome-'));
try {
    await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
    const address = server.address(); assert.ok(address && typeof address === 'object');
    const chrome = process.env.SPRAVA_TEST_CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
    for (const phase of ['write', 'read']) {
        const child = spawn(chrome, ['--headless', '--disable-gpu', '--no-first-run',
            '--no-default-browser-check', '--disable-extensions', '--disable-background-networking',
            `--user-data-dir=${profile}`, '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0'],
            { stdio: ['ignore', 'ignore', 'pipe'] });
        const exited = once(child, 'exit');
        const timer = setTimeout(() => child.kill('SIGTERM'), 30000);
        let socket: WebSocket | undefined;
        try {
            const endpoint = await new Promise<string>((resolve, reject) => {
                let stderr = '';
                child.stderr.on('data', bytes => {
                    stderr += bytes.toString();
                    const match = /DevTools listening on (ws:\/\/[^\s]+)/.exec(stderr);
                    if (match) resolve(match[1]!);
                });
                child.once('error', reject);
                child.once('exit', () => reject(new Error('Disposable Chrome exited before connecting')));
            });
            const port = new URL(endpoint).port;
            const target = await fetch(`http://127.0.0.1:${port}/json/new?http://localhost:${address.port}/${phase}`,
                { method: 'PUT' }).then(r => r.json()) as { webSocketDebuggerUrl: string };
            socket = new WebSocket(target.webSocketDebuggerUrl);
            await once(socket, 'open');
            const completed = new Promise<string>((resolve, reject) => {
                socket!.addEventListener('message', event => {
                    const message = JSON.parse(String(event.data));
                    if (message.id !== 1) return;
                    if (message.error || message.result.exceptionDetails) reject(new Error('Browser test evaluation failed'));
                    else resolve(message.result.result.value);
                });
                socket!.addEventListener('close', () => reject(new Error('Disposable Chrome disconnected')));
            });
            socket.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: {
                expression: `new Promise(resolve => { const poll = () => {
                    const value = document.body?.textContent;
                    if (value === 'PASS' || value?.startsWith('FAIL:')) resolve(value); else setTimeout(poll, 20);
                }; poll(); })`, awaitPromise: true, returnByValue: true,
            } }));
            assert.equal(await completed, 'PASS', `${phase}: isolated browser check failed`);
        } finally {
            socket?.close(); clearTimeout(timer); child.kill('SIGTERM'); await exited;
        }
    }
    process.stdout.write('PASS: Chrome pairs with an independent owner, sends encrypted HTTP requests, restarts, and reconciles signed outcomes\n');
} finally {
    await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(profile, { recursive: true, force: true });
}
