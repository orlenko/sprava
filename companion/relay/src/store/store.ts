// What the relay keeps, and the rules every object follows (companion-v0 §7.8): each object is either write-once,
// with content fixed by its first writer, or informative and never used to decide anything.
import { sameBytes } from '../encoding.ts';

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
 * §6 step 5, §7.8: writes a write-once object. Called under the creation lock, so the check and the write are
 * atomic in this process. 'same' means the stored bytes are identical (a retry), 'different' that another
 * writer fixed them first, or that a write of other bytes this process sent may still land. Across a restart
 * or a second instance, the lease (lease.ts) and content that every writer of a key derives alike carry the
 * same guarantee.
 */
export async function writeOnce(store: Store, key: string, body: Uint8Array): Promise<WriteOnce> {
    const pending = uncertain.get(store) ?? new Map<string, Uint8Array>();
    uncertain.set(store, pending);
    const earlier = pending.get(key);
    if (earlier !== undefined && !sameBytes(earlier, body)) return 'different';
    const existing = await store.get(key);
    if (existing !== null) {
        if (!sameBytes(existing, body)) return 'different';
        // A retry is acknowledged only once the object is durable, which an earlier attempt may not have finished.
        await store.sync(key);
        pending.delete(key);
        return 'same';
    }
    if (earlier === undefined && pending.size >= MAX_UNCERTAIN) throw new Error('too many writes of unknown outcome');
    let created: boolean;
    try {
        created = await store.putIfAbsent(key, body);
    } catch (error) {
        pending.set(key, body);
        throw error;
    }
    pending.delete(key);
    if (created) return 'created';
    const stored = await store.get(key);
    if (stored === null || !sameBytes(stored, body)) return 'different';
    await store.sync(key);
    return 'same';
}

/** Deletes every key under a prefix. */
export async function deleteAll(store: Store, prefix: string): Promise<void> {
    for (const key of await store.list(prefix)) await store.delete(key);
}
