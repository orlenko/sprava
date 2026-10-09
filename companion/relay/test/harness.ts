// Runs a relay in this process on a free port, over a fresh local folder, for the endpoint tests.
import { mkdtemp } from 'node:fs/promises';
import { createServer, request, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { CLAIM_TIMING } from '../src/claim.ts';
import { readConfig } from '../src/config.ts';
import { formatTime, newId, newToken, sha256Hex, tokenHash } from '../src/encoding.ts';
import { deviceKeys, ownerRecord, pairingKeys } from '../src/layout.ts';
import { jsonLog } from '../src/log.ts';
import { startRelay, type Handler, type Relay } from '../src/relay.ts';
import { FsStore } from '../src/store/fs.ts';
import { scoped, type Store } from '../src/store/store.ts';

export const WEB_ORIGIN = 'https://companion.example.org';
export const INSTANCE = '0123456789abcdef0123456789abcdef';
export const SETUP_CODE = 'q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJA=';

export interface TestRelay {
    url: string;
    relay: Relay;
    /** The whole folder, unscoped. */
    raw: Store;
    logs: string[];
    ready: Promise<void>;
    close(): Promise<void>;
}

/** Tests take leases that are checked often and need no wait unless they ask for one. */
export const TEST_LEASE = { checkMs: 50, warmupMs: 0 };

export async function serve(handler: Handler): Promise<{ url: string; server: Server }> {
    const server = createServer((req, res) => void handler(req, res));
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    server.unref(); // a failed test that never closes it must not keep the run alive
    return { url: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, server };
}

export interface TestOptions {
    raw?: Store;
    env?: Record<string, string>;
    now?: () => number;
    lease?: { checkMs: number; warmupMs: number };
    /** False to get the relay while it is still warming up. */
    waitReady?: boolean;
    claimTiming?: typeof CLAIM_TIMING;
}

export async function startTestRelay(options: TestOptions = {}): Promise<TestRelay> {
    const raw = options.raw ?? new FsStore(await mkdtemp(join(tmpdir(), 'sprava-relay-')));
    const config = readConfig({
        SPRAVA_INSTANCE: INSTANCE,
        SPRAVA_WEB_ORIGIN: WEB_ORIGIN,
        SPRAVA_SETUP_CODE: SETUP_CODE,
        SPRAVA_STORAGE: 'fs:/unused',
        ...options.env,
    });
    const logs: string[] = [];
    const started = await startRelay(config, scoped(raw, INSTANCE), {
        log: jsonLog((line) => logs.push(line)),
        lease: options.lease ?? TEST_LEASE,
        ...(options.now ? { now: options.now } : {}),
        ...(options.claimTiming ? { claimTiming: options.claimTiming } : {}),
    });
    if (options.waitReady !== false) await started.ready;
    const { url, server } = await serve(started.handler);
    return {
        url,
        relay: started.relay,
        raw,
        logs,
        ready: started.ready,
        close: () => {
            started.stop();
            return new Promise((resolve) => server.close(() => resolve()));
        },
    };
}

/** Claims the relay with the test setup code; returns the owner token. */
export async function claim(t: TestRelay): Promise<string> {
    const token = newToken();
    const res = await fetch(`${t.url}/v0/claim`, {
        method: 'POST',
        body: JSON.stringify({ setup_code: SETUP_CODE, owner_token_sha256: tokenHash(token) }),
    });
    if (res.status !== 204) throw new Error(`claim failed: ${res.status}`);
    return token;
}

export interface Seeded {
    id: string;
    token: string;
    pairing: string;
}

/** Writes a device and its pairing straight into a store, as a join would (§7.8); restart to load it. */
export async function seedDevice(store: Store, options: { active?: boolean; expiresAt?: number; now?: number } = {}): Promise<Seeded> {
    const id = newId();
    const token = newToken();
    const pairing = newId();
    const now = options.now ?? Date.now();
    const json = (value: unknown) => new Uint8Array(Buffer.from(JSON.stringify(value)));
    await store.put(
        pairingKeys(pairing).created,
        json({ owner_public_key: newToken(), device_id: id, secret_sha256: tokenHash(newToken()), expires_at: formatTime(options.expiresAt ?? now + 600_000) }),
    );
    await store.put(pairingKeys(pairing).joined, json({ device_public_key: newToken(), hello: 'aGVsbG8' }));
    await store.put(deviceKeys(id).record, json({ pairing_id: pairing }));
    await store.put(deviceKeys(id).token(tokenHash(token)), json({ joined_at: formatTime(now) }));
    if (options.active) {
        await store.put(pairingKeys(pairing).keySha, new Uint8Array(Buffer.from('0'.repeat(64))));
        await store.put(deviceKeys(id).active, new Uint8Array());
    }
    return { id, token, pairing };
}

export const bearer = (token: string): Record<string, string> => ({ Authorization: `Bearer ${token}` });

/**
 * Sends a body the relay will refuse part-way: the status is taken as soon as the answer arrives, since the relay
 * closes the connection while the client may still be writing (fetch would report only the broken pipe).
 */
export function sendOversized(url: string, method: string, headers: Record<string, string>, body: Uint8Array): Promise<number> {
    return new Promise((resolve, reject) => {
        const req = request(url, { method, headers: { ...headers, 'Content-Length': String(body.length) } }, (res) => {
            res.resume();
            resolve(res.statusCode ?? 0);
        });
        req.on('error', (error) => setTimeout(() => reject(error), 1000));
        req.end(body);
    });
}

/** Writes the owner record straight into a store, as a claim would; returns the owner token. */
export async function seedOwner(store: Store): Promise<string> {
    const token = newToken();
    await seedOwnerHash(store, tokenHash(token));
    return token;
}

/**
 * Starts a request whose body is held back after its first part: it is authenticated by then, and its action
 * waits for the rest. `finish` sends the rest and resolves with the answer.
 */
export function slowRequest(url: string, method: string, headers: Record<string, string>, body: Uint8Array = new Uint8Array([1, 2])) {
    let answered: (value: { status: number; body: Buffer }) => void = () => {};
    const answer = new Promise<{ status: number; body: Buffer }>((resolve) => (answered = resolve));
    const req = request(url, { method, headers: { ...headers, 'Content-Length': String(body.length) } }, (res) => {
        const chunks: Buffer[] = [];
        res.on('data', (c: Buffer) => chunks.push(c));
        res.on('end', () => answered({ status: res.statusCode ?? 0, body: Buffer.concat(chunks) }));
    });
    req.write(body.subarray(0, 1));
    return {
        finish: async () => {
            await new Promise((r) => setTimeout(r, 30));
            req.end(body.subarray(1));
            return answer;
        },
    };
}

/** Writes a claim and its owner record, as a claim would (§6, layout.ts). */
export async function seedOwnerHash(store: Store, hash: string): Promise<void> {
    await store.put(`claims/${sha256Hex(ownerRecord(hash))}`, new Uint8Array());
    await store.put(`owner/${sha256Hex(ownerRecord(hash))}`, ownerRecord(hash));
}

/** A fresh folder store scoped to the test instance, and the raw store under it. */
export async function freshStore(): Promise<{ raw: Store; store: Store }> {
    const raw = new FsStore(await mkdtemp(join(tmpdir(), 'sprava-relay-')));
    return { raw, store: scoped(raw, INSTANCE) };
}
