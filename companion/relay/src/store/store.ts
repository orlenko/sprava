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
const intentsOf = (key: string): string => `${INTENTS}${key}/`;

/**
 * §6 step 5, §7.8: writes a write-once object. Called under the lock that guards the key, so the check and the
 * write are atomic in this process; across processes and restarts, the intents above fix the bytes. 'same' means
 * the stored bytes are identical (a retry, made durable before it is acknowledged), 'different' that other bytes
 * were stored or chosen first.
 */
export async function writeOnce(store: Store, key: string, body: Uint8Array): Promise<WriteOnce> {
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
    const existing = await store.get(key);
    if (existing !== null) return confirm(existing);
    const mine = intentsOf(key) + sha256Hex(body);
    const others = async (): Promise<boolean> => (await store.list(intentsOf(key))).some((name) => name !== mine);
    if (await others()) return 'different';
    if (earlier === undefined && pending.size >= MAX_UNCERTAIN) throw new Error('too many writes of unknown outcome');
    let created: boolean;
    try {
        await store.put(mine, new Uint8Array());
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
 * The store as the relay writes it: deleting a key also deletes its intents, after the key, so they do not pile up.
 * A late write of a deleted key can bring it back; every reader treats such a copy as stale (a duplicate request,
 * an older revision, a part without its record).
 */
export function withIntents(store: Store): Store {
    return {
        ...bind(store),
        delete: async (key) => {
            await store.delete(key);
            if (!key.startsWith(INTENTS)) for (const intent of await store.list(intentsOf(key))) await store.delete(intent);
        },
    };
}

function bind(store: Store): Store {
    return {
        get: (key) => store.get(key),
        has: (key) => store.has(key),
        put: (key, body) => store.put(key, body),
        putIfAbsent: (key, body) => store.putIfAbsent(key, body),
        sync: (key) => store.sync(key),
        delete: (key) => store.delete(key),
        list: (prefix) => store.list(prefix),
    };
}

/** Deletes every key under a prefix. */
export async function deleteAll(store: Store, prefix: string): Promise<void> {
    for (const key of await store.list(prefix)) await store.delete(key);
}
