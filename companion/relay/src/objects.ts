// Objects (companion-v0 §7.5): what the owner publishes, immutable and named by its revision.
import { isId, parseUnsigned, sha256Hex } from './encoding.ts';
import { HttpError, type Call, type Route } from './http.ts';
import { SlidingWindow } from './limits.ts';
import type { Relay } from './relay.ts';
import type { Devices } from './devices.ts';
import { deleteAll, deleteForGood, FLOORS, forget, forgetAll, INTENTS, isDeleted, raiseFloor, readFloor, TOMBSTONES, writeOnce } from './store/store.ts';

const HOUR = 3_600_000;
const READS_PER_HOUR = 600;

/** A revision, version or epoch in a name: an unsigned integer of at least 1, without leading zeros. */
const isRevision = (text: string | undefined): boolean => text !== undefined && (parseUnsigned(text) ?? 0) >= 1;

/** §7.5: `index/{r}`, `views/{id}/{version}`, `devices/{D}/keys/{e}`, `devices/{D}/outcomes/{r}`; nothing else. */
export function parseName(name: string): { prefix: string; device: string | null } | null {
    const s = name.split('/');
    if (s.length === 2 && s[0] === 'index' && isRevision(s[1])) return { prefix: 'index/', device: null };
    if (s.length === 3 && s[0] === 'views' && isId(s[1]) && isRevision(s[2])) return { prefix: `views/${s[1]}/`, device: null };
    if (s.length === 4 && s[0] === 'devices' && isId(s[1]) && (s[2] === 'keys' || s[2] === 'outcomes') && isRevision(s[3])) {
        return { prefix: `devices/${s[1]}/${s[2]}/`, device: s[1]! };
    }
    return null;
}

/** §7.5: the prefixes a listing may name. */
function parsePrefix(prefix: string): { device: string | null } | null {
    const parsed = parseName(prefix + '1');
    return parsed !== null && parsed.prefix === prefix ? { device: parsed.device } : null;
}

/**
 * Each object prefix (`index/`, `views/{id}/`, `devices/{D}/keys/`, `devices/{D}/outcomes/`) has a floor (store.ts),
 * `floors/objects/{prefix}`, following the floor protocol of the README: raised only under the creation lock, only
 * to the lowest name the owner has not deleted, and durable before anything it covers is deleted.
 */
export const ABANDONED_UPLOAD_MS = 24 * 3_600_000;
const FLOOR_CACHE = 1024;

export function objects(relay: Relay, devices: Devices): { routes: Route[]; sweep: () => Promise<void> } {
    const { store } = relay;
    const reads = new SlidingWindow(HOUR, READS_PER_HOUR);
    /**
     * Floors known above 0, at most FLOOR_CACHE of them, least recently used dropped first; a dropped or absent one
     * is read from the bucket again. Values only ever rise: a read that finishes after a raise never lowers one.
     */
    const floors = new Map<string, number>();
    const scopeOf = (prefix: string): string => `objects/${prefix.slice(0, -1)}`;
    const remember = (prefix: string, floor: number): number => {
        const known = Math.max(floor, floors.get(prefix) ?? 0);
        floors.delete(prefix);
        if (known > 0) {
            floors.set(prefix, known);
            if (floors.size > FLOOR_CACHE) floors.delete(floors.keys().next().value!);
        }
        return known;
    };
    const floorOf = async (prefix: string): Promise<number> => {
        const cached = floors.get(prefix);
        return cached !== undefined ? remember(prefix, cached) : remember(prefix, await readFloor(store, scopeOf(prefix)));
    };
    const numbersUnder = async (root: string): Promise<number[]> =>
        (await store.list(root)).map((key) => key.slice(root.length).split('/')[0]!).filter((n) => isRevision(n)).map(Number);

    /** Whether a name counts as deleted: tombstoned, or below its prefix's floor. The floor is read last (README). */
    async function dead(prefix: string, n: number): Promise<boolean> {
        return (await isDeleted(store, `objects/${prefix}${n}`)) || n < (await floorOf(prefix));
    }

    /**
     * Raises a prefix's floor to the lowest name the owner has not deleted. A name is known by its intent, which every
     * upload writes first and only the floor removes, so a copy the store has lost for a while is never taken for
     * a deletion. One exception keeps an abandoned upload from holding the floor forever: a name with an intent, no
     * copy and no tombstone, older than a day and below a name that has a copy, is deleted for good first. Copies
     * that count as deleted are deleted. Under the creation lock, like every PUT and DELETE.
     */
    async function compactLocked(prefix: string): Promise<void> {
        const floor = await floorOf(prefix);
        const copies = new Set(await numbersUnder(`objects/${prefix}`));
        const tombstoned = new Set(await numbersUnder(`${TOMBSTONES}objects/${prefix}`));
        const intents = new Map<number, number>();
        for (const { key, modified } of await store.listTimes(`${INTENTS}objects/${prefix}`)) {
            const n = key.slice(`${INTENTS}objects/${prefix}`.length).split('/')[0]!;
            if (isRevision(n)) intents.set(Number(n), Math.max(modified, intents.get(Number(n)) ?? 0));
        }
        for (const n of copies) if (n < floor || tombstoned.has(n)) await forget(store, `objects/${prefix}${n}`);
        const highestCopy = Math.max(0, ...[...copies].filter((n) => n >= floor && !tombstoned.has(n)));
        for (const [n, modified] of intents) {
            const abandoned = !copies.has(n) && !tombstoned.has(n) && n >= floor && n < highestCopy && modified < relay.now() - ABANDONED_UPLOAD_MS;
            if (abandoned) {
                await deleteForGood(store, `objects/${prefix}${n}`);
                tombstoned.add(n);
            }
        }
        const live = [...new Set([...copies, ...intents.keys()])].filter((n) => n >= floor && !tombstoned.has(n));
        const known = [...copies, ...intents.keys(), ...tombstoned];
        if (known.length === 0) return;
        const next = live.length > 0 ? Math.min(...live) : Math.max(floor - 1, ...known) + 1;
        if (next <= floor) return;
        await raiseFloor(store, scopeOf(prefix), next); // durable first
        remember(prefix, next); // then known to every reader, before anything it covers goes
        for (const n of tombstoned) if (n < next) await store.delete(`${TOMBSTONES}objects/${prefix}${n}`);
        for (const n of intents.keys()) if (n < next) await deleteAll(store, `${INTENTS}objects/${prefix}${n}/`);
    }

    /** Hourly: every prefix is compacted, so a late copy no listing meets is still deleted; a revoked device's go. */
    async function sweep(): Promise<void> {
        const prefixes = new Set<string>();
        for (const root of ['objects/', `${TOMBSTONES}objects/`, `${INTENTS}objects/`]) {
            for (const key of await store.list(root)) {
                const parsed = parseName(key.slice(root.length).split('/').slice(0, key.startsWith(`${INTENTS}`) ? -1 : undefined).join('/'));
                if (parsed !== null) prefixes.add(parsed.prefix);
            }
        }
        for (const prefix of prefixes) {
            const device = prefix.startsWith('devices/') ? prefix.split('/')[1]! : null;
            if (device !== null && (await devices.isRevoked(device))) {
                for (const root of ['objects/', `${TOMBSTONES}objects/`, `${FLOORS}objects/`]) await forgetAll(store, `${root}${prefix}`);
                continue;
            }
            await relay.lock.run(() => compactLocked(prefix));
        }
    }

    /** §7.1: what an active device may read; anything else is 404, so it cannot learn what exists. §7.5: 600 an hour. */
    const mayRead = (call: Call, device: string | null, prefix: string, listing: boolean): void => {
        if (call.principal?.kind !== 'device') return;
        if (!reads.admit(call.principal.id, relay.now())) throw new HttpError(429, 'Too many reads; wait and try again.');
        // A device reads the index and views, and its own keys and outcomes; it lists no binder's views.
        const allowed = device === null ? !(listing && prefix.startsWith('views/')) : device === call.principal.id;
        if (!allowed) throw new HttpError(404, 'There is no such object.');
    };
    const named = (call: Call) => {
        const parsed = parseName(call.params.name ?? '');
        if (parsed === null) throw new HttpError(404, 'There is no such object.');
        return { ...parsed, key: `objects/${call.params.name}` };
    };
    const routes: Route[] = [
        {
            method: 'GET',
            path: '/v0/objects',
            access: ['owner', 'active'],
            browser: true,
            async handle(call) {
                const prefix = call.query.get('prefix') ?? '';
                const parsed = parsePrefix(prefix);
                const limitText = call.query.get('limit') ?? '20';
                const limit = parseUnsigned(limitText) ?? 0;
                const belowText = call.query.get('below');
                const below = belowText === null ? Infinity : parseUnsigned(belowText);
                if (parsed === null || limit < 1 || limit > 100 || below === null) {
                    throw new HttpError(400, 'The prefix must be one the protocol names, the limit from 1 to 100, and below a number.');
                }
                mayRead(call, parsed.device, prefix, true);
                const listed = (await relay.store.list(`objects/${prefix}`))
                    .map((key) => key.slice(`objects/${prefix}`.length))
                    .filter((last) => isRevision(last))
                    .map(Number)
                    .filter((n) => n < below);
                // A copy a late write brought back after its deletion is not listed, and is deleted (invariant 5).
                const numbers: number[] = [];
                for (const n of listed) {
                    if (await dead(prefix, n)) await forget(store, `objects/${prefix}${n}`);
                    else numbers.push(n);
                }
                numbers.sort((a, b) => b - a);
                const page = numbers.slice(0, limit);
                return { status: 200, json: { names: page.map((n) => prefix + n), next: numbers.length > limit ? page[page.length - 1] : null } };
            },
        },
        {
            method: 'GET',
            path: '/v0/objects/*name',
            access: ['owner', 'active'],
            browser: true,
            async handle(call) {
                const { key, device, prefix } = named(call);
                mayRead(call, device, prefix, false);
                // The bytes first, then whether the name counts as deleted: a floor raised meanwhile is seen.
                const fetched = await store.get(key);
                const bytes = fetched !== null && !(await dead(prefix, Number(key.slice(key.lastIndexOf('/') + 1)))) ? fetched : null;
                if (bytes === null) throw new HttpError(404, 'There is no such object.');
                // Objects never change under a name, so their hash is a strong ETag (§7.7 exposes it).
                const etag = `"${sha256Hex(bytes)}"`;
                if (call.headers['if-none-match'] === etag) return { status: 304, headers: { ETag: etag } };
                return { status: 200, bytes, headers: { ETag: etag } };
            },
        },
        {
            method: 'PUT',
            path: '/v0/objects/*name',
            access: ['owner'],
            browser: false,
            body: { kind: 'bytes', limit: 1024 * 1024 },
            async handle(call) {
                const { key, prefix } = named(call);
                if (call.body.length === 0) throw new HttpError(400, 'An object needs its sealed bytes.');
                // §7.5: a name that exists keeps its bytes; identical bytes are a harmless retry (409 for others). A
                // deleted name, tombstoned or below the prefix's floor, takes no bytes again: 410, so the owner can
                // tell a name it superseded and deleted from a relay that holds bytes it never sent.
                const number = Number(key.slice(key.lastIndexOf('/') + 1));
                const result = await relay.lock.run(async () => ((await dead(prefix, number)) ? 'deleted' : writeOnce(store, key, call.body)));
                if (result === 'deleted') throw new HttpError(410, 'This name was deleted, and is never written again.');
                if (result === 'different') throw new HttpError(409, 'Another object already has this name.');
                return { status: 204 };
            },
        },
        {
            method: 'DELETE',
            path: '/v0/objects/*name',
            access: ['owner'],
            browser: false,
            async handle(call) {
                // A name the owner deletes is dead for good: its tombstone first, so no late write or deletion can
                // change what was acknowledged, and a PUT of it is 409 from then on (invariant 5).
                const { key, prefix } = named(call);
                await relay.lock.run(async () => {
                    await deleteForGood(store, key);
                    await compactLocked(prefix);
                });
                return { status: 204 };
            },
        },
    ];
    return { routes, sweep };
}
