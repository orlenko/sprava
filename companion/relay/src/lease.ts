// One writer at a time (companion-v0 §7: the relay runs as exactly one instance). A host may start the new
// instance and send it traffic before it stops the old one (DigitalOcean App Platform does, and offers no
// stop-before-start option), and an S3-compatible store cannot refuse a stale writer. So each process takes a
// lease, a write-once object ranked above every earlier one, and fences itself:
//
// - every write is preceded by a check, at most `checkMs` old, that no lease ranks above its own; once one does,
//   the process is fenced for good: every later write fails with 503 and the process exits;
// - a new process that finds an earlier lease waits `warmupMs` before it reads its state or writes anything,
//   longer than the staleness of a check plus the longest write (the S3 client's attempts and retries), so any
//   write the old process began before it noticed has ended first. Until then it serves only health.
//
// A lease's content is empty and its name says everything, so a late write of a lease changes nothing.
import { randomBytes } from 'node:crypto';
import { HttpError } from './http.ts';
import type { Log } from './log.ts';
import type { Store } from './store/store.ts';

export const LEASE_TIMING = { checkMs: 5_000, warmupMs: 50_000 };

export class FencedError extends HttpError {
    constructor() {
        super(503, 'This relay is being replaced; try again shortly.', { 'Retry-After': '5' });
        this.name = 'FencedError';
    }
}

/** A wait that never keeps the process alive by itself. */
export const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms).unref());

const PREFIX = 'leases/';
const NAME = /^leases\/([0-9]{16})-([0-9a-f]{32})$/;

export class Lease {
    readonly name: string;
    readonly #store: Store;
    readonly #log: Log;
    readonly #timing: typeof LEASE_TIMING;
    readonly #onFenced: () => void;
    #fenced = false;
    #checkedAt = -Infinity;
    #timer: NodeJS.Timeout | null = null;

    private constructor(store: Store, name: string, log: Log, timing: typeof LEASE_TIMING, onFenced: () => void) {
        this.#store = store;
        this.name = name;
        this.#log = log;
        this.#timing = timing;
        this.#onFenced = onFenced;
    }

    /** Takes a lease above every listed one. `hadPredecessor` says whether the new process must wait. */
    static async take(store: Store, log: Log, timing = LEASE_TIMING, onFenced: () => void = () => {}): Promise<{ lease: Lease; hadPredecessor: boolean }> {
        const existing = (await store.list(PREFIX)).filter((key) => NAME.test(key));
        const highest = existing.reduce((n, key) => Math.max(n, Number(NAME.exec(key)![1])), 0);
        const name = `${PREFIX}${String(highest + 1).padStart(16, '0')}-${randomBytes(16).toString('hex')}`;
        await store.put(name, new Uint8Array());
        const lease = new Lease(store, name, log, timing, onFenced);
        await lease.check();
        lease.#timer = setInterval(() => void lease.check().catch(() => undefined), timing.checkMs);
        lease.#timer.unref();
        return { lease, hadPredecessor: existing.length > 0 };
    }

    get fenced(): boolean {
        return this.#fenced;
    }

    /** Lists the leases; any that ranks above this one fences this process for good. */
    async check(): Promise<void> {
        const started = performance.now();
        const names = (await this.#store.list(PREFIX)).filter((key) => NAME.test(key));
        if (names.some((other) => other > this.name)) this.#fence();
        else this.#checkedAt = started;
    }

    /** Before every write: throws once fenced, and checks again when the last check is too old. */
    async assertHeld(): Promise<void> {
        if (!this.#fenced && performance.now() - this.#checkedAt > this.#timing.checkMs * 2) await this.check();
        if (this.#fenced) throw new FencedError();
    }

    /** Deletes the leases ranked below this one, once their processes can no longer write. */
    async retireEarlier(): Promise<void> {
        for (const key of await this.#store.list(PREFIX)) {
            if (NAME.test(key) && key < this.name) await this.fenceStore().delete(key);
        }
    }

    /** The store as this process may use it: every write and deletion first asserts the lease. */
    fenceStore(): Store {
        const store = this.#store;
        return {
            get: (key) => store.get(key),
            has: (key) => store.has(key),
            list: (prefix) => store.list(prefix),
            put: async (key, body) => {
                await this.assertHeld();
                return store.put(key, body);
            },
            putIfAbsent: async (key, body) => {
                await this.assertHeld();
                return store.putIfAbsent(key, body);
            },
            sync: async (key) => {
                await this.assertHeld();
                return store.sync(key);
            },
            delete: async (key) => {
                await this.assertHeld();
                return store.delete(key);
            },
        };
    }

    stop(): void {
        if (this.#timer !== null) clearInterval(this.#timer);
        this.#timer = null;
    }

    #fence(): void {
        if (this.#fenced) return;
        this.#fenced = true;
        this.stop();
        this.#log.event('fenced');
        this.#onFenced();
    }
}
