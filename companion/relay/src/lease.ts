// One writer at a time (companion-v0 §7: the relay runs as exactly one instance). A host may start the new
// instance and send it traffic before it stops the old one (DigitalOcean App Platform does, and offers no
// stop-before-start option), and an S3-compatible store cannot refuse a stale writer. So each process takes a
// lease, a write-once object ranked above every earlier one, and fences itself:
//
// - every write is preceded by a check, at most `checkMs` old, that no lease ranks above its own; once one does,
//   the process is fenced for good: every later write fails with 503 and the process exits;
// - every new process waits `warmupMs` and checks again before it reads its state or writes anything, so that a
//   process starting at the same moment is seen and only the higher lease goes on, and an older process has
//   noticed and stopped. Until then it serves only health.
//
// The lease keeps in-memory state single; it is not what keeps a late write from replacing stored bytes. That is
// the intent each write-once object records first (store.ts), which holds whenever the late write lands.
//
// A lease's content is empty and its name says everything, so a late write of a lease changes nothing.
import { randomBytes } from 'node:crypto';
import { HttpError } from './http.ts';
import type { Log } from './log.ts';
import type { Store } from './store/store.ts';

export const LEASE_TIMING = { checkMs: 5_000, warmupMs: 50_000 };

export class InconsistentStore extends Error {}

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
        // §13: the store must show a completed write in every later read and listing. Its own lease is the first
        // thing a process can check that on; a store that does not refuses to start rather than run unfenced.
        if (!(await store.has(name)) || !(await store.list(PREFIX)).includes(name)) {
            throw new InconsistentStore('The store did not show a write it had just completed; it must be strongly consistent.');
        }
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
        else if (!names.includes(this.name)) {
            // Its own lease is gone with none above it: only a store that lost or hid a completed write does that.
            this.#log.event('store-inconsistent');
            this.#fence();
        } else this.#checkedAt = started;
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
            listTimes: (prefix) => store.listTimes(prefix),
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
