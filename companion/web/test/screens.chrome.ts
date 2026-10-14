// Actual PWA screens in a fresh, disposable Chrome profile. Every key and document is invented.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createDecipheriv } from 'node:crypto';
import { once } from 'node:events';
import { createServer } from 'node:http';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { decodeB64, encodeB64, utf8 } from '../src/encoding.ts';
import { bucketNames } from '../src/view-payloads.ts';
import { id, publicBytes, raw, sealed } from './owner-fixture.ts';

const title = '<img src=x onerror="window.injected=true">';
const timestamp = '2026-10-08T07:06:05Z';
const index = sealed('index/5', 'account', 1, { revision: 5, generated_at: timestamp,
    binders: [{ id, name: title, view_version: 7, key: encodeB64(raw) }] });
const view = sealed(`views/${id}/7`, id, 1, { version: 7, generated_at: timestamp, today: null,
    binder: { name: title, description: 'Invented fixture' }, notes_omitted: false,
    items: [7, '7'].map((id, i) => ({ id, title: `Invented ${i === 0 ? 'numeric' : 'string'} item`,
        changed_in: 7, status: 'open', priority: null, due: null, waiting_on: null, follow_up_at: null,
        notes: null, tags: [], contexts: [] })), closed: [], documents: [],
    buckets: Object.fromEntries(bucketNames.map(b => [b, b === 'today' ? [7, '7'] : []])) });
const delivery = sealed(`pairings/${id}/key`, 'wrap', 1, { device_id: id, epoch: 1,
    min_index_revision: 5, account_key: encodeB64(raw), owner_signing_key: encodeB64(publicBytes) }, false);
let sentText: string | undefined;
let serverError: unknown;
const server = createServer((request, response) => {
    void respond(request, response).catch(error => { serverError = error; response.writeHead(500); response.end(); });
});
async function respond(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const url = new URL(request.url!, 'http://localhost');
    response.setHeader('Cache-Control', 'no-cache');
    if (url.pathname === '/v0/objects') {
        response.setHeader('Content-Type', 'application/json');
        response.end(JSON.stringify({ names: url.searchParams.get('prefix') === 'index/' ? ['index/5'] : [], next: null })); return;
    }
    if (url.pathname === '/v0/objects/index/5' || url.pathname === `/v0/objects/views/${id}/7`) {
        response.end(url.pathname.endsWith('/5') ? index : view); return;
    }
    if (url.pathname.startsWith('/v0/requests/')) {
        const chunks: Buffer[] = []; for await (const chunk of request) chunks.push(chunk);
        const envelope = JSON.parse(Buffer.concat(chunks).toString()), ciphertext = decodeB64(envelope.c), nonce = decodeB64(envelope.n);
        assert.ok(ciphertext && nonce);
        const decipher = createDecipheriv('aes-256-gcm', raw, nonce);
        decipher.setAAD(utf8(`sprava-companion/v0|requests/${id}/${url.pathname.split('/').at(-1)}|device|1`));
        decipher.setAuthTag(ciphertext.subarray(-16));
        sentText = JSON.parse(Buffer.concat([decipher.update(ciphertext.subarray(0, -16)), decipher.final()]).toString()).text;
        response.writeHead(201); response.end(); return;
    }
    if (url.pathname === '/frame.html') {
        response.setHeader('Content-Type', 'text/html'); response.end('<!doctype html><iframe src="/"></iframe>'); return;
    }
    const path = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
    if (!/^[a-zA-Z0-9_./-]+$/.test(path) || path.includes('..')) { response.writeHead(404); response.end(); return; }
    try {
        const body = await readFile(new URL(`../dist/${path}`, import.meta.url));
        response.setHeader('Content-Type', path.endsWith('.js') ? 'text/javascript' : path.endsWith('.css') ? 'text/css' :
            path.endsWith('.html') ? 'text/html' : path.endsWith('.svg') ? 'image/svg+xml' : 'application/json');
        response.end(body);
    } catch { response.writeHead(404); response.end(); }
}
const profile = await mkdtemp(join(tmpdir(), 'sprava-pwa-chrome-'));
let child: ReturnType<typeof spawn> | undefined, exited: Promise<unknown> | undefined, socket: WebSocket | undefined;
let timer: ReturnType<typeof setTimeout> | undefined;
try {
    await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
    const address = server.address(); assert.ok(address && typeof address === 'object');
    const origin = `http://localhost:${address.port}`;
    const chrome = process.env.SPRAVA_TEST_CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
    async function openBrowser(): Promise<void> {
    child = spawn(chrome, ['--headless', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
        '--disable-extensions', '--disable-background-networking', `--user-data-dir=${profile}`,
        '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0'], { stdio: ['ignore', 'ignore', 'pipe'] });
    exited = once(child, 'exit'); timer = setTimeout(() => child?.kill('SIGTERM'), 60000);
    const endpoint = await new Promise<string>((resolve, reject) => {
        let stderr = '';
        child!.stderr!.on('data', bytes => { stderr += bytes.toString();
            const match = /DevTools listening on (ws:\/\/[^\s]+)/.exec(stderr); if (match) resolve(match[1]!); });
        child!.once('error', reject); child!.once('exit', () => reject(new Error('Disposable Chrome exited')));
    });
    const target = await fetch(`http://127.0.0.1:${new URL(endpoint).port}/json/new?${origin}/#pair=invalid`,
        { method: 'PUT' }).then(r => r.json()) as { webSocketDebuggerUrl: string };
    socket = new WebSocket(target.webSocketDebuggerUrl); await once(socket, 'open');
    }
    await openBrowser();
    let sequence = 0;
    const pending = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void }>();
    function messaging(): void {
    socket!.addEventListener('message', event => {
        const message = JSON.parse(String(event.data)), item = pending.get(message.id);
        if (!item) return; pending.delete(message.id);
        if (message.error || message.result.exceptionDetails) item.reject(new Error('Invented browser fixture failed: ' +
            JSON.stringify(message.error ?? message.result.exceptionDetails)));
        else item.resolve(message.result);
    });
    socket!.addEventListener('close', () => { for (const item of pending.values()) item.reject(new Error('Chrome disconnected')); });
    }
    messaging();
    function command(method: string, params: object = {}): Promise<any> {
        return new Promise((resolve, reject) => { const id = ++sequence; pending.set(id, { resolve, reject });
            socket!.send(JSON.stringify({ id, method, params })); });
    }
    function loaded(): Promise<void> {
        return new Promise(resolve => {
            const listener = (event: MessageEvent) => {
                if (JSON.parse(String(event.data)).method !== 'Page.loadEventFired') return;
                socket!.removeEventListener('message', listener); resolve();
            };
            socket!.addEventListener('message', listener);
        });
    }
    await command('Page.enable');
    const evaluate = async (expression: string) => {
        try { return (await command('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })).result.value; }
        catch (error) { throw new Error(`Screen check: ${expression.slice(0, 180)}`, { cause: error }); }
    };
    const wait = async (condition: string) => {
        const until = Date.now() + 10000;
        while (Date.now() < until) {
            try { if (await evaluate(condition)) return; } catch { /* A navigation replaces the evaluation context. */ }
            await new Promise(resolve => setTimeout(resolve, 20));
        }
        throw new Error(`Screen condition timed out: ${condition}`);
    };
    await wait(`document.querySelector('#device-label') !== null`);
    const initialLoaded = loaded(); await command('Page.navigate', { url: origin + '/index.html#pair=invalid' }); await initialLoaded;
    await wait(`location.pathname === '/index.html' && document.querySelector('#device-label') !== null && location.hash === ''`);
    assert.equal(await evaluate('location.hash'), '');
    await evaluate(`(async () => {
        const { BrowserStore } = await import('/web/src/browser-store.js');
        const { importKey } = await import('/web/src/sealed.js');
        const store = await BrowserStore.open(), r = await store.reserve(${JSON.stringify(id)});
        const raw = new Uint8Array(${JSON.stringify([...raw])});
        await store.install(r, { deviceId: ${JSON.stringify(id)}, relayOrigin: location.origin, instanceId: '0'.repeat(32),
            token: ${JSON.stringify(encodeB64(raw))}, expiresAt: ${JSON.stringify(timestamp)},
            deviceKey: await importKey(raw), wrapKey: await importKey(raw), delivery: new Uint8Array(${JSON.stringify([...delivery])}) });
        await store.acknowledged(r.generation, r.pairingId);
        await store.acceptIndex(5, 1, new Uint8Array(${JSON.stringify([...index])}));
        await store.acceptView(${JSON.stringify(id)}, 7, new Uint8Array(${JSON.stringify([...view])}));
        store.close(); const channel = new BroadcastChannel('sprava-companion-changes'); channel.postMessage('changed'); channel.close();
    })()`);
    await wait(`document.querySelector('nav button') !== null`);
    await evaluate(`document.querySelector('nav button').click()`);
    await wait(`document.querySelector('#binder-view').textContent.includes('Invented string item')`);
    assert.equal(await evaluate(`document.querySelector('#binder-view img') !== null || window.injected === true`), false);
    assert.equal(await evaluate(`document.querySelector('#binder-view').textContent.includes('Invented numeric item')`), true);
    await evaluate(`const editor = document.querySelector('#note'); editor.value = 'Invented unsent draft'; editor.dispatchEvent(new Event('input'));
        document.querySelector('header button').click();`);
    await wait(`!document.querySelector('header button').disabled`);
    assert.equal(await evaluate(`document.querySelector('#note').value`), 'Invented unsent draft');
    await wait(`document.querySelector('#note').nextElementSibling.nextElementSibling.textContent.includes('draft saved')`);
    // Terminate the disposable browser without unload handlers, then reopen the same owned profile.
    socket!.close(); clearTimeout(timer); child!.kill('SIGKILL'); await exited;
    await openBrowser(); messaging(); await command('Page.enable');
    await wait(`document.querySelector('#note')?.value === 'Invented unsent draft'`);
    await wait(`document.querySelector('#note').nextElementSibling.nextElementSibling.textContent.includes('draft saved')`);
    await evaluate(`document.querySelector('#note').value = '\\u0000'; document.querySelector('#note').dispatchEvent(new Event('input'));
        document.querySelector('#note').nextElementSibling.click()`);
    await wait(`document.querySelector('#status').textContent.includes('could not finish')`);
    await wait(`!document.querySelector('#note').nextElementSibling.disabled`);
    assert.equal(await evaluate(`document.querySelector('#note').value`), '\u0000');
    await evaluate(`document.querySelector('#note').value = 'Invented saved note'; document.querySelector('#note').dispatchEvent(new Event('input'));
        document.querySelector('#note').nextElementSibling.click()`);
    await wait(`document.querySelector('#pending').textContent.includes('note #1: sent')`);
    assert.equal(sentText, 'Invented saved note'); assert.equal(await evaluate(`document.querySelector('#note').value`), '');
    await evaluate(`(async () => { await navigator.serviceWorker.ready; if (!navigator.serviceWorker.controller)
        await new Promise(resolve => navigator.serviceWorker.addEventListener('controllerchange', resolve, { once: true })); })()`);
    assert.equal(await evaluate(`(async () => { const keys = await caches.keys(); for (const name of keys) {
        const requests = await (await caches.open(name)).keys(); if (requests.some(r => new URL(r.url).pathname.startsWith('/v0/'))) return true;
    } return false; })()`), false);
    await command('Network.enable');
    await command('Network.emulateNetworkConditions', { offline: true, latency: 0, downloadThroughput: 0, uploadThroughput: 0 });
    const offlineLoaded = loaded(); await command('Page.reload'); await offlineLoaded;
    await wait(`document.querySelector('nav button') !== null`);
    await evaluate(`document.querySelector('nav button').click()`);
    await wait(`document.querySelector('#binder-view').textContent.includes('Invented string item')`);
    await command('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
    await command('Page.navigate', { url: origin + '/frame.html' });
    await wait(`document.querySelector('iframe')?.contentDocument?.body?.textContent.includes('own window')`);
    assert.equal(serverError, undefined);
    process.stdout.write('PASS: PWA text stays inert, typed ids stay distinct, drafts survive refresh/failure/browser termination, saved notes send, shell/cache reopen offline, frames are refused\n');
} finally {
    socket?.close(); clearTimeout(timer); child?.kill('SIGTERM'); if (exited) await exited;
    await new Promise<void>(resolve => server.close(() => resolve())); await rm(profile, { recursive: true, force: true });
}
