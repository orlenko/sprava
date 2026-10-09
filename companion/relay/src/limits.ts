// Counts in memory over a sliding window: claim failures per address (§6), reads and requests per device (§7.5,
// §7.6). They reset when the relay restarts (§7).

export class SlidingWindow {
    readonly #windowMs: number;
    readonly #hits = new Map<string, number[]>();

    constructor(windowMs: number) {
        this.#windowMs = windowMs;
    }

    /** Records one hit for `key` at `now` and returns how many hits it has within the window, this one included. */
    hit(key: string, now: number): number {
        const recent = (this.#hits.get(key) ?? []).filter((t) => t > now - this.#windowMs);
        recent.push(now);
        this.#hits.set(key, recent);
        if (this.#hits.size > 10_000) this.#prune(now);
        return recent.length;
    }

    #prune(now: number): void {
        for (const [key, times] of this.#hits) {
            if (times.every((t) => t <= now - this.#windowMs)) this.#hits.delete(key);
        }
    }
}

export const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));
