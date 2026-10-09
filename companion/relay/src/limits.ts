// Counts in memory over a sliding window: claim failures per address (§6), reads and requests per device (§7.5,
// §7.6). They reset when the relay restarts (§7).

export class SlidingWindow {
    readonly #windowMs: number;
    readonly #limit: number;
    readonly #maxKeys: number;
    readonly #hits = new Map<string, number[]>();

    /** At most `limit` hits per key are kept, and at most `maxKeys` keys: memory stays bounded whatever callers send. */
    constructor(windowMs: number, limit: number, maxKeys = 10_000) {
        this.#windowMs = windowMs;
        this.#limit = limit;
        this.#maxKeys = maxKeys;
    }

    /** Counts one hit for `key` at `now` if it has fewer than `limit` within the window; false, and nothing kept, if not. */
    admit(key: string, now: number): boolean {
        const recent = (this.#hits.get(key) ?? []).filter((t) => t > now - this.#windowMs);
        if (recent.length >= this.#limit) {
            this.#hits.set(key, recent);
            return false;
        }
        recent.push(now);
        this.#hits.delete(key); // re-inserted last: the map's order is then least recently counted first
        this.#hits.set(key, recent);
        if (this.#hits.size > this.#maxKeys) this.#evict(now);
        return true;
    }

    /** Drops keys with nothing left in the window, then the least recently counted ones beyond the bound. */
    #evict(now: number): void {
        for (const [key, times] of this.#hits) {
            if (times.every((t) => t <= now - this.#windowMs)) this.#hits.delete(key);
        }
        for (const key of this.#hits.keys()) {
            if (this.#hits.size <= this.#maxKeys) break;
            this.#hits.delete(key);
        }
    }

    /**
     * Counts one hit for `key` at `now`, always, and returns how many it had within the window before it. Only the
     * last `limit` are kept: enough to say whether the limit was reached, so memory stays bounded.
     */
    record(key: string, now: number): number {
        const recent = (this.#hits.get(key) ?? []).filter((t) => t > now - this.#windowMs);
        const before = recent.length;
        recent.push(now);
        this.#hits.delete(key);
        this.#hits.set(key, recent.slice(-this.#limit));
        if (this.#hits.size > this.#maxKeys) this.#evict(now);
        return before;
    }

    get size(): number {
        return this.#hits.size;
    }

    count(key: string): number {
        return this.#hits.get(key)?.length ?? 0;
    }
}

export const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));
