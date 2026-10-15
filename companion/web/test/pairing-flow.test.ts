import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createCipheriv, createDecipheriv, createPrivateKey, createPublicKey, diffieHellman, hkdfSync } from 'node:crypto';
import { IDBFactory } from 'fake-indexeddb';
import { BrowserStore } from '../src/browser-store.ts';
import { pairDevice, resumeAcknowledgement, PairingFlowError } from '../src/pairing-flow.ts';
import { decodeB64, encodeB64, joinBytes, utf8 } from '../src/encoding.ts';
import { confirmationCode } from '../src/pairing-keys.ts';
import { writeJson } from '../../shared/json.ts';
import { id, otherId, raw, publicBytes } from './owner-fixture.ts';
const now = Date.parse('2026-10-08T07:06:05Z');
const a = createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), Buffer.from(raw)]),
    format: 'der', type: 'pkcs8' });
const A = new Uint8Array(createPublicKey(a).export({ format: 'der', type: 'spki' }).subarray(-32));
const link = () => ({ relayOrigin: 'https://relay.example', pairingId: id, deviceId: id, secret: otherId, ownerPublicKey: A });
const json = (v: unknown, status = 200) => new Response(JSON.stringify(v), { status });
async function fixture() {
    const factory = new IDBFactory(), store = await BrowserStore.open('fixture', factory);
    let clock = now, joinFailures = 0, lost = false, acknowledgements = 0, ackStatus = 204, expectedCode = '', delivery: Uint8Array;
    let beforeKey: (() => Promise<void>) | undefined;
    const joins: string[] = [], waits: number[] = [];
    const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
        const path = new URL(String(input)).pathname;
        if (path === '/v0/health') return json({ protocol: 0, claimed: true, instance: '0'.repeat(32) });
        if (path.endsWith('/join')) {
            const body = new TextDecoder().decode(init!.body as Uint8Array); joins.push(body);
            if (lost) throw new Error('Invented lost reply');
            if (joinFailures-- > 0) return json({}, 503);
            const v = JSON.parse(body), B = decodeB64(v.device_public_key)!;
            const b = createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), Buffer.from(B)]),
                format: 'der', type: 'spki' });
            const Z = diffieHellman({ privateKey: a, publicKey: b });
            const info = (kind: string) => joinBytes(utf8(`sprava-companion/v0 ${kind}`), A, B, decodeB64(id)!);
            const W = new Uint8Array(hkdfSync('sha256', Z, utf8(id), info('wrap'), 32));
            expectedCode = confirmationCode(new Uint8Array(hkdfSync('sha256', Z, utf8(id), info('confirm'), 4)));
            const hello = JSON.parse(new TextDecoder().decode(decodeB64(v.hello)!)), cipher = decodeB64(hello.c)!;
            const decipher = createDecipheriv('aes-256-gcm', W, decodeB64(hello.n)!);
            decipher.setAAD(utf8(`sprava-companion/v0|pairings/${id}/hello|wrap|0`)); decipher.setAuthTag(cipher.subarray(-16));
            const plain = Buffer.concat([decipher.update(cipher.subarray(0, -16)), decipher.final()]);
            assert.equal(plain.length, 512); assert.equal(JSON.parse(plain.toString()).label, 'Invented phone');
            const nonce = new Uint8Array(12), encrypt = createCipheriv('aes-256-gcm', W, nonce);
            encrypt.setAAD(utf8(`sprava-companion/v0|pairings/${id}/key|wrap|1`));
            const packet = writeJson({ account_key: encodeB64(raw), epoch: 1, device_id: id,
                min_index_revision: 0, owner_signing_key: encodeB64(publicBytes) });
            const encrypted = Buffer.concat([encrypt.update(packet), encrypt.final(), encrypt.getAuthTag()]);
            delivery = writeJson({ v: 0, kid: 'wrap', e: 1, n: encodeB64(nonce), c: encodeB64(encrypted) });
            return json({ device_id: id, device_token: encodeB64(raw), expires_at: '2026-10-08T07:16:05Z' });
        }
        if (path.endsWith('/key')) { if (beforeKey) await beforeKey(); return new Response(new Uint8Array(delivery)); }
        if (path.endsWith('/ack')) {
            acknowledgements++; const p = (await store.read()).pairing;
            assert.ok(p && p.acknowledgementPending && !p.deviceKey.extractable && !p.ownerKey.extractable);
            return ackStatus === 204 ? new Response(null, { status: 204 }) : json({}, ackStatus);
        }
        return json({}, 404);
    }) as typeof fetch;
    return { store, factory, joins, waits, fetcher,
        environment: { fetcher, clock: () => clock, wait: async (ms: number) => { waits.push(ms); clock += ms; } },
        code: () => expectedCode, acks: () => acknowledgements,
        failJoins(n: number) { joinFailures = n; }, loseReply() { lost = true; },
        beforeKey(fn: () => Promise<void>) { beforeKey = fn; }, setAck(n: number) { ackStatus = n; }, setClock(n: number) { clock = n; } };
}

test('pairing interoperates with independent owner crypto and acknowledges only after durable pinned-key installation', async () => {
    const f = await fixture(); let shown = '';
    const result = await pairDevice(f.store, link(), 'Invented phone', { ...f.environment, onCode: code => { shown = code; } });
    assert.equal(shown, f.code()); assert.match(shown, /^\d{6}$/); assert.equal(result.acknowledgement, 'acknowledged');
    assert.equal((await f.store.read()).pairing!.generation, result.generation);
    assert.equal((await f.store.read()).pairing!.acknowledgementPending, false); assert.equal(f.acks(), 1);
    await assert.rejects(pairDevice(f.store, link(), 'Invented phone', f.environment), PairingFlowError);
    assert.equal(f.joins.length, 1); f.store.close();
});

test('only explicit 503 join replies retry, with identical transcript/body and bounded exponential delays', async () => {
    const f = await fixture(); f.failJoins(4);
    await pairDevice(f.store, link(), 'Invented phone', f.environment);
    assert.deepEqual(f.waits, [5000,10000,20000,30000]); assert.equal(new Set(f.joins).size, 1); f.store.close();
    const lost = await fixture(); lost.loseReply();
    await assert.rejects(pairDevice(lost.store, link(), 'Invented phone', lost.environment), PairingFlowError);
    assert.equal(lost.joins.length, 1); assert.equal((await lost.store.read()).pairing, undefined);
    assert.equal((await lost.store.read()).reservation, undefined); lost.store.close();
});

test('a newer reservation cancels an old delivery without installing keys or acknowledging it', async () => {
    const f = await fixture(); f.beforeKey(async () => { await f.store.reserve(otherId); });
    await assert.rejects(pairDevice(f.store, link(), 'Invented phone', f.environment), PairingFlowError);
    assert.equal((await f.store.read()).pairing, undefined);
    assert.equal((await f.store.read()).reservation!.pairingId, otherId); assert.equal(f.acks(), 0); f.store.close();
});

test('ack failures keep durable keys/flag and startup recovery clears it only on success or expiry', async () => {
    const f = await fixture(); f.setAck(503);
    assert.equal((await pairDevice(f.store, link(), 'Invented phone', f.environment)).acknowledgement, 'pending');
    assert.equal((await f.store.read()).pairing!.acknowledgementPending, true);
    f.setAck(404); assert.equal(await resumeAcknowledgement(f.store, f.environment), 'pending');
    f.setClock(now + 600000); assert.equal(await resumeAcknowledgement(f.store, f.environment), 'expired');
    assert.equal((await f.store.read()).pairing!.acknowledgementPending, false); f.store.close();
});

test('an old flow cannot acknowledge an installed replacement generation', async () => {
    const f = await fixture(), install = f.store.install.bind(f.store);
    f.store.install = async (...args) => {
        const done = await install(...args);
        const request = f.factory.open('fixture', 1);
        const db = await new Promise<IDBDatabase>(resolve => { request.onsuccess = () => resolve(request.result); });
        const tx = db.transaction('state', 'readwrite', { durability: 'strict' }), state = tx.objectStore('state'), read = state.get('current');
        read.onsuccess = () => { const value = read.result; value.pairing.generation = otherId; state.put(value, 'current'); };
        await new Promise<void>(resolve => { tx.oncomplete = () => resolve(); }); db.close(); return done;
    };
    assert.equal((await pairDevice(f.store, link(), 'Invented phone', f.environment)).acknowledgement, 'stale');
    assert.equal(f.acks(), 0); assert.equal((await f.store.read()).pairing!.acknowledgementPending, true); f.store.close();
});


test('cancellation before delivery installs nothing and retires only the flow reservation', async () => {
    const f = await fixture(), controller = new AbortController();
    f.beforeKey(async () => { controller.abort(); });
    await assert.rejects(pairDevice(f.store, link(), 'Invented phone', { ...f.environment, signal: controller.signal }), PairingFlowError);
    assert.equal((await f.store.read()).pairing, undefined); assert.equal((await f.store.read()).reservation, undefined);
    assert.equal(f.acks(), 0); f.store.close();
});
