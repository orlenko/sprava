// Objects (companion-v0 §7.5): what the owner publishes, immutable and named by its revision.
import { isId, parseUnsigned, sha256Hex } from './encoding.ts';
import { HttpError, type Call, type Route } from './http.ts';
import { SlidingWindow } from './limits.ts';
import type { Relay } from './relay.ts';
import { writeOnce } from './store/store.ts';

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

export function objectRoutes(relay: Relay): Route[] {
    const reads = new SlidingWindow(HOUR, READS_PER_HOUR);
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
    return [
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
                const numbers = (await relay.store.list(`objects/${prefix}`))
                    .map((key) => key.slice(`objects/${prefix}`.length))
                    .filter((last) => isRevision(last))
                    .map(Number)
                    .filter((n) => n < below)
                    .sort((a, b) => b - a);
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
                const bytes = await relay.store.get(key);
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
                const { key } = named(call);
                if (call.body.length === 0) throw new HttpError(400, 'An object needs its sealed bytes.');
                // §7.5: a name that exists keeps its bytes; identical bytes are a harmless retry.
                const result = await relay.lock.run(() => writeOnce(relay.store, key, call.body));
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
                await relay.store.delete(named(call).key);
                return { status: 204 };
            },
        },
    ];
}
