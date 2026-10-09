// Request mailboxes (companion-v0 §7.6): each active device posts sealed requests for the owner, who lists them
// by ordinal, reads and deletes them. Stored as `requests/{D}/{ordinal}-{R}` (§7.8).
import { formatTime, isId, parseUnsigned, sha256Hex } from './encoding.ts';
import { HttpError, type Route } from './http.ts';
import { SlidingWindow } from './limits.ts';
import type { Devices } from './devices.ts';
import type { Relay } from './relay.ts';
import { deleteForGood, forget, forgetAll, INTENTS, intentsOf, raiseFloor, readFloor, tombstoneOf, writeOnce } from './store/store.ts';

const HOUR = 3_600_000;
const PER_HOUR = 120;
const MAX_PENDING = 1000;
/**
 * At most this many request names above a device's floor, pending or deleted out of order: the bound on what its
 * mailbox keeps (invariant 6), whatever the rate of requests and however often the relay restarts.
 */
const MAX_NAMES = 10_000;
export const REQUEST_EXPIRY_MS = 30 * 24 * HOUR;
const RESERVED = 'ordinals/';
const TOMBSTONE = /^tombstones\/requests\/([A-Za-z0-9_-]{22})\/([0-9]{16})-([A-Za-z0-9_-]{22})$/;
const pad = (n: number): string => String(n).padStart(16, '0');
const BLOCK = 1024;
const INTENTS_PREFIX = 'intents/requests/';
const INTENT = /^intents\/requests\/([A-Za-z0-9_-]{22})\/([0-9]{16})-([A-Za-z0-9_-]{22})\/([0-9a-f]{64})$/;
const NAME = /^requests\/([A-Za-z0-9_-]{22})\/([0-9]{16})-([A-Za-z0-9_-]{22})$/;

interface Entry {
    ordinal: number;
    key: string;
    received: number;
    /** SHA-256 of the bytes when this process stored or read them; null for an entry only listed so far. */
    digest: string | null;
}

export function requests(relay: Relay, devices: Devices) {
    const { store } = relay;
    /**
     * Per device, R → its stored copy. Entries come from this process's writes and from every listing of the bucket
     * (§7.8), and leave only by the owner's deletion, the device's revocation or expiry: an entry missing from a
     * listing stays, listed with a 404 body, so no later request overtakes one the relay acknowledged.
     */
    const mailboxes = new Map<string, Map<string, Entry>>();
    const nextOrdinal = new Map<string, number>();
    const sent = new SlidingWindow(HOUR, PER_HOUR);
    /** Per device, the end (exclusive) of the block of ordinals this process reserved and may use. */
    const reservedUpTo = new Map<string, number>();
    /** Per device, how many of its request names above its floor are tombstoned (bounded by MAX_NAMES). */
    const deadAbove = new Map<string, number>();
    /** Per device, its floor (§7.6): read once from the bucket, raised only by this process. */
    const floors = new Map<string, number>();

    /** `floors/requests/{D}/{ordinal}` (store.ts): every request name of the device below it counts as deleted. */
    async function floorLocked(d: string): Promise<number> {
        if (!floors.has(d)) floors.set(d, await readFloor(store, `requests/${d}`));
        return floors.get(d)!;
    }

    /**
     * Merges a device's listing into its mailbox; the device's lock must be held. Two copies of one R keep the
     * lower ordinal; the other goes. The first read in this process also starts above every block of ordinals an
     * earlier process reserved, so no ordinal it may have used, even for a write still to land, is given again.
     */
    async function refreshLocked(d: string): Promise<Map<string, Entry>> {
        if (await devices.revokedLocked(d)) {
            // A revoked device keeps nothing here: what a late write left after its deletion goes too.
            for (const prefix of [`requests/${d}/`, `tombstones/requests/${d}/`, `floors/requests/${d}/`, `${RESERVED}${d}/`]) await forgetAll(store, prefix);
            mailboxes.set(d, new Map());
            deadAbove.delete(d);
            return mailboxes.get(d)!;
        }
        const mailbox = mailboxes.get(d) ?? new Map<string, Entry>();
        const floor = await floorLocked(d);
        let highest = floor;
        const bodies = new Set<string>();
        // The device's tombstones, read once: every name below is checked against this set, not one call each.
        const tombstones = new Set(await store.list(`tombstones/requests/${d}/`));
        const deleted = (key: string): boolean => tombstones.has(`tombstones/${key}`);
        for (const { key, modified } of await store.listTimes(`requests/${d}/`)) {
            const match = NAME.exec(key);
            if (match === null || match[1] !== d) continue;
            highest = Math.max(highest, Number(match[2]));
            // A copy a late write brought back after the owner deleted it stays deleted (invariant 5): below the
            // floor every name is deleted, and above it the tombstone says so.
            if (Number(match[2]) < floor || deleted(key)) {
                await retire(key);
                continue;
            }
            bodies.add(key);
            await merge(mailbox, match[3]!, { ordinal: Number(match[2]), key, received: modified, digest: null });
        }
        // The durable record of what was accepted: each request's intent, written before its body and deleted only
        // with it. An intent whose body is missing is a request the relay may have acknowledged, so it stays listed
        // (with a 404 body) across restarts, and no later request overtakes it (§9.2).
        for (const { key: intent, modified } of await store.listTimes(intentsOf(`requests/${d}`))) {
            const match = INTENT.exec(intent);
            if (match === null || match[1] !== d) continue;
            const key = `requests/${d}/${match[2]}-${match[3]}`;
            highest = Math.max(highest, Number(match[2]));
            if (Number(match[2]) < floor) {
                await store.delete(intent);
                continue;
            }
            if (bodies.has(key)) continue;
            if (deleted(key)) {
                await retire(key); // a deletion cut short after the tombstone: finished now
                continue;
            }
            if (mailbox.has(match[3]!)) continue;
            mailbox.set(match[3]!, { ordinal: Number(match[2]), key, received: modified, digest: match[4]! });
        }
        // An entry whose name is deleted (its tombstone written, or below the floor) is finished and leaves, whatever
        // a deletion cut short left of it: the next listing never shows a request that was deleted.
        for (const [r, entry] of mailbox) {
            if (entry.ordinal < floor || deleted(entry.key)) {
                mailbox.delete(r);
                await retire(entry.key);
            }
        }
        mailboxes.set(d, mailbox);
        let next = Math.max(nextOrdinal.get(d) ?? 1, highest + 1);
        if (!reservedUpTo.has(d)) {
            const blocks = (await store.list(`${RESERVED}${d}/`)).map((key) => Number(key.slice(`${RESERVED}${d}/`.length)));
            next = Math.max(next, (Math.max(-1, ...blocks.filter(Number.isSafeInteger)) + 1) * BLOCK);
        }
        nextOrdinal.set(d, next);
        return mailbox;
    }

    /** A request's stored name, from its copy or its intent; null when the bucket holds neither. */
    async function findKey(d: string, r: string): Promise<string | null> {
        for (const key of await store.list(`requests/${d}/`)) if (key.endsWith(`-${r}`)) return key;
        for (const intent of await store.list(intentsOf(`requests/${d}`))) {
            const match = INTENT.exec(intent);
            if (match !== null && match[3] === r) return `requests/${d}/${match[2]}-${match[3]}`;
        }
        return null;
    }

    /** Two copies of one R keep the lower ordinal; the other is retired. */
    async function merge(mailbox: Map<string, Entry>, r: string, entry: Entry): Promise<void> {
        const known = mailbox.get(r);
        if (known === undefined || known.key === entry.key) {
            if (known === undefined) mailbox.set(r, entry);
            return;
        }
        const lower = entry.ordinal < known.ordinal;
        await retire(lower ? known.key : entry.key);
        if (lower) mailbox.set(r, entry);
    }

    /**
     * Deletes a request for good: its tombstone first, so a copy a late write brings back reads as deleted, then its
     * body, then its intents, which are the record of what is pending. Its name, with its ordinal, is never reused.
     */
    async function retire(key: string): Promise<void> {
        await deleteForGood(store, key);
        for (const intent of await store.list(intentsOf(key))) await store.delete(intent);
        const match = NAME.exec(key);
        if (match !== null && deadAbove.has(match[1]!)) deadAbove.set(match[1]!, deadAbove.get(match[1]!)! + 1);
    }

    /** Counts a device's tombstones at or above its floor; the device's lock must be held. */
    async function countDeadLocked(d: string): Promise<number> {
        const floor = await floorLocked(d);
        let count = 0;
        for (const key of await store.list(`tombstones/requests/${d}/`)) {
            const match = TOMBSTONE.exec(key);
            if (match !== null && Number(match[2]) >= floor) count++;
        }
        deadAbove.set(d, count);
        return count;
    }

    /**
     * Raises the device's floor to its lowest pending ordinal (or its next one, with nothing pending), then deletes
     * what the floor now covers: tombstones, stray copies and intents, lower floors, and ordinal reservations but
     * the highest. So what deletion leaves behind is bounded by what is pending, not by every request ever made,
     * and a late write below the floor still counts as deleted. The device's lock must be held.
     */
    async function compactLocked(d: string): Promise<void> {
        const mailbox = mailboxes.get(d);
        if (mailbox === undefined) return;
        const lowest = Math.min(nextOrdinal.get(d) ?? 1, Number.MAX_SAFE_INTEGER, ...[...mailbox.values()].map((e) => e.ordinal));
        if (lowest <= (await floorLocked(d))) return;
        floors.set(d, lowest); // known first, as for objects (objects.ts), then durable, then what it covers goes
        await raiseFloor(store, `requests/${d}`, lowest);
        for (const key of await store.list(`tombstones/requests/${d}/`)) {
            const match = TOMBSTONE.exec(key);
            if (match !== null && Number(match[2]) < lowest) await store.delete(key);
        }
        await countDeadLocked(d);
        const blocks = await store.list(`${RESERVED}${d}/`);
        for (const key of blocks.slice(0, -1)) {
            if ((Number(key.slice(`${RESERVED}${d}/`.length)) + 1) * BLOCK <= lowest) await forget(store, key);
        }
        // Reservation intents whose reservation is gone (a forget cut short) go too.
        for (const intent of await store.list(`${INTENTS}${RESERVED}${d}/`)) {
            const block = intent.slice(`${INTENTS}${RESERVED}${d}/`.length).split('/')[0]!;
            if (!blocks.includes(`${RESERVED}${d}/${block}`) || (Number(block) + 1) * BLOCK <= lowest) {
                if (blocks.at(-1) !== `${RESERVED}${d}/${block}`) await store.delete(intent);
            }
        }
    }

    /**
     * §7.6: the next ordinal, taken before the write so a write of unknown outcome never shares its ordinal. Its
     * block is reserved durably first (`ordinals/{D}/{block}`, written once, holding this process's lease name), so
     * a later process starts above it, and two processes can never both hold one block.
     */
    async function takeOrdinalLocked(d: string): Promise<number> {
        if (!mailboxes.has(d)) await refreshLocked(d);
        let ordinal = nextOrdinal.get(d)!;
        while (ordinal >= (reservedUpTo.get(d) ?? 0)) {
            const block = Math.floor(ordinal / BLOCK);
            const held = await writeOnce(store, `${RESERVED}${d}/${String(block).padStart(16, '0')}`, Buffer.from(relay.writer));
            if (held !== 'different') reservedUpTo.set(d, (block + 1) * BLOCK);
            else ordinal = (block + 1) * BLOCK;
        }
        nextOrdinal.set(d, ordinal + 1);
        return ordinal;
    }

    /** At start, and hourly: every mailbox is read again, and requests older than 30 days are deleted (§7.6). */
    async function sweep(): Promise<void> {
        // A device whose copies are all missing still has intents: it is found from them too.
        const listed = [
            ...(await store.list('requests/')).map((key) => key.split('/')[1]!),
            ...(await store.list(INTENTS_PREFIX)).map((key) => key.split('/')[2]!),
        ];
        for (const d of new Set([...listed, ...mailboxes.keys()].filter((id) => isId(id)))) {
            await relay.deviceLocks.run(d, async () => {
                const mailbox = await refreshLocked(d);
                for (const [r, entry] of mailbox) {
                    if (entry.received < relay.now() - REQUEST_EXPIRY_MS) {
                        await retire(entry.key);
                        mailbox.delete(r);
                    }
                }
                await compactLocked(d);
            });
        }
    }

    const ids = (d: string | undefined, r?: string): string => {
        if (!isId(d) || (r !== undefined && !isId(r))) throw new HttpError(400, 'That is not a device or request id.');
        return d;
    };

    const routes: Route[] = [
        {
            method: 'POST',
            path: '/v0/requests/:R',
            access: ['active'],
            browser: true,
            body: { kind: 'bytes', limit: 64 * 1024 },
            async handle(call) {
                const r = call.params.R!;
                if (call.principal?.kind !== 'device' || !isId(r) || call.body.length === 0) throw new HttpError(400, 'A request needs an id and its sealed bytes.');
                const d = call.principal.id;
                // Runs under the device's lock (guard), which every revocation takes: nothing is stored after one.
                if (!mailboxes.has(d)) await refreshLocked(d);
                const mailbox = mailboxes.get(d)!;
                const digest = sha256Hex(call.body);
                const known = mailbox.get(r);
                if (known !== undefined) {
                    // §7.6: 409 tells the device its request is stored, so it is said only once that is verified.
                    if ((await store.get(known.key)) !== null) {
                        // A copy found, perhaps one whose write failed after it landed: durable before it is said so.
                        await store.sync(known.key);
                        throw new HttpError(409, 'This request is already stored.');
                    }
                    if ((known.digest ?? digest) !== digest || (await writeOnce(store, known.key, call.body)) === 'different') {
                        throw new HttpError(503, 'This request is not stored yet; try again.', { 'Retry-After': '5' });
                    }
                    mailbox.set(r, { ...known, digest });
                    return { status: 201 };
                }
                if (!sent.admit(d, relay.now())) throw new HttpError(429, 'Too many requests; wait and try again.');
                if (mailbox.size >= MAX_PENDING) throw new HttpError(507, 'Too many requests are waiting for the Mac.');
                const deadCount = deadAbove.get(d) ?? (await countDeadLocked(d));
                if (mailbox.size + deadCount >= MAX_NAMES) {
                    throw new HttpError(507, 'Too many requests wait behind an older one; the Mac must collect it first.');
                }
                const ordinal = await takeOrdinalLocked(d);
                const key = `requests/${d}/${pad(ordinal)}-${r}`;
                let written;
                try {
                    written = await writeOnce(store, key, call.body);
                } catch (error) {
                    // Its intent may be durable and its copy may still land: the name and bytes stay this request's,
                    // so a retry with other bytes is refused rather than stored under another ordinal (invariant 1).
                    mailbox.set(r, { ordinal, key, received: relay.now(), digest });
                    throw error;
                }
                if (written === 'different') {
                    throw new HttpError(503, 'This request could not be stored; try again.', { 'Retry-After': '5' });
                }
                mailbox.set(r, { ordinal, key, received: relay.now(), digest });
                return { status: 201 };
            },
        },
        {
            method: 'GET',
            path: '/v0/requests/:D',
            access: ['owner'],
            browser: false,
            async handle(call) {
                const d = ids(call.params.D);
                const limit = parseUnsigned(call.query.get('limit') ?? '25') ?? 0;
                const after = parseUnsigned(call.query.get('after') ?? '0');
                if (limit < 1 || limit > 100 || after === null) throw new HttpError(400, 'The limit must be from 1 to 100, and after an ordinal.');
                const mailbox = await relay.deviceLocks.run(d, () => refreshLocked(d));
                const listed = [...mailbox].filter(([, e]) => e.ordinal > after).sort(([, a], [, b]) => a.ordinal - b.ordinal);
                // Ordinals are never given twice, but a page never ends between equal ones either: `after` could
                // then skip a request.
                let end = Math.min(limit, listed.length);
                while (end < listed.length && listed[end]![1].ordinal === listed[end - 1]![1].ordinal) end++;
                const page = listed.slice(0, end);
                return {
                    status: 200,
                    json: {
                        requests: page.map(([r, e]) => ({ request_id: r, ordinal: e.ordinal, received_at: formatTime(e.received) })),
                        next: listed.length > end ? page[page.length - 1]![1].ordinal : null,
                    },
                };
            },
        },
        {
            method: 'GET',
            path: '/v0/requests/:D/:R',
            access: ['owner'],
            browser: false,
            async handle(call) {
                const entry = mailboxes.get(ids(call.params.D, call.params.R))?.get(call.params.R!);
                const bytes = entry === undefined ? null : await store.get(entry.key);
                if (bytes === null) throw new HttpError(404, 'There is no such request.');
                return { status: 200, bytes };
            },
        },
        {
            method: 'DELETE',
            path: '/v0/requests/:D/:R',
            access: ['owner'],
            browser: false,
            async handle(call) {
                const d = ids(call.params.D, call.params.R);
                await relay.deviceLocks.run(d, async () => {
                    if (!mailboxes.has(d)) await refreshLocked(d);
                    const r = call.params.R!;
                    // The request's name: remembered, or else found in the bucket, so a retry after a failure never
                    // answers from memory alone.
                    const key = mailboxes.get(d)?.get(r)?.key ?? (await findKey(d, r));
                    if (key !== null) {
                        // Acknowledged only once the tombstone is durable; only then does it leave the mailbox, and
                        // the copy and intents go. If a later step fails, the tombstone keeps it out of every listing,
                        // and the next listing, sweep or retry finishes it.
                        await store.put(tombstoneOf(key), new Uint8Array());
                        mailboxes.get(d)?.delete(r);
                        await retire(key);
                    }
                    await compactLocked(d);
                });
                return { status: 204 };
            },
        },
    ];
    return { routes, sweep };
}
