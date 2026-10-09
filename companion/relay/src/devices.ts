// Devices (companion-v0 §7.3, §7.4): admitting their tokens, listing them, and revoking them for good.
import { formatTime, isId, sameSecret, tokenHash } from './encoding.ts';
import { HttpError, type Principal, type Route } from './http.ts';
import { deviceElsewhere, deviceKeys, EMPTY, groupParts, readRecord, type DeviceRecord } from './layout.ts';
import type { Relay } from './relay.ts';
import { deleteAll, writeOnce } from './store/store.ts';

const HOUR = 3_600_000;

/** What the relay remembers of devices. Only facts that never change back are cached (§7.8). */
export class Devices {
    readonly #relay: Relay;
    /** Token hash → device id, from every record at start and every join since. */
    readonly #byToken = new Map<string, string>();
    readonly #records = new Map<string, DeviceRecord>();
    readonly #revoked = new Set<string>();
    readonly #active = new Set<string>();
    readonly #seenHour = new Map<string, number>();

    constructor(relay: Relay) {
        this.#relay = relay;
    }

    /** Reads every device record; called at start, after the cleanup. */
    async load(): Promise<void> {
        for (const [d, parts] of groupParts(await this.#relay.store.list('devices/'), 'devices')) {
            if (parts.has('revoked')) this.#revoked.add(d);
            const record = parts.has('record.json') ? readRecord<DeviceRecord>(await this.#relay.store.get(deviceKeys(d).record)) : null;
            if (record !== null) this.remember(d, record);
        }
    }

    remember(d: string, record: DeviceRecord): void {
        this.#records.set(d, record);
        this.#byToken.set(record.token_sha256, d);
    }

    /** §7.3: the revocation marker first, then the record, then the activation marker. */
    async authenticate(token: string): Promise<Principal | null> {
        const hash = tokenHash(token);
        if (this.#relay.ownerHash !== null && sameSecret(hash, this.#relay.ownerHash)) return { kind: 'owner' };
        const d = this.#byToken.get(hash);
        const record = d === undefined ? undefined : this.#records.get(d);
        if (d === undefined || record === undefined || !sameSecret(hash, record.token_sha256)) return null;
        if (await this.isRevoked(d)) return null;
        if (!(await this.#relay.store.has(deviceKeys(d).record))) return null;
        const active = await this.isActive(d);
        await this.#touch(d);
        return { kind: 'device', id: d, active, pairing: record.pairing_id };
    }

    /**
     * Whether the device has a revocation marker. §7.8 rule 1 applies first: a stored self-revocation without a
     * marker (a crash between the two writes) gets its marker now.
     */
    async isRevoked(d: string): Promise<boolean> {
        if (this.#revoked.has(d)) return true;
        const keys = deviceKeys(d);
        if (await this.#relay.store.has(keys.revoked)) {
            this.#revoked.add(d);
            return true;
        }
        if (await this.#relay.store.has(keys.revocation)) {
            await this.markRevoked(d);
            return true;
        }
        return false;
    }

    async isActive(d: string): Promise<boolean> {
        if (this.#active.has(d)) return true;
        const active = await this.#relay.store.has(deviceKeys(d).active);
        if (active) this.#active.add(d);
        return active;
    }

    /** Writes the revocation marker under the creation lock, so no request of the device is stored after it. */
    async markRevoked(d: string): Promise<void> {
        await this.#relay.lock.run(() => writeOnce(this.#relay.store, deviceKeys(d).revoked, EMPTY));
        this.#revoked.add(d);
    }

    /** §7.4: everything of a device but its revocation marker, which stays until the instance is retired. */
    async deleteParts(d: string): Promise<void> {
        const keys = deviceKeys(d);
        const record = this.#records.get(d);
        await this.#relay.store.delete(keys.record);
        if (record !== undefined) this.#byToken.delete(record.token_sha256);
        this.#records.delete(d);
        for (const prefix of deviceElsewhere(d)) await deleteAll(this.#relay.store, prefix);
        for (const key of [keys.active, keys.lastSeen, keys.revocation]) await this.#relay.store.delete(key);
    }

    /** §7.4: `last_seen` is informative, kept to the hour, and written at most once an hour per device. */
    async #touch(d: string): Promise<void> {
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
                const limit = call.query.has('limit') ? Number(call.query.get('limit')) : 50;
                const after = call.query.get('after');
                if (!/^[0-9]+$/.test(call.query.get('limit') ?? '50') || limit < 1 || limit > 50 || (after !== null && !isId(after))) {
                    throw new HttpError(400, 'The limit must be from 1 to 50, and after a device id.');
                }
                const groups = groupParts(await relay.store.list('devices/'), 'devices');
                const ids = [...groups.keys()].filter((d) => groups.get(d)!.has('record.json') && (after === null || d > after)).sort();
                const page = ids.slice(0, limit);
                const listed = [];
                for (const d of page) {
                    const revoked = await devices.isRevoked(d);
                    const active = groups.get(d)!.has('active');
                    const record = readRecord<DeviceRecord>(await relay.store.get(deviceKeys(d).record));
                    const seen = await relay.store.get(deviceKeys(d).lastSeen);
                    const seenAt = seen === null ? NaN : Date.parse(Buffer.from(seen).toString('utf8'));
                    listed.push({
                        device_id: d,
                        state: revoked ? 'revoked' : active ? 'active' : 'pending',
                        paired_at: active && record !== null ? record.joined_at : null,
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
            async handle(call) {
                if (call.principal?.kind !== 'device' || call.body.length === 0) throw new HttpError(400, 'A sealed revocation is required.');
                const d = call.principal.id;
                // §7.4: the revocation first, then the marker, so a crash between them is repaired at start.
                await relay.lock.run(() => writeOnce(relay.store, deviceKeys(d).revocation, call.body));
                await devices.markRevoked(d);
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
                await devices.markRevoked(d);
                await devices.deleteParts(d);
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
