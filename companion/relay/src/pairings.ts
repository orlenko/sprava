// Pairings (companion-v0 §7.3): the owner opens one, a device joins it with the QR code's secret, the owner
// posts the sealed key, and the device acknowledges it. The state is the furthest write-once part that exists.
//
// Locks (devices.ts): everything that reads a pairing's state and then changes it (join, key, acknowledgement,
// expiry, deletion) runs under the lock of the pairing's device, so expiry can never run between a check and the
// writes of an activation. Opening a pairing and the join's capacity checks take the creation lock, after the
// device's lock, never before it.
import { randomBytes } from 'node:crypto';
import { decodeB64, encodeB64, formatTime, isId, newToken, sameSecret, sha256Hex, tokenHash } from './encoding.ts';
import type { Devices } from './devices.ts';
import { HttpError, type Call, type Reply, type Route } from './http.ts';
import { deviceKeys, EMPTY, groupParts, pairingKeys, readRecord, type DeviceRecord, type PairingCreated } from './layout.ts';
import type { Relay } from './relay.ts';
import { INTENTS, LockBusy, writeOnce } from './store/store.ts';

export const PAIRING_TTL_MS = 10 * 60_000;
const MAX_OPEN = 3;
const MAX_DEVICES = 20;
const MAX_FAILED_JOINS = 5;
const MAX_JOINS_IN_FLIGHT = 16;
const JOIN_QUEUE = 8;
const JOIN_WAIT_MS = 10_000;

type State = 'open' | 'joined' | 'keyed' | 'acknowledged';

interface Pairing {
    id: string;
    created: PairingCreated;
    parts: Set<string>;
    state: State;
    expired: boolean;
}

const json = (value: unknown): Uint8Array => new Uint8Array(Buffer.from(JSON.stringify(value), 'utf8'));
const missing = (): HttpError => new HttpError(404, 'There is no such pairing.');

/** The pairing endpoints, and a sweep that deletes expired pairings (run every minute by the relay). */
export function pairings(relay: Relay, devices: Devices): { routes: Route[]; sweep: () => Promise<void> } {
    const { store } = relay;
    const failedJoins = new Map<string, number>();
    let joinsInFlight = 0;

    /** Reads a pairing as it is now; it changes nothing. */
    async function read(p: string | undefined): Promise<Pairing | null> {
        if (!isId(p)) return null;
        const parts = new Set((await store.list(`pairings/${p}/`)).map((k) => k.slice(`pairings/${p}/`.length)));
        // A deleted pairing stays deleted, whatever a late write or a deletion cut short left beside its tombstone.
        if (parts.has('deleted')) return null;
        const created = parts.has('created.json') ? readRecord<PairingCreated>(await store.get(pairingKeys(p).created)) : null;
        if (created === null) return null;
        return { id: p, created, parts, state: stateOf(parts), expired: !(Date.parse(created.expires_at) > relay.now()) };
    }

    /**
     * Runs `work` on a live pairing under its device's lock, read again under the lock; an expired one is deleted
     * there and answers 404. `held` says the caller already holds that lock (a device acting on its own pairing).
     */
    async function withPairing<T>(
        p: string | undefined,
        work: (pairing: Pairing) => Promise<T>,
        held: string | null = null,
        bound?: { limit: number; waitMs: number; signal: AbortSignal },
    ): Promise<T> {
        const first = await read(p);
        if (first === null) throw missing();
        const d = first.created.device_id;
        const locked = async (): Promise<T> => {
            const pairing = await read(p);
            if (pairing === null) throw missing();
            if (pairing.expired) {
                await expireLocked(pairing);
                throw missing();
            }
            return work(pairing);
        };
        if (held !== null) {
            if (held !== d) throw new HttpError(403, 'This token may only use its own pairing.');
            return locked();
        }
        return relay.deviceLocks.run(d, locked, bound).catch((error: unknown) => {
            if (error instanceof LockBusy) throw new HttpError(503, 'The relay is busy with this pairing; try again.', { 'Retry-After': '5' });
            throw error;
        });
    }

    /**
     * §7.3: a pairing is deleted 10 minutes after it was made, with its device if that is still pending. Its
     * tombstone comes first, durably, so a deletion cut short or a late write can never reopen it (invariant 5).
     */
    async function expireLocked(pairing: Pairing): Promise<void> {
        // A device that never became active goes with its pairing, revoked for good before anything is deleted, so
        // a late write of its token, record or activation can never bring it back (invariant 5). Its id is never
        // used again (§5.2). Then the pairing's tombstone, while created.json still names the device for a retry.
        const d = pairing.created.device_id;
        const pending = !(await store.has(deviceKeys(d).active));
        if (pending) await devices.markRevokedLocked(d);
        await store.put(pairingKeys(pairing.id).deleted, new Uint8Array());
        if (pending) await devices.deletePartsLocked(d);
        await finishDeleted(pairing.id);
        failedJoins.delete(pairing.id);
    }

    /** Deletes what is left beside a pairing's tombstone; the parts are dead, so no lock is needed. */
    async function finishDeleted(p: string): Promise<void> {
        for (const key of await store.list(`pairings/${p}/`)) if (key !== pairingKeys(p).deleted) await store.delete(key);
    }

    async function allPairings(): Promise<Pairing[]> {
        const all: Pairing[] = [];
        for (const p of groupParts(await store.list('pairings/'), 'pairings').keys()) {
            const pairing = await read(p);
            if (pairing !== null) all.push(pairing);
        }
        return all;
    }

    /** The pending devices whose pairing is gone or expired (§7.8 rule 5). */
    async function orphans(live: Pairing[], joining: string | null = null): Promise<{ orphaned: string[]; counted: number }> {
        const orphaned: string[] = [];
        let counted = 0;
        for (const [d, parts] of groupParts(await store.list('devices/'), 'devices')) {
            if (!parts.has('record.json') || parts.has('revoked') || d === joining) continue;
            if (!parts.has('active')) {
                const record = readRecord<DeviceRecord>(await store.get(deviceKeys(d).record));
                if (record === null || !live.some((p) => p.id === record.pairing_id)) {
                    orphaned.push(d);
                    continue;
                }
            }
            counted++;
        }
        return { orphaned, counted };
    }

    /** §7.8 rule 5, applied again before counting: each orphaned pending device is deleted under its own lock. */
    async function deleteOrphans(): Promise<void> {
        const { orphaned } = await orphans((await allPairings()).filter((p) => !p.expired));
        for (const d of orphaned) {
            await relay.deviceLocks.run(d, async () => {
                const { orphaned: still } = await orphans((await allPairings()).filter((p) => !p.expired));
                if (still.includes(d) && !(await store.has(deviceKeys(d).active))) {
                    await devices.markRevokedLocked(d);
                    await devices.deletePartsLocked(d);
                }
            });
        }
    }

    /** The join itself (§7.3), under the pairing's device lock with a bounded wait. */
    async function join(p: string | undefined, secret: string, b: string, hello: string, signal: AbortSignal): Promise<Reply> {
        return withPairing(
            p,
            async (pairing) => {
                if (!sameSecret(sha256Hex(secret), pairing.created.secret_sha256)) {
                    const failures = (failedJoins.get(pairing.id) ?? 0) + 1;
                    failedJoins.set(pairing.id, failures);
                    if (failures >= MAX_FAILED_JOINS) await expireLocked(pairing);
                    throw new HttpError(403, 'The pairing secret is not right.');
                }
                const d = pairing.created.device_id;
                // Joined means joined.json exists. A join that failed part-way, whose writes may still land, left
                // at most a token nobody holds and a record every join writes alike (layout.ts).
                if (pairing.state !== 'open' || (await devices.revokedLocked(d))) throw new HttpError(409, 'This pairing was already joined.');
                // An earlier join whose transcript write may still land has consumed the pairing: its intent is
                // durable, and a second transcript must never be accepted (§7.3: B and hello never change).
                if ((await store.list(`${INTENTS}${pairingKeys(pairing.id).joined}/`)).length > 0) {
                    throw new HttpError(409, 'This pairing was already joined.');
                }
                return relay.lock.run(async () => {
                    // §7.3: at most 20 devices, pending and active, counted under the creation lock at the join.
                    // The joining device itself is left out: an earlier attempt of this join may have written its
                    // record, and finishing the join adds no device.
                    if ((await orphans((await allPairings()).filter((p) => !p.expired), d)).counted >= MAX_DEVICES) {
                        throw new HttpError(507, 'There are too many devices.');
                    }
                    return completeJoin(pairing, d, b, hello);
                });
            },
            null,
            { limit: JOIN_QUEUE, waitMs: JOIN_WAIT_MS, signal },
        );
    }

    /** The join's writes: its token's marker, the record every join writes alike, then the transcript. */
    async function completeJoin(pairing: Pairing, d: string, b: string, hello: string): Promise<Reply> {
        const token = newToken();
        const hash = tokenHash(token);
        await writeOnce(store, deviceKeys(d).token(hash), json({ joined_at: formatTime(relay.now()) }));
        const record: DeviceRecord = { pairing_id: pairing.id };
        if ((await writeOnce(store, deviceKeys(d).record, json(record))) === 'different') throw new HttpError(409, 'This pairing was already joined.');
        if ((await writeOnce(store, pairingKeys(pairing.id).joined, json({ device_public_key: b, hello }))) === 'different') {
            throw new HttpError(409, 'This pairing was already joined.');
        }
        devices.remember(d, pairing.id, hash);
        return { status: 200, json: { device_id: d, device_token: token, expires_at: pairing.created.expires_at } };
    }

    const ownDevice = (call: Call): string => {
        if (call.principal?.kind !== 'device' || call.principal.pairing !== call.params.P) {
            throw new HttpError(403, 'This token may only use its own pairing.');
        }
        return call.principal.id;
    };

    const sweep = async (): Promise<void> => {
        // A deleted pairing's leftovers, and parts without created.json, are unreachable by every route (read()
        // refuses them); they only need deleting. Tombstones stay.
        for (const [p, parts] of groupParts(await store.list('pairings/'), 'pairings')) {
            if (parts.has('deleted') || !parts.has('created.json')) await finishDeleted(p);
        }
        for (const pairing of await allPairings()) {
            if (!pairing.expired) continue;
            await relay.deviceLocks.run(pairing.created.device_id, async () => {
                const now = await read(pairing.id);
                if (now !== null && now.expired) await expireLocked(now);
            });
        }
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
                await deleteOrphans();
                return relay.deviceLocks.run(d, () =>
                    relay.lock.run(async () => {
                        const live = (await allPairings()).filter((p) => !p.expired);
                        const used = (await store.list(`devices/${d}/`)).length > 0 || (await allPairings()).some((p) => p.created.device_id === d);
                        if (used) throw new HttpError(409, 'That device id is already in use.');
                        if (live.filter((p) => p.state === 'open').length >= MAX_OPEN || (await orphans(live)).counted >= MAX_DEVICES) {
                            throw new HttpError(507, 'There are too many open pairings or devices.');
                        }
                        const p = encodeB64(randomBytes(16));
                        const secret = encodeB64(randomBytes(16));
                        const expiresAt = formatTime(relay.now() + PAIRING_TTL_MS);
                        const created: PairingCreated = { owner_public_key: a, device_id: d, secret_sha256: sha256Hex(secret), expires_at: expiresAt };
                        await writeOnce(store, pairingKeys(p).created, json(created));
                        return { status: 200, json: { pairing_id: p, secret, expires_at: expiresAt } };
                    }),
                );
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
                // Joins are public: at most a few are admitted at once, before any storage is read, and each waits
                // for its pairing's lock in a bounded queue with a deadline, dropped when its client leaves, so no
                // flood of joins can pile up work or hold an owner's revocation behind it.
                if (joinsInFlight >= MAX_JOINS_IN_FLIGHT) throw new HttpError(503, 'The relay is busy; try again.', { 'Retry-After': '5' });
                joinsInFlight++;
                try {
                    return await join(call.params.P, secret, b, hello, call.signal);
                } finally {
                    joinsInFlight--;
                }
            },
        },
        {
            method: 'GET',
            path: '/v0/pairings/:P',
            access: ['owner'],
            browser: false,
            async handle(call) {
                return withPairing(call.params.P, async (pairing) => {
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
                });
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
                return withPairing(call.params.P, async (pairing) => {
                    const keys = pairingKeys(pairing.id);
                    const d = pairing.created.device_id;
                    if (pairing.state === 'open' || (await devices.revokedLocked(d))) throw new HttpError(409, 'This pairing cannot take a key now.');
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
            // Runs under the device's lock (guard), its revocation checked there.
            async handle(call) {
                return withPairing(
                    call.params.P,
                    async (pairing) => {
                        const bytes = pairing.parts.has('ack') ? null : await store.get(pairingKeys(pairing.id).key);
                        if (bytes === null) throw new HttpError(404, 'The key is not there.');
                        return { status: 200, bytes };
                    },
                    ownDevice(call),
                );
            },
        },
        {
            method: 'POST',
            path: '/v0/pairings/:P/ack',
            access: ['pending', 'active'],
            browser: true,
            async handle(call) {
                return withPairing(
                    call.params.P,
                    async (pairing) => {
                        if (pairing.state !== 'keyed' && pairing.state !== 'acknowledged') throw new HttpError(409, 'There is no key to acknowledge yet.');
                        // §7.3: the acknowledgement, then the payload goes; key.sha256 stays until the pairing is deleted.
                        await writeOnce(store, pairingKeys(pairing.id).ack, EMPTY);
                        await store.delete(pairingKeys(pairing.id).key);
                        return { status: 204 };
                    },
                    ownDevice(call),
                );
            },
        },
        {
            method: 'DELETE',
            path: '/v0/pairings/:P',
            access: ['owner'],
            browser: false,
            async handle(call) {
                if (!isId(call.params.P)) throw new HttpError(400, 'That is not a pairing id.');
                try {
                    await withPairing(call.params.P, (pairing) => expireLocked(pairing));
                } catch (error) {
                    if (!(error instanceof HttpError && error.status === 404)) throw error;
                    await finishDeleted(call.params.P); // a deletion cut short is finished by its retry
                }
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
