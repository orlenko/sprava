// Devices (companion-v0 §7.3, §7.4): admitting their tokens, listing them, and revoking them for good.
//
// Locks. Every action of a device, and every change to a device, runs under that device's lock
// (`Relay.deviceLocks`), with the device's authorization checked again under it: so a revocation is atomic with
// respect to every request of the device in flight, whenever its body arrives. The order is: a device's lock,
// then the creation lock (`Relay.lock`). Code holding the creation lock never takes a device lock, and nothing
// holds two device locks. Methods named `...Locked` expect the device's lock to be held and never take it.
import { formatTime, isId, parseUnsigned, sameSecret, tokenHash } from './encoding.ts';
import { HttpError, type Principal, type Reply, type Route } from './http.ts';
import { deviceElsewhere, deviceKeys, EMPTY, groupParts, readRecord, type DeviceRecord, type TokenRecord } from './layout.ts';
import type { Relay } from './relay.ts';
import { deleteAll, LockBusy, writeOnce } from './store/store.ts';

const HOUR = 3_600_000;
const DEVICE_QUEUE = 8;
const DEVICE_WAIT_MS = 10_000;

/** What the relay remembers of devices. Only facts that never change back are cached (§7.8). */
export class Devices {
    readonly #relay: Relay;
    /** Token hash → device id, from every token marker at start and every join since. */
    readonly #byToken = new Map<string, string>();
    readonly #pairing = new Map<string, string>();
    readonly #revoked = new Set<string>();
    readonly #active = new Set<string>();
    readonly #seenHour = new Map<string, number>();

    constructor(relay: Relay) {
        this.#relay = relay;
    }

    /** Reads every device's record and tokens; called at start, after the cleanup. */
    async load(): Promise<void> {
        const { store } = this.#relay;
        for (const [d, parts] of groupParts(await store.list('devices/'), 'devices')) {
            if (parts.has('revoked')) this.#revoked.add(d);
            const record = parts.has('record.json') ? readRecord<DeviceRecord>(await store.get(deviceKeys(d).record)) : null;
            if (record === null) continue;
            for (const key of await store.list(deviceKeys(d).tokens)) this.remember(d, record.pairing_id, key.slice(deviceKeys(d).tokens.length));
        }
    }

    remember(d: string, pairing: string, hash: string): void {
        this.#pairing.set(d, pairing);
        this.#byToken.set(hash, d);
    }

    /**
     * Who holds this token. It only identifies the caller: the authorization that counts is checked again under the
     * device's lock by `guard`, after the request's body has arrived, right before the action.
     */
    async authenticate(token: string): Promise<Principal | null> {
        const hash = tokenHash(token);
        if (this.#relay.ownerHash !== null && sameSecret(hash, this.#relay.ownerHash)) return { kind: 'owner' };
        const d = this.#byToken.get(hash);
        const pairing = d === undefined ? undefined : this.#pairing.get(d);
        if (d === undefined || pairing === undefined || this.#revoked.has(d)) return null;
        return { kind: 'device', id: d, active: await this.#isActive(d), pairing, token: hash };
    }

    /**
     * Runs a device's action under its lock, after checking again, in §7.3's order, its revocation marker, its record
     * and token, then its activation marker. A device revoked while its request was in flight gets 401.
     */
    async guard(principal: Principal & { kind: 'device' }, action: () => Promise<Reply>, signal: AbortSignal): Promise<Reply> {
        const d = principal.id;
        // A device's calls wait in a bounded queue, each with a deadline and dropped when its client leaves, so no
        // device can pile up work or hold its owner's revocation behind a backlog.
        const bound = { limit: DEVICE_QUEUE, waitMs: DEVICE_WAIT_MS, signal };
        return this.#relay.deviceLocks.run(d, async () => {
            const { store } = this.#relay;
            if (await this.revokedLocked(d)) throw new HttpError(401, 'A valid token is required.');
            if (!(await store.has(deviceKeys(d).record)) || !(await store.has(deviceKeys(d).token(principal.token)))) {
                throw new HttpError(401, 'A valid token is required.');
            }
            principal.active = await this.#isActive(d);
            await this.#touchLocked(d);
            return action();
        }, bound).catch((error: unknown) => {
            if (error instanceof LockBusy) throw new HttpError(503, 'This device has too many calls in progress; try again.', { 'Retry-After': '5' });
            throw error;
        });
    }

    /**
     * Whether the device has a revocation marker. §7.8 rule 1 applies first: a stored self-revocation without a
     * marker (a crash between the two writes) gets its marker now. The device's lock must be held.
     */
    async revokedLocked(d: string): Promise<boolean> {
        if (this.#revoked.has(d)) return true;
        const keys = deviceKeys(d);
        if (await this.#relay.store.has(keys.revoked)) {
            this.#revoked.add(d);
            return true;
        }
        if (await this.#relay.store.has(keys.revocation)) {
            await this.markRevokedLocked(d);
            return true;
        }
        return false;
    }

    isRevoked(d: string): Promise<boolean> {
        return this.#relay.deviceLocks.run(d, () => this.revokedLocked(d));
    }

    /** Writes the revocation marker; from then on no action of the device passes `guard`. The lock must be held. */
    async markRevokedLocked(d: string): Promise<void> {
        await writeOnce(this.#relay.store, deviceKeys(d).revoked, EMPTY);
        this.#revoked.add(d);
    }

    markRevoked(d: string): Promise<void> {
        return this.#relay.deviceLocks.run(d, () => this.markRevokedLocked(d));
    }

    /** §7.4: everything of a device but its revocation marker, which stays until the instance is retired. */
    async deletePartsLocked(d: string): Promise<void> {
        const { store } = this.#relay;
        const keys = deviceKeys(d);
        await store.delete(keys.record);
        for (const [hash, holder] of this.#byToken) if (holder === d) this.#byToken.delete(hash);
        this.#pairing.delete(d);
        this.#active.delete(d);
        for (const prefix of [keys.tokens, ...deviceElsewhere(d)]) await deleteAll(store, prefix);
        for (const key of [keys.active, keys.lastSeen, keys.revocation]) await store.delete(key);
    }

    deleteParts(d: string): Promise<void> {
        return this.#relay.deviceLocks.run(d, () => this.deletePartsLocked(d));
    }

    /** When the device joined: the earliest of its token markers, which are informative. */
    async joinedAt(d: string): Promise<string | null> {
        let earliest: string | null = null;
        for (const key of await this.#relay.store.list(deviceKeys(d).tokens)) {
            const joined = readRecord<TokenRecord>(await this.#relay.store.get(key))?.joined_at;
            if (typeof joined === 'string' && (earliest === null || joined < earliest)) earliest = joined;
        }
        return earliest;
    }

    async #isActive(d: string): Promise<boolean> {
        if (this.#active.has(d)) return true;
        const active = await this.#relay.store.has(deviceKeys(d).active);
        if (active) this.#active.add(d);
        return active;
    }

    /** §7.4: `last_seen` is informative, kept to the hour, and written at most once an hour per device. */
    async #touchLocked(d: string): Promise<void> {
        const hour = Math.floor(this.#relay.now() / HOUR);
        if (this.#seenHour.get(d) === hour) return;
        this.#seenHour.set(d, hour);
        await this.#relay.store.put(deviceKeys(d).lastSeen, Buffer.from(formatTime(hour * HOUR))).catch(() => undefined);
    }
}

export function deviceRoutes(relay: Relay, devices: Devices): Route[] {
    const deviceId = (text: string | undefined): string => {
        if (!isId(text)) throw new HttpError(400, 'That is not a device id.');
        return text;
    };
    return [
        {
            method: 'GET',
            path: '/v0/devices',
            access: ['owner'],
            browser: false,
            async handle(call) {
                const limit = parseUnsigned(call.query.get('limit') ?? '50') ?? 0;
                const after = call.query.get('after');
                if (limit < 1 || limit > 50 || (after !== null && !isId(after))) {
                    throw new HttpError(400, 'The limit must be from 1 to 50, and after a device id.');
                }
                const groups = groupParts(await relay.store.list('devices/'), 'devices');
                const ids = [...groups.keys()].filter((d) => groups.get(d)!.has('record.json') && (after === null || d > after)).sort();
                const page = ids.slice(0, limit);
                const listed = [];
                for (const d of page) {
                    const revoked = await devices.isRevoked(d);
                    const active = groups.get(d)!.has('active');
                    const seen = await relay.store.get(deviceKeys(d).lastSeen);
                    const seenAt = seen === null ? NaN : Date.parse(Buffer.from(seen).toString('utf8'));
                    listed.push({
                        device_id: d,
                        state: revoked ? 'revoked' : active ? 'active' : 'pending',
                        paired_at: active ? await devices.joinedAt(d) : null,
                        last_seen: Number.isNaN(seenAt) ? null : formatTime(Math.floor(seenAt / HOUR) * HOUR),
                    });
                }
                return { status: 200, json: { devices: listed, next: ids.length > limit ? page[page.length - 1] : null } };
            },
        },
        {
            method: 'DELETE',
            path: '/v0/devices/self',
            access: ['active'],
            browser: true,
            body: { kind: 'bytes', limit: 1024 },
            // Runs under the device's lock (guard), so an owner revocation cannot complete in the middle.
            async handle(call) {
                if (call.principal?.kind !== 'device' || call.body.length === 0) throw new HttpError(400, 'A sealed revocation is required.');
                const d = call.principal.id;
                // §7.4: the revocation first, then the marker, so a crash between them is repaired at start. The marker
                // is written only once this revocation is the one stored: the owner needs it to act (§9.2).
                if ((await writeOnce(relay.store, deviceKeys(d).revocation, call.body)) === 'different') {
                    throw new HttpError(409, 'Another revocation of this device may still be stored; try again later.');
                }
                await devices.markRevokedLocked(d);
                await deleteAll(relay.store, `requests/${d}/`);
                return { status: 204 };
            },
        },
        {
            method: 'DELETE',
            path: '/v0/devices/:D',
            access: ['owner'],
            browser: false,
            async handle(call) {
                const d = deviceId(call.params.D);
                await relay.deviceLocks.run(d, async () => {
                    await devices.markRevokedLocked(d);
                    await devices.deletePartsLocked(d);
                });
                return { status: 204 };
            },
        },
        {
            method: 'GET',
            path: '/v0/devices/:D/revocation',
            access: ['owner'],
            browser: false,
            async handle(call) {
                const bytes = await relay.store.get(deviceKeys(deviceId(call.params.D)).revocation);
                if (bytes === null) throw new HttpError(404, 'There is no revocation for this device.');
                return { status: 200, bytes };
            },
        },
    ];
}
