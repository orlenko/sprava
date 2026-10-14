// Optional real-browser persistence check. Uses only a fresh, disposable profile and invented data.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { encodeB64 } from '../src/encoding.ts';
import { bucketNames } from '../src/view-payloads.ts';
import { id, publicBytes, raw, sealed } from './owner-fixture.ts';

const fixtures = {
    id, raw: [...raw], token: encodeB64(raw),
    delivery: [...sealed(`pairings/${id}/key`, 'wrap', 1, { device_id: id, epoch: 1, min_index_revision: 5,
        account_key: encodeB64(raw), owner_signing_key: encodeB64(publicBytes) }, false)],
    index: [...sealed('index/5', 'account', 1, { revision: 5, generated_at: '2026-10-08T07:06:05Z',
        binders: [{ id, name: 'Invented binder', view_version: 7, key: encodeB64(raw) }] })],
    view: [...sealed(`views/${id}/7`, id, 1, { version: 7, generated_at: '2026-10-08T07:06:05Z', today: null,
        binder: { name: 'Invented binder', description: null }, notes_omitted: false,
        items: [], closed: [], documents: [], buckets: Object.fromEntries(bucketNames.map(b => [b, []])) })],
};
function page(write: boolean): string {
    return `<!doctype html><html><body>WAIT<script type="module">
import { BrowserStore } from '/modules/web/src/browser-store.js';
import { importKey } from '/modules/web/src/sealed.js';
import { openView } from '/modules/web/src/view-payloads.js';
const f = ${JSON.stringify(fixtures)};
const check = value => { if (!value) throw Error('check failed'); };
try {
    const store = await BrowserStore.open('disposable-fixture');
    if (${write}) {
        const reservation = await store.reserve(f.id); check(reservation);
        check(await store.install(reservation, { deviceId: f.id, relayOrigin: 'https://relay.example',
            instanceId: '0'.repeat(32), token: f.token, expiresAt: '2026-10-08T07:16:05Z',
            wrapKey: await importKey(new Uint8Array(f.raw)), deviceKey: await importKey(new Uint8Array(f.raw)),
            delivery: new Uint8Array(f.delivery) }));
        check(await store.acceptIndex(5, 1, new Uint8Array(f.index)));
        check(await store.acceptView(f.id, 7, new Uint8Array(f.view)));
        check(await store.acknowledged(reservation.generation, f.id));
    }
    const state = await store.read();
    check(state.pairing?.epoch === 1 && state.pairing.nextSeq === 1 && !state.pairing.acknowledgementPending);
    const cached = await store.readView(f.id);
    check(state.index?.revision === 5 && state.viewMarks[f.id] === 7 && cached?.version === 7);
    const p = state.pairing, b = state.index.binders[0];
    check(!p.accountKey.extractable && !p.deviceKey.extractable && !p.ownerKey.extractable && !b.key.extractable);
    const view = await openView(f.id, 7, 1, b.key, p.ownerKey, cached.bytes);
    check(view.binder.name === 'Invented binder');
    check(!JSON.stringify(state).includes('Invented binder'));
    store.close(); document.body.textContent = 'PASS';
} catch { document.body.textContent = 'FAIL'; }
</script></body></html>`;
}
const server = createServer(async (request, response) => {
    const pathname = new URL(request.url!, 'http://localhost').pathname;
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
            const target = await fetch(`http://127.0.0.1:${port}/json/new?http://127.0.0.1:${address.port}/${phase}`,
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
                    if (value === 'PASS' || value === 'FAIL') resolve(value); else setTimeout(poll, 20);
                }; poll(); })`, awaitPromise: true, returnByValue: true,
            } }));
            assert.equal(await completed, 'PASS', `${phase}: isolated browser check failed`);
        } finally {
            socket?.close(); clearTimeout(timer); child.kill('SIGTERM'); await exited;
        }
    }
    process.stdout.write('PASS: encrypted state and non-extractable keys survive a real Chrome restart\n');
} finally {
    await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(profile, { recursive: true, force: true });
}
