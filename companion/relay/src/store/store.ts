// What the relay keeps, and the rules every object follows (companion-v0 §7.8): each object is either write-once,
// with content fixed by its first writer, or informative and never used to decide anything.
import { sameBytes, sha256Hex } from '../encoding.ts';

/** A flat key-value store of bytes: a folder on disk, or an S3-compatible bucket. */
export interface Store {
    /** The bytes under `key`, or null when there is none. */
    get(key: string): Promise<Uint8Array | null>;
    has(key: string): Promise<boolean>;
    /** Writes or replaces. Only for informative objects (§7.8). */
    put(key: string, body: Uint8Array): Promise<void>;
    /**
     * Writes only if absent, as far as the backend can tell: false when it saw the key exists. Some S3-compatible
     * stores overwrite anyway (§6, step 5), so callers rely on the creation lock, never on this alone.
     */
    putIfAbsent(key: string, body: Uint8Array): Promise<boolean>;
    /**
     * Makes an object that exists durable before it is acknowledged again: a write whose last step failed may have
     * left it readable but not yet safe from a power loss.
     */
    sync(key: string): Promise<void>;
    /** Deletes; a missing key is not an error. */
    delete(key: string): Promise<void>;
    /** Every key under `prefix`, in ascending byte order. */
    list(prefix: string): Promise<string[]>;
}

/** §6, §7.8: everything lives under the prefix `SPRAVA_INSTANCE/`, so a new instance never sees an old one. */
export function scoped(store: Store, instance: string): Store {
    const root = `${instance}/`;
    return {
        get: (key) => store.get(root + key),
        has: (key) => store.has(root + key),
        put: (key, body) => store.put(root + key, body),
        putIfAbsent: (key, body) => store.putIfAbsent(root + key, body),
        sync: (key) => store.sync(root + key),
        delete: (key) => store.delete(root + key),
        list: async (prefix) => (await store.list(root + prefix)).map((key) => key.slice(root.length)),
    };
}

/** One in-process lock: callers run one at a time, in arrival order. The relay runs as one instance (§7). */
export class Mutex {
    #tail: Promise<unknown> = Promise.resolve();

    run<T>(work: () => Promise<T>): Promise<T> {
        const result = this.#tail.then(work);
        this.#tail = result.catch(() => undefined);
        return result;
    }
}

/** A bounded wait for a keyed lock was refused: the queue was full, the deadline passed or the caller left. */
export class LockBusy extends Error {}

interface Waiter {
    start: () => void;
    /** Leaves the queue, refused with LockBusy; set for bounded waiters only. */
    refuse: (() => void) | null;
    kind: 'bounded' | 'plain' | 'priority';
}

/**
 * A lock per key, created on first use and dropped when idle, so memory follows only the keys in use, in arrival
 * order, with two exceptions:
 *
 * - a caller can ask for a bounded wait (a device's calls): at most `limit` such callers queue per key, each leaves
 *   at `waitMs` or when `signal` aborts, and is then refused with LockBusy and never runs;
 * - a priority caller (the owner's revocation of the device) is never queued behind those: it goes ahead of every
 *   waiter but earlier priority ones and waits only for the call running now, whose storage calls are each bounded
 *   (lease.ts). Once it waits, every bounded caller queued is refused, and so is every new one until it has run.
 */
export class KeyedMutex {
    readonly #queues = new Map<string, { busy: boolean; waiting: Waiter[] }>();

    async run<T>(
        key: string,
        work: () => Promise<T>,
        bound?: { limit: number; waitMs: number; signal: AbortSignal },
        priority = false,
    ): Promise<T> {
        const queue = this.#queues.get(key) ?? { busy: false, waiting: [] };
        this.#queues.set(key, queue);
        if (queue.busy) {
            const kind: Waiter['kind'] = priority ? 'priority' : bound !== undefined ? 'bounded' : 'plain';
            if (
                kind === 'bounded' &&
                (bound!.signal.aborted ||
                    queue.waiting.some((w) => w.kind === 'priority') ||
                    queue.waiting.filter((w) => w.kind === 'bounded').length >= bound!.limit)
            ) {
                throw new LockBusy('too many calls are waiting');
            }
            await new Promise<void>((resolve, reject) => {
                const leave = (): void => {
                    const at = queue.waiting.indexOf(waiter);
                    if (at < 0) return;
                    queue.waiting.splice(at, 1);
                    cleanup();
                    reject(new LockBusy('the wait ended'));
                };
                const waiter: Waiter = {
                    start: () => {
                        cleanup();
                        resolve();
                    },
                    refuse: kind === 'bounded' ? leave : null,
                    kind,
                };
                const timer = kind === 'bounded' ? setTimeout(leave, bound!.waitMs) : undefined;
                const cleanup = (): void => {
                    if (timer !== undefined) clearTimeout(timer);
                    bound?.signal.removeEventListener('abort', leave);
                };
                if (kind === 'bounded') bound!.signal.addEventListener('abort', leave);
                if (kind === 'priority') {
                    queue.waiting.splice(queue.waiting.filter((w) => w.kind === 'priority').length, 0, waiter);
                    for (const w of [...queue.waiting]) w.refuse?.();
                } else {
                    queue.waiting.push(waiter);
                }
            });
        } else {
            queue.busy = true;
        }
        try {
            return await work();
        } finally {
            const next = queue.waiting.shift();
            if (next !== undefined) next.start();
            else {
                queue.busy = false;
                if (this.#queues.get(key) === queue) this.#queues.delete(key);
            }
        }
    }

    get size(): number {
        return this.#queues.size;
    }
}

export type WriteOnce = 'created' | 'same' | 'different';

/**
 * Writes this process sent whose outcome it does not know (a timeout, a broken connection, a 5xx): they may still
 * land, at any time. On a store that ignores conditional writes, a later writer of other bytes would see the key
 * absent and be overwritten by the late one; so until the same bytes are confirmed, the key belongs to them.
 */
const uncertain = new WeakMap<Store, Map<string, Uint8Array>>();
const MAX_UNCERTAIN = 10_000;

/**
 * Intents: `intents/{key}/{sha256 of the bytes}`, empty, written and confirmed before the bytes are sent. A write
 * may land long after its process stopped, so an in-memory lock or a timing assumption cannot keep a later writer
 * from storing other bytes under the same key first. The intent can: it is durable before the write is sent, and
 * every writer reads it. A key with an intent for other bytes refuses ours, for as long as that write's outcome
 * may be unknown; two writers that record intents at the same moment both see each other and both refuse. An
 * intent's name is its content, so a late write of one changes nothing, and an intent whose write was never sent
 * only keeps other bytes out, which is safe.
 */
export const INTENTS = 'intents/';
export const intentsOf = (key: string): string => `${INTENTS}${key}/`;

/**
 * The lease name of the process writing through a store (lease.ts), recorded in each intent it writes. Once a
 * process has finished its warm-up, no write a lower-ranked process began can still land (§7.9: every S3 call ends
 * within the warm-up), so an intent of a lower rank whose object is absent will never be followed by its bytes: it
 * is void. Only where contenders legitimately bring other bytes (claims, joins) do void intents block nothing
 * (writeOnce's `voidStale`); everywhere else every intent counts, so the protection holds without the timing.
 * Intents of this process, of a higher rank, or of no recorded rank always count.
 */
const writers = new WeakMap<Store, string>();

export function setWriter(store: Store, lease: string): void {
    writers.set(store, lease);
}

/** The intents of a key that can still be followed by their bytes (see setWriter). */
export async function liveIntents(store: Store, key: string): Promise<string[]> {
    const me = writers.get(store);
    const live: string[] = [];
    for (const name of await store.list(intentsOf(key))) {
        if (me !== undefined) {
            const writer = Buffer.from((await store.get(name)) ?? new Uint8Array()).toString('utf8');
            if (writer !== '' && writer < me) continue;
        }
        live.push(name);
    }
    return live;
}

/**
 * §6 step 5, §7.8: writes a write-once object. Called under the lock that guards the key, so the check and the
 * write are atomic in this process; across processes and restarts, the intents above fix the bytes. 'same' means
 * the stored bytes are identical (a retry, made durable before it is acknowledged), 'different' that other bytes
 * were stored or chosen first.
 */
export async function writeOnce(store: Store, key: string, body: Uint8Array, options: { voidStale?: boolean } = {}): Promise<WriteOnce> {
    const pending = uncertain.get(store) ?? new Map<string, Uint8Array>();
    uncertain.set(store, pending);
    const earlier = pending.get(key);
    if (earlier !== undefined && !sameBytes(earlier, body)) return 'different';
    const confirm = async (stored: Uint8Array | null): Promise<WriteOnce> => {
        if (stored === null || !sameBytes(stored, body)) return 'different';
        // A retry is acknowledged only once the object is durable, which an earlier attempt may not have finished.
        await store.sync(key);
        pending.delete(key);
        return 'same';
    };
    // A dead name takes no bytes again, not even the same ones (invariant 5).
    if (await isDeleted(store, key)) return 'different';
    const existing = await store.get(key);
    if (existing !== null) return confirm(existing);
    const mine = intentsOf(key) + sha256Hex(body);
    const intents = async (): Promise<string[]> => (options.voidStale === true ? liveIntents(store, key) : store.list(intentsOf(key)));
    const others = async (): Promise<boolean> => (await intents()).some((name) => name !== mine);
    if (await others()) return 'different';
    if (earlier === undefined && pending.size >= MAX_UNCERTAIN) throw new Error('too many writes of unknown outcome');
    let created: boolean;
    try {
        await store.put(mine, new Uint8Array(Buffer.from(writers.get(store) ?? '')));
        if (await others()) return 'different';
        created = await store.putIfAbsent(key, body);
    } catch (error) {
        pending.set(key, body);
        throw error;
    }
    pending.delete(key);
    return created ? 'created' : confirm(await store.get(key));
}

/**
 * Tombstones: `tombstones/{key}`, empty. A deletion of an object whose name could be written again (an object
 * the owner deletes) writes the tombstone first, durably, then deletes the object. From then on the name is dead:
 * writeOnce refuses every write to it, and readers that serve such objects check the tombstone, so a copy that a
 * late write brings back is treated as deleted, and a late deletion only removes what is already dead. Intents
 * are never deleted with their object: they keep refusing other bytes for the name as long as the instance lives.
 */
export const TOMBSTONES = 'tombstones/';
export const tombstoneOf = (key: string): string => `${TOMBSTONES}${key}`;

/** Deletes a name for good: its tombstone, durable, then the object. Repeating it is harmless. */
export async function deleteForGood(store: Store, key: string): Promise<void> {
    await store.put(tombstoneOf(key), new Uint8Array());
    await store.delete(key);
}

export function isDeleted(store: Store, key: string): Promise<boolean> {
    return store.has(tombstoneOf(key));
}

/** Deletes every key under a prefix. */
export async function deleteAll(store: Store, prefix: string): Promise<void> {
    for (const key of await store.list(prefix)) await store.delete(key);
}
