// Pairings (companion-v0 §7.3): the owner opens one, a device joins it with the QR code's secret, the owner
// posts the sealed key, and the device acknowledges it. The state is the furthest write-once part that exists.
import { randomBytes } from 'node:crypto';
import { decodeB64, encodeB64, formatTime, isId, newToken, sameSecret, sha256Hex, tokenHash } from './encoding.ts';
import type { Devices } from './devices.ts';
import { HttpError, type Call, type Route } from './http.ts';
import { deviceKeys, EMPTY, groupParts, pairingKeys, readRecord, type DeviceRecord, type PairingCreated } from './layout.ts';
import type { Relay } from './relay.ts';
import { writeOnce } from './store/store.ts';

export const PAIRING_TTL_MS = 10 * 60_000;
const MAX_OPEN = 3;
const MAX_DEVICES = 20;
const MAX_FAILED_JOINS = 5;

type State = 'open' | 'joined' | 'keyed' | 'acknowledged';

interface Pairing {
    id: string;
    created: PairingCreated;
    parts: Set<string>;
    state: State;
}

const json = (value: unknown): Uint8Array => new Uint8Array(Buffer.from(JSON.stringify(value), 'utf8'));

/** The pairing endpoints, and a sweep that deletes expired pairings (run every minute by the relay). */
export function pairings(relay: Relay, devices: Devices): { routes: Route[]; sweep: () => Promise<void> } {
    const { store } = relay;
    const failedJoins = new Map<string, number>();

    /** Reads a live pairing; null when it is missing or past its expiry, which then deletes it. */
    async function find(p: string | undefined): Promise<Pairing | null> {
        if (!isId(p)) return null;
        const parts = new Set((await store.list(`pairings/${p}/`)).map((k) => k.slice(`pairings/${p}/`.length)));
        const created = parts.has('created.json') ? readRecord<PairingCreated>(await store.get(pairingKeys(p).created)) : null;
        if (created === null) return null;
        const pairing: Pairing = { id: p, created, parts, state: stateOf(parts) };
        if (Date.parse(created.expires_at) <= relay.now()) {
            await expire(pairing);
            return null;
        }
        return pairing;
    }

    /** §7.3: a pairing is deleted 10 minutes after it was made, with its device if that is still pending. */
    async function expire(pairing: Pairing): Promise<void> {
        const d = pairing.created.device_id;
        if (await isPending(d)) await devices.deleteParts(d);
        for (const part of pairing.parts) await store.delete(`pairings/${pairing.id}/${part}`);
        failedJoins.delete(pairing.id);
    }

    async function isPending(d: string): Promise<boolean> {
        return (await store.has(deviceKeys(d).record)) && !(await store.has(deviceKeys(d).active)) && !(await store.has(deviceKeys(d).revoked));
    }

    async function livePairings(): Promise<Pairing[]> {
        const live: Pairing[] = [];
        for (const p of groupParts(await store.list('pairings/'), 'pairings').keys()) {
            const pairing = await find(p);
            if (pairing !== null) live.push(pairing);
        }
        return live;
    }

    /** §7.8 rule 5, applied again before counting: an orphaned pending record never holds a device slot. */
    async function countDevices(live: Pairing[]): Promise<number> {
        let count = 0;
        for (const [d, parts] of groupParts(await store.list('devices/'), 'devices')) {
            if (!parts.has('record.json') || parts.has('revoked')) continue;
            if (!parts.has('active')) {
                const record = readRecord<DeviceRecord>(await store.get(deviceKeys(d).record));
                if (record === null || !live.some((p) => p.id === record.pairing_id)) {
                    await store.delete(deviceKeys(d).record);
                    continue;
                }
            }
            count++;
        }
        return count;
    }

    const ownPairing = async (call: Call): Promise<Pairing> => {
        const pairing = await find(call.params.P);
        if (call.principal?.kind !== 'device' || call.principal.pairing !== call.params.P) {
            throw new HttpError(403, 'This token may only use its own pairing.');
        }
        if (pairing === null) throw new HttpError(404, 'There is no such pairing.');
        return pairing;
    };
    const ownerPairing = async (call: Call): Promise<Pairing> => {
        const pairing = await find(call.params.P);
        if (pairing === null) throw new HttpError(404, 'There is no such pairing.');
        return pairing;
    };

    const sweep = async (): Promise<void> => {
        await livePairings();
    };
    const routes: Route[] = [
        {
            method: 'POST',
            path: '/v0/pairings',
            access: ['owner'],
            browser: false,
            body: { kind: 'json', limit: 4096 },
            async handle(call) {
                const a = call.json.owner_public_key;
                const d = call.json.device_id;
                if (typeof a !== 'string' || decodeB64(a)?.length !== 32 || !isId(d)) {
                    throw new HttpError(400, 'A pairing needs the owner public key (32 bytes in b64) and a device id.');
                }
                return relay.lock.run(async () => {
                    const live = await livePairings();
                    const used = (await store.list(`devices/${d}/`)).length > 0 || live.some((p) => p.created.device_id === d);
                    if (used) throw new HttpError(409, 'That device id is already in use.');
                    if (live.filter((p) => p.state === 'open').length >= MAX_OPEN || (await countDevices(live)) >= MAX_DEVICES) {
                        throw new HttpError(507, 'There are too many open pairings or devices.');
                    }
                    const p = encodeB64(randomBytes(16));
                    const secret = encodeB64(randomBytes(16));
                    const expiresAt = formatTime(relay.now() + PAIRING_TTL_MS);
                    const created: PairingCreated = { owner_public_key: a, device_id: d, secret_sha256: sha256Hex(secret), expires_at: expiresAt };
                    await writeOnce(store, pairingKeys(p).created, json(created));
                    return { status: 200, json: { pairing_id: p, secret, expires_at: expiresAt } };
                });
            },
        },
        {
            method: 'POST',
            path: '/v0/pairings/:P/join',
            access: ['public'],
            browser: true,
            body: { kind: 'json', limit: 4096 },
            async handle(call) {
                const { secret, device_public_key: b, hello } = call.json;
                if (typeof secret !== 'string' || typeof b !== 'string' || decodeB64(b)?.length !== 32 || typeof hello !== 'string' || hello.length > 2048 || !decodeB64(hello)?.length) {
                    throw new HttpError(400, 'A join needs the secret, the device public key (32 bytes in b64) and the sealed hello in b64.');
                }
                return relay.lock.run(async () => {
                    const pairing = await find(call.params.P);
                    if (pairing === null) throw new HttpError(404, 'There is no such pairing.');
                    if (!sameSecret(sha256Hex(secret), pairing.created.secret_sha256)) {
                        const failures = (failedJoins.get(pairing.id) ?? 0) + 1;
                        failedJoins.set(pairing.id, failures);
                        if (failures >= MAX_FAILED_JOINS) await expire(pairing);
                        throw new HttpError(403, 'The pairing secret is not right.');
                    }
                    const d = pairing.created.device_id;
                    if (pairing.state !== 'open' || (await store.list(`devices/${d}/`)).length > 0) throw new HttpError(409, 'This pairing was already joined.');
                    const token = newToken();
                    const record: DeviceRecord = { pairing_id: pairing.id };
                    await writeOnce(store, deviceKeys(d).token(tokenHash(token)), json({ joined_at: formatTime(relay.now()) }));
                    if ((await writeOnce(store, deviceKeys(d).record, json(record))) === 'different') throw new HttpError(409, 'This pairing was already joined.');
                    devices.remember(d, pairing.id, tokenHash(token));
                    await writeOnce(store, pairingKeys(pairing.id).joined, json({ device_public_key: b, hello }));
                    return { status: 200, json: { device_id: d, device_token: token, expires_at: pairing.created.expires_at } };
                });
            },
        },
        {
            method: 'GET',
            path: '/v0/pairings/:P',
            access: ['owner'],
            browser: false,
            async handle(call) {
                const pairing = await ownerPairing(call);
                const joined = pairing.state === 'open' ? null : readRecord<{ device_public_key: string; hello: string }>(await store.get(pairingKeys(pairing.id).joined));
                return {
                    status: 200,
                    json: {
                        state: pairing.state,
                        device_id: joined === null ? null : pairing.created.device_id,
                        device_public_key: joined?.device_public_key ?? null,
                        hello: joined?.hello ?? null,
                    },
                };
            },
        },
        {
            method: 'PUT',
            path: '/v0/pairings/:P/key',
            access: ['owner'],
            browser: false,
            body: { kind: 'bytes', limit: 1024 },
            async handle(call) {
                if (call.body.length === 0) throw new HttpError(400, 'The sealed key payload is required.');
                const hash = new Uint8Array(Buffer.from(sha256Hex(call.body), 'ascii'));
                return relay.lock.run(async () => {
                    const pairing = await ownerPairing(call);
                    const keys = pairingKeys(pairing.id);
                    const d = pairing.created.device_id;
                    if (pairing.state === 'open' || (await devices.isRevoked(d))) throw new HttpError(409, 'This pairing cannot take a key now.');
                    if (pairing.state === 'joined') {
                        // §7.3: the activation marker first, so a device that can fetch its key is always active.
                        await writeOnce(store, deviceKeys(d).active, EMPTY);
                    }
                    if ((await writeOnce(store, keys.keySha, hash)) === 'different') throw new HttpError(409, 'This pairing already has another key.');
                    if (!pairing.parts.has('ack')) await writeOnce(store, keys.key, call.body);
                    return { status: 204 };
                });
            },
        },
        {
            method: 'GET',
            path: '/v0/pairings/:P/key',
            access: ['pending', 'active'],
            browser: true,
            async handle(call) {
                const pairing = await ownPairing(call);
                const bytes = pairing.parts.has('ack') ? null : await store.get(pairingKeys(pairing.id).key);
                if (bytes === null) throw new HttpError(404, 'The key is not there.');
                return { status: 200, bytes };
            },
        },
        {
            method: 'POST',
            path: '/v0/pairings/:P/ack',
            access: ['pending', 'active'],
            browser: true,
            async handle(call) {
                return relay.lock.run(async () => {
                    const pairing = await ownPairing(call);
                    if (pairing.state !== 'keyed' && pairing.state !== 'acknowledged') throw new HttpError(409, 'There is no key to acknowledge yet.');
                    // §7.3: the acknowledgement, then the payload goes; key.sha256 stays until the pairing is deleted.
                    await writeOnce(store, pairingKeys(pairing.id).ack, EMPTY);
                    await store.delete(pairingKeys(pairing.id).key);
                    return { status: 204 };
                });
            },
        },
        {
            method: 'DELETE',
            path: '/v0/pairings/:P',
            access: ['owner'],
            browser: false,
            async handle(call) {
                if (!isId(call.params.P)) throw new HttpError(400, 'That is not a pairing id.');
                await relay.lock.run(async () => {
                    const pairing = await find(call.params.P);
                    if (pairing !== null) await expire(pairing);
                });
                return { status: 204 };
            },
        },
    ];
    return { routes, sweep };
}

function stateOf(parts: Set<string>): State {
    if (parts.has('ack')) return 'acknowledged';
    if (parts.has('key.sha256')) return 'keyed';
    if (parts.has('joined.json')) return 'joined';
    return 'open';
}
