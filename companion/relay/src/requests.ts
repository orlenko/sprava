// Request mailboxes (companion-v0 §7.6): each active device posts sealed requests for the owner, who lists them
// by ordinal, reads and deletes them. Stored as `requests/{D}/{ordinal}-{R}` (§7.8).
import { formatTime, isId, parseUnsigned } from './encoding.ts';
import { HttpError, type Route } from './http.ts';
import { SlidingWindow } from './limits.ts';
import type { Devices } from './devices.ts';
import type { Relay } from './relay.ts';
import { writeOnce } from './store/store.ts';

const HOUR = 3_600_000;
const PER_HOUR = 120;
const MAX_PENDING = 1000;
export const REQUEST_EXPIRY_MS = 30 * 24 * HOUR;
const RESERVED = 'ordinals/';
const BLOCK = 1024;
const NAME = /^requests\/([A-Za-z0-9_-]{22})\/([0-9]{16})-([A-Za-z0-9_-]{22})$/;

interface Entry {
    ordinal: number;
    key: string;
    received: number;
}

export function requests(relay: Relay, devices: Devices) {
    const { store } = relay;
    /** Per device, R → its stored copy. Rebuilt from the bucket at start and at every owner listing (§7.8). */
    const mailboxes = new Map<string, Map<string, Entry>>();
    const nextOrdinal = new Map<string, number>();
    const sent = new SlidingWindow(HOUR, PER_HOUR);

    /** Per device, the end (exclusive) of the block of ordinals this process reserved and may use. */
    const reservedUpTo = new Map<string, number>();

    /**
     * Reads a device's mailbox from the bucket. Two copies of one R keep the lower ordinal; the other goes. The
     * first read in this process also starts above every block of ordinals an earlier process reserved, so no
     * ordinal it may have used, even for a write still to land, is ever given again.
     */
    async function refresh(d: string): Promise<Map<string, Entry>> {
        const mailbox = new Map<string, Entry>();
        let highest = 0;
        for (const { key, modified } of await store.listTimes(`requests/${d}/`)) {
            const match = NAME.exec(key);
            if (match === null || match[1] !== d) continue;
            const ordinal = Number(match[2]);
            highest = Math.max(highest, ordinal);
            if (mailbox.has(match[3]!)) await store.delete(key); // the listing is in ordinal order
            else mailbox.set(match[3]!, { ordinal, key, received: modified });
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

    /**
     * §7.6: the next ordinal, taken before the write so a write of unknown outcome never shares its ordinal. Its
     * block is reserved durably first (`ordinals/{D}/{block}`, written once, empty), so a later process starts
     * above it.
     */
    async function takeOrdinal(d: string): Promise<number> {
        if (!mailboxes.has(d)) await refresh(d);
        const ordinal = nextOrdinal.get(d)!;
        if (ordinal >= (reservedUpTo.get(d) ?? 0)) {
            const block = Math.floor(ordinal / BLOCK);
            await writeOnce(store, `${RESERVED}${d}/${String(block).padStart(16, '0')}`, new Uint8Array());
            reservedUpTo.set(d, (block + 1) * BLOCK);
        }
        nextOrdinal.set(d, ordinal + 1);
        return ordinal;
    }

    /** At start, and hourly: every mailbox is read again, and requests older than 30 days are deleted (§7.6). */
    async function sweep(): Promise<void> {
        const ids = new Set((await store.list('requests/')).map((key) => key.split('/')[1]!).filter((d) => isId(d)));
        for (const d of ids) {
            await relay.lock.run(async () => {
                for (const [r, entry] of await refresh(d)) {
                    if (entry.received < relay.now() - REQUEST_EXPIRY_MS) {
                        await store.delete(entry.key);
                        mailboxes.get(d)!.delete(r);
                    }
                }
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
                return relay.lock.run(async () => {
                    // Under the creation lock, which a revocation also takes: nothing is stored after the marker.
                    if (await devices.revokedLocked(d)) throw new HttpError(401, 'A valid token is required.');
                    if (!mailboxes.has(d)) await refresh(d);
                    const mailbox = mailboxes.get(d)!;
                    if (mailbox.has(r)) throw new HttpError(409, 'This request is already stored.');
                    if (!sent.admit(d, relay.now())) throw new HttpError(429, 'Too many requests; wait and try again.');
                    if (mailbox.size >= MAX_PENDING) throw new HttpError(507, 'Too many requests are waiting for the Mac.');
                    const ordinal = await takeOrdinal(d);
                    const key = `requests/${d}/${String(ordinal).padStart(16, '0')}-${r}`;
                    // A late write from before a restart can only be this same request, with the same bytes (§7.6).
                    if ((await writeOnce(store, key, call.body)) === 'different') throw new HttpError(409, 'This request is already stored.');
                    mailbox.set(r, { ordinal, key, received: relay.now() });
                    return { status: 201 };
                });
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
                const mailbox = await relay.lock.run(() => refresh(d));
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
                await relay.lock.run(async () => {
                    const entry = mailboxes.get(d)?.get(call.params.R!);
                    if (entry !== undefined) await store.delete(entry.key);
                    mailboxes.get(d)?.delete(call.params.R!);
                });
                return { status: 204 };
            },
        },
    ];
    return { routes, sweep };
}
