// Objects (companion-v0 §7.5): what the owner publishes, immutable and named by its revision.
import { isId, parseUnsigned, sha256Hex } from './encoding.ts';
import { HttpError, type Call, type Route } from './http.ts';
import { SlidingWindow } from './limits.ts';
import type { Relay } from './relay.ts';
import type { Devices } from './devices.ts';
import { deleteAll, deleteForGood, FLOORS, forget, forgetAll, INTENTS, intentsOf, isDeleted, raiseFloor, readFloor, TOMBSTONES, writeOnce } from './store/store.ts';

const HOUR = 3_600_000;
const READS_PER_HOUR = 600;

/** A revision, version or epoch in a name: an unsigned integer of at least 1, without leading zeros. */
const isRevision = (text: string | undefined): boolean => text !== undefined && (parseUnsigned(text) ?? 0) >= 1;
/** A deletion's marker among a name's intents: written before its tombstone, so the name takes no upload again. */
const DELETING = 'deleting';

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

export function objects(relay: Relay, devices: Devices): { routes: Route[]; sweep: () => Promise<void> } {
    const { store } = relay;
    const reads = new SlidingWindow(HOUR, READS_PER_HOUR);
    /**
     * The high-water mark of every floor above 0 this process has seen, never dropped: a read that finishes after a
     * raise never lowers one, however late. Only prefixes with a floor are kept, and only the owner's deletions make
     * one (a binder shown, a device kept), so a device asking about names that do not exist adds nothing; a revoked
     * device's go with it. A prefix not kept is read from the bucket each time.
     */
    const floors = new Map<string, number>();
    const scopeOf = (prefix: string): string => `objects/${prefix.slice(0, -1)}`;
    const remember = (prefix: string, floor: number): number => {
        const known = Math.max(floor, floors.get(prefix) ?? 0);
        if (known > 0) floors.set(prefix, known);
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
     * A copy that counts as deleted goes. Below the floor its intents go with it; above, they stay until the floor
     * covers the name, since they show it was uploaded, which lets the floor pass it (compactLocked).
     */
    async function dropCopy(prefix: string, n: number): Promise<void> {
        const key = `objects/${prefix}${n}`;
        await (n < (await floorOf(prefix)) ? forget(store, key) : store.delete(key));
    }

    /**
     * Raises a prefix's floor to the lowest name the owner has not deleted: the lowest uploaded name (one with an
     * upload's intent or a copy) that has no tombstone; with none, just above the highest uploaded name. Every
     * upload writes its intent first and only the floor removes it, so a copy the store has lost for a while, or an
     * upload that failed, keeps its name live until the owner deletes it: the relay never retires an object on its
     * own. A name never uploaded is passed only below an uploaded one: a deletion of a name that never existed, a
     * lone tombstone, never retires the names below it. Never above the highest valid name, whose tombstone the
     * floor then leaves in place. Copies that count as deleted are deleted. Under the creation lock, like every PUT
     * and DELETE.
     */
    async function compactLocked(prefix: string): Promise<void> {
        const floor = await floorOf(prefix);
        const copies = new Set(await numbersUnder(`objects/${prefix}`));
        const tombstoned = new Set(await numbersUnder(`${TOMBSTONES}objects/${prefix}`));
        // Uploads' intents, and deletions' markers (`intents/objects/{name}/deleting`), which are not uploads.
        const intents = new Set<number>();
        const marked = new Set<number>();
        for (const key of await store.list(`${INTENTS}objects/${prefix}`)) {
            const [n, last] = key.slice(`${INTENTS}objects/${prefix}`.length).split('/');
            if (isRevision(n)) (last === DELETING ? marked : intents).add(Number(n));
        }
        for (const n of copies) if (n < floor || tombstoned.has(n)) await dropCopy(prefix, n);
        const uploaded = [...new Set([...copies, ...intents])].filter((n) => n >= floor);
        if (uploaded.length === 0) return;
        const live = uploaded.filter((n) => !tombstoned.has(n));
        const next = Math.min(live.length > 0 ? Math.min(...live) : Math.max(...uploaded) + 1, Number.MAX_SAFE_INTEGER);
        if (next <= floor) return;
        // Known to every reader and writer first: every name below `next` was deleted by the owner or never existed,
        // so refusing them before the floor is durable loses nothing, and if writing it fails, the floor may still
        // land, so nothing below it may be accepted meanwhile. Then durable, then what it covers goes.
        remember(prefix, next);
        await raiseFloor(store, scopeOf(prefix), next);
        for (const n of tombstoned) if (n < next) await store.delete(`${TOMBSTONES}objects/${prefix}${n}`);
        for (const n of new Set([...intents, ...marked])) if (n < next) await deleteAll(store, `${INTENTS}objects/${prefix}${n}/`);
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
                floors.delete(prefix); // nothing is ever written under a revoked device's prefix again
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
                    if (await dead(prefix, n)) await dropCopy(prefix, n);
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
                // A deletion begun (its marker written) refuses it too, even while its tombstone may still land.
                const result = await relay.lock.run(async () =>
                    (await dead(prefix, number)) || (await store.has(intentsOf(key) + DELETING)) ? 'deleted' : writeOnce(store, key, call.body),
                );
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
                    // Its marker first, durably: from then on the name takes no upload, so a tombstone whose write
                    // failed but lands later can never hide an upload acknowledged meanwhile. A retry finishes it.
                    await store.put(intentsOf(key) + DELETING, new Uint8Array());
                    await deleteForGood(store, key);
                    await compactLocked(prefix);
                });
                return { status: 204 };
            },
        },
    ];
    return { routes, sweep };
}
